# scripts/feed_discovery/sources/google_news.py

from __future__ import annotations

import time
from urllib.parse import urlencode

from ..models import Candidate
from ..profiles._schema import CountryProfile, SourceConfig
from ._base import ProbeResult


class GoogleNewsSource:
    """Google News RSS feeds by country and language.

    Uses Google News RSS URLs that work without authentication:
    https://news.google.com/rss/search?q={query}&hl={lang}&gl={iso2}&ceid={iso2}:{lang}

    Generates RSS feed URLs for top news, local topics, and regional
    coverage per country. No API key required.
    """

    name = "google_news"
    BASE = "https://news.google.com/rss"

    # ISO2 country code mapping
    _ISO2_MAP: dict[str, str] = {}

    def __init__(self):
        self.enabled = True
        self._load_iso2_map()

    def _load_iso2_map(self):
        import json
        from pathlib import Path
        countries_path = (
            Path(__file__).resolve().parents[1] / "data" / "countries.json"
        )
        if not countries_path.exists():
            return
        try:
            countries = json.loads(countries_path.read_text(encoding="utf-8"))
        except Exception:
            return
        for slug, data in countries.items():
            iso2 = data.get("iso2", "").lower()
            if iso2:
                self._ISO2_MAP[slug] = iso2

    async def search(
        self, query: str, profile: CountryProfile,
        config: SourceConfig, session,
    ) -> list[Candidate]:
        """Generate Google News RSS feeds for the profile's country.

        With a query, uses
        https://news.google.com/rss/search?q={query}&hl={lang}&gl={iso2}&ceid={iso2}:{lang}
        so a sub-region query does not degrade into the country's general
        headlines. Without a query (probe), falls back to the localized
        top-headlines feed https://news.google.com/rss?hl={lang}&gl={iso2}&ceid={iso2}:{lang}.
        """
        country_slug = (profile.country or "").lower()
        iso2 = self._ISO2_MAP.get(country_slug, "")
        if not iso2:
            return []

        languages = profile.languages[:2] if profile.languages else ["en"]
        candidates: list[Candidate] = []
        seen: set[str] = set()

        for lang in languages:
            iso2u = iso2.upper()
            if query:
                params = urlencode(
                    {"q": query, "hl": lang, "gl": iso2u, "ceid": f"{iso2u}:{lang}"}
                )
                url = f"{self.BASE}/search?{params}"
            else:
                # Google News RSS — localized top headlines
                url = f"{self.BASE}?hl={lang}&gl={iso2u}&ceid={iso2u}:{lang}"
            if url not in seen:
                seen.add(url)
                candidates.append(Candidate(
                    url=url,
                    category="News",
                    title=f"Google News — {country_slug.upper()} ({lang})",
                    genre="",
                    national=True,
                    national_reason=f"google_news:{country_slug}:{lang}",
                ))

        return candidates[:config.max_results]

    async def probe(
        self, profile: CountryProfile,
        config: SourceConfig, session,
    ) -> ProbeResult:
        if not self._ISO2_MAP.get((profile.country or "").lower()):
            return ProbeResult(
                source_name="google_news", success=False,
                result_count=0, latency_ms=0,
                error=f"no ISO2 for {profile.country}",
            )
        t0 = time.monotonic()
        try:
            results = await self.search("", profile, config, session)
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="google_news",
                success=len(results) > 0,
                result_count=len(results),
                latency_ms=elapsed,
            )
        except Exception as e:
            return ProbeResult(
                source_name="google_news", success=False,
                result_count=0, latency_ms=(time.monotonic() - t0) * 1000,
                error=str(e)[:200],
            )
