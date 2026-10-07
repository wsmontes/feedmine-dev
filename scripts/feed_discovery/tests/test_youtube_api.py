# scripts/feed_discovery/tests/test_youtube_api.py

import os
import pytest
from scripts.feed_discovery.sources._base import SourceProtocol, ProbeResult
from scripts.feed_discovery.sources.youtube_api import YouTubeAPISource
from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig
from scripts.feed_discovery.models import Candidate


def test_implements_protocol():
    assert isinstance(YouTubeAPISource(), SourceProtocol)


def test_name():
    assert YouTubeAPISource().name == "youtube_api"


def test_disabled_without_env_var(monkeypatch):
    monkeypatch.delenv("YOUTUBE_API_KEY", raising=False)
    source = YouTubeAPISource()
    assert source.enabled is False


def test_enabled_with_env_var(monkeypatch):
    monkeypatch.setenv("YOUTUBE_API_KEY", "test-key")
    source = YouTubeAPISource()
    assert source.enabled is True


def test_has_search_and_probe():
    source = YouTubeAPISource()
    assert callable(source.search)
    assert callable(source.probe)


@pytest.mark.asyncio
async def test_search_returns_candidates():
    if not os.getenv("YOUTUBE_API_KEY"):
        pytest.skip("YOUTUBE_API_KEY not set")
    source = YouTubeAPISource()
    profile = CountryProfile(country="nigeria", languages=["en"])
    config = SourceConfig(priority=3, max_results=10, timeout=15, params={"regionCode": "NG"})
    import aiohttp
    async with aiohttp.ClientSession() as session:
        results = await source.search("lagos nigeria news", profile, config, session)
    assert isinstance(results, list)
    if results:
        assert isinstance(results[0], Candidate)
        assert results[0].category == "YouTube"


@pytest.mark.asyncio
async def test_probe_returns_probe_result():
    if not os.getenv("YOUTUBE_API_KEY"):
        pytest.skip("YOUTUBE_API_KEY not set")
    source = YouTubeAPISource()
    profile = CountryProfile(country="nigeria", languages=["en"])
    config = SourceConfig(priority=3, max_results=5, timeout=15, params={"regionCode": "NG"})
    import aiohttp
    async with aiohttp.ClientSession() as session:
        result = await source.probe(profile, config, session)
    assert isinstance(result, ProbeResult)
    assert result.source_name == "youtube_api"


@pytest.mark.asyncio
async def test_search_disabled_returns_empty():
    source = YouTubeAPISource()
    source.enabled = False
    profile = CountryProfile(country="nigeria")
    config = SourceConfig(priority=3)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        results = await source.search("test", profile, config, session)
    assert results == []


def test_channel_rss_url_format():
    """Verify RSS URL construction for YouTube channels."""
    source = YouTubeAPISource()
    url = source._channel_rss_url("UC1234567890abcdefghij")
    assert url == "https://www.youtube.com/feeds/videos.xml?channel_id=UC1234567890abcdefghij"


class _StubResponse:
    def __init__(self, payload):
        self.status = 200
        self._payload = payload

    async def json(self):
        return self._payload

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc_info):
        return False


class _StubSession:
    """Minimal session stub: search.list returns one channel and
    channels.list reports the country that channel declares."""

    def __init__(self, channel_country):
        self.channel_country = channel_country
        self.requested: list[str] = []

    def get(self, url, **kwargs):
        self.requested.append(url)
        if "/search?" in url:
            return _StubResponse(
                {"items": [{"snippet": {"channelId": "UC_foreign_channel"}}]}
            )
        return _StubResponse({
            "items": [{
                "id": "UC_foreign_channel",
                "snippet": {"title": "Elsewhere TV"},
                "brandingSettings": {"channel": {"country": self.channel_country}},
            }]
        })


@pytest.mark.asyncio
async def test_channel_from_another_country_is_not_national(monkeypatch):
    """regionCode is search relevance; a channel declaring another country must
    not be promoted as a national source (no network: stubbed session)."""
    monkeypatch.setenv("YOUTUBE_API_KEY", "test-key")
    source = YouTubeAPISource()
    profile = CountryProfile(country="usa", languages=["en"])
    config = SourceConfig(priority=3, params={"regionCode": "US"})

    candidates = await source.search("usa news", profile, config, _StubSession("GB"))

    assert len(candidates) == 1
    assert candidates[0].national is False
    assert candidates[0].national_reason == "youtube_api:GB!=US"


@pytest.mark.asyncio
async def test_channel_from_the_same_country_is_national(monkeypatch):
    monkeypatch.setenv("YOUTUBE_API_KEY", "test-key")
    source = YouTubeAPISource()
    profile = CountryProfile(country="usa", languages=["en"])
    config = SourceConfig(priority=3, params={"regionCode": "US"})

    candidates = await source.search("usa news", profile, config, _StubSession("US"))

    assert len(candidates) == 1
    assert candidates[0].national is True
    assert candidates[0].national_reason == "youtube_api:US"


def test_quota_cost_estimate():
    """search_channels costs ~100 units, list_channels costs ~1 unit per channel."""
    source = YouTubeAPISource()
    # 1 search (100) + 10 channels (1 each) = 110 units
    assert source._estimate_quota(10) == 110
    # 1 search (100) + 0 channels = 100
    assert source._estimate_quota(0) == 100
