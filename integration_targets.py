"""Bounded, evidence-based installation routes for host-dependent repositories.

This module never executes repository instructions. Every result names the exact
host boundary reached, so a prepared browser extension is not called installed.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import tomllib
import zipfile
from pathlib import Path
from typing import Any


SKILL_NAME = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$")
MAX_SKILLS = 8
MAX_FILES = 200
MAX_BYTES = 12 * 1024 * 1024


def _read_json(path: Path) -> dict[str, Any]:
    try:
        if path.stat().st_size > 1048576:
            return {}
        value = json.loads(path.read_text(encoding="utf-8-sig"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def _read_browser_manifest(path: Path) -> dict[str, Any]:
    """Chrome permits comments in unpacked manifests; leave quoted URLs intact."""
    try:
        if path.stat().st_size > 1048576:
            return {}
        text = path.read_text(encoding="utf-8-sig")
        if len(text) > 1048576:
            return {}
        output: list[str] = []
        index = 0
        quoted = False
        escaped = False
        while index < len(text):
            character = text[index]
            following = text[index + 1] if index + 1 < len(text) else ""
            if quoted:
                output.append(character)
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == '"':
                    quoted = False
            elif character == '"':
                quoted = True
                output.append(character)
            elif character == "/" and following == "/":
                index = text.find("\n", index)
                if index < 0:
                    break
                output.append("\n")
            elif character == "/" and following == "*":
                end = text.find("*/", index + 2)
                if end < 0:
                    return {}
                output.append("\n" * text[index:end + 2].count("\n"))
                index = end + 1
            else:
                output.append(character)
            index += 1
        value = json.loads("".join(output))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def _skill_name(path: Path) -> str:
    try:
        with path.open("r", encoding="utf-8-sig") as handle:
            text = handle.read(8192)
    except OSError:
        return ""
    if not text.startswith("---\n") and not text.startswith("---\r\n"):
        return ""
    match = re.search(r"^name:\s*['\"]?([^'\"\r\n]+)", text.split("---", 2)[1], re.M)
    name = match.group(1).strip() if match else path.parent.name
    return name if SKILL_NAME.fullmatch(name) else ""


def _runtime_requirements(folder: Path) -> str:
    notes: list[str] = []
    requirements = folder / "requirements.txt"
    if requirements.is_file() and not requirements.is_symlink():
        with requirements.open("r", encoding="utf-8", errors="replace") as handle:
            excerpt = handle.read(65536)
        lines = [line.strip() for line in excerpt.splitlines()
                 if line.strip() and not line.lstrip().startswith("#")]
        if lines:
            notes.append("Python packages in requirements.txt")
    package = _read_json(folder / "package.json")
    if package.get("dependencies") or package.get("optionalDependencies"):
        notes.append("Node packages in package.json")
    return "; ".join(notes)


def application_evidence(root: Path) -> list[str]:
    """Read declared entry points, never import or execute a repository."""
    evidence: list[str] = []
    def text(name: str) -> str:
        path = root / name
        try:
            if path.is_symlink() or root.resolve() not in path.resolve().parents or path.stat().st_size > 1048576:
                return ""
            return path.read_text(encoding="utf-8-sig")
        except (OSError, UnicodeError):
            return ""
    def table(value):
        return value if isinstance(value, dict) else {}
    for filename in ("pyproject.toml", "Cargo.toml"):
        try:
            data = tomllib.loads(text(filename))
            if filename == "pyproject.toml":
                project = table(data.get("project"))
                poetry = table(table(data.get("tool")).get("poetry"))
                if any(isinstance(value, dict) and any(isinstance(v, (str, dict)) and v for v in value.values())
                       for value in (project.get("scripts"), project.get("gui-scripts"), poetry.get("scripts"))):
                    evidence.append("Python entry point")
            elif data.get("package") and (data.get("bin") or text("src/main.rs")):
                evidence.append("Rust application")
        except (ValueError, TypeError):
            pass
    import configparser
    config = configparser.ConfigParser(interpolation=None)
    try:
        config.read_string(text("setup.cfg"))
        if any(config.get("options.entry_points", key, fallback="").strip() for key in ("console_scripts", "gui_scripts")):
            evidence.append("Python setup.cfg entry point")
    except configparser.Error:
        pass
    try:
        package = table(json.loads(text("package.json") or "{}"))
    except ValueError:
        package = {}
    scripts = table(package.get("scripts"))
    dependencies = {**table(package.get("dependencies")), **table(package.get("devDependencies"))}
    if package.get("bin") or (isinstance(scripts.get("start"), str) and scripts["start"].strip()):
        evidence.append("Node entry point")
    elif package.get("main") and "electron" in dependencies:
        evidence.append("Electron entry point")
    if re.search(r"(?m)^web:\s*\S", text("Procfile")):
        evidence.append("Procfile web entry point")
    if text("go.mod") and re.search(r"(?m)^package\s+main\b", text("main.go")):
        evidence.append("Go application")
    # A container or Compose file can be tooling for a collection. Treat it as
    # a competing possible purpose rather than silently making it primary.
    if text("Dockerfile") or any(text(name) for name in ("compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml")):
        evidence.append("container (purpose needs confirmation)")
    return evidence


def repository_purposes(root: Path, candidates: list[dict[str, str]]) -> list[str]:
    """Classify the whole checkout before choosing any artifact adapter."""
    evidence = application_evidence(root)
    kinds = {item["kind"] for item in candidates}
    purposes = ["app"] if evidence else []
    if "browser_extension" in kinds:
        purposes.append("browser")
    if "vscode_extension" in kinds:
        purposes.append("vscode")
    skills = bool(kinds & {"agent_skill", "selection_required"})
    root_skill = any(item["kind"] == "agent_skill" and item.get("relative") == "." for item in candidates)
    strong_app = any("purpose needs confirmation" not in item for item in evidence)
    if skills and (root_skill or not purposes or (not strong_app and purposes == ["app"])):
        purposes.append("skills")
    return purposes or ["app"]


def is_standalone_app_with_bundled_skills(root: Path, candidates: list[dict[str, str]]) -> bool:
    return bool(candidates) and repository_purposes(root, candidates) == ["app"]


def discover_integrations(root: Path, selected_skill: str = "") -> list[dict[str, str]]:
    """Recognize supported artifacts without following arbitrary repository links."""
    root = root.resolve()
    found: list[dict[str, str]] = []
    skill_files: list[Path] = []
    scanned = 0
    for current, dirs, names in os.walk(root, followlinks=False):
        current_path = Path(current)
        scanned += 1
        if scanned > 2500:
            break
        depth = len(current_path.relative_to(root).parts)
        dirs[:] = sorted(d for d in dirs if d not in {".git", "node_modules", ".venv", "venv", "__pycache__", "build"} and not (current_path / d).is_symlink())
        if depth >= 6:
            dirs.clear()
        if "SKILL.md" in names:
            skill_files.append(current_path / "SKILL.md")
        if len(skill_files) > 100:
            break
    readme = ""
    for readme_name in ("README.md", "README.zh-CN.md"):
        readme_path = root / readme_name
        if readme_path.is_file() and not readme_path.is_symlink():
            with readme_path.open("r", encoding="utf-8", errors="replace") as handle:
                readme = handle.read(4000)
            break
    claude_only = bool(re.search(r"claude code skill|requires claude code|a \[claude code\]", readme, re.I)
                       and not re.search(r"\bcodex\b|\bgrok\b|\bcursor\b", readme, re.I))
    for path in skill_files:
        if not path.is_file() or path.is_symlink():
            continue
        name = _skill_name(path)
        if name:
            relative = path.parent.relative_to(root).as_posix()
            runtime_requirements = _runtime_requirements(path.parent)
            if not runtime_requirements and path.parent != root and (path.parent / "scripts").is_dir():
                runtime_requirements = _runtime_requirements(root)
            found.append({"kind": "agent_skill", "name": name, "source": str(path.parent), "relative": relative,
                          "host_hint": "claude,grok" if relative == "." and claude_only else "",
                          "runtime_requirements": runtime_requirements})
    nested_names = {item["name"] for item in found if item["relative"] != "."}
    found = [item for item in found if item["relative"] != "." or item["name"] not in nested_names]
    if selected_skill:
        matches = [item for item in found if item["name"] == selected_skill or item["relative"] == selected_skill]
        found = matches if len(matches) == 1 else [{"kind": "selection_required", "name": selected_skill, "source": str(root), "relative": ".", "available": ", ".join(item["relative"] for item in found[:30])}]
    elif len(found) > MAX_SKILLS:
        found = [{"kind": "selection_required", "name": "skills", "source": str(root), "relative": ".", "available": ", ".join(item["relative"] for item in found[:30])}]

    if selected_skill:
        return found

    for relative in ("dist/manifest.json", "build/manifest.json", "manifest.json", "extension/manifest.json", "browser-extension/manifest.json", "chrome-extension/manifest.json"):
        path = root / relative
        if path.is_symlink() or path.parent.is_symlink() or root not in path.resolve().parents or not path.is_file():
            continue
        data = _read_browser_manifest(path)
        if data.get("manifest_version") in (2, 3) and isinstance(data.get("name"), str):
            referenced = []
            background = data.get("background") or {}
            action = data.get("action") or {}
            if isinstance(background, dict) and background.get("service_worker"):
                referenced.append(str(background["service_worker"]))
            if isinstance(action, dict) and action.get("default_popup"):
                referenced.append(str(action["default_popup"]))
            for script in data.get("content_scripts") or []:
                if isinstance(script, dict):
                    referenced.extend(str(item) for item in script.get("js") or [])
            missing = [item for item in referenced if not (path.parent / item).is_file()]
            permissions = list(data.get("permissions") or []) + list(data.get("host_permissions") or [])
            found.append({"kind": "browser_extension", "name": str(data["name"])[:100], "source": str(path.parent), "relative": path.parent.relative_to(root).as_posix(), "missing_files": ", ".join(missing[:8]), "permissions": ", ".join(str(item) for item in permissions[:16]), "manifest_version": str(data["manifest_version"])})
            break

    package = _read_json(root / "package.json")
    if isinstance(package.get("engines"), dict) and package["engines"].get("vscode"):
        vsix = sorted(p for base in (root, root / "release", root / "dist") if base.is_dir() and not base.is_symlink()
                      for p in base.glob("*.vsix") if p.is_file() and not p.is_symlink() and root in p.resolve().parents)
        source = vsix[0] if vsix else root / "package.json"
        found.append({"kind": "vscode_extension", "name": str(package.get("name") or root.name), "source": str(source), "relative": source.relative_to(root).as_posix()})
    return found


def _known_executable(command: str, paths: list[Path]) -> str:
    found = shutil.which(command)
    if found:
        return found
    return next((str(path) for path in paths if path.is_file()), "")


def validate_dsh_bundle(path: Path) -> Path:
    bundle = path.expanduser().resolve()
    manifest = _read_json(bundle / "PORTABLE-MANIFEST.json")
    if (manifest.get("app") != "dataelement/dsh-desktop v0.9.2"
            or not (bundle / "app/DSH Desktop.exe").is_file()
            or not (bundle / "Start-DSH.ps1").is_file()):
        raise ValueError("请选择解压后的 RepoWayfinder DSH v0.9.2 便携包目录（内含 Start-DSH.ps1 与 app 文件夹）。")
    return bundle


def detect_hosts(user_home: Path | None = None, dsh_bundle: str = "") -> dict[str, dict[str, str]]:
    home = user_home or Path.home()
    result: dict[str, dict[str, str]] = {}
    program_files = Path(os.environ.get("PROGRAMFILES", r"C:\Program Files"))
    local = Path(os.environ.get("LOCALAPPDATA", home / "AppData/Local"))
    codex = _known_executable("codex", [local / "Programs/OpenAI/Codex/bin/codex.exe"])
    grok = _known_executable("grok", [home / ".grok/bin/grok.exe"])
    code = _known_executable("code", [local / "Programs/Microsoft VS Code/bin/code.cmd", program_files / "Microsoft VS Code/bin/code.cmd"])
    claude = _known_executable("claude", [home / ".local/bin/claude.exe", home / ".claude/bin/claude.exe"])
    cursor = _known_executable("cursor", [local / "Programs/Cursor/Cursor.exe", local / "Programs/cursor/Cursor.exe"])
    if codex:
        result["codex"] = {"executable": codex, "skills_dir": str(home / ".agents/skills"), "native_skills_dir": str(Path(os.environ.get("CODEX_HOME", home / ".codex")) / "skills")}
    if grok:
        result["grok"] = {"executable": grok, "skills_dir": str(home / ".agents/skills" if codex or cursor else Path(os.environ.get("GROK_HOME", home / ".grok")) / "skills"), "native_skills_dir": str(Path(os.environ.get("GROK_HOME", home / ".grok")) / "skills")}
    if claude:
        result["claude"] = {"executable": claude, "skills_dir": str(home / ".claude/skills")}
    if cursor:
        result["cursor"] = {"executable": cursor, "skills_dir": str(home / ".agents/skills"), "native_skills_dir": str(home / ".cursor/skills")}
    # Domestic agent hosts use their documented discovery roots.
    for host, commands, paths in (
        ("codebuddy", ("codebuddy",), [local / "Programs/CodeBuddy/CodeBuddy.exe", local / "Programs/CodeBuddy CN/CodeBuddy CN.exe"]),
        ("qoder", ("qodercli", "qoder"), [local / "Programs/Qoder/Qoder.exe"]),
    ):
        executable = next((found for command in commands if (found := _known_executable(command, paths))), "")
        if executable:
            result[host] = {"executable": executable, "skills_dir": str(home / f".{host}/skills")}
    dsh = _known_executable("dsh", [local / "Programs/DSH Desktop/DSH Desktop.exe", program_files / "DSH Desktop/DSH Desktop.exe"])
    if dsh:
        desktop = Path(dsh).name.casefold() == "dsh desktop.exe"
        dsh_home = (Path(os.environ.get("APPDATA", home / "AppData/Roaming")) / "dsh-desktop/harness"
                    if desktop else Path(os.environ.get("DSH_HOME", home / ".dsh")))
        result["dsh"] = {"executable": dsh,
                         "skills_dir": str(Path(os.environ.get("DSH_AGENTS_HOME", home / ".agents")) / "skills"),
                         "native_skills_dir": str(dsh_home / "skills")}
    portable = os.environ.get("REPOWAYFINDER_DSH_BUNDLE", "").strip() or dsh_bundle
    if portable:
        bundle = validate_dsh_bundle(Path(portable))
        executable = bundle / "app/DSH Desktop.exe"
        result["dsh-portable"] = {"executable": str(executable), "skills_dir": str(bundle / "data/Home/.agents/skills"),
                                  "native_skills_dir": str(bundle / "data/Roaming/dsh-desktop/harness/skills")}
    if code:
        result["vscode"] = {"executable": code}
    chrome = _known_executable("chrome", [program_files / "Google/Chrome/Application/chrome.exe", Path(os.environ.get("PROGRAMFILES(X86)", r"C:\Program Files (x86)")) / "Google/Chrome/Application/chrome.exe", local / "Google/Chrome/Application/chrome.exe"])
    edge = _known_executable("msedge", [program_files / "Microsoft/Edge/Application/msedge.exe", Path(os.environ.get("PROGRAMFILES(X86)", r"C:\Program Files (x86)")) / "Microsoft/Edge/Application/msedge.exe"])
    if chrome:
        result["chrome"] = {"executable": chrome, "manage_url": "chrome://extensions"}
    if edge:
        result["edge"] = {"executable": edge, "manage_url": "edge://extensions"}
    return result


def _safe_files(source: Path) -> tuple[list[tuple[Path, Path]], str]:
    """Return files and content digest after rejecting escapes, links, and huge payloads."""
    files: list[tuple[Path, Path]] = []
    size = 0
    digest = hashlib.sha256()
    for current, dirs, names in os.walk(source, followlinks=False):
        current_path = Path(current)
        dirs[:] = sorted(d for d in dirs if d not in {".git", "__pycache__", "node_modules", "reports", "rejected-builds"})
        if any((current_path / d).is_symlink() for d in dirs):
            raise ValueError("Skill contains a symbolic-link directory")
        for name in sorted(names):
            if name in {".env", ".env.local", "修改项目API Key.bat"} or name.startswith(".reposcout"):
                continue
            path = current_path / name
            if path.is_symlink() or not path.is_file():
                raise ValueError("Skill contains a link or special file")
            relative = path.relative_to(source)
            size += path.stat().st_size
            if len(files) >= MAX_FILES or size > MAX_BYTES:
                raise ValueError("Skill exceeds the bounded copy limit")
            data = path.read_bytes()
            digest.update(relative.as_posix().encode("utf-8"))
            digest.update(b"\0")
            digest.update(data)
            files.append((path, relative))
    return files, digest.hexdigest()


def _grok_discovers_skill(target: dict[str, str], destination: Path, name: str) -> bool:
    if not target.get("executable"):
        return False
    try:
        inspected = subprocess.run([target["executable"], "inspect", "--json"], cwd=destination.parent,
                                   capture_output=True, text=True, encoding="utf-8", errors="replace",
                                   timeout=12, check=False)
        if inspected.returncode:
            return False
        data = json.loads(inspected.stdout or "{}")
        expected = destination / "SKILL.md"
        return any((skill.get("source") or {}).get("path") and
                   Path(skill["source"]["path"]).resolve() == expected.resolve() and
                   skill.get("name") == name for skill in data.get("skills") or [])
    except (OSError, TypeError, ValueError, subprocess.TimeoutExpired):
        return False


def _vsix_identity(path: Path) -> str:
    if path.stat().st_size > 100 * 1024 * 1024:
        raise ValueError("VSIX exceeds 100 MiB review limit")
    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        if len(infos) > 5000 or sum(info.file_size for info in infos) > 500 * 1024 * 1024:
            raise ValueError("VSIX expands beyond review limit")
        info = archive.getinfo("extension/package.json")
        if info.file_size > 1048576:
            raise ValueError("VSIX package metadata is too large")
        data = json.loads(archive.read(info).decode("utf-8-sig"))
        if not isinstance(data, dict) or not isinstance(data.get("engines"), dict) or not data["engines"].get("vscode"):
            raise ValueError("VSIX does not declare a VS Code extension")
        publisher = data.get("publisher", "")
        name = data.get("name", "")
        if not (isinstance(publisher, str) and isinstance(name, str) and SKILL_NAME.fullmatch(publisher) and SKILL_NAME.fullmatch(name)):
            raise ValueError("VSIX publisher/name is missing or invalid")
        return f"{publisher}.{name}".lower()


def _vscode_extension_list(executable: str) -> set[str]:
    completed = subprocess.run([executable, "--list-extensions"], capture_output=True, text=True,
                               encoding="utf-8", errors="replace", timeout=25, check=False)
    if completed.returncode:
        raise RuntimeError("VS Code could not list installed extensions")
    return {line.strip().lower() for line in completed.stdout.splitlines() if line.strip()}


def _install_vsix(candidate: dict[str, str], host: dict[str, str]) -> dict[str, str]:
    result = {"kind": "vscode_extension", "name": candidate["name"], "host": "vscode", "source": candidate["source"]}
    try:
        source = Path(candidate["source"])
        extension_id = _vsix_identity(source)
        result["extension_id"] = extension_id
        executable = host["executable"]
        if extension_id in _vscode_extension_list(executable):
            return {**result, "status": "already_installed", "detail": "VS Code already lists this extension ID; existing version preserved."}
        completed = subprocess.run([executable, "--install-extension", str(source)], capture_output=True, text=True,
                                   encoding="utf-8", errors="replace", timeout=90, check=False)
        if completed.returncode:
            return {**result, "status": "failed", "detail": (completed.stdout + completed.stderr)[-1000:]}
        verified = extension_id in _vscode_extension_list(executable)
        return {**result, "status": "host_discovered" if verified else "verification_failed",
                "detail": "VS Code listed the installed extension ID." if verified else "Installer exited successfully but extension ID was absent from VS Code's list."}
    except (OSError, ValueError, KeyError, RuntimeError, zipfile.BadZipFile, subprocess.TimeoutExpired) as exc:
        return {**result, "status": "blocked", "detail": str(exc)}


def _install_skill(candidate: dict[str, str], host: str, target: dict[str, str]) -> dict[str, str]:
    source = Path(candidate["source"])
    destination_root = Path(target["skills_dir"])
    destination = destination_root / candidate["name"]
    result = {"kind": "agent_skill", "name": candidate["name"], "host": host, "destination": str(destination)}
    runtime_requirements = candidate.get("runtime_requirements", "")
    try:
        files, digest = _safe_files(source)
        if destination.exists() or destination.is_symlink():
            if destination.is_symlink() or not destination.is_dir():
                return {**result, "status": "conflict", "detail": "Target path is not a plain directory; preserved unchanged."}
            _, current_digest = _safe_files(destination)
            if current_digest != digest:
                return {**result, "status": "conflict", "detail": "Existing target preserved unchanged."}
            discovered = host == "grok" and _grok_discovers_skill(target, destination, candidate["name"])
            if runtime_requirements:
                return {**result, "status": "dependencies_pending", "sha256": digest, "runtime_requirements": runtime_requirements,
                        "host_discovered": str(discovered), "detail": "Skill files are present, but declared runtime packages were not installed into the host environment."}
            return {**result, "status": "host_discovered" if discovered else "already_installed", "sha256": digest,
                    "detail": "Existing identical target preserved; Grok confirmed discovery." if discovered else "Existing identical target preserved unchanged."}
        destination_root.mkdir(parents=True, exist_ok=True)
        staging = Path(tempfile.mkdtemp(prefix=".rwf-skill-", dir=destination_root))
        try:
            for path, relative in files:
                output = staging / relative
                output.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, output, follow_symlinks=False)
            _, staged_digest = _safe_files(staging)
            if staged_digest != digest:
                raise ValueError("Skill source changed during copy")
            staging.rename(destination)
        finally:
            if staging.exists():
                shutil.rmtree(staging)
        _, installed_digest = _safe_files(destination)
        if installed_digest != digest:
            return {**result, "status": "verification_failed", "detail": "Copied files did not match source."}
        if runtime_requirements:
            discovered = host == "grok" and _grok_discovers_skill(target, destination, candidate["name"])
            return {**result, "status": "dependencies_pending", "sha256": digest, "runtime_requirements": runtime_requirements,
                    "host_discovered": str(discovered), "detail": "Skill files are present, but declared runtime packages were not installed into the host environment."}
        if host == "grok" and _grok_discovers_skill(target, destination, candidate["name"]):
            return {**result, "status": "host_discovered", "sha256": digest, "detail": "Grok inspect listed the installed Skill from this exact path."}
        return {**result, "status": "installed", "sha256": digest, "detail": "Files copied to the host's documented skill discovery directory; host session may need refresh."}
    except (OSError, ValueError) as exc:
        return {**result, "status": "blocked", "detail": str(exc)}


def apply_integrations(candidates: list[dict[str, str]], hosts: dict[str, dict[str, str]], *, allow_vsix_install: bool = False) -> list[dict[str, str]]:
    results: list[dict[str, str]] = []
    for candidate in candidates:
        kind = candidate["kind"]
        if kind == "selection_required":
            results.append({"kind": kind, "name": candidate["name"], "host": "", "status": "selection_required", "detail": "Choose one Skill by name or repository path: " + candidate.get("available", "")})
        elif kind == "agent_skill":
            relative = candidate.get("relative", "")
            if candidate.get("host_hint"):
                eligible = tuple(candidate["host_hint"].split(","))
            elif relative.startswith(".codebuddy/"):
                eligible = ("codebuddy",)
            elif relative.startswith(".qoder/"):
                eligible = ("qoder",)
            elif relative.startswith(".dsh/"):
                eligible = ("dsh", "dsh-portable")
            elif relative.startswith(".codex/"):
                eligible = ("codex",)
            elif relative.startswith(".grok/"):
                eligible = ("grok",)
            elif relative.startswith(".claude/"):
                eligible = ("claude", "grok")
            elif relative.startswith(".cursor/"):
                eligible = ("cursor",)
            else:
                eligible = ("codex", "grok", "claude", "cursor", "codebuddy", "qoder", "dsh", "dsh-portable")
            targets = [host for host in eligible if host in hosts]
            if not targets:
                results.append({"kind": kind, "name": candidate["name"], "host": "", "status": "host_missing", "detail": "No compatible installed agent host detected; no Skill copied."})
            for host in targets:
                target = hosts[host]
                if relative.startswith((".codex/", ".grok/", ".cursor/", ".dsh/")) or (relative.startswith(".claude/") and host == "grok") or (candidate.get("host_hint") and host == "grok"):
                    target = {**target, "skills_dir": target.get("native_skills_dir", target["skills_dir"])}
                results.append(_install_skill(candidate, host, target))
        elif kind == "browser_extension":
            targets = [host for host in ("chrome", "edge") if host in hosts]
            if not targets:
                results.append({"kind": kind, "name": candidate["name"], "host": "", "status": "host_missing", "detail": "Chrome/Edge not detected; browser extension not loaded."})
            for host in targets:
                missing = candidate.get("missing_files", "")
                unsupported = host == "chrome" and candidate.get("manifest_version") == "2"
                status = "unsupported_version" if unsupported else "package_required" if missing else "user_action_required"
                detail = ("Chrome no longer loads Manifest V2 extensions; a V3 version is required." if unsupported
                          else "Extension files missing from this source tree: " + missing if missing
                          else "Open the extension page, review requested permissions, enable Developer mode, choose Load unpacked, and select source. Verify it appears enabled.")
                results.append({"kind": kind, "name": candidate["name"], "host": host, "status": status, "source": candidate["source"], "manage_url": hosts[host]["manage_url"], "detail": detail, "permissions": candidate.get("permissions", ""), "manifest_version": candidate.get("manifest_version", "")})
        elif kind == "vscode_extension":
            host = hosts.get("vscode")
            source = Path(candidate["source"])
            if not host:
                results.append({"kind": kind, "name": candidate["name"], "host": "vscode", "status": "host_missing", "detail": "VS Code CLI not detected."})
            elif source.suffix.lower() != ".vsix":
                results.append({"kind": kind, "name": candidate["name"], "host": "vscode", "status": "package_required", "detail": "VS Code extension source found, but no VSIX package; arbitrary build scripts were not run."})
            elif not allow_vsix_install:
                results.append({"kind": kind, "name": candidate["name"], "host": "vscode", "status": "user_action_required", "source": str(source), "detail": "Review this executable extension package, then install it with VS Code's Install from VSIX action."})
            else:
                results.append(_install_vsix(candidate, host))
    return results
