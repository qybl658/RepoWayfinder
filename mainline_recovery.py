"""Bounded, offline recipe preparation and one-command package mirror proposals.

Derived from the existing Python recovery branch and the MB recovery guards.
These helpers never run a command, contact a registry, or edit source recipes.
"""
from __future__ import annotations

from dataclasses import replace
import hashlib
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
from typing import Any, Mapping


PYPI_MIRROR_URL = "https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple"
NPM_MIRROR_URL = "https://registry.npmmirror.com"
DEBIAN_DOCKER_EOL_REPAIRS = {"bullseye": {"successor": "bookworm", "public_lts_ended": "2026-08-31"}}


def _command_parts(command: str) -> list[str]:
    quote = ""
    for char in command:
        if char in "\r\n`%$":
            return []
        if char in "\"'":
            if not quote:
                quote = char
            elif quote == char:
                quote = ""
        elif not quote and char in "&|;<>":
            return []
    if quote:
        return []
    try:
        parts = shlex.split(command, posix=os.name != "nt")
    except ValueError:
        return []
    return [part[1:-1] if len(part) > 1 and part[0] == part[-1] and part[0] in "\"'" else part for part in parts]


def _render(parts: list[str]) -> str:
    return subprocess.list2cmdline(parts) if os.name == "nt" else shlex.join(parts)


def docker_build_uses_default_dockerfile(step: Any) -> bool:
    parts = _command_parts(step.cmd)
    lowered = [part.lower() for part in parts]
    if lowered[:2] == ["docker", "build"]:
        index = 2
    elif lowered[:3] == ["docker", "buildx", "build"]:
        index = 3
    else:
        return False
    valued = {"-t", "--tag", "--target", "--platform", "--build-arg", "--progress", "--network", "--label", "--cache-from", "--cache-to"}
    switches = {"--pull", "--no-cache", "--quiet", "-q", "--rm", "--force-rm", "--load", "--compress", "--disable-content-trust"}
    contexts = []
    while index < len(parts):
        token = lowered[index]
        if token == "--":
            contexts.extend(parts[index + 1:])
            break
        if token in {"-f", "--file"} or token.startswith("--file=") or (token.startswith("-f") and not token.startswith("--")):
            return False
        if token in valued:
            index += 2
            continue
        if any(token.startswith(option + "=") for option in valued | switches if option.startswith("--")) or token in switches:
            index += 1
            continue
        if token.startswith("-t") and not token.startswith("--"):
            index += 1
            continue
        if token.startswith("-"):
            return False
        contexts.append(parts[index])
        index += 1
    # The root Dockerfile only owns the root build context. Explicit/remote
    # contexts, custom files and unknown Docker options are not rewritten.
    return contexts == ["."] or contexts == ["./"] or contexts == [".\\"]


def _docker_instructions(source: str):
    pending = ""
    for line in source.splitlines(keepends=True):
        if not pending and (not line.strip() or line.lstrip().startswith("#")):
            yield line
            continue
        pending += line
        if not line.rstrip().endswith("\\"):
            yield pending
            pending = ""
    if pending:
        yield pending


def _migrate_recipe(source: str) -> str | None:
    migrated = []
    stages: dict[str, bool] = {}
    current_stage = False
    changed_base = False
    changed_source = False
    base_pattern = re.compile(r"(?is)^(\s*FROM\s+(?:--platform=\S+\s+)?)(\S+)(.*)$")
    apt_entry = re.compile(r"(?i)(\bdeb(?:-src)?\s+(?:\[[^\]\r\n]+\]\s+)?https?://[^\s\"']+/(?:debian|debian-security)/?\s+)(bullseye(?:-security|-updates|-backports)?)(?=\s+main\b)")
    apt_destination = re.compile(r"(?:>{1,2}\s*|\btee\s+(?:-a\s+)?)['\"]?/etc/apt/sources\.list(?:\.d/[^\s'\"]+)?(?:['\"]|\s|$)")
    for instruction in _docker_instructions(source):
        match = base_pattern.match(instruction)
        if match:
            image = match.group(2)
            # A fixed digest cannot be migrated by editing a tag. Reject the
            # complete recipe, including mixed pinned/unpinned build stages.
            if "bullseye" in image.lower() and "@" in image:
                return None
            current_stage = bool(re.search(r"(?:-|:)bullseye$", image, re.IGNORECASE))
            if current_stage:
                if "$" in image:
                    return None
                image = re.sub(r"bullseye$", "bookworm", image, flags=re.IGNORECASE)
                instruction = match.group(1) + image + match.group(3)
                changed_base = True
            else:
                current_stage = stages.get(image.lower(), False)
            alias = re.search(r"(?i)^\s+AS\s+(\S+)", match.group(3))
            if alias:
                stages[alias.group(1).lower()] = current_stage
        elif current_stage and re.match(r"(?i)^\s*RUN\s+", instruction) and "<<" not in instruction:
            # Only active apt-source writes are migrated; comments, filenames,
            # arbitrary shell prose and unrelated stage contents stay intact.
            lines = instruction.splitlines(keepends=True)
            active = "".join(line for line in lines if not line.lstrip().startswith("#"))
            if apt_destination.search(active) and apt_entry.search(active):
                rewritten = []
                for line in lines:
                    if not line.lstrip().startswith("#"):
                        line, count = apt_entry.subn(lambda m: m.group(1) + m.group(2).lower().replace("bullseye", "bookworm", 1), line)
                        changed_source = changed_source or bool(count)
                    rewritten.append(line)
                instruction = "".join(rewritten)
        migrated.append(instruction)
    return "".join(migrated) if changed_base and changed_source else None


def _read_recipe(repo_path: Path, plan: Any) -> tuple[Path, bytes, str] | None:
    if not any(docker_build_uses_default_dockerfile(step) for step in plan.steps):
        return None
    root = repo_path.resolve()
    path = root / "Dockerfile"
    try:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or getattr(metadata, "st_file_attributes", 0) & 0x400 or metadata.st_size > 200_000:
            return None
        original = path.read_bytes()
        repaired = _migrate_recipe(original.decode("utf-8-sig"))
    except (OSError, UnicodeError):
        return None
    return (path, original, repaired) if repaired is not None else None


def detect_eol_debian_dockerfile(repo_path: Path, plan: Any) -> dict[str, str] | None:
    recipe = _read_recipe(repo_path, plan)
    if recipe is None:
        return None
    path, original, _ = recipe
    return {"suite": "bullseye", **DEBIAN_DOCKER_EOL_REPAIRS["bullseye"],
            "dockerfile": str(path), "source_sha256": hashlib.sha256(original).hexdigest()}


def prepare_eol_docker_repair(repo_path: Path, plan: Any, report_dir: Path, *, approved: bool = False,
                              expected_source_sha256: str = "") -> tuple[Any, dict[str, Any] | None, str]:
    recipe = _read_recipe(repo_path, plan)
    if recipe is None:
        return plan, None, ""
    source, original, repaired = recipe
    diagnosis = {"suite": "bullseye", **DEBIAN_DOCKER_EOL_REPAIRS["bullseye"],
                 "dockerfile": str(source), "source_sha256": hashlib.sha256(original).hexdigest()}
    record: dict[str, Any] = {"kind": "docker_base_distribution_eol", "diagnosis": diagnosis,
                              "status": "confirmation_required", "original_repository_modified": False}
    if expected_source_sha256 and diagnosis["source_sha256"] != expected_source_sha256:
        record["status"] = "source_changed"
        return plan, record, "Dockerfile changed after the migration proposal; review the current recipe before continuing."
    if not approved:
        return plan, record, "Debian bullseye public LTS ended on 2026-08-31. Confirm a report-local bookworm Dockerfile migration before continuing."
    report_root = report_dir.resolve()
    root = repo_path.resolve()
    if report_root == root or root in report_root.parents:
        record["status"] = "generation_failed"
        return plan, record, "The Docker repair report directory must be outside the source checkout."
    repair_dir = report_root / "repairs"
    repair_dir.mkdir(parents=True, exist_ok=True)
    if repair_dir.resolve() != repair_dir or getattr(repair_dir.lstat(), "st_file_attributes", 0) & 0x400:
        record["status"] = "generation_failed"
        return plan, record, "The report-local repairs path redirects outside its expected directory."
    encoded = repaired.encode("utf-8")
    digest = hashlib.sha256(encoded).hexdigest()
    path = repair_dir / f"Dockerfile.bookworm-{digest[:16]}"
    # Exclusive creation never overwrites a report-local link or prior bytes.
    try:
        with path.open("xb") as stream:
            stream.write(encoded)
    except FileExistsError:
        if path.is_symlink() or getattr(path.lstat(), "st_file_attributes", 0) & 0x400 or path.read_bytes() != encoded:
            record["status"] = "generation_failed"
            return plan, record, "An existing Docker repair path does not match the proposed recipe."
    if source.read_bytes() != original:
        record["status"] = "source_changed"
        return plan, record, "Dockerfile changed while preparing the repair; review the current recipe before continuing."
    steps = []
    for step in plan.steps:
        if docker_build_uses_default_dockerfile(step):
            parts = _command_parts(step.cmd)
            index = 2 if parts[1].lower() == "build" else 3
            parts[index:index] = ["--file", str(path)]
            step = replace(step, cmd=_render(parts), purpose=step.purpose + "; report-local Debian bookworm repair")
        steps.append(step)
    record.update(status="isolated_repair_created", repair_path=str(path), repair_sha256=digest, replacement="bullseye -> bookworm")
    return replace(plan, steps=steps), record, ""


def _package_command(command: str) -> tuple[list[str], bool, int] | None:
    parts = _command_parts(command)
    if not parts:
        return None
    name = parts[0].replace("\\", "/").rsplit("/", 1)[-1].lower()
    index = 0
    python = False
    if name in {"python", "python.exe", "python3", "py"} and parts[1:3] == ["-m", "pip"]:
        index, python = 3, True
    elif name in {"pip", "pip.exe", "pip3"}:
        index, python = 1, True
    elif name in {"npm", "npm.cmd", "pnpm", "pnpm.cmd", "yarn", "yarn.cmd"}:
        index = 1
    actions = {"install", "download", "wheel"} if python else {"install", "ci", "add"}
    if not index or len(parts) <= index or parts[index] not in actions:
        return None
    return parts, python, index


def _explicit_source(parts: list[str]) -> bool:
    for token in parts:
        lower = token.lower()
        if lower.startswith(("--index", "--extra-index", "--registry", "--find-links", "--no-index", "--trusted-host", "--userconfig", "--globalconfig", "--use-yarnrc")):
            return True
        if (lower.startswith(("-i", "-f")) and not lower.startswith("--")) or "://" in token or lower.startswith("git+"):
            return True
    return False


def _requirements_have_custom_source(parts: list[str], root: Path, visited: set[Path] | None = None) -> bool:
    visited = set() if visited is None else visited
    index = 0
    while index < len(parts):
        token = parts[index]
        filename = ""
        if token in {"-r", "-c", "--requirement", "--constraint"}:
            index += 1
            if index >= len(parts):
                return True
            filename = parts[index]
        elif token.startswith(("--requirement=", "--constraint=")):
            filename = token.split("=", 1)[1]
        elif token.startswith(("-r", "-c")) and not token.startswith("--"):
            filename = token[2:]
        if filename:
            path = (root / filename).resolve()
            if path in visited:
                index += 1
                continue
            if len(visited) >= 20 or (path != root and root not in path.parents):
                return True
            visited.add(path)
            try:
                if path.stat().st_size > 200_000:
                    return True
                content = path.read_text(encoding="utf-8-sig")
            except (OSError, UnicodeError):
                return True
            for line in content.splitlines():
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                try:
                    items = shlex.split(line.rstrip("\\"), posix=True)
                except ValueError:
                    return True
                if _explicit_source(items) or _requirements_have_custom_source(items, path.parent, visited):
                    return True
        index += 1
    return False


def has_custom_package_source(repo_path: Path, python: bool, environ: Mapping[str, str] | None = None) -> bool:
    env = os.environ if environ is None else environ
    normalized = {key.lower(): value for key, value in env.items()}
    keys = {"pip_index_url", "pip_extra_index_url", "pip_config_file", "pip_find_links", "pip_no_index"} if python else {
        "npm_config_registry", "npm_config_userconfig", "npm_config_globalconfig", "yarn_registry", "yarn_npmregistryserver", "pnpm_registry"}
    if any(normalized.get(key) for key in keys):
        return True
    root = repo_path.resolve()
    names = ("pip.ini", "pip.conf") if python else (".npmrc", ".yarnrc", ".yarnrc.yml")
    locations = [root, *root.parents]
    for variable in ("home", "userprofile", "appdata", "programdata", "xdg_config_home", "virtual_env", "prefix", "npm_config_prefix"):
        if normalized.get(variable):
            locations.append(Path(normalized[variable]))
    if python:
        locations.extend([root / ".venv", Path(sys.prefix), Path("/etc"), Path("/etc/xdg")])
        locations.extend(Path(value) for value in normalized.get("xdg_config_dirs", "").split(os.pathsep) if value)
    for location in locations:
        for name in names:
            relatives = (name, f"pip/{name}", f".pip/{name}", f".config/pip/{name}") if python else (name, "etc/npmrc", "npm/etc/npmrc")
            if any(os.path.lexists(location / relative) for relative in relatives):
                return True
    return False


def package_mirror_eligible(command: str, repo_path: Path, *, environ: Mapping[str, str] | None = None) -> bool:
    parsed = _package_command(command)
    if parsed is None:
        return False
    parts, python, index = parsed
    if _explicit_source(parts[index + 1:]) or has_custom_package_source(repo_path, python, environ):
        return False
    return not python or not _requirements_have_custom_source(parts[index + 1:], repo_path.resolve())


def package_mirror_command(command: str, repo_path: Path, *, public_packages_confirmed: bool = False,
                           environ: Mapping[str, str] | None = None) -> str:
    if not public_packages_confirmed or not package_mirror_eligible(command, repo_path, environ=environ):
        return ""
    parts, python, index = _package_command(command)
    parts.insert(index + 1, f"--index-url={PYPI_MIRROR_URL}" if python else f"--registry={NPM_MIRROR_URL}")
    return _render(parts)
