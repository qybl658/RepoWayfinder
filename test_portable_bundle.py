"""Focused exporter checks; no third-party target repository is run."""
from __future__ import annotations

import json
import hashlib
import os
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

from portable_bundle import (BundleError, PythonEntrypoint, export_python_bundle,
                             _generated_absolute_config_launcher, _ps_literal, _safe_plan_text)


OFFICIAL_31315_SHA256 = "d1f04d990aee1253d8569e8e5104e30fa9f5fa830899f14843448872d936a2cf"


class BundleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="repowayfinder-bundle-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source checkout"
        self.source.mkdir()
        (self.source / "LICENSE").write_text("MIT License\n", encoding="utf-8")
        (self.source / "app.py").write_text(
            "import sys\nprint('BUNDLE_FIXTURE_OK')\nprint('INTERPRETER=' + sys.executable)\n",
            encoding="utf-8",
        )
        (self.source / ".env").write_text("OPENAI_API_KEY=synthetic-private-value\n", encoding="utf-8")
        (self.source / "run.md").write_text("private machine log\n", encoding="utf-8")
        (self.source / ".reposcout-source.json").write_text(
            json.dumps({"source_revision": "a" * 40}), encoding="utf-8"
        )
        self.report = self.root / "deployment_result.json"
        self.report.write_text(json.dumps({
            "repo": "example/fixture", "action": "DEPLOY", "success": True,
            "deployment_success": True, "repo_path": str(self.source),
            "plan": {"action": "DEPLOY", "steps": [{"type": "python", "cmd": "python app.py"}]},
            "plan_evidence": {"app.py": hashlib.sha256((self.source / "app.py").read_bytes()).hexdigest()},
        }), encoding="utf-8")

    def _export(self, *, mode="portable", entrypoint=None, needs_runtime=True):
        archive = os.environ.get("REPOWAYFINDER_TEST_EMBED_ZIP", "")
        if not archive and needs_runtime:
            self.skipTest("Set REPOWAYFINDER_TEST_EMBED_ZIP to an official reviewed Python embed ZIP.")
        output = self.root / f"{mode}.zip"
        return export_python_bundle(
            self.report, output, entrypoint=entrypoint or PythonEntrypoint("script", "app.py"),
            mode=mode, runtime_archive=archive,
            runtime_sha256=OFFICIAL_31315_SHA256, runtime_version="3.13.15",
            expected_revision="a" * 40,
        )

    def _run_bat(self, bundle: Path, name: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["PATH"] = os.path.join(os.environ["SystemRoot"], "System32")
        return subprocess.run([os.path.join(os.environ["SystemRoot"], "System32", "cmd.exe"),
                               "/d", "/c", str(bundle / name)],
                              env=env, cwd=self.root, capture_output=True, text=True,
                              encoding="utf-8", errors="replace", timeout=30)

    def test_rejects_unsuccessful_report_and_traversal(self):
        report = json.loads(self.report.read_text())
        report["deployment_success"] = False
        self.report.write_text(json.dumps(report))
        with self.assertRaisesRegex(BundleError, "successfully deployed"):
            self._export(entrypoint=PythonEntrypoint("script", "app.py"), needs_runtime=False)
        report["deployment_success"] = True
        self.report.write_text(json.dumps(report))
        with self.assertRaisesRegex(BundleError, "traversal"):
            self._export(entrypoint=PythonEntrypoint("script", "../outside.py"), needs_runtime=False)

    def test_rejects_filled_secret_template(self):
        (self.source / ".env.example").write_text("OPENAI_API_KEY=real-looking-secret\n", encoding="utf-8")
        with self.assertRaisesRegex(BundleError, "non-placeholder sensitive"):
            self._export()

    def test_excludes_only_repowayfinder_generated_absolute_config_launcher(self):
        launcher = self.source / "修改项目API Key.bat"
        launcher.write_text("@rem RepoWayfinder target-project configuration entry\n@echo off\n")
        self.assertTrue(_generated_absolute_config_launcher(launcher))
        launcher.write_text("@echo off\necho upstream launcher\n")
        self.assertFalse(_generated_absolute_config_launcher(launcher))

    def test_https_links_are_not_windows_paths(self):
        self.assertIn("https://github.com/settings/tokens", _ps_literal("https://github.com/settings/tokens"))
        self.assertEqual(_safe_plan_text("open https://example.org/docs", self.source, self.report),
                         "open https://example.org/docs")
        with self.assertRaisesRegex(BundleError, "build-machine paths"):
            _ps_literal("C:/Users/private/file")
        with self.assertRaisesRegex(BundleError, "absolute machine path"):
            _safe_plan_text("read C:/Users/private/file", self.source, self.report)

    def test_git_archive_excludes_untracked_deployment_artifacts(self):
        archive = os.environ.get("REPOWAYFINDER_TEST_EMBED_ZIP", "")
        if not archive:
            self.skipTest("Reviewed Python embed ZIP is unavailable.")
        subprocess.run(["git", "init", "-q", str(self.source)], check=True)
        subprocess.run(["git", "-C", str(self.source), "add", "LICENSE", "app.py"], check=True)
        subprocess.run(["git", "-C", str(self.source), "-c", "user.name=Fixture",
                        "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"], check=True)
        (self.source / "rwf_output").mkdir()
        (self.source / "rwf_output" / "personal.txt").write_text("private fixture output")
        output = self.root / "git-archive.zip"
        export_python_bundle(self.report, output, entrypoint=PythonEntrypoint("script", "app.py"),
                             mode="portable", runtime_archive=archive,
                             runtime_sha256=OFFICIAL_31315_SHA256, runtime_version="3.13.15",
                             expected_revision=subprocess.run(["git", "-C", str(self.source), "rev-parse", "HEAD"],
                                                              capture_output=True, text=True, check=True).stdout.strip())
        with zipfile.ZipFile(output) as zipped:
            names = set(zipped.namelist())
        self.assertIn("source/app.py", names)
        self.assertNotIn("source/rwf_output/personal.txt", names)

    def test_fixed_git_template_is_cleared_and_reported(self):
        archive = os.environ.get("REPOWAYFINDER_TEST_EMBED_ZIP", "")
        if not archive:
            self.skipTest("Reviewed Python embed ZIP is unavailable.")
        (self.source / ".env.example").write_text(
            "# Upstream example\nS3_SECRET_KEY=gitingest123\nGITHUB_TOKEN=\n", encoding="utf-8"
        )
        subprocess.run(["git", "init", "-q", str(self.source)], check=True)
        subprocess.run(["git", "-C", str(self.source), "add", "LICENSE", "app.py", ".env.example"], check=True)
        subprocess.run(["git", "-C", str(self.source), "-c", "user.name=Fixture",
                        "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"], check=True)
        revision = subprocess.run(["git", "-C", str(self.source), "rev-parse", "HEAD"],
                                  capture_output=True, text=True, check=True).stdout.strip()
        site = Path(__file__).parent / ".reposcout-venv" / "Lib" / "site-packages"
        dotenv = site / "dotenv"
        info = site / "python_dotenv-1.2.3.dist-info"
        if not dotenv.is_dir() or not info.is_dir():
            self.skipTest("Existing pinned python-dotenv distribution is unavailable.")
        deps = self.root / "sanitized-deps"
        deps.mkdir()
        shutil.copytree(dotenv, deps / "dotenv", ignore=shutil.ignore_patterns("__pycache__"))
        shutil.copytree(info, deps / info.name)
        lock = self.root / "sanitized.lock"
        lock.write_text("python-dotenv==1.2.3\n", encoding="utf-8")
        licenses = self.root / "sanitized-licenses"
        licenses.mkdir()
        shutil.copy2(info / "licenses" / "LICENSE", licenses / "python-dotenv-LICENSE")
        output = self.root / "sanitized.zip"
        export_python_bundle(self.report, output, entrypoint=PythonEntrypoint("script", "app.py"),
                             mode="portable", runtime_archive=archive,
                             runtime_sha256=OFFICIAL_31315_SHA256, runtime_version="3.13.15",
                             expected_revision=revision, dependency_tree=deps,
                             requirements_lock=lock, dependency_licenses=licenses)
        with zipfile.ZipFile(output) as zipped:
            self.assertEqual(zipped.read("source/.env.example").decode("utf-8").replace("\r\n", "\n"),
                             '# Upstream example\nS3_SECRET_KEY=""\nGITHUB_TOKEN=\n')
            manifest = json.loads(zipped.read("manifest.json"))
            self.assertEqual(manifest["sanitized_config_templates"], [".env.example"])
            self.assertNotIn(b"gitingest123", zipped.read("source/.env.example"))

    def test_reviewed_adapter_runs_after_relocation(self):
        archive = os.environ.get("REPOWAYFINDER_TEST_EMBED_ZIP", "")
        if not archive:
            self.skipTest("Reviewed Python embed ZIP is unavailable.")
        adapter = self.root / "fixture_adapter.py"
        adapter.write_text("print('REVIEWED_ADAPTER_OK')\n", encoding="utf-8")
        output = self.root / "adapter.zip"
        export_python_bundle(self.report, output,
                             entrypoint=PythonEntrypoint("adapter_script", "fixture_adapter.py"),
                             adapter_script=adapter, mode="bootstrap", runtime_archive=archive,
                             runtime_sha256=OFFICIAL_31315_SHA256, runtime_version="3.13.15",
                             expected_revision="a" * 40)
        moved = self.root / "adapter folder 中文"
        with zipfile.ZipFile(output) as zipped:
            zipped.extractall(moved)
        self.assertEqual(self._run_bat(moved, "1-首次配置环境.bat").returncode, 0)
        completed = self._run_bat(moved, "2-启动项目.bat")
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("REVIEWED_ADAPTER_OK", completed.stdout)

    def test_portable_real_runtime_after_relocation(self):
        result = self._export()
        moved = self.root / "moved folder 中文"
        with zipfile.ZipFile(result.zip_path) as zipped:
            zipped.extractall(moved)
        self.assertFalse((moved / "source" / ".env").exists())
        self.assertFalse((moved / "source" / "run.md").exists())
        self.assertTrue((moved / "source" / "LICENSE").is_file())
        completed = self._run_bat(moved, "2-启动项目.bat")
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("BUNDLE_FIXTURE_OK", completed.stdout)
        self.assertIn("INTERPRETER=", completed.stdout)
        self.assertIn("runtime\\python\\python.exe", completed.stdout)

    def test_module_entrypoint_uses_packaged_source(self):
        (self.source / "modulefixture.py").write_text("print('MODULE_ENTRY_OK')\n", encoding="utf-8")
        report = json.loads(self.report.read_text())
        report["plan_evidence"]["modulefixture.py"] = hashlib.sha256(
            (self.source / "modulefixture.py").read_bytes()
        ).hexdigest()
        self.report.write_text(json.dumps(report), encoding="utf-8")
        result = self._export(entrypoint=PythonEntrypoint("module", "modulefixture"))
        moved = self.root / "module folder 中文"
        with zipfile.ZipFile(result.zip_path) as zipped:
            zipped.extractall(moved)
        completed = self._run_bat(moved, "2-启动项目.bat")
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("MODULE_ENTRY_OK", completed.stdout)

    def test_bootstrap_can_repeat_setup_and_run(self):
        result = self._export(mode="bootstrap")
        moved = self.root / "bootstrap folder 中文"
        with zipfile.ZipFile(result.zip_path) as zipped:
            zipped.extractall(moved)
        self.assertFalse((moved / "runtime" / "python" / "python.exe").exists())
        first = self._run_bat(moved, "1-首次配置环境.bat")
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        second = self._run_bat(moved, "1-首次配置环境.bat")
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        completed = self._run_bat(moved, "2-启动项目.bat")
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("BUNDLE_FIXTURE_OK", completed.stdout)

    def test_bundle_config_helper_reads_blank_local_template(self):
        archive = os.environ.get("REPOWAYFINDER_TEST_EMBED_ZIP", "")
        if not archive:
            self.skipTest("Reviewed Python embed ZIP is unavailable.")
        (self.source / ".env.example").write_text(
            "LLM_PROVIDER=\"openai\"\nOPENAI_API_KEY=\"\"\n", encoding="utf-8"
        )
        site = Path(__file__).parent / ".reposcout-venv" / "Lib" / "site-packages"
        dotenv = site / "dotenv"
        info = site / "python_dotenv-1.2.3.dist-info"
        if not dotenv.is_dir() or not info.is_dir():
            self.skipTest("Existing pinned python-dotenv distribution is unavailable.")
        deps = self.root / "prepared-deps"
        deps.mkdir()
        shutil.copytree(dotenv, deps / "dotenv", ignore=shutil.ignore_patterns("__pycache__"))
        shutil.copytree(info, deps / info.name)
        lock = self.root / "requirements.lock"
        lock.write_text("python-dotenv==1.2.3\n", encoding="utf-8")
        licenses = self.root / "dependency-licenses"
        licenses.mkdir()
        shutil.copy2(info / "licenses" / "LICENSE", licenses / "python-dotenv-LICENSE")
        output = self.root / "config.zip"
        export_python_bundle(
            self.report, output, entrypoint=PythonEntrypoint("script", "app.py"),
            mode="portable", runtime_archive=archive,
            runtime_sha256=OFFICIAL_31315_SHA256, runtime_version="3.13.15",
            expected_revision="a" * 40,
            dependency_tree=deps, requirements_lock=lock, dependency_licenses=licenses,
        )
        moved = self.root / "config folder 中文"
        with zipfile.ZipFile(output) as zipped:
            zipped.extractall(moved)
        self.assertTrue((moved / "配置项目密钥.bat").is_file())
        self.assertFalse((moved / "source" / ".env").exists())
        setup = self._run_bat(moved, "1-首次配置环境.bat")
        self.assertEqual(setup.returncode, 0, setup.stdout + setup.stderr)
        self.assertTrue((moved / "source" / ".env").is_file())
        self.assertNotIn("synthetic-private-value", (moved / "source" / ".env").read_text())
        ps = os.path.join(os.environ["SystemRoot"], "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
        command = (
            f". '{(moved / 'tools' / 'project_configuration.ps1').as_posix()}' "
            f"-DefineOnly -Root '{(moved / 'source').as_posix()}' "
            f"-PythonExecutable '{(moved / 'runtime' / 'python' / 'python.exe').as_posix()}'; "
            f"$p=Get-TargetProjectConfigPlan '{(moved / 'source').as_posix()}'; "
            "if ($p.Groups.Count -lt 1) { exit 4 }; 'CONFIG_PLAN_OK'"
        )
        env = os.environ.copy()
        env["PATH"] = os.path.join(os.environ["SystemRoot"], "System32")
        checked = subprocess.run([ps, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command],
                                 env=env, capture_output=True, text=True, encoding="utf-8",
                                 errors="replace", timeout=30)
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        self.assertIn("CONFIG_PLAN_OK", checked.stdout)


if __name__ == "__main__":
    unittest.main()
