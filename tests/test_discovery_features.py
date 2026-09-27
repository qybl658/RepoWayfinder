import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch, MagicMock

import main as app
import integration_targets as integration
from weekly_trending import parse_weekly_trending


class DiscoveryFeaturesTests(unittest.TestCase):
    def setUp(self):
        self.enterContext(patch.object(app, "log"))

    def test_expansion_keeps_original_and_rejects_dropped_names(self):
        with patch.object(app, "AI_API_KEY", "test"), patch.object(app, "OpenAI") as factory:
            create = factory.return_value.chat.completions.create
            create.return_value = SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content=json.dumps({"queries": ["pdf batch rename", "file rename"]})))])
            self.assertEqual(app.prepare_search_queries("按内容批量重命名PDF"), ["按内容批量重命名PDF", "pdf batch rename"])
            self.assertEqual(create.call_count, 1)
            self.assertEqual(factory.call_args.kwargs["max_retries"], 0)
            create.side_effect = TimeoutError("must not be logged")
            self.assertEqual(app.prepare_search_queries("PDF工具"), ["PDF工具"])
            create.side_effect = None
            create.return_value.choices[0].message.content = '{"queries":["pdf stars:>999999"]}'
            self.assertEqual(app.prepare_search_queries("PDF工具"), ["PDF工具"])
            create.reset_mock()
            for keyword in ("pdf language:Python", "DeepSeek", "a/repo"):
                self.assertEqual(app.prepare_search_queries(keyword), [keyword])
            create.assert_not_called()

    def test_expansion_count_dedup_and_empty_plan(self):
        with patch.object(app, "AI_API_KEY", "test"), patch.object(app, "OpenAI") as factory:
            create = factory.return_value.chat.completions.create
            for variants, expected in [([], ["截图翻译"]),
                                       (["screen translation", "SCREEN translation"], ["截图翻译", "screen translation"]),
                                       (["a", "b", "c"], ["截图翻译"])]:
                create.return_value = SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content=json.dumps({"queries": variants})))])
                self.assertEqual(app.prepare_search_queries("截图翻译"), expected)

    def test_queries_search_original_and_rank_original_intent(self):
        repo = app.RepoInfo("a", "pdf", "a/pdf", "", "")
        queries = ["按内容重命名PDF", "pdf rename"]
        with patch.object(app, "prepare_search_queries", return_value=queries), \
             patch.object(app, "search_repos", return_value=[repo]) as search, \
             patch.object(app, "rank_repository_candidates", return_value=([repo], False)) as rank, \
             patch.object(app, "reposcout_interactive", return_value=True), \
             patch.object(app, "read_visible_input", return_value=""):
            self.assertIsNone(app.choose_target("按内容重命名PDF", 20))
            search.assert_called_once_with("按内容重命名PDF", max_candidates=20, queries=queries)
            rank.assert_called_once_with("按内容重命名PDF", [repo])
        with patch.object(app, "fetch_repo_info", return_value=repo), patch.object(app, "prepare_search_queries") as expand:
            self.assertIs(app.choose_target("a/pdf", 20), repo)
            expand.assert_not_called()

    def test_weekly_order_entities_and_missing_metrics(self):
        def article(name, week):
            return f'<article class="Box-row"><h2><a href="/{name}">owner / repo</a></h2><p>PDF &amp; office</p><span itemprop="programmingLanguage">Python</span><a href="/{name}/stargazers"><svg></svg>12,345</a><span>{week}</span></article>'
        html = article("a/low", "1,234 stars this week") + article("b/high", "9,876 stars this week") + article("a/low", "1,234 stars this week")
        rows = parse_weekly_trending(html)
        self.assertEqual([r["repo"] for r in rows], ["a/low", "b/high"])
        self.assertEqual(rows[0]["description"], "PDF & office")
        self.assertEqual(rows[0]["stars"], 12345)
        self.assertEqual(rows[0]["weekly_stars"], 1234)
        with self.assertRaises(ValueError):
            parse_weekly_trending(article("a/repo", "1,234 stars today"))

    def test_domestic_hosts_route_to_own_directories_without_other_hosts(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            bundle = home / "DSH portable"
            (bundle / "app").mkdir(parents=True)
            (bundle / "app/DSH Desktop.exe").touch()
            (bundle / "Start-DSH.ps1").touch()
            (bundle / "PORTABLE-MANIFEST.json").write_text(json.dumps({"app": "dataelement/dsh-desktop v0.9.2"}))
            with patch.dict(os.environ, {"REPOWAYFINDER_DSH_BUNDLE": str(bundle)}), \
                 patch.object(integration, "_known_executable", side_effect=lambda command, paths: command if command in {"qodercli", "codebuddy"} else ""):
                hosts = integration.detect_hosts(home)
            self.assertEqual(set(hosts), {"qoder", "codebuddy", "dsh-portable"})
            source = home / "repo"
            source.mkdir()
            (source / "SKILL.md").write_text("---\nname: sample\ndescription: Example\n---\nHello", encoding="utf-8")
            results = integration.apply_integrations(integration.discover_integrations(source), hosts)
            self.assertTrue(all(r["status"] == "installed" for r in results))
            for relative in (".qoder/skills/sample/SKILL.md", ".codebuddy/skills/sample/SKILL.md", "DSH portable/data/Home/.agents/skills/sample/SKILL.md"):
                self.assertTrue((home / relative).is_file())
            self.assertFalse((home / ".agents").exists())
            nested = source / ".dsh/skills/native"
            nested.mkdir(parents=True)
            (nested / "SKILL.md").write_text("---\nname: native\ndescription: DSH workflow\n---\nHello", encoding="utf-8")
            selected = integration.discover_integrations(source, "native")
            routed = integration.apply_integrations(selected, hosts)
            self.assertEqual([row["host"] for row in routed], ["dsh-portable"])
            self.assertTrue((bundle / "data/Roaming/dsh-desktop/harness/skills/native/SKILL.md").is_file())
            self.assertFalse((bundle / "data/Home/.agents/skills/native").exists())

    def test_portable_setting_preserves_preferences_and_clear_preserves_bundle(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "settings.json"
            path.write_text('{"ui_language":"en","include_deployed_in_search":true}', encoding="utf-8")
            bundle = Path(folder) / "bundle"
            bundle.mkdir()
            with patch.object(app, "SETTINGS_PATH", path), patch.object(app, "reposcout_interactive", return_value=True), \
                 patch.object(app.integration_targets, "validate_dsh_bundle", return_value=bundle), \
                 patch.object(app, "read_visible_input", side_effect=[str(bundle), "-"]):
                self.assertEqual(app.configure_integration_hosts(), 0)
                self.assertEqual(app.read_user_settings()["dsh_bundle_path"], str(bundle))
                self.assertTrue(app.read_user_settings()["include_deployed_in_search"])
                self.assertEqual(app.configure_integration_hosts(), 0)
                self.assertEqual(app.read_user_settings(), {"ui_language": "en", "include_deployed_in_search": True})
            self.assertTrue(bundle.exists())

    def test_weekly_selection_uses_displayed_repo_and_noninteractive_only_lists(self):
        rows = [{"repo": "a/first", "description": "Example", "language": "Python", "stars": 10, "weekly_stars": 3},
                {"repo": "b/second", "description": "Example", "language": "Go", "stars": 20, "weekly_stars": 5}]
        with patch("weekly_trending.fetch_weekly_trending", return_value=rows), \
             patch.object(app, "reposcout_interactive", return_value=True), \
             patch.object(app, "read_visible_input", return_value="2"):
            self.assertEqual(app.choose_weekly_trending(), "b/second")
        with patch("weekly_trending.fetch_weekly_trending", return_value=rows), \
             patch.object(app, "reposcout_interactive", return_value=False), \
             patch.object(app, "read_visible_input") as prompt:
            self.assertIsNone(app.choose_weekly_trending())
            prompt.assert_not_called()


if __name__ == "__main__":
    unittest.main()
