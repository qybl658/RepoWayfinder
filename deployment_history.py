"""Local deployment history; no credentials, repository text or commands stored."""
from __future__ import annotations

import json
from pathlib import Path
import re
import time


def repository_name(value: object) -> str:
    if isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", value):
        return value
    return ""


def entry_from_report(report: dict, path: Path) -> dict | None:
    name = repository_name(report.get("repo"))
    if not name or not report.get("repo_path") or report.get("action") not in {
        "DEPLOY", "WAITING_ENVIRONMENT", "BLOCKED_SECURITY", "ERROR"
    }:
        return None
    return {"repo": name, "status": str(report.get("action", "")),
            "success": report.get("deployment_success") is True,
            "last_run": str(report.get("finished_at") or report.get("started_at") or ""),
            "project_path": str(report["repo_path"]), "report_path": str(path.resolve())}


def load_history(path: Path, reports_root: Path) -> list[dict]:
    entries: dict[str, dict] = {}
    if path.is_file():
        try:
            saved = json.loads(path.read_text(encoding="utf-8-sig"))
            for item in saved.get("entries", []):
                if isinstance(item, dict) and repository_name(item.get("repo")):
                    entries[item["repo"].casefold()] = item
        except (OSError, ValueError, TypeError, AttributeError):
            pass  # Old reports remain the independent recovery source.
    if reports_root.is_dir():
        for report_path in reports_root.glob("*/deployment_result.json"):
            if report_path.is_symlink() or reports_root.resolve() not in report_path.resolve().parents:
                continue
            try:
                if report_path.stat().st_size > 4 * 1024 * 1024:
                    continue
                data = json.loads(report_path.read_text(encoding="utf-8-sig"))
                item = entry_from_report(data, report_path) if isinstance(data, dict) else None
                if item:
                    key = item["repo"].casefold()
                    if key not in entries or item["last_run"] >= entries[key].get("last_run", ""):
                        entries[key] = item
            except (OSError, ValueError, TypeError):
                continue
    return sorted(entries.values(), key=lambda item: item.get("last_run", ""), reverse=True)


def record_report(path: Path, reports_root: Path, report: dict, report_path: Path) -> None:
    item = entry_from_report(report, report_path)
    if item is None:
        return
    entries = {entry["repo"].casefold(): entry for entry in load_history(path, reports_root)}
    entries[item["repo"].casefold()] = item
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".pending-" + str(time.time_ns()))
    try:
        with temporary.open("x", encoding="utf-8") as stream:
            json.dump({"version": 1, "entries": list(entries.values())}, stream, ensure_ascii=False, indent=2)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
