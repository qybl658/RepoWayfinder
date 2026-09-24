"""Export one reviewed Python deployment as a movable Windows x64 bundle.

No target code is executed while building. Runtime and dependencies are supplied
by the caller and must have been reviewed and prepared before this step.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Sequence
from urllib.parse import urlsplit


class BundleError(ValueError):
    pass


@dataclass(frozen=True)
class PythonEntrypoint:
    kind: str  # "module", "script", or "adapter_script"
    value: str  # module name, source-relative .py path, or adapter .py filename
    args: tuple[str, ...] = ()
    cwd: str = "."  # source-relative directory


@dataclass(frozen=True)
class ConfigHint:
    field: str
    purpose: str
    application_url: str = ""
    required: bool = False


@dataclass(frozen=True)
class BundleResult:
    zip_path: Path
    sha256: str
    source_revision: str
    mode: str


_DENY_DIRS = {".git", ".venv", "venv", "env", "__pycache__", "node_modules",
              ".reposcout-demo-venv", ".reposcout-venv", ".reposcout-python",
              ".reposcout-tools", "reports", ".pytest_cache", ".mypy_cache", ".tox"}
_DENY_FILES = {".env", "config.toml", "run.md", "deployment_result.json",
               ".reposcout.env", ".reposcout-settings.json", ".reposcout-history.json",
               ".reposcout-source.json"}
_LICENSE_RE = re.compile(r"^(?:license|licence|copying|notice)(?:[._-].*)?$", re.I)
_MODULE_RE = re.compile(r"^[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*$")
_LOCK_RE = re.compile(r"^[A-Za-z0-9_.-]+==[A-Za-z0-9_.+!-]+(?:\s+--hash=sha256:[a-fA-F0-9]{64})*$")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _relative(value: str, *, file: bool = False) -> Path:
    if not value or "\\" in value or "\x00" in value or ":" in value:
        raise BundleError("Bundle paths must be source-relative POSIX paths.")
    pure = PurePosixPath(value)
    if pure.is_absolute() or any(part in {"", ".", ".."} for part in pure.parts):
        if value != "." or file:
            raise BundleError("Path traversal or absolute paths are not allowed.")
    return Path(*pure.parts)


def _safe_member(name: str) -> Path:
    if name.endswith("/"):
        name = name[:-1]
    return _relative(name, file=True)


def _is_private(path: Path) -> bool:
    name = path.name.lower()
    if name in _DENY_FILES or name.endswith((".pem", ".key", ".pfx", ".p12", ".log")):
        return True
    if name.startswith(".env.") and not name.endswith((".example", ".sample", ".template")):
        return True
    if re.search(r"(?:^|[._-])(?:credential|secret|token|password|cookie|session)(?:[._-]|$)", name):
        return True
    return False


def _generated_absolute_config_launcher(path: Path) -> bool:
    if path.name != "修改项目API Key.bat":
        return False
    try:
        with path.open("rb") as stream:
            return stream.read(100).startswith(b"@rem RepoWayfinder target-project configuration entry")
    except OSError:
        return False


def _check_config_template(path: Path) -> None:
    """Do not redistribute filled API keys hidden in an example template."""
    if path.name.lower() not in {".env.example", "config.example.toml"}:
        return
    try:
        text = path.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeError):
        raise BundleError("Project configuration template is not readable UTF-8.") from None
    if len(text) > 2 * 1024 * 1024:
        raise BundleError("Project configuration template is unexpectedly large.")
    for line in text.splitlines():
        match = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)", line)
        if not match:
            continue
        key, raw = match.groups()
        if not re.search(r"(?:^|_)(?:api_?key|token|secret|password|credential|cookie)(?:_|$)", key, re.I):
            continue
        value = raw.split("#", 1)[0].strip().strip("\"'").strip()
        if value.lower() not in {"", "[]", "null", "none", "your_key", "your_api_key",
                                 "your_token", "placeholder", "changeme", "<your-key>", "<api-key>"}:
            raise BundleError("Configuration example contains a non-placeholder sensitive field.")


def _source_revision(source: Path) -> str:
    if (source / ".git").exists():
        result = subprocess.run(["git", "-C", str(source), "rev-parse", "HEAD"],
                                capture_output=True, text=True, timeout=15, check=False)
        revision = result.stdout.strip() if result.returncode == 0 else ""
    else:
        marker = source / ".reposcout-source.json"
        try:
            record = json.loads(marker.read_text(encoding="utf-8-sig")) if marker.is_file() else {}
            revision = str(record.get("source_revision") or record.get("revision") or "")
        except (OSError, ValueError):
            revision = ""
    if not re.fullmatch(r"[0-9a-fA-F]{40}", revision):
        raise BundleError("A fixed 40-character source revision is required.")
    return revision.lower()


def _verify_plan_evidence(source: Path, report: dict) -> None:
    evidence = report.get("plan_evidence")
    if not isinstance(evidence, dict) or not evidence:
        raise BundleError("Report planning evidence is missing.")
    for name, expected in evidence.items():
        rel = _relative(str(name), file=True)
        current = source / rel
        if current.is_symlink() or source not in current.resolve().parents:
            raise BundleError("Report planning input escaped the checkout.")
        actual = _sha256(current) if current.is_file() else "missing"
        if actual != expected:
            raise BundleError("Report planning inputs changed after deployment.")


def _sanitize_git_config_template(path: Path) -> bool:
    """Clear upstream example secrets from a fixed Git archive before redistribution."""
    if path.name.lower() not in {".env.example", "config.example.toml"}:
        return False
    content = path.read_text(encoding="utf-8-sig")
    lines = []
    changed = False
    for line in content.splitlines(keepends=True):
        match = re.match(r"(\s*[A-Za-z_][A-Za-z0-9_]*\s*=\s*)(.*?)(\r?\n)?$", line)
        if match:
            key = match.group(1).split("=", 1)[0].strip()
            if re.search(r"(?:^|_)(?:api_?key|token|secret|password|credential|cookie)(?:_|$)", key, re.I):
                raw = match.group(2)
                value = raw.split("#", 1)[0].strip().strip("\"'").strip()
                if value.lower() not in {"", "[]", "null", "none", "your_key", "your_api_key",
                                         "your_token", "placeholder", "changeme", "<your-key>", "<api-key>"}:
                    line = match.group(1) + '""' + (match.group(3) or "")
                    changed = True
        lines.append(line)
    if changed:
        path.write_text("".join(lines), encoding="utf-8")
    return changed


def _copy_source(source: Path, target: Path, sanitized_templates: list[str]) -> list[str]:
    if (source / ".git").exists():
        target.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="repowayfinder-source-") as temporary:
            archive = Path(temporary) / "source.zip"
            result = subprocess.run(["git", "-C", str(source), "archive", "--format=zip",
                                     "HEAD", "-o", str(archive)], capture_output=True,
                                    text=True, timeout=120, check=False)
            if result.returncode != 0:
                raise BundleError("Could not archive the fixed Git revision.")
            copied: list[str] = []
            with zipfile.ZipFile(archive) as zipped:
                for member in zipped.infolist():
                    rel = _safe_member(member.filename)
                    if member.is_dir():
                        continue
                    if (member.external_attr >> 16) & 0o170000 == 0o120000:
                        raise BundleError("Git source contains a symlink; review it before export.")
                    if any(part.lower() in _DENY_DIRS for part in rel.parts) or _is_private(rel):
                        continue
                    destination = target / rel
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with zipped.open(member) as input_stream, destination.open("wb") as output_stream:
                        shutil.copyfileobj(input_stream, output_stream)
                    if _generated_absolute_config_launcher(destination):
                        destination.unlink()
                        continue
                    if _sanitize_git_config_template(destination):
                        sanitized_templates.append(rel.as_posix())
                    _check_config_template(destination)
                    copied.append(rel.as_posix())
            if not any("/" not in name and _LICENSE_RE.match(name) for name in copied):
                raise BundleError("A project license or notice file is required for this export.")
            return sorted(copied)
    copied: list[str] = []
    for root, dirs, files in os.walk(source, followlinks=False):
        root_path = Path(root)
        clean_dirs: list[str] = []
        for name in dirs:
            path = root_path / name
            if name.lower() in _DENY_DIRS or name.lower().startswith(".reposcout-"):
                continue
            if path.is_symlink() or getattr(path.stat(), "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
                raise BundleError("Source contains a redirected directory.")
            clean_dirs.append(name)
        dirs[:] = clean_dirs
        for name in files:
            path = root_path / name
            if path.is_symlink() or getattr(path.stat(), "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
                raise BundleError("Source contains a redirected file.")
            if _is_private(path):
                continue
            if _generated_absolute_config_launcher(path):
                continue
            _check_config_template(path)
            rel = path.relative_to(source)
            if any(part.lower() in _DENY_DIRS for part in rel.parts):
                continue
            destination = target / rel
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, destination)
            copied.append(rel.as_posix())
    if not any("/" not in name and _LICENSE_RE.match(name) for name in copied):
        raise BundleError("A project license or notice file is required for this export.")
    return sorted(copied)


def _extract_runtime(archive: Path, destination: Path, expected_sha256: str, version: str) -> None:
    if not re.fullmatch(r"[0-9a-fA-F]{64}", expected_sha256):
        raise BundleError("An official runtime SHA-256 is required.")
    if _sha256(archive) != expected_sha256.lower():
        raise BundleError("Runtime archive SHA-256 mismatch.")
    if not re.fullmatch(r"3\.\d{1,2}\.\d{1,2}", version):
        raise BundleError("Use a pinned Python 3.x runtime version.")
    major, minor, _ = version.split(".")
    if major != "3":
        raise BundleError("Only Python 3 is supported.")
    with zipfile.ZipFile(archive) as zipped:
        for member in zipped.infolist():
            rel = _safe_member(member.filename)
            if member.is_dir():
                continue
            if (member.external_attr >> 16) & 0o170000 == 0o120000:
                raise BundleError("Runtime archive symlinks are not supported.")
            output = destination / rel
            output.parent.mkdir(parents=True, exist_ok=True)
            with zipped.open(member) as source_stream, output.open("wb") as target_stream:
                shutil.copyfileobj(source_stream, target_stream)
    pth = destination / f"python{major}{minor}._pth"
    for required in (destination / "python.exe", destination / f"python{major}{minor}.zip", pth):
        if not required.is_file():
            raise BundleError("Runtime is not a matching Windows embeddable Python archive.")
    existing = pth.read_text(encoding="utf-8-sig")
    pth.write_text(existing.rstrip() + "\nsite-packages\n..\\..\\source\n", encoding="utf-8")


def _validate_lock(lock_path: Path | None, dependency_tree: Path | None) -> str:
    if dependency_tree is None:
        return ""
    if lock_path is None or not lock_path.is_file():
        raise BundleError("Prepared dependencies require an exact requirements lock file.")
    content = lock_path.read_text(encoding="utf-8-sig")
    pins = 0
    for line in content.splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and not _LOCK_RE.fullmatch(stripped):
            raise BundleError("Requirements must use exact package==version pins with optional SHA-256 hashes.")
        if stripped and not stripped.startswith("#"):
            pins += 1
    if pins == 0:
        raise BundleError("Prepared dependencies require at least one exact package pin.")
    return content


def _copy_dependencies(source: Path | None, destination: Path) -> None:
    if source is None:
        return
    if not source.is_dir():
        raise BundleError("Prepared dependency tree is missing.")
    for root, dirs, files in os.walk(source, followlinks=False):
        root_path = Path(root)
        dirs[:] = [name for name in dirs if name.lower() not in {"__pycache__", "scripts", "bin"}]
        for name in dirs + files:
            path = root_path / name
            if path.is_symlink() or getattr(path.stat(), "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
                raise BundleError("Prepared dependencies contain a redirected path.")
        for name in files:
            rel = (root_path / name).relative_to(source)
            if name.lower() == "direct_url.json" or any(part.lower() in {"__pycache__", "scripts", "bin"} for part in rel.parts):
                continue
            if rel.as_posix() == "coloredlogs.pth":
                expected = ('import os; exec(\'try: __import__("coloredlogs").auto_install() '
                            'if os.environ.get("COLOREDLOGS_AUTO_INSTALL") else None\\n'
                            'except ImportError: pass\')')
                if (root_path / name).read_text(encoding="utf-8").strip() != expected:
                    raise BundleError("Prepared coloredlogs startup hook differs from the reviewed wheel.")
                continue
            if name.lower().endswith((".pth", ".exe", ".bat", ".cmd", ".ps1")) or (
                _is_private(rel) and rel.suffix.lower() not in {".py", ".pyi"}
                and rel.as_posix() != "certifi/cacert.pem"
            ):
                raise BundleError("Prepared dependencies contain a startup hook or private file.")
            output = destination / rel
            output.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(root_path / name, output)


def _ps_literal(value: str) -> str:
    if "\r" in value or "\n" in value or "\x00" in value:
        raise BundleError("Entrypoint arguments cannot contain control characters.")
    if re.search(r"(?<![A-Za-z0-9])[A-Za-z]:[\\/]", value) or value.startswith("\\\\") or "%USERPROFILE%" in value.upper():
        raise BundleError("Entrypoint arguments must not contain build-machine paths.")
    return "'" + value.replace("'", "''") + "'"


def _write_launchers(stage: Path, entrypoint: PythonEntrypoint, mode: str,
                     has_config: bool, hints: Sequence[ConfigHint]) -> None:
    args = ", ".join(_ps_literal(item) for item in entrypoint.args)
    entry = _ps_literal(entrypoint.value)
    cwd = _ps_literal(entrypoint.cwd)
    if entrypoint.kind == "module":
        run = "& $python -I -m " + entry + " @entryArgs"
    elif entrypoint.kind == "adapter_script":
        run = "& $python -I (Join-Path (Join-Path $root 'adapter') " + entry + ") @entryArgs"
    else:
        run = "& $python -I (Join-Path $source " + entry + ") @entryArgs"
    setup = [
        "$ErrorActionPreference = 'Stop'",
        "$root = Split-Path -Parent $MyInvocation.MyCommand.Path",
        "$pythonRoot = Join-Path $root 'runtime\\python'",
    ]
    if mode == "bootstrap":
        setup += [
            "$archive = Join-Path $root 'payload\\python-runtime.zip'",
            "$expected = " + _ps_literal((stage / "payload" / "python-runtime.sha256").read_text().strip()),
            "$sha = [Security.Cryptography.SHA256]::Create()",
            "try { $actual = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($archive))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }",
            "if ($actual -ne $expected) { throw '包内运行环境校验失败，请重新解压原始 ZIP。' }",
            "if (-not (Test-Path -LiteralPath (Join-Path $pythonRoot '.bundle-ready') -PathType Leaf)) {",
            "  $runtimeDir = Join-Path $root 'runtime'",
            "  New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null",
            "  $temporary = Join-Path $runtimeDir ('python.pending-' + [guid]::NewGuid().ToString('N'))",
            "  Add-Type -AssemblyName System.IO.Compression.FileSystem",
            "  [IO.Compression.ZipFile]::ExtractToDirectory($archive, $temporary)",
            "  if (-not (Test-Path -LiteralPath (Join-Path $temporary 'python.exe') -PathType Leaf)) { throw '包内 Python 解压不完整。' }",
            "  Set-Content -LiteralPath (Join-Path $temporary '.bundle-ready') -Value $expected -Encoding ascii",
            "  if (Test-Path -LiteralPath $pythonRoot) { Move-Item -LiteralPath $pythonRoot -Destination (Join-Path $runtimeDir ('python.previous-' + [guid]::NewGuid().ToString('N'))) }",
            "  Move-Item -LiteralPath $temporary -Destination $pythonRoot",
            "}",
        ]
    setup += [
        "$source = Join-Path $root 'source'",
        "foreach ($pair in @(@('.env.example','.env'), @('config.example.toml','config.toml'))) {",
        "  $template = Join-Path $source $pair[0]",
        "  $localConfig = Join-Path $source $pair[1]",
        "  if ((Test-Path -LiteralPath $template -PathType Leaf) -and -not (Test-Path -LiteralPath $localConfig)) { Copy-Item -LiteralPath $template -Destination $localConfig }",
        "}",
    ]
    setup += [
        "if (-not (Test-Path -LiteralPath (Join-Path $pythonRoot 'python.exe') -PathType Leaf)) { throw '包内 Python 缺失，请重新解压原始 ZIP。' }",
        "Write-Host '运行环境已准备好。'",
    ]
    (stage / "setup.ps1").write_text("\n".join(setup) + "\n", encoding="utf-8-sig")
    launch = [
        "$ErrorActionPreference = 'Stop'",
        "$root = Split-Path -Parent $MyInvocation.MyCommand.Path",
        "$python = Join-Path $root 'runtime\\python\\python.exe'",
        "if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw '请先双击 1-首次配置环境.bat。' }",
        "$source = Join-Path $root 'source'",
        "Set-Location -LiteralPath (Join-Path $source " + cwd + ")",
        "$entryArgs = @(" + args + ")",
        "Write-Host '项目正在运行；关闭本窗口或按 Ctrl+C 停止。'",
        run,
        "exit $LASTEXITCODE",
    ]
    (stage / "start.ps1").write_text("\n".join(launch) + "\n", encoding="utf-8-sig")
    _bat(stage / "1-首次配置环境.bat", "setup.ps1")
    _bat(stage / "2-启动项目.bat", "start.ps1")
    if has_config:
        config = [
            "$ErrorActionPreference = 'Stop'",
            "$root = Split-Path -Parent $MyInvocation.MyCommand.Path",
            "$python = Join-Path $root 'runtime\\python\\python.exe'",
            "if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw '请先双击 1-首次配置环境.bat。' }",
            "Write-Host '项目配置提示：只填写当前需要的功能；留空保留已有值。'",
            *["Write-Host " + _ps_literal(f"{hint.field}：{hint.purpose}（{'必需' if hint.required else '可选'}）" +
                                            (f" 申请入口：{hint.application_url}" if hint.application_url else ""))
              for hint in hints],
            "& $env:SystemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\\project_configuration.ps1') -Root (Join-Path $root 'source') -PythonExecutable $python -Language zh-CN",
            "exit $LASTEXITCODE",
        ]
        (stage / "config.ps1").write_text("\n".join(config) + "\n", encoding="utf-8-sig")
        _bat(stage / "配置项目密钥.bat", "config.ps1")


def _bat(path: Path, script: str) -> None:
    body = ["@echo off", "chcp 65001 >nul", "setlocal", "set \"SCRIPT_DIR=%~dp0\"",
            '"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%' + script + '"',
            "set \"CODE=%ERRORLEVEL%\"", "if not \"%CODE%\"==\"0\" (",
            "  echo 操作未完成，请查看上方原因。", "  pause", ")", "exit /b %CODE%"]
    path.write_bytes(("\r\n".join(body) + "\r\n").encode("utf-8"))


def _add_config_helper(stage: Path, hints: Sequence[ConfigHint],
                       sanitized_templates: list[str]) -> bool:
    source = stage / "source"
    if not any((source / name).is_file() for name in (".env.example", "config.example.toml")):
        if hints:
            raise BundleError("Configuration hints require a supported project template.")
        return False
    template_text = "\n".join((source / name).read_text(encoding="utf-8-sig")
                              for name in (".env.example", "config.example.toml")
                              if (source / name).is_file())
    for hint in hints:
        if not re.search(r"(?m)^\s*" + re.escape(hint.field) + r"\s*=", template_text):
            activated = False
            for name in (".env.example", "config.example.toml"):
                template = source / name
                if not template.is_file():
                    continue
                content = template.read_text(encoding="utf-8-sig")
                pattern = r"(?m)^(\s*)#\s*" + re.escape(hint.field) + r"\s*=.*$"
                revised, count = re.subn(pattern, lambda m: m.group(1) + hint.field + '=\"\"',
                                         content, count=1)
                if count:
                    template.write_text(revised, encoding="utf-8")
                    if name not in sanitized_templates:
                        sanitized_templates.append(name)
                    activated = True
                    break
            if not activated:
                raise BundleError("Configuration hint does not match an active or commented project template field.")
    dependency = stage / "runtime" / "python" / "site-packages" / "dotenv"
    if not dependency.is_dir():
        raise BundleError("Target configuration templates require prepared python-dotenv in the bundle.")
    helper_root = Path(__file__).resolve().parent
    tools = stage / "tools"
    tools.mkdir()
    for filename in ("project_config.py", "project_configuration.ps1"):
        shutil.copy2(helper_root / filename, tools / filename)
    if hints:
        lines = ["# 项目配置字段说明", "", "先运行 `1-首次配置环境.bat`，再双击 `配置项目密钥.bat`。只填写需要启用的功能，留空保留已有值。", ""]
        for hint in hints:
            lines.append(f"- `{hint.field}`（{'必需' if hint.required else '可选'}）：{hint.purpose}" +
                         (f"；申请入口：{hint.application_url}" if hint.application_url else ""))
        (tools / "配置字段说明.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return True


def _validate_hints(hints: Sequence[ConfigHint]) -> None:
    for hint in hints:
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,99}", hint.field):
            raise BundleError("Configuration field name is invalid.")
        if not hint.purpose or len(hint.purpose) > 300 or any(c in hint.purpose for c in "\r\n\x00"):
            raise BundleError("Configuration purpose must be short plain text.")
        if hint.application_url:
            if any(c in hint.application_url for c in "\r\n\x00"):
                raise BundleError("Configuration application link contains control characters.")
            url = urlsplit(hint.application_url)
            if url.scheme != "https" or not url.hostname or url.username or url.password or url.query or url.fragment:
                raise BundleError("Configuration application link must be a plain HTTPS URL.")


def _copy_dependency_licenses(source: Path, destination: Path) -> None:
    if not source.is_dir():
        raise BundleError("Dependency license folder is missing.")
    found = False
    for path in source.rglob("*"):
        if path.is_symlink() or getattr(path.stat(), "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
            raise BundleError("Dependency licenses contain a redirected path.")
        if not path.is_file():
            continue
        if path.stat().st_size > 2 * 1024 * 1024 or path.suffix.lower() not in {"", ".txt", ".md", ".rst", ".ijg", ".license", ".licence", ".apache", ".bsd", ".python"}:
            raise BundleError("Dependency license folder contains an unexpected file.")
        output = destination / path.relative_to(source)
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, output)
        found = True
    if not found:
        raise BundleError("Dependency license folder is empty.")


def _scan_machine_paths(stage: Path, source: Path, report_path: Path) -> None:
    needles = [str(source), str(report_path), str(Path.home())]
    for path in stage.rglob("*"):
        if not path.is_file() or path.stat().st_size > 2 * 1024 * 1024:
            continue
        raw = path.read_bytes()
        for needle in needles:
            if needle and (needle.encode("utf-8") in raw or needle.encode("utf-16le") in raw):
                raise BundleError("Bundle contains a build-machine path; inspect the reviewed inputs.")


def _safe_plan_text(value: object, source: Path, report_path: Path, *, limit: int = 600) -> str:
    text = str(value)
    if len(text) > limit or any(char in text for char in "\r\n\x00"):
        raise BundleError("Saved deployment plan contains oversized or multiline text.")
    if any(needle.lower() in text.lower() for needle in (str(source), str(report_path), str(Path.home()))):
        raise BundleError("Saved deployment plan contains a build-machine path.")
    if re.search(r"(?<![A-Za-z0-9])[A-Za-z]:[\\/]|\\\\[^\\\s]+\\|/(?:home|Users|mnt|tmp)/", text, re.I):
        raise BundleError("Saved deployment plan contains an absolute machine path.")
    if re.search(r"(?i)(?:api_?key|token|secret|password|credential)\s*=\s*[^\s\"']+", text):
        raise BundleError("Saved deployment plan contains a possible credential value.")
    if re.search(r"https?://[^/\s]+@", text, re.I):
        raise BundleError("Saved deployment plan contains URL credentials.")
    return text


def _write_deployment_plan(stage: Path, report: dict, source: Path,
                           report_path: Path, entrypoint: PythonEntrypoint, mode: str) -> None:
    plan = report["plan"]
    source_name = _safe_plan_text(plan.get("source", "unknown"), source, report_path, limit=100)
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", source_name):
        raise BundleError("Saved deployment plan source is invalid.")
    steps = []
    for raw in plan.get("steps", []):
        if not isinstance(raw, dict):
            raise BundleError("Saved deployment plan step is invalid.")
        steps.append({"type": _safe_plan_text(raw.get("type", ""), source, report_path, limit=60),
                      "purpose": _safe_plan_text(raw.get("purpose", ""), source, report_path, limit=300),
                      "command": _safe_plan_text(raw.get("cmd", ""), source, report_path)})
    exported = {"schema": 1, "project": report["repo"],
                "verified_plan": {"source": source_name, "steps": steps,
                                  "note": "这些是原部署验证步骤；其中的本地测试样例可能未包含在发行包中，不作为本包启动命令。"},
                "bundle_launch": {"mode": mode, "first_setup": "1-首次配置环境.bat",
                                  "start": "2-启动项目.bat", "entrypoint": {
                                      "kind": entrypoint.kind, "value": entrypoint.value,
                                      "args": list(entrypoint.args), "cwd": entrypoint.cwd}},
                "environment": "包内 Python 与依赖；不修改系统 PATH、全局配置或启动项。"}
    (stage / "deployment-plan.json").write_text(
        json.dumps(exported, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _check_entrypoint_in_bundle(stage: Path, entrypoint: PythonEntrypoint) -> None:
    if entrypoint.kind == "adapter_script":
        if not (stage / "adapter" / entrypoint.value).is_file():
            raise BundleError("Reviewed adapter script is absent from the bundle.")
        return
    if entrypoint.kind != "module":
        return
    rel = Path(*entrypoint.value.split("."))
    roots = (stage / "source", stage / "runtime" / "python" / "site-packages")
    for root in roots:
        if (root / rel).with_suffix(".py").is_file() or (root / rel / "__main__.py").is_file():
            return
    raise BundleError("Reviewed Python module entrypoint is absent from source and prepared dependencies.")


def _write_guide(stage: Path, report: dict, mode: str, hints: Sequence[ConfigHint],
                 has_config: bool, entrypoint: PythonEntrypoint) -> None:
    lines = [f"# {report['repo']} — Windows x64 便携包", "",
             "1. 双击 `1-首次配置环境.bat`。可重复运行；只在本文件夹准备包内环境。",
             "2. 双击 `2-启动项目.bat`。保持窗口打开，使用完按 Ctrl+C 或关闭窗口。",
             "", "包内包含项目源码、许可与 Python 运行环境。首次准备不写全局设置或启动项。"]
    if mode == "bootstrap":
        lines.append("首次准备会在本文件夹解压已随包附带的 Python 与依赖，无需联网安装。")
    if entrypoint.kind == "adapter_script":
        lines.append("启动后按窗口提示输入本机文件路径；处理结果保存在本文件夹的 `outputs/`，再次运行会生成新文件。")
    if has_config:
        lines += ["", "## 项目配置", "", "若需启用额外功能，双击 `配置项目密钥.bat`。基础功能可先尝试跳过；密钥只保存在你解压后的项目目录，不随导出包携带。"]
        for hint in hints:
            status = "必需" if hint.required else "可选"
            link = f"；申请入口：{hint.application_url}" if hint.application_url else ""
            lines.append(f"- `{hint.field}`（{status}）：{hint.purpose}{link}")
    lines += ["", "## 来源与许可", "", f"源仓库：{report['repo']}",
              "精确提交与文件 SHA-256 见 `manifest.json`；原项目许可文件在 `source/` 中，运行时与依赖许可在 `licenses/` 中。"]
    (stage / "README-先看我.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def _make_zip(root: Path, output: Path) -> None:
    with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zipped:
        for path in sorted(root.rglob("*")):
            if path.is_file():
                zipped.write(path, path.relative_to(root).as_posix())


def export_python_bundle(
    report_path: Path | str,
    output_zip: Path | str,
    *,
    entrypoint: PythonEntrypoint,
    mode: str,
    runtime_archive: Path | str,
    runtime_sha256: str,
    runtime_version: str,
    expected_revision: str,
    adapter_script: Path | str | None = None,
    dependency_tree: Path | str | None = None,
    requirements_lock: Path | str | None = None,
    dependency_licenses: Path | str | None = None,
    config_hints: Sequence[ConfigHint] = (),
) -> BundleResult:
    """Build a reviewed, fixed-input bundle; never run target project code."""
    if os.name != "nt":
        raise BundleError("This bundle profile currently builds only on Windows.")
    if mode not in {"portable", "bootstrap"}:
        raise BundleError("Mode must be portable or bootstrap.")
    _validate_hints(config_hints)
    report_path = Path(report_path).resolve()
    output_zip = Path(output_zip).resolve()
    if output_zip.exists():
        raise BundleError("Output ZIP already exists; refusing to overwrite it.")
    report = json.loads(report_path.read_text(encoding="utf-8-sig"))
    if report.get("action") != "DEPLOY" or report.get("success") is not True or report.get("deployment_success") is not True:
        raise BundleError("Only a successfully deployed project can be exported.")
    if not isinstance(report.get("plan"), dict) or not report["plan"].get("steps"):
        raise BundleError("A saved deployment plan is required.")
    source = Path(str(report.get("repo_path", ""))).resolve()
    if not source.is_dir() or not re.fullmatch(r"[^/\s]+/[^/\s]+", str(report.get("repo", ""))):
        raise BundleError("Report repository or checkout is missing.")
    if source == output_zip.parent or source in output_zip.parents:
        raise BundleError("Export outside the source checkout.")
    revision = _source_revision(source)
    if not re.fullmatch(r"[0-9a-fA-F]{40}", expected_revision) or revision != expected_revision.lower():
        raise BundleError("Checkout revision differs from the reviewed deployment revision.")
    _verify_plan_evidence(source, report)
    if entrypoint.kind not in {"module", "script", "adapter_script"}:
        raise BundleError("Only explicit Python module or script entrypoints are supported.")
    if entrypoint.kind == "module" and not _MODULE_RE.fullmatch(entrypoint.value):
        raise BundleError("Invalid Python module entrypoint.")
    if entrypoint.kind == "script":
        script = _relative(entrypoint.value, file=True)
        if script.suffix.lower() != ".py" or not (source / script).is_file():
            raise BundleError("Reviewed Python script is missing.")
    if entrypoint.kind == "adapter_script":
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*\.py", entrypoint.value):
            raise BundleError("Adapter script must use a simple Python filename.")
        if adapter_script is None:
            raise BundleError("Reviewed adapter script path is required.")
        adapter_script = Path(adapter_script).resolve()
        if (not adapter_script.is_file() or adapter_script.is_symlink()
                or adapter_script.name != entrypoint.value
                or adapter_script.stat().st_size > 128 * 1024):
            raise BundleError("Reviewed adapter script is missing, redirected, or too large.")
    elif adapter_script is not None:
        raise BundleError("Adapter script was provided for a different entrypoint kind.")
    cwd = _relative(entrypoint.cwd)
    if not (source / cwd).is_dir():
        raise BundleError("Entrypoint working directory is missing.")
    for arg in entrypoint.args:
        _ps_literal(arg)
    dependencies = Path(dependency_tree).resolve() if dependency_tree else None
    lock_text = _validate_lock(Path(requirements_lock).resolve() if requirements_lock else None, dependencies)
    archive = Path(runtime_archive).resolve()
    if not archive.is_file():
        raise BundleError("Python embeddable runtime archive is missing.")
    if dependencies is not None and dependency_licenses is None:
        raise BundleError("Prepared dependencies require their redistribution licenses.")
    with tempfile.TemporaryDirectory(prefix="repowayfinder-bundle-") as temporary:
        stage = Path(temporary)
        sanitized_templates: list[str] = []
        copied = _copy_source(source, stage / "source", sanitized_templates)
        if entrypoint.kind == "script" and entrypoint.value not in copied:
            raise BundleError("Entrypoint was excluded from sanitized source files.")
        runtime = stage / "runtime" / "python"
        runtime.mkdir(parents=True)
        _extract_runtime(archive, runtime, runtime_sha256, runtime_version)
        _copy_dependencies(dependencies, runtime / "site-packages")
        if adapter_script is not None:
            adapter_dir = stage / "adapter"
            adapter_dir.mkdir()
            shutil.copy2(adapter_script, adapter_dir / entrypoint.value)
        _check_entrypoint_in_bundle(stage, entrypoint)
        licenses = stage / "licenses"
        licenses.mkdir()
        runtime_license = next((p for p in runtime.iterdir() if _LICENSE_RE.match(p.name)), None)
        if runtime_license is None:
            raise BundleError("Python runtime license stack is missing.")
        shutil.copy2(runtime_license, licenses / runtime_license.name)
        if dependency_licenses:
            license_root = Path(dependency_licenses).resolve()
            _copy_dependency_licenses(license_root, licenses / "dependencies")
        if lock_text:
            (stage / "requirements.lock").write_text(lock_text, encoding="utf-8")
        has_config = _add_config_helper(stage, config_hints, sanitized_templates)
        if adapter_script is not None or has_config:
            owner_license = Path(__file__).resolve().parent / "LICENSE"
            if not owner_license.is_file():
                raise BundleError("RepoWayfinder license is required for bundled helper code.")
            shutil.copy2(owner_license, licenses / "RepoWayfinder-LICENSE")
        if mode == "bootstrap":
            payload = stage / "payload"
            payload.mkdir()
            _make_zip(runtime, payload / "python-runtime.zip")
            (payload / "python-runtime.sha256").write_text(_sha256(payload / "python-runtime.zip"), encoding="ascii")
            shutil.rmtree(runtime)
        _write_launchers(stage, entrypoint, mode, has_config, config_hints)
        _write_guide(stage, report, mode, config_hints, has_config, entrypoint)
        _write_deployment_plan(stage, report, source, report_path, entrypoint, mode)
        _scan_machine_paths(stage, source, report_path)
        files = {path.relative_to(stage).as_posix(): _sha256(path)
                 for path in stage.rglob("*") if path.is_file()}
        manifest = {"schema": 1, "repo": report["repo"], "source_revision": revision,
                    "mode": mode, "platform": "windows-x64", "runtime": f"Python {runtime_version}",
                    "runtime_archive_sha256": runtime_sha256.lower(),
                    "reviewed_plan_source": str(report["plan"].get("source", ""))[:100],
                    "reviewed_plan_sha256": hashlib.sha256(json.dumps(report["plan"], sort_keys=True,
                                                             ensure_ascii=False).encode("utf-8")).hexdigest(),
                    "entrypoint": {"kind": entrypoint.kind, "value": entrypoint.value,
                                   "args": list(entrypoint.args), "cwd": entrypoint.cwd},
                    "source_files": copied, "sanitized_config_templates": sanitized_templates,
                    "files": files}
        (stage / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        output_zip.parent.mkdir(parents=True, exist_ok=True)
        _make_zip(stage, output_zip)
    return BundleResult(output_zip, _sha256(output_zip), revision, mode)
