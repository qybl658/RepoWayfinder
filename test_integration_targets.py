import json
import tempfile
import unittest
import zipfile
from pathlib import Path
from subprocess import CompletedProcess
from unittest.mock import patch

import integration_targets as integration


class HostIntegrationTests(unittest.TestCase):
    def test_skill_installs_to_detected_hosts_and_preserves_conflicts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "repo" / "skills" / "sample"
            source.mkdir(parents=True)
            (source / "SKILL.md").write_text("---\nname: sample\ndescription: Sample workflow\n---\nDo the task.\n", encoding="utf-8")
            (source / "reference.txt").write_text("reference", encoding="utf-8")
            candidates = integration.discover_integrations(root / "repo")
            self.assertEqual([item["kind"] for item in candidates], ["agent_skill"])
            hosts = {
                "codex": {"skills_dir": str(root / "agents" / "skills")},
                "grok": {"skills_dir": str(root / "agents" / "skills")},
            }
            first = integration.apply_integrations(candidates, hosts)
            self.assertEqual([item["status"] for item in first], ["installed", "already_installed"])
            target = root / "agents" / "skills" / "sample"
            self.assertEqual((target / "reference.txt").read_text(encoding="utf-8"), "reference")
            (target / "reference.txt").write_text("user change", encoding="utf-8")
            second = integration.apply_integrations(candidates, hosts)
            self.assertEqual([item["status"] for item in second], ["conflict", "conflict"])
            self.assertEqual((target / "reference.txt").read_text(encoding="utf-8"), "user change")

    def test_browser_extension_requires_browser_action(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.joinpath("manifest.json").write_text(json.dumps({"manifest_version": 3, "name": "Sample", "version": "1"}), encoding="utf-8")
            candidates = integration.discover_integrations(root)
            self.assertEqual(candidates[0]["kind"], "browser_extension")
            result = integration.apply_integrations(candidates, {"chrome": {"manage_url": "chrome://extensions"}})
            self.assertEqual(result[0]["status"], "user_action_required")
            self.assertEqual(result[0]["source"], str(root))

    def test_source_link_does_not_escape_install_boundary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "repo"
            source.mkdir()
            (source / "SKILL.md").write_text("---\nname: safe-name\ndescription: Test\n---\n", encoding="utf-8")
            outside = root / "outside.txt"
            outside.write_text("outside", encoding="utf-8")
            try:
                (source / "outside.txt").symlink_to(outside)
            except OSError:
                self.skipTest("Creating symlinks requires special Windows privileges")
            result = integration.apply_integrations(integration.discover_integrations(source), {"codex": {"skills_dir": str(root / "target")}})
            self.assertEqual(result[0]["status"], "blocked")
            self.assertFalse((root / "target" / "safe-name").exists())

    def test_vsix_uses_host_cli_and_checks_extension_id(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "extension.vsix"
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr("extension/package.json", json.dumps({"name": "sample", "publisher": "publisher", "engines": {"vscode": "^1.80.0"}}))
            candidate = {"kind": "vscode_extension", "name": "sample", "source": str(source)}
            host = {"vscode": {"executable": "code"}}
            with patch.object(integration.subprocess, "run", side_effect=[
                CompletedProcess([], 0, "", ""),
                CompletedProcess([], 0, "installed", ""),
                CompletedProcess([], 0, "publisher.sample\n", ""),
            ]) as run:
                result = integration.apply_integrations([candidate], host, allow_vsix_install=True)
            self.assertEqual(result[0]["status"], "host_discovered")
            self.assertEqual(result[0]["extension_id"], "publisher.sample")
            self.assertEqual(run.call_args_list[1].args[0], ["code", "--install-extension", str(source)])

    def test_large_skill_collection_can_select_nested_skill(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for index in range(9):
                skill = root / "examples" / "skills" / f"item-{index}"
                skill.mkdir(parents=True)
                (skill / "SKILL.md").write_text(f"---\nname: item-{index}\ndescription: Example\n---\n", encoding="utf-8")
            self.assertEqual(integration.discover_integrations(root)[0]["kind"], "selection_required")
            chosen = integration.discover_integrations(root, "examples/skills/item-3")
            self.assertEqual([(item["kind"], item["name"]) for item in chosen], [("agent_skill", "item-3")])

    def test_cli_app_with_bundled_skills_uses_project_route_by_default(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "pyproject.toml").write_text(
                '[project]\nname = "sample-app"\n[project.scripts]\nsample = "sample:main"\n', encoding="utf-8")
            for index in range(9):
                skill = root / "optional-skills" / f"item-{index}"
                skill.mkdir(parents=True)
                (skill / "SKILL.md").write_text(f"---\nname: item-{index}\n---\n", encoding="utf-8")
            candidates = integration.discover_integrations(root)
            self.assertEqual(candidates[0]["kind"], "selection_required")
            self.assertTrue(integration.is_standalone_app_with_bundled_skills(root, candidates))
            chosen = integration.discover_integrations(root, "optional-skills/item-3")
            self.assertEqual([(item["kind"], item["name"]) for item in chosen], [("agent_skill", "item-3")])

    def test_skill_collection_with_project_dependencies_stays_skill_route(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "pyproject.toml").write_text(
                '[project]\nname = "skill-collection"\ndependencies = ["sample"]\n', encoding="utf-8")
            for index in range(9):
                skill = root / "skills" / f"item-{index}"
                skill.mkdir(parents=True)
                (skill / "SKILL.md").write_text(f"---\nname: item-{index}\n---\n", encoding="utf-8")
            self.assertFalse(integration.is_standalone_app_with_bundled_skills(root, integration.discover_integrations(root)))

    def test_explicit_claude_skill_does_not_install_to_codex(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "README.md").write_text("A Claude Code skill for writing reports.", encoding="utf-8")
            (root / "SKILL.md").write_text("---\nname: report-skill\ndescription: Report\n---\n", encoding="utf-8")
            candidates = integration.discover_integrations(root)
            hosts = {"codex": {"skills_dir": str(root / "codex")}, "grok": {"skills_dir": str(root / "grok")}}
            results = integration.apply_integrations(candidates, hosts)
            self.assertEqual([item["host"] for item in results], ["grok"])

    def test_skill_with_runtime_packages_is_not_called_ready(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "SKILL.md").write_text("---\nname: package-skill\ndescription: Test\n---\n", encoding="utf-8")
            (root / "requirements.txt").write_text("pandas>=2\n", encoding="utf-8")
            candidate = integration.discover_integrations(root)
            result = integration.apply_integrations(candidate, {"codex": {"skills_dir": str(root / "host")}})
            self.assertEqual(result[0]["status"], "dependencies_pending")
            self.assertIn("requirements.txt", result[0]["runtime_requirements"])

    def test_nested_skill_wins_over_same_named_root_copy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            text = "---\nname: data-analysis\ndescription: Test\n---\n"
            (root / "SKILL.md").write_text(text, encoding="utf-8")
            nested = root / ".claude" / "skills" / "data-analysis"
            nested.mkdir(parents=True)
            (nested / "SKILL.md").write_text(text, encoding="utf-8")
            (nested / "scripts").mkdir()
            (root / "package.json").write_text(json.dumps({"dependencies": {"example": "1.0"}}), encoding="utf-8")
            found = integration.discover_integrations(root)
            self.assertEqual(len(found), 1)
            self.assertEqual(found[0]["relative"], ".claude/skills/data-analysis")
            self.assertIn("package.json", found[0]["runtime_requirements"])


if __name__ == "__main__":
    unittest.main()
