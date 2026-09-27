"""Recovery through deployment/resume/step entry points; process calls are local mocks."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
spec = importlib.util.spec_from_file_location("recovery_pipeline_app", ROOT / "main.py")
app = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = app
spec.loader.exec_module(app)

RECIPE = ('FROM python:3.11-slim-bullseye\n'
          'RUN echo "deb http://deb.debian.org/debian bullseye main" > /etc/apt/sources.list\n')


class RecoveryPipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pipeline-test-", dir=ROOT / "tests")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo_path = self.root / "checkout"
        self.repo_path.mkdir()
        self.reports = self.root / "reports"
        self.artifacts = self.reports / "run"
        self.artifacts.mkdir(parents=True)
        self.report_path = self.artifacts / "deployment_result.json"
        self.repo = app.RepoInfo("fixture", "public", "fixture/public", "", "")
        self.plan = app.ExecutionPlan("DEPLOY", [app.CommandStep("exec", "docker build -t fixture .", "build", 20)], "fixture", "dockerfile")
        self.enterContext(patch.object(app, "ARTIFACT_DIR", self.artifacts))
        self.enterContext(patch.object(app, "REPORTS_DIR", self.reports))
        self.enterContext(patch.object(app, "REPORT_PATH", self.report_path))
        self.enterContext(patch.object(app, "ENVIRONMENT_CHANGES", []))
        self.enterContext(patch.object(app, "ACTIVE_DEPLOYMENT_MODE", "protected"))
        self.enterContext(patch.object(app, "log"))
        self.enterContext(patch.object(app, "write_running_status"))
        self.enterContext(patch.object(app, "generate_beginner_guide", return_value={"title": "fixture"}))
        self.write_report = self.enterContext(patch.object(app, "write_report"))
        self.enterContext(patch.object(app, "show_deployment_result"))
        self.enterContext(patch.object(app, "reposcout_interactive", return_value=True))
        self.confirm = self.enterContext(patch.object(app, "prompt_yes_no", return_value=True))
        self.enterContext(patch.object(app.time, "sleep"))

    def deployment_mocks(self):
        (self.repo_path / "Dockerfile").write_text(RECIPE, encoding="utf-8")
        self.enterContext(patch.object(app, "clone_repo", return_value=self.repo_path))
        self.enterContext(patch.object(app, "scan_repo", return_value="fixture scan"))
        self.enterContext(patch.object(app, "detect_required_config", return_value=[]))
        self.enterContext(patch.object(app, "ai_execution_plan", return_value=self.plan))
        self.enterContext(patch.object(app, "should_deploy", return_value=("DEPLOY", "fixture")))
        self.enterContext(patch.object(app, "announce_execution_route", return_value=({}, {})))
        self.enterContext(patch.object(app, "review_repository_security", return_value={"blocked": False}))
        self.enterContext(patch.object(app, "configure_target_project"))
        self.prerequisites = self.enterContext(patch.object(app, "ensure_plan_prerequisites", return_value=(True, [], "")))
        self.execute = self.enterContext(patch.object(app, "execute_plan", return_value=(True, [], [{"kind": "runtime_fixture"}], app.RuntimeCheck("process", True))))

    def test_declined_docker_migration_waits_without_install_or_project_command(self):
        self.deployment_mocks()
        self.confirm.return_value = False
        report = app.deploy_repo(self.repo)
        self.assertEqual(report.action, "WAITING_ENVIRONMENT")
        self.assertFalse(report.project_execution_started)
        self.assertEqual(report.repairs[0]["status"], "declined")
        self.prerequisites.assert_not_called()
        self.execute.assert_not_called()
        self.assertFalse((self.artifacts / "repairs").exists())
        self.assertFalse(self.confirm.call_args.kwargs["default_yes"])

    def test_approved_deploy_preserves_recipe_evidence_and_runtime_repairs(self):
        self.deployment_mocks()
        report = app.deploy_repo(self.repo)
        self.assertTrue(report.deployment_success)
        self.assertEqual([r["kind"] for r in report.repairs], ["docker_base_distribution_eol", "runtime_fixture"])
        executed_plan = self.execute.call_args.args[1]
        self.assertIn("--file", executed_plan.steps[0].cmd)
        self.assertEqual(report.plan, app.plan_to_dict(executed_plan))
        self.assertEqual(report.plan_evidence, app.capture_plan_evidence(self.repo_path, executed_plan))
        self.assertEqual((self.repo_path / "Dockerfile").read_text(encoding="utf-8"), RECIPE)
        app.verify_report_docker_repairs(report, executed_plan)

    def test_source_changed_during_confirmation_stays_waiting(self):
        self.deployment_mocks()
        def change_source(*args, **kwargs):
            (self.repo_path / "Dockerfile").write_text(RECIPE + "# changed\n", encoding="utf-8")
            return True
        self.confirm.side_effect = change_source
        report = app.deploy_repo(self.repo)
        self.assertEqual(report.action, "WAITING_ENVIRONMENT")
        self.assertEqual(report.repairs[0]["status"], "source_changed")
        self.execute.assert_not_called()

    def make_waiting_recipe_report(self):
        (self.repo_path / "Dockerfile").write_text(RECIPE, encoding="utf-8")
        report = app.DeploymentReport(self.repo.full_name, "WAITING_ENVIRONMENT", True, "Docker not ready",
                                     repo_path=str(self.repo_path), plan=app.plan_to_dict(self.plan))
        prepared, waiting = app.prepare_report_docker_repair(self.repo_path, self.plan, report)
        self.assertFalse(waiting)
        self.report_path.write_text(json.dumps(app.asdict(report)), encoding="utf-8")
        return report, prepared

    def test_resume_rejects_changed_recipe_copy_before_commands_or_report_rewrite(self):
        report, _ = self.make_waiting_recipe_report()
        Path(report.repairs[0]["repair_path"]).write_text("FROM unexpected\n", encoding="utf-8")
        before = self.report_path.read_bytes()
        with patch.object(app, "execute_plan") as execute, patch.object(app, "ensure_plan_prerequisites") as prerequisite:
            with self.assertRaisesRegex(app.RepoWayfinderError, "Docker"):
                app.resume_deployment_report(self.report_path)
        execute.assert_not_called()
        prerequisite.assert_not_called()
        self.write_report.assert_not_called()
        self.assertEqual(self.report_path.read_bytes(), before)

    def test_resume_unchanged_recipe_reuses_approved_copy_without_reprompt(self):
        _, prepared = self.make_waiting_recipe_report()
        self.confirm.reset_mock()
        with patch.object(app, "local_repo_info_from_checkout", return_value=self.repo), \
             patch.object(app, "scan_repo", return_value="fixture scan"), \
             patch.object(app, "review_repository_security", return_value={"blocked": False}), \
             patch.object(app, "ensure_plan_prerequisites", return_value=(True, [], "")), \
             patch.object(app, "execute_plan", return_value=(True, [], [], app.RuntimeCheck("process", True))) as execute:
            self.assertEqual(app.resume_deployment_report(self.report_path), 0)
        self.assertEqual(execute.call_args.args[1].steps, prepared.steps)
        self.confirm.assert_not_called()
        self.assertEqual(self.write_report.call_args.args[0].repairs[0]["status"], "isolated_repair_created")

    def test_generated_demo_launcher_rebuilds_using_the_approved_report_copy(self):
        self.plan.steps.append(app.CommandStep("exec", "docker run --rm -p 8000:8000 fixture", "start server", 20))
        report, _ = self.make_waiting_recipe_report()
        repair_path = report.repairs[0]["repair_path"]
        report.route_summary = {"route": "docker"}
        report.runtime_url = "http://127.0.0.1:8000/"
        # Even a stale guide mentioning the original build must not displace
        # the approved plan when the launcher rebuilds a missing image.
        report.beginner_guide = {"how_to_run_again": ["cd checkout", "docker build -t fixture .", "docker run --rm -p 8000:8000 fixture"]}
        with patch.object(app, "trusted_replay_path_directories", return_value=[]):
            app.write_start_script(report)
        script = Path(report.start_script_path).read_text(encoding="utf-8-sig")
        builds = [line.strip() for line in script.splitlines() if line.strip().startswith("& ") and "'build'" in line]
        self.assertEqual(len(builds), 1)
        self.assertIn("'--file'", builds[0])
        self.assertIn(app.ps_single_quoted(repair_path), builds[0])
        self.assertIn("'run' '--rm' '-p' '8000:8000' 'fixture'", script)
        self.assertIn("start_demo.ps1", Path(report.start_bat_path).read_text(encoding="utf-8"))
        self.assertEqual(report.demo_venv_path, "")
        self.assertEqual((self.repo_path / "Dockerfile").read_text(encoding="utf-8"), RECIPE)

    def network_failure(self):
        return app.CommandResult("fixture", 1, "connection timed out", "")

    def test_network_error_retries_public_mirror_once_and_stops_on_mirror_failure(self):
        for mirror_success in (True, False):
            with self.subTest(mirror_success=mirror_success), patch.dict(app.os.environ, {}, clear=True), \
                 patch.object(app, "run_process", side_effect=[self.network_failure(), app.CommandResult("fixture", 0 if mirror_success else 1, "connection timed out", "")]) as run:
                attempts, repairs = [], []
                ok, _ = app.run_step_with_repairs(app.CommandStep("exec", "npm ci", "install"), self.repo_path, None, attempts, repairs)
                self.assertEqual(ok, mirror_success)
                self.assertEqual(run.call_count, 2)
                self.assertEqual(len(attempts), 2)
                self.assertEqual(repairs[0]["kind"], "public_package_mirror")
                self.assertTrue(repairs[0]["public_packages_confirmed"])
                self.assertTrue(run.call_args.kwargs["target_process"])
                self.assertIn("--registry=" + app.mainline_recovery.NPM_MIRROR_URL, run.call_args.args[0])
                self.assertFalse(self.confirm.call_args.kwargs["default_yes"])

    def test_decline_or_custom_source_never_sends_to_mirror_or_reprompts(self):
        for custom_source in (False, True):
            with self.subTest(custom_source=custom_source), patch.dict(app.os.environ, {"npm_config_registry": "https://private.example"} if custom_source else {}, clear=True), \
                 patch.object(app, "run_process", side_effect=[self.network_failure(), self.network_failure(), self.network_failure()]) as run:
                self.confirm.reset_mock()
                self.confirm.return_value = False
                ok, _ = app.run_step_with_repairs(app.CommandStep("exec", "npm ci", "install"), self.repo_path, None, [], [])
                self.assertFalse(ok)
                self.assertEqual(self.confirm.call_count, 0 if custom_source else 1)
                self.assertEqual(run.call_count, 3)
                self.assertTrue(all(call.args[0] == ["npm", "ci"] for call in run.call_args_list))

    def test_protected_mode_still_blocks_inferred_new_package(self):
        failure = app.CommandResult("fixture", 1, "ModuleNotFoundError: No module named 'dotenv'", "")
        with patch.object(app, "run_process", return_value=failure) as run:
            repairs = []
            ok, _ = app.run_step_with_repairs(app.CommandStep("exec", "python -m pip install requests", "install"), self.repo_path, Path(sys.executable), [], repairs)
        self.assertFalse(ok)
        self.assertTrue(repairs[-1]["blocked_by_security_mode"])
        run.assert_called_once()
        self.confirm.assert_not_called()


if __name__ == "__main__":
    unittest.main()
