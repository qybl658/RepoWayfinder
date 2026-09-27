"""Candidate recall and multi-signal ordering, before AI and user selection."""
import unittest
from unittest.mock import patch
import main as app


class MultidimensionalSearchTests(unittest.TestCase):
    def setUp(self):
        self.enterContext(patch.object(app, "read_user_settings", return_value={}))
        self.enterContext(patch.object(app.deployment_history, "load_history", return_value=[]))
        self.logs = self.enterContext(patch.object(app, "log"))

    def test_non_star_top_twenty_candidate_can_enter_pool(self):
        popular = [{"full_name": f"a/popular{i:02}", "stargazers_count": 1000-i, "forks_count": 1, "pushed_at": "2020-01-01T00:00:00Z"} for i in range(25)]
        relevant = {"full_name": "a/relevant", "stargazers_count": 5, "forks_count": 100, "pushed_at": "2026-09-01T00:00:00Z", "description": "Matches the actual task"}
        with patch.object(app, "github_get_json", side_effect=[{"items": [relevant]}, {"items": popular}]) as get:
            pool = app.search_repos("task", 20)
        self.assertEqual(pool[0].full_name, "a/relevant")
        self.assertEqual(len(pool), 20)
        self.assertEqual(get.call_count, 2)
        self.assertGreater(pool[0].preselection_score, pool[-1].preselection_score)

    def test_each_signal_and_archive_status_affects_order(self):
        def repo(name, **kw):
            return app.RepoInfo("a", name, "a/"+name, "", "", **kw)
        pairs = [
            (repo("z", stars=10), repo("a", stars=1)),
            (repo("z", forks=10), repo("a", forks=1)),
            (repo("z", pushed_at="2026-01-01T00:00:00Z"), repo("a", pushed_at="2020-01-01T00:00:00Z")),
        ]
        for expected, other in pairs:
            self.assertIs(app.rank_search_pool([other, expected])[0], expected)
        archived = repo("a", stars=100, forks=100, pushed_at="2026-01-01T00:00:00Z", archived=True)
        maintained = repo("b", stars=90, forks=90, pushed_at="2025-01-01T00:00:00Z")
        small = repo("c", stars=1, forks=1, pushed_at="2020-01-01T00:00:00Z")
        self.assertIs(app.rank_search_pool([archived, maintained, small])[0], maintained)

    def test_missing_invalid_dates_and_singleton_are_bounded(self):
        invalid = app.RepoInfo("a", "a", "a/a", "", "", pushed_at="2026-02-31T00:00:00Z", updated_at="2026-01-01T00:00:00Z")
        fallback = app.RepoInfo("a", "b", "a/b", "", "", updated_at="2026-01-01T00:00:00Z")
        self.assertIs(app.rank_search_pool([invalid, fallback])[0], fallback)
        self.assertEqual(invalid.preselection_score, 0)
        self.assertEqual(app.rank_search_pool([fallback])[0].preselection_score, 0.4)

    def test_duplicate_ids_are_one_candidate_and_partial_failure_is_labeled(self):
        rows = [{"full_name": "a/repo", "stargazers_count": 5}, {"full_name": "A/Repo", "stargazers_count": 5}]
        with patch.object(app, "github_get_json", side_effect=[{"items": rows}, TimeoutError()]):
            pool = app.search_repos("task", 20)
        self.assertEqual(len(pool), 1)
        self.assertTrue(self.logs.called)
        with patch.object(app, "github_get_json", side_effect=TimeoutError()):
            with self.assertRaises(TimeoutError):
                app.search_repos("task", 20)

    def test_both_routes_are_sampled_and_refill_is_bounded(self):
        rows = [{"full_name": f"a/repo{i}"} for i in range(100)]
        with patch.object(app.deployment_history, "load_history", return_value=[{"repo": row["full_name"]} for row in rows]), patch.object(app, "github_get_json", return_value={"items": rows}) as get:
            self.assertEqual(app.search_repos("task", 20), [])
            self.assertEqual(get.call_count, 4)
            self.assertTrue(all("page=2" in call.args[0] for call in get.call_args_list[2:]))
            self.assertTrue(all(call.kwargs == {"timeout": 25, "retries": 1} for call in get.call_args_list))

    def test_keyword_candidates_are_public_even_with_existing_token(self):
        with patch.object(app, "github_get_json", return_value={"items": [None, {"full_name": "a/private", "private": True}, {"full_name": "a/public", "private": False}]}) as get:
            pool = app.search_repos("task", 20)
        self.assertEqual([repo.full_name for repo in pool], ["a/public"])
        self.assertTrue(all("is%3Apublic" in call.args[0] for call in get.call_args_list))


if __name__ == "__main__":
    unittest.main()
