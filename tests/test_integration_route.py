"""Routing checks only; no project command or installer is executed."""

from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import main as app


class IntegrationRouteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.checkout = Path(self.temp.name)
        (self.checkout / "pyproject.toml").write_text(
            '[project]\nname = "sample-app"\n[project.scripts]\nsample = "sample:main"\n', encoding="utf-8")
        for index in range(9):
            skill = self.checkout / "optional-skills" / f"item-{index}"
            skill.mkdir(parents=True)
            (skill / "SKILL.md").write_text(f"---\nname: item-{index}\n---\n", encoding="utf-8")
        self.repo = app.RepoInfo("fixture", "sample-app", "fixture/sample-app", "", "")
        self.enterContext(patch.object(app, "clone_repo", return_value=self.checkout))
        self.enterContext(patch.object(app, "scan_repo", return_value="sample app"))
        self.enterContext(patch.object(app, "detect_required_config", return_value=["SAMPLE_API_KEY"]))
        self.enterContext(patch.object(app, "reposcout_interactive", return_value=True))
        self.enterContext(patch.object(app, "generate_beginner_guide", return_value={}))
        self.enterContext(patch.object(app, "write_report"))

    def test_default_route_reaches_project_plan_without_skill_question(self):
        plan = app.ExecutionPlan("LEARN", [], "fixture", "test")
        with patch.object(app, "ai_execution_plan", return_value=plan) as planner, \
             patch.object(app, "should_deploy", return_value=("LEARN", "fixture")), \
             patch.object(app, "prompt_deploy_override", return_value=plan), \
             patch.object(app, "read_visible_input") as ask, \
             patch.object(app, "integrate_repo_artifacts") as integrate:
            report = app.deploy_repo(self.repo)
        self.assertEqual(report.action, "LEARN")
        self.assertEqual(report.integration_candidates, [])
        planner.assert_called_once()
        ask.assert_not_called()
        integrate.assert_not_called()

    def test_explicit_skill_selection_still_uses_integration_route(self):
        with patch.object(app, "integrate_repo_artifacts") as integrate, \
             patch.object(app, "ai_execution_plan") as planner, \
             patch.object(app, "read_visible_input") as ask:
            app.deploy_repo(self.repo, integration_skill="optional-skills/item-3")
        self.assertEqual(integrate.call_args.args[3][0]["relative"], "optional-skills/item-3")
        planner.assert_not_called()
        ask.assert_not_called()

    def test_mixed_app_and_browser_requires_choice_and_only_handles_chosen_type(self):
        (self.checkout / "manifest.json").write_text('{"manifest_version":3,"name":"fixture","version":"1"}', encoding="utf-8")
        with patch.object(app, "read_visible_input", return_value="2"), \
             patch.object(app, "integrate_repo_artifacts") as integrate, \
             patch.object(app, "ai_execution_plan") as planner:
            app.deploy_repo(self.repo)
        self.assertEqual([item["kind"] for item in integrate.call_args.args[3]], ["browser_extension"])
        planner.assert_not_called()

    def test_ambiguous_cancel_does_not_install_or_plan(self):
        (self.checkout / "manifest.json").write_text('{"manifest_version":3,"name":"fixture","version":"1"}', encoding="utf-8")
        for interactive in (True, False):
            with self.subTest(interactive=interactive), patch.object(app, "reposcout_interactive", return_value=interactive), \
                 patch.object(app, "read_visible_input", return_value=""), \
                 patch.object(app, "integrate_repo_artifacts") as integrate, \
                 patch.object(app, "ai_execution_plan") as planner:
                report = app.deploy_repo(self.repo)
                self.assertEqual(report.integration_results[0]["status"], "selection_required")
                self.assertFalse(report.deployment_success)
                self.assertFalse(report.project_execution_started)
                integrate.assert_not_called()
                planner.assert_not_called()

    def test_reviewed_plan_skips_artifact_discovery_and_questions(self):
        plan = app.ExecutionPlan("LEARN", [], "fixture", "test")
        with patch.object(app.integration_targets, "discover_integrations") as discover, \
             patch.object(app, "reviewed_execution_plan", return_value=plan), \
             patch.object(app, "should_deploy", return_value=("LEARN", "fixture")), \
             patch.object(app, "prompt_deploy_override", return_value=plan), \
             patch.object(app, "read_visible_input") as ask:
            app.deploy_repo(self.repo, reviewed_plan={"test": "pinned"})
        discover.assert_not_called()
        ask.assert_not_called()


if __name__ == "__main__":
    unittest.main()
