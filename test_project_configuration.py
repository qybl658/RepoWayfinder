"""Offline tests of the original project configuration entry; no main import."""
import ast
import base64
import json
from pathlib import Path
import re
import shutil
import sys
import tempfile
from types import SimpleNamespace
import unittest


class ProjectConfigurationTests(unittest.TestCase):
    def owner(self):
        source_root = Path(__file__).parent
        tree = ast.parse((source_root / "main.py").read_text(encoding="utf-8-sig"))
        names = {"write_project_configuration_launcher", "configure_target_project"}
        nodes = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in names]
        calls = []
        namespace = dict(
            Path=Path, PROJECT_DIR=source_root, UI_LANGUAGE="en", shutil=shutil, sys=sys,
            os=SimpleNamespace(name="nt", getenv=lambda name: None),
            read_text_limited=lambda path, maximum: path.read_text(encoding="utf-8-sig"),
            reposcout_interactive=lambda: True, log=lambda message: None,
            ui_text=lambda zh, en: en, ENVIRONMENT_CHANGES=[],
            RepoWayfinderError=RuntimeError, json=json,
            subprocess=SimpleNamespace(CREATE_NO_WINDOW=0, run=lambda args, **kwargs: (calls.append((args, kwargs)) or SimpleNamespace(returncode=0, stdout='{"status":"preserved_cancelled","configuration":[]}'))),
        )
        exec(compile(ast.Module(body=nodes, type_ignores=[]), "main.py project configuration owners", "exec"), namespace)
        return namespace, calls

    def test_project_entry_calls_project_owner_and_preserves_existing_keys(self):
        app, calls = self.owner()
        with tempfile.TemporaryDirectory(prefix="reposcout-project-config-") as temp:
            root = Path(temp)
            (root / "config.example.toml").write_text('[app]\ndeepseek_api_key = ""\n', encoding="utf-8")
            expected = '[app]\ndeepseek_api_key = "synthetic-existing-target-only"\n'
            (root / "config.toml").write_text(expected, encoding="utf-8")
            app["configure_target_project"](root, ["deepseek_api_key"])
            self.assertEqual((root / "config.toml").read_text(), expected)
            self.assertEqual(len(calls), 1)
            self.assertIn("project_configuration.ps1", " ".join(calls[0][0]))
            self.assertIn("en", calls[0][0])
            self.assertNotIn("synthetic-existing-target-only", repr(calls))
            launcher = (root / "修改项目API Key.bat").read_text(encoding="utf-8")
            self.assertNotIn(b'\r\r\n', (root / "修改项目API Key.bat").read_bytes())
            self.assertNotIn("-EncodedCommand", launcher)
            script = launcher
            self.assertIn("project_configuration.ps1", script)
            self.assertIn(' -Root "%~dp0."', script)
            self.assertNotIn("ForceApiSetup", script)
            self.assertNotIn("run_reposcout.ps1", script)
            self.assertNotIn("synthetic-existing-target-only", script)

    def test_existing_user_entry_is_preserved(self):
        app, _ = self.owner()
        with tempfile.TemporaryDirectory(prefix="reposcout-project-config-") as temp:
            root = Path(temp)
            (root / ".env.example").write_text("API_KEY=\n", encoding="utf-8")
            path = root / "修改项目API Key.bat"
            path.write_text("user-owned entry", encoding="utf-8")
            app["write_project_configuration_launcher"](root)
            self.assertEqual(path.read_text(), "user-owned entry")


if __name__ == "__main__":
    unittest.main()
