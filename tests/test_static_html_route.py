"""Focused static-page planning and report launcher checks; no target commands run."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
spec = importlib.util.spec_from_file_location("static_html_app", ROOT / "main.py")
app = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = app
spec.loader.exec_module(app)


class StaticHtmlRouteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="static-html-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "index.html").write_text(
            '<link rel="stylesheet" href="style.css?v=1"><script src="js/app.js"></script>',
            encoding="utf-8",
        )
        (self.root / "style.css").write_text("body { color: black; }", encoding="utf-8")
        (self.root / "js").mkdir()
        (self.root / "js" / "app.js").write_text("console.log('ready')", encoding="utf-8")
        self.repo = app.RepoInfo("example", "page", "example/page", "", "")

    def test_static_page_uses_deterministic_plan_and_exact_index_url(self):
        with patch.object(app, "AI_API_KEY", "dummy"), patch.object(app, "OpenAI") as model:
            plan = app.ai_execution_plan(self.repo, self.root, "")
        model.assert_not_called()
        self.assertEqual(plan.source, "static_html")
        self.assertEqual(len(plan.steps), 1)
        self.assertEqual(app.execution_route_summary(plan)["route"], "static_html")
        self.assertIn("python -I -m http.server", plan.steps[0].cmd)
        self.assertTrue(app.static_html_url(plan.steps[0].cmd).endswith("/index.html"))
        self.assertEqual(app.validate_plan(plan)[0], True)

    def test_missing_asset_or_runtime_manifest_refuses_static_route(self):
        (self.root / "style.css").unlink()
        self.assertIsNone(app.static_html_execution_plan(self.root))
        (self.root / "style.css").write_text("body {}", encoding="utf-8")
        for manifest in ("package.json", "vite.config.ts", "requirements.txt", "server.js"):
            with self.subTest(manifest=manifest):
                path = self.root / manifest
                path.write_text("{}", encoding="utf-8")
                self.assertIsNone(app.static_html_execution_plan(self.root))
                path.unlink()
        (self.root / "index.html").write_text('<script type="module" src="js/app.js"></script>', encoding="utf-8")
        self.assertIsNone(app.static_html_execution_plan(self.root))

    def test_obvious_backend_calls_refuse_static_route(self):
        (self.root / "js" / "app.js").write_text("fetch('/api/state').then(render)", encoding="utf-8")
        self.assertIsNone(app.static_html_execution_plan(self.root))
        (self.root / "js" / "app.js").write_text("console.log('ready')", encoding="utf-8")
        (self.root / "index.html").write_text("<script>new WebSocket('/events')</script>", encoding="utf-8")
        self.assertIsNone(app.static_html_execution_plan(self.root))

    def test_static_evidence_tracks_html_and_assets(self):
        plan = app.static_html_execution_plan(self.root)
        before = app.capture_plan_evidence(self.root, plan)
        self.assertIn("index.html", before)
        self.assertIn("js/app.js", before)
        (self.root / "js" / "app.js").write_text("console.log('changed')", encoding="utf-8")
        self.assertNotEqual(before, app.capture_plan_evidence(self.root, plan))

    def test_launcher_keeps_verified_port_and_uses_existing_python(self):
        plan = app.static_html_execution_plan(self.root)
        command = plan.steps[0].cmd
        url = app.static_html_url(command)
        report = app.DeploymentReport(
            repo="example/page", action="DEPLOY", success=True, reason="verified", repo_path=str(self.root),
            runtime_url=url, plan=app.plan_to_dict(plan),
            attempts=[{"planned_cmd": command, "argv": [sys.executable, "-m", "http.server"]}],
        )
        with patch.object(app, "ARTIFACT_DIR", self.root):
            app.write_start_script(report)
        script = Path(report.start_script_path).read_text(encoding="utf-8-sig")
        self.assertIn(str(app.urlsplit(url).port), script)
        self.assertIn("-I -m http.server", script)
        self.assertIn(sys.executable, script)
        self.assertNotIn("-m venv", script.lower())
        self.assertIn(url, Path(report.start_bat_path).read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
