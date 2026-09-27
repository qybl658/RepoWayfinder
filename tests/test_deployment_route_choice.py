"""Route choice with local fixtures; no project commands or installers run."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
spec = importlib.util.spec_from_file_location("route_choice_app", ROOT / "main.py")
app = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = app
spec.loader.exec_module(app)


class RouteChoiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="route-choice-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "Dockerfile").write_text('FROM node:20\nCOPY . .\nEXPOSE 3000\nCMD ["npm", "start"]\n', encoding="utf-8")
        (self.root / "package.json").write_text('{"scripts":{"start":"node server.js"}}', encoding="utf-8")
        (self.root / "README.md").write_text("Run the app:\n\nnpm start\n", encoding="utf-8")
        self.repo = app.RepoInfo("fixture", "web", "fixture/web", "", "")
        self.docker = app.local_heuristic_plan(self.repo, self.root)
        self.enterContext(patch.object(app, "log"))

    def status(self, docker="not_running", node="ready"):
        def probe(name, **_kwargs):
            value = {"docker": docker, "node": node}[name]
            return {"name": name, "status": value, "detail": f"{name} {value}", "executable": f"/fake/{name}"}
        return patch.object(app, "prerequisite_status", side_effect=probe)

    def test_ready_node_route_selected_without_prompt_despite_docker_cli(self):
        with self.status(), patch.object(app, "read_visible_input") as prompt:
            selected, options = app.choose_ready_deployment_route(self.repo, self.root, self.docker)
        self.assertEqual(app.execution_route_summary(selected)["route"], "node")
        self.assertEqual([option["ready"] for option in options], [False, True])
        prompt.assert_not_called()

    def test_ready_docker_keeps_documented_original_route(self):
        with self.status(docker="ready", node="ready"), patch.object(app, "read_visible_input") as prompt:
            selected, _ = app.choose_ready_deployment_route(self.repo, self.root, self.docker)
        self.assertIs(selected, self.docker)
        prompt.assert_not_called()

    def test_different_python_app_is_not_substituted_for_docker_node_app(self):
        (self.root / "Procfile").write_text("web: python app.py\n", encoding="utf-8")
        (self.root / "requirements.txt").write_text("flask\n", encoding="utf-8")
        with self.status(), patch.object(app, "choose_python_executable",
                                  side_effect=app.PythonEnvironmentError("waiting_python", "Python missing")), \
                patch.object(app, "read_visible_input") as prompt:
            selected, options = app.choose_ready_deployment_route(self.repo, self.root, self.docker)
        self.assertEqual([option["route"] for option in options], ["docker", "node"])
        self.assertEqual(app.execution_route_summary(selected)["route"], "node")
        prompt.assert_not_called()

    def test_no_ready_route_requires_explicit_choice_and_explains_setup(self):
        with self.status(node="missing"), patch.object(app, "reposcout_interactive", return_value=True), \
                patch.object(app, "read_visible_input", return_value="2"), patch.object(app, "log") as output:
            selected, options = app.choose_ready_deployment_route(self.repo, self.root, self.docker)
        self.assertEqual(app.execution_route_summary(selected)["route"], "node")
        self.assertFalse(any(option["ready"] for option in options))
        displayed = "\n".join(str(call.args[0]) for call in output.call_args_list)
        self.assertIn("Docker Desktop/WSL2", displayed)
        self.assertIn("重启", displayed)
        self.assertIn("需要安装或修复 Node.js 和 npm", displayed)
        self.assertNotIn("node missing", displayed)
        self.assertNotIn("docker not_running", displayed)

    def test_no_ready_noninteractive_waits_without_choosing(self):
        with self.status(node="missing"), patch.object(app, "reposcout_interactive", return_value=False), \
                patch.object(app, "read_visible_input") as prompt:
            selected, _ = app.choose_ready_deployment_route(self.repo, self.root, self.docker)
        self.assertIsNone(selected)
        prompt.assert_not_called()

    def test_no_comparable_host_route_keeps_docker_plan(self):
        (self.root / "README.md").write_text("No local start instructions\n", encoding="utf-8")
        with self.status(node="ready"), patch.object(app, "read_visible_input") as prompt:
            selected, options = app.choose_ready_deployment_route(self.repo, self.root, self.docker)
        self.assertIs(selected, self.docker)
        self.assertEqual(options, [])
        prompt.assert_not_called()

    def test_localhost_url_without_explicit_start_does_not_create_alt_route(self):
        (self.root / "README.md").write_text("Open http://localhost:3000 after setup.\n", encoding="utf-8")
        self.assertIsNone(app.documented_node_execution_plan(self.root))
        self.assertEqual(app.comparable_deployment_routes(self.repo, self.root, self.docker), [self.docker])

    def test_build_script_is_included_before_start(self):
        (self.root / "package.json").write_text('{"scripts":{"build":"tsc","start":"node dist/server.js"}}', encoding="utf-8")
        plan = app.documented_node_execution_plan(self.root)
        self.assertEqual([step.cmd for step in plan.steps], ["npm install", "npm run build", "npm start"])

    def test_pnpm_project_does_not_get_fabricated_npm_route(self):
        (self.root / "package.json").write_text('{"packageManager":"pnpm@9.0.0","scripts":{"start":"node server.js"}}', encoding="utf-8")
        self.assertIsNone(app.documented_node_execution_plan(self.root))
        self.assertEqual(app.local_heuristic_plan(self.repo, self.root, include_docker=False).action, "LEARN")
        self.assertEqual(app.comparable_deployment_routes(self.repo, self.root, self.docker), [self.docker])

    def test_documented_pnpm_and_yarn_routes_use_declared_manager(self):
        for manager in ("pnpm", "yarn"):
            with self.subTest(manager=manager):
                (self.root / "package.json").write_text(json.dumps({"packageManager": f"{manager}@9.0.0",
                    "scripts": {"build": "node build.js", "start": "node server.js"}}), encoding="utf-8")
                (self.root / "README.md").write_text(f"{manager} start\n", encoding="utf-8")
                (self.root / "Dockerfile").write_text(f"FROM node:20\nCOPY . .\nEXPOSE 3000\nCMD {manager} start\n", encoding="utf-8")
                plan = app.documented_node_execution_plan(self.root)
                self.assertEqual([step.cmd for step in plan.steps],
                                 [f"{manager} install", "yarn build" if manager == "yarn" else "pnpm run build", f"{manager} start"])
                self.assertEqual(app.required_plan_prerequisites(plan), ["node", manager])
                docker = app.local_heuristic_plan(self.repo, self.root)
                self.assertEqual(len(app.comparable_deployment_routes(self.repo, self.root, docker)), 2)

    def test_node_engine_mismatch_prevents_automatic_choice(self):
        (self.root / "package.json").write_text('{"engines":{"node":">=20 <23"},"scripts":{"start":"node server.js"}}', encoding="utf-8")
        def status(name, **_kwargs):
            return {"name": name, "status": "not_running" if name == "docker" else "ready",
                    "detail": "daemon unavailable" if name == "docker" else "v18.19.0"}
        with patch.object(app, "prerequisite_status", side_effect=status), \
                patch.object(app, "reposcout_interactive", return_value=False):
            selected, options = app.choose_ready_deployment_route(self.repo, self.root, self.docker)
        self.assertIsNone(selected)
        self.assertEqual(options[1]["missing"][0]["status"], "version_mismatch")
        self.assertEqual(options[1]["missing"][0]["required_version"], ">=20 <23")

    def test_incompatible_node_choice_stays_waiting_for_version(self):
        (self.root / "package.json").write_text('{"engines":{"node":">=20"},"scripts":{"start":"node server.js"}}', encoding="utf-8")
        def status(name, **_kwargs):
            return {"name": name, "status": "not_running" if name == "docker" else "ready",
                    "detail": "daemon unavailable" if name == "docker" else "v18.19.0"}
        with patch.object(app, "prerequisite_status", side_effect=status), \
                patch.object(app, "reposcout_interactive", return_value=True), \
                patch.object(app, "read_visible_input", return_value="2"):
            selected, _ = app.choose_ready_deployment_route(self.repo, self.root, self.docker)
        self.assertIsNone(selected)

    def test_matching_node_engine_allows_ready_route(self):
        (self.root / "package.json").write_text('{"engines":{"node":">=20 <23"},"scripts":{"start":"node server.js"}}', encoding="utf-8")
        def status(name, **_kwargs):
            return {"name": name, "status": "not_running" if name == "docker" else "ready",
                    "detail": "daemon unavailable" if name == "docker" else "v20.11.0"}
        with patch.object(app, "prerequisite_status", side_effect=status):
            selected, _ = app.choose_ready_deployment_route(self.repo, self.root, self.docker)
        self.assertEqual(app.execution_route_summary(selected)["route"], "node")

    def test_final_prerequisite_gate_waits_for_node_engine_without_install(self):
        (self.root / "package.json").write_text('{"engines":{"node":">=20"},"scripts":{"start":"node server.js"}}', encoding="utf-8")
        plan = app.documented_node_execution_plan(self.root)
        with patch.object(app, "prerequisite_status", return_value={"name": "node", "status": "ready", "detail": "v18.19.0"}), \
                patch.object(app, "install_prerequisite") as install:
            ready, evidence, reason = app.ensure_plan_prerequisites(plan, self.root)
        self.assertFalse(ready)
        self.assertEqual(evidence[0]["status_after"], "version_mismatch")
        self.assertIn("Node.js >=20", reason)
        install.assert_not_called()

    def test_final_gate_rechecks_engine_after_node_install(self):
        (self.root / "package.json").write_text('{"engines":{"node":">=20"},"scripts":{"start":"node server.js"}}', encoding="utf-8")
        plan = app.documented_node_execution_plan(self.root)
        statuses = [{"name": "node", "status": "missing", "detail": "not installed"},
                    {"name": "node", "status": "ready", "detail": "v18.19.0"}]
        with patch.object(app, "prerequisite_status", side_effect=statuses), \
                patch.object(app, "reposcout_interactive", return_value=True), \
                patch.object(app, "prompt_prerequisite_consent", return_value=True), \
                patch.object(app, "install_prerequisite", return_value=app.CommandResult("install node", 0)), \
                patch.object(app, "log"):
            ready, evidence, _ = app.ensure_plan_prerequisites(plan, self.root)
        self.assertFalse(ready)
        self.assertEqual(evidence[0]["status_after"], "version_mismatch")

    def test_complex_node_engine_range_needs_review(self):
        (self.root / "package.json").write_text('{"engines":{"node":">=18 || >=20"},"scripts":{"start":"node server.js"}}', encoding="utf-8")
        issue = app.declared_node_engine_status(self.root, "v20.11.0")
        self.assertEqual(issue["status"], "unknown")

    def test_docker_smoke_and_python_metadata_are_not_comparable(self):
        (self.root / "Dockerfile").write_text("FROM python:3.11\nCOPY . .\n", encoding="utf-8")
        (self.root / "pyproject.toml").write_text('[project]\nname="fixture"\nversion="1.0"\n[project.scripts]\nfixture="app:main"\n', encoding="utf-8")
        docker = app.local_heuristic_plan(self.repo, self.root)
        self.assertEqual(app.comparable_deployment_routes(self.repo, self.root, docker), [docker])

    def test_route_probe_never_runs_repository_venv_python(self):
        (self.root / "Procfile").write_text("web: python app.py\n", encoding="utf-8")
        (self.root / "requirements.txt").write_text("flask\n", encoding="utf-8")
        (self.root / ".python-version").write_text(f"{sys.version_info.major}.{sys.version_info.minor}\n", encoding="utf-8")
        venv_python = self.root / ".venv" / ("Scripts" if sys.platform == "win32" else "bin") / ("python.exe" if sys.platform == "win32" else "python")
        venv_python.parent.mkdir(parents=True)
        venv_python.write_text("repository-controlled executable", encoding="utf-8")
        executed = []
        def run(args, **kwargs):
            executed.append((Path(args[0]).resolve(), args, kwargs))
            return SimpleNamespace(returncode=0, stdout=f"{sys.version_info.major}.{sys.version_info.minor}.9\n")
        plan = app.procfile_execution_plan(self.root)
        with patch.object(app.subprocess, "run", side_effect=run), \
                patch.object(app.shutil, "which", return_value=str(venv_python)):
            missing = app.route_environment_status(plan, self.root, {})
        self.assertFalse(missing)
        self.assertTrue(executed)
        self.assertTrue(all(path != venv_python.resolve() for path, _, _ in executed))
        self.assertTrue(all("-I" in args and kwargs["cwd"] == str(app.PROJECT_DIR) for _, args, kwargs in executed))

    def test_repository_node_executable_is_not_probed_before_review(self):
        node = self.root / "node.exe"
        npm = self.root / "npm.cmd"
        node.write_text("fixture", encoding="utf-8")
        npm.write_text("fixture", encoding="utf-8")
        with patch.object(app.shutil, "which", side_effect=lambda name: str(node if name == "node" else npm)), \
                patch.object(app, "probe_command") as probe:
            status = app.prerequisite_status("node", blocked_root=self.root)
        self.assertEqual(status["status"], "untrusted")
        probe.assert_not_called()

    def test_pyproject_python_requirement_is_checked_before_ready(self):
        (self.root / "pyproject.toml").write_text('[project]\nrequires-python = ">=3.12,<3.14"\n', encoding="utf-8")
        issue = app.declared_python_requirement_status(self.root, (3, 11, 9))
        self.assertEqual(issue["status"], "version_mismatch")
        self.assertIsNone(app.declared_python_requirement_status(self.root, (3, 12, 1)))

    def test_deployment_waits_for_route_choice_before_security_or_project_commands(self):
        with self.status(node="missing"), patch.object(app, "reposcout_interactive", return_value=False), \
                patch.object(app, "clone_repo", return_value=self.root), patch.object(app, "scan_repo", return_value="fixture"), \
                patch.object(app, "detect_required_config", return_value=[]), \
                patch.object(app.integration_targets, "discover_integrations", return_value=[]), \
                patch.object(app, "ai_execution_plan", return_value=self.docker), \
                patch.object(app, "generate_beginner_guide", return_value={}), \
                patch.object(app, "write_report"), \
                patch.object(app, "review_repository_security") as review, \
                patch.object(app, "execute_plan") as execute:
            report = app.deploy_repo(self.repo)
        self.assertEqual(report.action, "WAITING_ENVIRONMENT")
        self.assertTrue(report.route_summary["selection_pending"])
        self.assertFalse(report.project_execution_started)
        self.assertEqual(report.plan_evidence, app.capture_plan_evidence(self.root, self.docker))
        review.assert_not_called()
        execute.assert_not_called()

    def test_continuation_reselects_route_after_readiness_changes(self):
        reports = self.root / "reports"
        artifact = reports / "run"
        artifact.mkdir(parents=True)
        report_file = artifact / "deployment_result.json"
        saved = app.DeploymentReport(self.repo.full_name, "WAITING_ENVIRONMENT", True, "choose route",
                                     repo_path=str(self.root), plan=app.plan_to_dict(self.docker),
                                     plan_evidence=app.capture_plan_evidence(self.root, self.docker),
                                     route_summary={"selection_pending": True})
        report_file.write_text(json.dumps(app.asdict(saved)), encoding="utf-8")
        with self.status(), patch.object(app, "REPORTS_DIR", reports), patch.object(app, "log"), \
                patch.object(app, "write_report") as written, patch.object(app, "show_deployment_result"), \
                patch.object(app, "review_repository_security", return_value={"blocked": False}), \
                patch.object(app, "prepare_report_docker_repair", side_effect=lambda _path, plan, _report: (plan, "")), \
                patch.object(app, "ensure_plan_prerequisites", return_value=(False, [], "fixture wait")), \
                patch.object(app, "generate_beginner_guide", return_value={}), \
                patch.object(app, "execute_plan") as execute:
            result = app.resume_deployment_report(report_file)
        self.assertEqual(result, 0)
        continued = written.call_args.args[0]
        self.assertEqual(continued.action, "WAITING_ENVIRONMENT")
        self.assertEqual(continued.route_summary["route"], "node")
        self.assertNotIn("selection_pending", continued.route_summary)
        self.assertEqual(continued.plan_evidence, app.capture_plan_evidence(self.root, app.normalize_plan(continued.plan)))
        execute.assert_not_called()


if __name__ == "__main__":
    unittest.main()
