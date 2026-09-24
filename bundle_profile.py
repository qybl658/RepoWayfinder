"""Load an explicit local packaging profile without executing its contents."""
from pathlib import Path
import json

from portable_bundle import ConfigHint, PythonEntrypoint, export_python_bundle


def export_from_profile(report: Path, profile: Path, output: Path):
    profile = profile.resolve()
    if profile.stat().st_size > 131072:
        raise ValueError("Bundle profile exceeds 128 KiB")
    data = json.loads(profile.read_text(encoding="utf-8-sig"))
    required = {"entrypoint", "mode", "runtime_archive", "runtime_sha256", "runtime_version", "expected_revision"}
    optional = {"dependency_tree", "requirements_lock", "dependency_licenses", "config_hints", "adapter_script"}
    if not isinstance(data, dict) or not required <= data.keys() or data.keys() - required - optional:
        raise ValueError("Bundle profile has missing or unknown fields")
    entry = data["entrypoint"]
    if not isinstance(entry, dict) or set(entry) - {"kind", "value", "args", "cwd"} or not {"kind", "value"} <= entry.keys():
        raise ValueError("Invalid bundle entrypoint")
    if not isinstance(entry.get("args", []), list) or not all(isinstance(x, str) for x in entry.get("args", [])):
        raise ValueError("Entrypoint args must be an array of strings")
    hints = data.get("config_hints", [])
    if not isinstance(hints, list) or any(not isinstance(h, dict) or not {"field", "purpose"} <= h.keys() or set(h) - {"field", "purpose", "application_url", "required"} for h in hints):
        raise ValueError("Invalid configuration hints")
    def path(key):
        value = data.get(key)
        if value is None:
            return None
        if not isinstance(value, str) or not value:
            raise ValueError(f"{key} must be a nonempty path")
        candidate = Path(value)
        return candidate if candidate.is_absolute() else profile.parent / candidate
    return export_python_bundle(
        report, output, entrypoint=PythonEntrypoint(entry["kind"], entry["value"], tuple(entry.get("args", [])), entry.get("cwd", ".")),
        mode=data["mode"], runtime_archive=path("runtime_archive"),
        runtime_sha256=data["runtime_sha256"], runtime_version=data["runtime_version"],
        expected_revision=data["expected_revision"], dependency_tree=path("dependency_tree"),
        requirements_lock=path("requirements_lock"), dependency_licenses=path("dependency_licenses"),
        config_hints=tuple(ConfigHint(**h) for h in hints), adapter_script=path("adapter_script"))
