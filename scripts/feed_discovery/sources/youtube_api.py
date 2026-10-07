# scripts/feed_discovery/sources/youtube_api.py

from __future__ import annotations

import os
import time
from urllib.parse import urlencode

import aiohttp

from ..models import Candidate
from ..opml import normalize_url
from ..profiles._schema import CountryProfile, SourceConfig
from ._base import ProbeResult


class YouTubeAPISource:
    """YouTube Data API v3 -- official API, 10K quota/day free.

    API docs: https://developers.google.com/youtube/v3/docs
    Auth: API key from Google Cloud Console.
    Quota: search.list costs 100 units, channels.list costs 1 unit.

    Replaces youtube_scrape.py (DDG parsing + About page scraping)
    with reliable, official API calls.

    Env vars:
        YOUTUBE_API_KEY: API key from console.cloud.google.com
    """
    name = "youtube_api"
    BASE = "https://www.googleapis.com/youtube/v3"

    def __init__(self):
        self.api_key = os.getenv("YOUTUBE_API_KEY", "")
        self.enabled = bool(self.api_key)
        if not self.enabled:
            import warnings
            warnings.warn(
                "YouTubeAPISource disabled: YOUTUBE_API_KEY env var not set. "
                "Get a free key at https://console.cloud.google.com/apis/credentials"
            )

    def _channel_rss_url(self, channel_id: str) -> str:
        return f"https://www.youtube.com/feeds/videos.xml?channel_id={channel_id}"

    def _estimate_quota(self, channel_count: int) -> int:
        """Estimate quota units consumed: search=100 + channels=1 each."""
        return 100 + channel_count if channel_count > 0 else 100

    async def search(
        self,
        query: str,
        profile: CountryProfile,
        config: SourceConfig,
        session: aiohttp.ClientSession,
    ) -> list[Candidate]:
        """Search YouTube for channels matching the query.

        Two-step process:
        1. search.list to find channel IDs (100 quota units)
        2. channels.list to get brandingSettings (country, title) (1 unit each)

        The regionCode parameter from config.params restricts results
        to channels relevant to the target country.
        """
        if not self.enabled:
            return []

        region_code = config.params.get("regionCode", "")
        candidates: list[Candidate] = []
        seen_channel_ids: set[str] = set()

        # Step 1: Search for channels
        search_params = {
            "part": "snippet",
            "type": "channel",
            "q": query,
            "maxResults": str(min(config.max_results, 50)),
            "key": self.api_key,
        }
        if region_code:
            search_params["regionCode"] = region_code

        search_url = f"{self.BASE}/search?{urlencode(search_params)}"
        channel_ids: list[str] = []

        try:
            async with session.get(
                search_url,
                timeout=aiohttp.ClientTimeout(total=config.timeout),
            ) as resp:
                if resp.status != 200:
                    return []
                data = await resp.json()
                for item in data.get("items", []):
                    cid = item.get("snippet", {}).get("channelId", "")
                    if cid and cid not in seen_channel_ids:
                        seen_channel_ids.add(cid)
                        channel_ids.append(cid)
        except Exception:
            return []

        if not channel_ids:
            return []

        # Step 2: Get channel details (brandingSettings for country)
        channels_params = {
            "part": "snippet,brandingSettings",
            "id": ",".join(channel_ids[:50]),
            "key": self.api_key,
        }
        channels_url = f"{self.BASE}/channels?{urlencode(channels_params)}"

        try:
            async with session.get(
                channels_url,
                timeout=aiohttp.ClientTimeout(total=config.timeout),
            ) as resp:
                if resp.status != 200:
                    return []
                data = await resp.json()
                for item in data.get("items", []):
                    cid = item.get("id", "")
                    snippet = item.get("snippet", {})
                    branding = item.get("brandingSettings", {})
                    channel_info = branding.get("channel", {})

                    title = snippet.get("title", "")
                    channel_country = channel_info.get("country", "")

                    rss_url = self._channel_rss_url(cid)
                    # Country-aware: regionCode is search relevance, not proof
                    # that the channel is national. A channel whose declared
                    # country differs from the profile's region stays in the
                    # list but is marked non-national, so it cannot be promoted
                    # as a local source; the reason keeps both codes for review.
                    mismatch = bool(
                        region_code and channel_country
                        and channel_country.upper() != region_code.upper()
                    )

                    candidates.append(Candidate(
                        url=rss_url,
                        category="YouTube",
                        title=title,
                        genre="",
                        national=not mismatch,
                        national_reason=(
                            f"youtube_api:{channel_country}!={region_code.upper()}"
                            if mismatch else f"youtube_api:{channel_country}"
                        ),
                    ))
        except Exception:
            pass

        return candidates

    async def probe(
        self,
        profile: CountryProfile,
        config: SourceConfig,
        session: aiohttp.ClientSession,
    ) -> ProbeResult:
        """Probe YouTube API with a country-targeted query."""
        if not self.enabled:
            return ProbeResult(
                source_name="youtube_api",
                success=False,
                result_count=0,
                latency_ms=0,
                error="disabled: missing YOUTUBE_API_KEY",
            )

        t0 = time.monotonic()
        query = f"{profile.country.replace('-', ' ')} news"
        try:
            results = await self.search(query, profile, config, session)
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="youtube_api",
                success=len(results) > 0,
                result_count=len(results),
                latency_ms=elapsed,
            )
        except Exception as e:
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="youtube_api",
                success=False,
                result_count=0,
                latency_ms=elapsed,
                error=str(e)[:200],
            )
