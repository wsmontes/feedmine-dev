# scripts/feed_discovery/sources/deezer.py

from __future__ import annotations

import time
from urllib.parse import urlencode

import aiohttp

from ..models import Candidate
from ..opml import normalize_url
from ..profiles._schema import CountryProfile, SourceConfig
from ._base import ProbeResult


class DeezerSource:
    """Deezer API — free, no auth, strong in LatAm/Africa/Europe.

    API docs: https://developers.deezer.com/api
    Podcast search: /search/podcast?q={query}
    No authentication required for search endpoints.

    Deezer's podcast catalog varies by region (based on IP for unauthenticated
    requests). Results include show ID, title, description, and a link to the
    Deezer web player. The actual RSS feed URL may need to be derived from
    the show ID or fetched from the show's detail page.
    """
    name = "deezer"
    BASE = "https://api.deezer.com"

    def __init__(self):
        self.enabled = True  # Always enabled — no auth needed

    async def search(
        self,
        query: str,
        profile: CountryProfile,
        config: SourceConfig,
        session: aiohttp.ClientSession,
    ) -> list[Candidate]:
        """Search Deezer for podcasts matching the query.

        Deezer's API returns no RSS URL — only the show's HTML page
        (https://www.deezer.com/show/{id}) — and a web page is not a feed, so
        this adapter yields no candidates: a sub-region OPML must not receive
        HTML. The requests stay so the endpoint contract remains observable
        and the probe can report service health.
        """
        candidates: list[Candidate] = []

        # Primary: podcast-specific search
        params = {"q": query, "limit": str(config.max_results)}
        url = f"{self.BASE}/search/podcast?{urlencode(params)}"

        try:
            async with session.get(
                url,
                timeout=aiohttp.ClientTimeout(total=config.timeout),
            ) as resp:
                if resp.status == 200:
                    await resp.json()
        except Exception:
            pass

        # Fallback: generic search filtered to podcasts; its type=podcast
        # entries are what a future feed resolver would consume.
        fallback_url = f"{self.BASE}/search?q={query}&limit={config.max_results}"
        try:
            async with session.get(
                fallback_url,
                timeout=aiohttp.ClientTimeout(total=config.timeout),
            ) as resp:
                if resp.status == 200:
                    await resp.json()
        except Exception:
            pass

        return candidates

    async def probe(
        self,
        profile: CountryProfile,
        config: SourceConfig,
        session: aiohttp.ClientSession,
    ) -> ProbeResult:
        """Probe Deezer with the country name."""
        t0 = time.monotonic()
        query = profile.country.replace("-", " ")
        try:
            results = await self.search(query, profile, config, session)
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="deezer",
                success=len(results) > 0,
                result_count=len(results),
                latency_ms=elapsed,
            )
        except Exception as e:
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="deezer",
                success=False,
                result_count=0,
                latency_ms=elapsed,
                error=str(e)[:200],
            )
