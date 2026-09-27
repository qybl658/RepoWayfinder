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
        self.enterContext(patch.object(app, "AI_API_KEY", ""))

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

    def test_weekly_introductions_batch_and_safe_fallback(self):
        rows = [{"repo": "a/one", "description": "Translate text in screenshots."},
                {"repo": "a/empty", "description": ""},
                {"repo": "a/long", "description": "Long description " * 30}]
        with patch.object(app, "AI_API_KEY", "test"), patch.object(app, "OpenAI") as factory:
            create = factory.return_value.chat.completions.create
            create.return_value = SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content=json.dumps({"a/one": "翻译截图中的文字。", "a/empty": "invented", "unknown/repo": "invented", "a/long": "x" * 121})))])
            descriptions = app.weekly_brief_introductions(rows)
            self.assertEqual(create.call_count, 1)
            self.assertEqual(factory.call_args.kwargs["timeout"], 20)
            self.assertEqual(create.call_args.kwargs["extra_body"], {"thinking": {"type": "disabled"}})
            self.assertEqual(descriptions["a/one"], "翻译截图中的文字。")
            self.assertNotEqual(descriptions["a/empty"], "invented")
            self.assertNotIn("unknown/repo", descriptions)
            self.assertLessEqual(len(descriptions["a/long"]), 120)
            create.side_effect = TimeoutError("private error")
            self.assertEqual(app.weekly_brief_introductions(rows)["a/one"], rows[0]["description"])
        with patch.object(app, "OpenAI") as factory:
            self.assertEqual(app.weekly_brief_introductions(rows)["a/one"], rows[0]["description"])
            factory.assert_not_called()

    def test_recent_projects_exclude_old_and_forks(self):
        from datetime import datetime, timezone
        from weekly_trending import fetch_recent_projects
        now = datetime(2026, 9, 27, tzinfo=timezone.utc)
        items = [{"full_name": "a/old", "created_at": "2020-01-01T00:00:00Z", "stargazers_count": 99999},
                 {"full_name": "a/new", "created_at": "2026-09-20T00:00:00Z", "stargazers_count": 99},
                 {"full_name": "a/fork", "created_at": "2026-09-20T00:00:00Z", "stargazers_count": 1000, "fork": True}]
        get = MagicMock(return_value={"items": items})
        self.assertEqual([r["repo"] for r in fetch_recent_projects(get, now)], ["a/new"])
        self.assertIn("created%3A%3E%3D2026-08-28", get.call_args.args[0])
        self.assertEqual(app.short_ai_request_options("https://api.deepseek.com")["extra_body"], {"thinking": {"type": "disabled"}})
        self.assertEqual(app.short_ai_request_options("https://example.com/v1"), {})

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

    def test_weekly_selection_uses_displayed_repo_and_noninteractive_only_lists(self):
        rows = [{"repo": "a/first", "description": "Example", "language": "Python", "stars": 10, "created_at": "2026-09-20T00:00:00Z"},
                {"repo": "b/second", "description": "Example", "language": "Go", "stars": 20, "created_at": "2026-09-21T00:00:00Z"}]
        with patch("weekly_trending.fetch_recent_projects", return_value=rows), \
             patch.object(app, "reposcout_interactive", return_value=True), \
             patch.object(app, "read_visible_input", return_value="2"):
            self.assertEqual(app.choose_weekly_trending(), "b/second")
        with patch("weekly_trending.fetch_recent_projects", return_value=rows), \
             patch.object(app, "reposcout_interactive", return_value=False), \
             patch.object(app, "read_visible_input") as prompt:
            self.assertIsNone(app.choose_weekly_trending())
            prompt.assert_not_called()


if __name__ == "__main__":
    unittest.main()
