"""Repository purpose checks use inert files; no project code is executed."""

import json
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import integration_targets as integration


class RepositoryPurposeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def write(self, relative, content):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return path

    def skill(self, relative="skills/helper/SKILL.md", name="helper"):
        self.write(relative, f"---\nname: {name}\ndescription: Fixture\n---\nUse this fixture.\n")

    def purposes(self):
        candidates = integration.discover_integrations(self.root)
        return integration.repository_purposes(self.root, candidates)

    def test_python_entry_points_make_nested_skills_bundled_content(self):
        manifests = {
            "project script": ("pyproject.toml", '[project]\nname = "sample"\n[project.scripts]\nsample = "sample:main"\n'),
            "project GUI script": ("pyproject.toml", '[project]\nname = "sample"\n[project.gui-scripts]\nsample = "sample:main"\n'),
            "Poetry script": ("pyproject.toml", '[tool.poetry]\nname = "sample"\n[tool.poetry.scripts]\nsample = "sample:main"\n'),
            "setuptools entry point": ("setup.cfg", '[options.entry_points]\nconsole_scripts =\n    sample = sample:main\n'),
        }
        for label, (name, content) in manifests.items():
            with self.subTest(label=label):
                self.skill()
                self.write(name, content)
                self.assertEqual(self.purposes(), ["app"])
                (self.root / name).unlink()

    def test_node_rust_go_and_procfile_entry_points_make_nested_skills_bundled(self):
        manifests = {
            "Node bin": ("package.json", json.dumps({"name": "sample", "bin": {"sample": "cli.js"}})),
            "Node start": ("package.json", json.dumps({"name": "sample", "scripts": {"start": "node app.js"}})),
            "Electron main": ("package.json", json.dumps({"name": "sample", "main": "desktop.js", "devDependencies": {"electron": "^30"}})),
            "Rust bin": ("Cargo.toml", '[package]\nname = "sample"\nversion = "0.1.0"\n[[bin]]\nname = "sample"\npath = "src/main.rs"\n'),
            "Rust main": ("src/main.rs", 'fn main() { println!("hello"); }\n'),
            "Go main": ("main.go", 'package main\nfunc main() {}\n'),
            "Procfile web": ("Procfile", 'web: python app.py\n'),
        }
        for label, (name, content) in manifests.items():
            with self.subTest(label=label):
                self.skill()
                self.write(name, content)
                if label == "Rust main":
                    self.write("Cargo.toml", '[package]\nname = "sample"\nversion = "0.1.0"\n')
                if label == "Go main":
                    self.write("go.mod", "module example.com/sample\n")
                self.assertEqual(self.purposes(), ["app"])
                (self.root / name).unlink()
                if label == "Rust main":
                    (self.root / "Cargo.toml").unlink()
                if label == "Go main":
                    (self.root / "go.mod").unlink()

    def test_dependency_manifests_alone_do_not_turn_skill_collection_into_app(self):
        self.skill()
        self.write("pyproject.toml", '[project]\nname = "sample"\ndependencies = ["requests"]\n')
        self.write("package.json", json.dumps({"name": "sample", "dependencies": {"lodash": "^4"}}))
        self.assertEqual(self.purposes(), ["skills"])

    def test_root_skill_and_app_entry_point_preserve_both_purposes(self):
        self.skill("SKILL.md", "root-helper")
        self.skill()
        self.write("pyproject.toml", '[project]\nname = "sample"\n[project.scripts]\nsample = "sample:main"\n')
        self.assertEqual(set(self.purposes()), {"app", "skills"})

    def test_container_file_and_nested_skills_need_purpose_choice(self):
        self.skill()
        self.write("Dockerfile", "FROM python:3.12-slim\nCMD [\"python\", \"app.py\"]\n")
        self.assertEqual(set(self.purposes()), {"app", "skills"})

    def test_extension_purposes_override_nested_skills_but_keep_root_skill(self):
        extensions = {
            "browser": ("manifest.json", json.dumps({"manifest_version": 3, "name": "Sample", "version": "1"})),
            "vscode": ("package.json", json.dumps({"name": "sample", "engines": {"vscode": "^1.80.0"}})),
        }
        for label, (name, content) in extensions.items():
            with self.subTest(extension=label):
                self.skill()
                self.write(name, content)
                self.assertEqual(self.purposes(), [label])
                self.skill("SKILL.md", "root-helper")
                self.assertEqual(set(self.purposes()), {label, "skills"})
                (self.root / "SKILL.md").unlink()
                (self.root / name).unlink()

    def test_app_and_extension_are_both_visible_with_nested_skills(self):
        self.skill()
        self.write("pyproject.toml", '[project]\nname = "sample"\n[project.scripts]\nsample = "sample:main"\n')
        self.write("manifest.json", json.dumps({"manifest_version": 3, "name": "Sample", "version": "1"}))
        self.assertEqual(set(self.purposes()), {"app", "browser"})
        (self.root / "manifest.json").unlink()
        self.write("package.json", json.dumps({"name": "sample", "engines": {"vscode": "^1.80.0"}}))
        self.assertEqual(set(self.purposes()), {"app", "vscode"})

    def test_explicit_skill_selection_excludes_unselected_extensions(self):
        self.skill()
        self.write("manifest.json", json.dumps({"manifest_version": 3, "name": "Sample", "version": "1"}))
        self.write("package.json", json.dumps({"name": "sample", "engines": {"vscode": "^1.80.0"}}))
        chosen = integration.discover_integrations(self.root, "skills/helper")
        self.assertEqual([(item["kind"], item["relative"]) for item in chosen], [("agent_skill", "skills/helper")])

    def test_malformed_manifests_do_not_crash_or_create_false_app_purpose(self):
        self.skill()
        self.write("pyproject.toml", "[project\n")
        self.write("Cargo.toml", "[[bin]\n")
        self.write("package.json", "{broken")
        self.write("manifest.json", "{broken")
        self.assertEqual(self.purposes(), ["skills"])
        self.write("pyproject.toml", 'tool = "bad"\n')
        self.assertEqual(self.purposes(), ["skills"])


if __name__ == "__main__":
    unittest.main()
