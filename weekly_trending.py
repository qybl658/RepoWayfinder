"""Read GitHub's public weekly Trending order without credentials or extra deps."""
from html.parser import HTMLParser
import re

import requests

TRENDING_URL = "https://github.com/trending?since=weekly"


class TrendingParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.rows = []
        self.row = None
        self.text = []
        self.heading = False
        self.capture = None
        self.buffer = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "article" and "Box-row" in attrs.get("class", "").split():
            self.row = {"repo": "", "description": "", "language": "", "stars": None}
            self.text = []
            self.heading = False
            self.capture = None
        if self.row is None:
            return
        if tag == "h2":
            self.heading = True
        href = attrs.get("href", "")
        if tag == "a" and self.heading and re.fullmatch(r"/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", href):
            self.row["repo"] = href[1:]
        field = None
        if tag == "p":
            field = "description"
        elif tag == "span" and attrs.get("itemprop") == "programmingLanguage":
            field = "language"
        elif tag == "a" and href == "/" + self.row["repo"] + "/stargazers":
            field = "stars"
        if field and self.capture is None:
            self.capture = (tag, field)
            self.buffer = []

    def handle_data(self, data):
        if self.row is not None:
            self.text.append(data)
            if self.capture:
                self.buffer.append(data)

    def handle_endtag(self, tag):
        if self.row is None:
            return
        if self.capture and tag == self.capture[0]:
            field = self.capture[1]
            value = " ".join(" ".join(self.buffer).split())
            self.row[field] = int(value.replace(",", "")) if field == "stars" and re.fullmatch(r"[\d,]+", value) else value
            self.capture = None
        if tag == "h2":
            self.heading = False
        if tag == "article":
            text = " ".join(" ".join(self.text).split())
            weekly = re.search(r"([\d,]+) stars? this week\b", text)
            if self.row["repo"] and weekly:
                self.row["weekly_stars"] = int(weekly[1].replace(",", ""))
                self.row["description"] = self.row["description"][:600]
                self.rows.append(self.row)
            self.row = None


def parse_weekly_trending(html: str) -> list[dict]:
    parser = TrendingParser()
    parser.feed(html)
    rows = []
    seen = set()
    for row in parser.rows:
        if row["repo"].casefold() not in seen:
            rows.append(row)
            seen.add(row["repo"].casefold())
    if not rows:
        raise ValueError("Weekly Trending entries were not found")
    return rows[:10]


def fetch_weekly_trending() -> list[dict]:
    with requests.get(TRENDING_URL, headers={"User-Agent": "RepoWayfinder", "Accept-Language": "en"},
                      timeout=(5, 15), stream=True) as response:
        response.raise_for_status()
        chunks = []
        size = 0
        for chunk in response.iter_content(65536):
            size += len(chunk)
            if size > 3 * 1024 * 1024:
                raise ValueError("Trending response exceeds size limit")
            chunks.append(chunk)
    return parse_weekly_trending(b"".join(chunks).decode("utf-8", errors="replace"))


def recent_projects_source(now=None):
    from datetime import datetime, timedelta, timezone
    from urllib.parse import quote
    now = now or datetime.now(timezone.utc)
    cutoff = (now - timedelta(days=30)).date().isoformat()
    query = f"created:>={cutoff} stars:>0 fork:false archived:false is:public"
    return query, "https://github.com/search?q=" + quote(query) + "&type=repositories&s=stars&o=desc"


def fetch_recent_projects(get_json, now=None) -> list[dict]:
    from datetime import datetime, timedelta, timezone
    from urllib.parse import quote
    now = now or datetime.now(timezone.utc)
    cutoff = (now - timedelta(days=30)).date()
    query, _ = recent_projects_source(now)
    data = get_json("https://api.github.com/search/repositories?q=" + quote(query)
                    + "&sort=stars&order=desc&per_page=30", timeout=20, retries=1)
    if not isinstance(data, dict) or not isinstance(data.get("items"), list) or data.get("incomplete_results"):
        raise ValueError("New-project search did not return a complete result")
    rows, seen = [], set()
    for item in data["items"]:
        if not isinstance(item, dict) or item.get("fork") or item.get("archived") or item.get("private"):
            continue
        try:
            name = item["full_name"]
            created = datetime.fromisoformat(item["created_at"].replace("Z", "+00:00"))
            if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", name) or not cutoff <= created.date() <= now.date():
                continue
            stars = int(item["stargazers_count"])
            if stars <= 0 or name.casefold() in seen:
                continue
            seen.add(name.casefold())
            rows.append({"repo": name, "description": str(item.get("description") or "")[:600],
                         "language": item.get("language") or "—", "stars": stars, "created_at": item["created_at"]})
        except (KeyError, TypeError, ValueError):
            continue
    return sorted(rows, key=lambda row: (-row["stars"], row["repo"].casefold()))[:10]
