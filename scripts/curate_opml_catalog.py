#!/usr/bin/env python3
"""Build Feedmine's editorial OPML tree from the analyzed feed corpus.

The Parquet corpus is the evidence layer: descriptions and tags were produced
from fetched entries, not inferred from feed names.  The generated OPML is the
runtime/editorial layer.  It intentionally keeps dormant evergreen archives,
while marking stale current-sensitive and personal feeds as disabled by
default.  Unanalysed discovery candidates are written to a separate staging
artifact and never bundled into the production tree.

This command only writes to ``--output`` and ``--report-dir``.  Replacing the
bundled Feeds directory is a separate, explicit step after validation.
"""

from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import json
import re
import shutil
import unicodedata
import urllib.parse
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Sequence

try:
    from scripts.catalog_identity import canonical_url, compute_source_id
except ModuleNotFoundError:  # Direct ``python scripts/...`` execution.
    from catalog_identity import canonical_url, compute_source_id

try:
    from scripts.catalog_collections import (
        PRODUCTION_COUNTRY_COLLECTION,
        is_country_collection,
        production_collection,
    )
except ModuleNotFoundError:
    from catalog_collections import (
        PRODUCTION_COUNTRY_COLLECTION,
        is_country_collection,
        production_collection,
    )

try:
    import duckdb
except ImportError as error:  # pragma: no cover - exercised by CLI users
    raise SystemExit(
        "duckdb is required; run this script with .venv_feeds/bin/python"
    ) from error


CURATION_SCHEMA_VERSION = 1


@dataclass(frozen=True)
class TopicRule:
    order: int
    key: str
    label: str
    subcategory: str
    keywords: tuple[str, ...]
    minimum_tag_matches: int = 0


@dataclass(frozen=True)
class Membership:
    collection: str
    topic: str
    subcategory: str
    language: str | None
    region: str
    country: str | None
    opml_file: str
    media_kind: str | None


@dataclass
class CuratedSource:
    source_id: str
    title: str
    xml_url: str
    site_url: str | None
    description: str
    tags: list[str]
    language: str | None
    status: str
    articles_fetched: int
    latest_item_at: str | None
    topic_order: int
    topic_key: str
    topic_label: str
    subcategory: str
    nature: str
    activity: str
    quality_score: int
    default_enabled: bool
    media_kind: str
    country: str | None
    old_files: list[str]
    contact_email: str | None = None
    contact_name: str | None = None
    contact_source: str | None = None
    contact_type: str | None = None

    @property
    def primary_relative_path(self) -> Path:
        if self.country:
            country_key = slug(self.country)
            return Path(PRODUCTION_COUNTRY_COLLECTION) / country_key / f"{country_key}.opml"
        editorial_name = self.topic_label.replace(" ", "_").replace("/", "-")
        ordered_key = f"{self.topic_order:02d}_{editorial_name}"
        return Path(ordered_key) / f"{ordered_key}.opml"


@dataclass
class CorpusDisposition:
    source_id: str
    title: str
    xml_url: str
    site_url: str | None
    status: str
    error_message: str | None
    attempt_count: int
    http_status: int | None
    final_url: str | None
    content_type: str | None
    articles_fetched: int
    latest_item_at: str | None
    old_files: list[str]

    @property
    def identity(self) -> str:
        return canonical_url(self.xml_url)


TOPIC_RULES: tuple[TopicRule, ...] = (
    TopicRule(1, "news_current_affairs", "News & Current Affairs", "World News", ("news", "breaking news", "current events", "journalism", "headlines", "newspaper")),
    TopicRule(1, "news_current_affairs", "News & Current Affairs", "Politics & Government", ("politics", "government", "election", "public policy", "geopolitics", "diplomacy", "international relations")),
    TopicRule(1, "news_current_affairs", "News & Current Affairs", "Local News", ("local news", "regional news", "community news", "city news")),
    TopicRule(
        1,
        "news_current_affairs",
        "News & Current Affairs",
        "Fact-Checking & Media Literacy",
        ("fact-checking", "fact checking", "misinformation", "disinformation", "fake news", "media literacy", "debunking"),
        minimum_tag_matches=2,
    ),
    TopicRule(1, "news_current_affairs", "News & Current Affairs", "Economy & Markets", ("economy", "economic news", "financial news", "business news", "finance", "personal finance", "banking", "taxes", "stock market", "markets", "investing", "cryptocurrency")),
    TopicRule(2, "arts_culture", "Arts & Culture", "Architecture & Design", ("architecture", "urbanism", "graphic design", "industrial design", "interior design")),
    TopicRule(2, "arts_culture", "Arts & Culture", "Books & Literature", ("books", "literature", "poetry", "fiction", "book reviews", "writing", "comics")),
    TopicRule(2, "arts_culture", "Arts & Culture", "Visual Arts", ("art", "visual arts", "painting", "sculpture", "photography", "illustration", "galleries", "museums")),
    TopicRule(2, "arts_culture", "Arts & Culture", "Mythology & Folklore", ("mythology", "greek mythology", "roman mythology", "myths", "legends", "folklore")),
    TopicRule(2, "arts_culture", "Arts & Culture", "Culture & Heritage", ("culture", "cultural heritage", "cultural news", "heritage", "folklore", "anthropology", "archaeology")),
    TopicRule(3, "entertainment", "Entertainment", "Film & Television", ("movies", "film", "cinema", "television", "tv shows", "streaming", "documentary")),
    TopicRule(3, "entertainment", "Entertainment", "Celebrity & Gossip", ("celebrity", "celebrities", "gossip", "entertainment news", "pop culture")),
    TopicRule(3, "entertainment", "Entertainment", "Comedy & Performance", ("comedy", "humor", "theatre", "theater", "performing arts")),
    TopicRule(3, "entertainment", "Entertainment", "True Crime & Mystery", ("true crime", "crime stories", "murder mystery", "unsolved mysteries")),
    TopicRule(3, "entertainment", "Entertainment", "Fandom", ("fandom", "fan fiction", "fanfic", "anime", "manga", "nerd culture")),
    TopicRule(4, "technology_science", "Technology & Science", "Software & Computing", ("technology", "software", "programming", "coding", "computing", "open source", "cybersecurity", "artificial intelligence", "machine learning")),
    TopicRule(4, "technology_science", "Technology & Science", "Space & Astronomy", ("astronomy", "space", "astrophysics", "cosmology", "nasa", "spaceflight")),
    TopicRule(4, "technology_science", "Technology & Science", "Earth & Life Sciences", ("science", "biology", "geology", "physics", "chemistry", "research", "environmental science", "cognitive science")),
    TopicRule(4, "technology_science", "Technology & Science", "Acoustics & Sound", ("acoustics", "audio engineering", "sound engineering", "sound science", "psychoacoustics")),
    TopicRule(4, "technology_science", "Technology & Science", "Gadgets & Engineering", ("gadgets", "consumer electronics", "engineering", "hardware", "robotics", "retro technology")),
    TopicRule(5, "business_industry", "Business & Industry", "Business & Entrepreneurship", ("business", "entrepreneurship", "startups", "small business", "management", "leadership")),
    TopicRule(5, "business_industry", "Business & Industry", "Work & Productivity", ("careers", "workplace", "productivity", "human resources", "remote work", "freelancing")),
    TopicRule(5, "business_industry", "Business & Industry", "Industry & Manufacturing", ("industry", "manufacturing", "construction", "metallurgy", "mining", "supply chain", "logistics")),
    TopicRule(5, "business_industry", "Business & Industry", "Agriculture", ("agriculture", "farming", "agribusiness", "crops", "livestock")),
    TopicRule(6, "health_wellness", "Health & Wellness", "Medicine & Public Health", ("health", "medicine", "medical", "nursing", "health sciences", "public health", "healthcare", "disease", "pharmacy")),
    TopicRule(6, "health_wellness", "Health & Wellness", "Mental Health", ("mental health", "psychology", "therapy", "anxiety", "depression", "neurodiversity")),
    TopicRule(6, "health_wellness", "Health & Wellness", "Fitness & Nutrition", ("fitness", "exercise", "nutrition", "wellness", "yoga", "running")),
    TopicRule(6, "health_wellness", "Health & Wellness", "Disability & Accessibility", ("disability", "disabilities", "accessibility", "chronic illness")),
    TopicRule(7, "sports", "Sports", "Football", ("football", "soccer", "fifa", "premier league")),
    TopicRule(7, "sports", "Sports", "Motor & Action Sports", ("motorsport", "motorcycling", "formula 1", "skateboarding", "surfing")),
    TopicRule(7, "sports", "Sports", "General Sports", ("sports",)),
    TopicRule(7, "sports", "Sports", "Outdoor Sports", ("fishing", "hiking", "trails", "cycling", "climbing", "skiing")),
    TopicRule(7, "sports", "Sports", "Team & Individual Sports", ("basketball", "baseball", "hockey", "tennis", "golf", "cricket", "rugby", "athletics")),
    TopicRule(8, "food_drink", "Food & Drink", "Cooking & Recipes", ("food", "cooking", "recipes", "baking", "cuisine", "restaurants")),
    TopicRule(8, "food_drink", "Food & Drink", "Drinks", ("wine", "beer", "whisky", "whiskey", "cocktails", "coffee", "tea")),
    TopicRule(9, "home_living", "Home & Living", "Home & DIY", ("home", "diy", "home improvement", "home decor", "woodworking", "gardening", "crafts", "sewing", "ceramics")),
    TopicRule(9, "home_living", "Home & Living", "Fashion & Beauty", ("fashion", "beauty", "makeup", "style", "luxury fashion", "skincare")),
    TopicRule(9, "home_living", "Home & Living", "Family & Parenting", ("family", "parenting", "motherhood", "fatherhood", "children", "relationships")),
    TopicRule(10, "travel_transport", "Travel & Transport", "Travel", ("travel", "tourism", "ecotourism", "travel guides", "family travel", "vacations", "destinations", "hotels", "backpacking", "theme parks")),
    TopicRule(10, "travel_transport", "Travel & Transport", "Cars & Motorcycles", ("automotive", "cars", "motorcycles", "vehicles", "auto industry")),
    TopicRule(10, "travel_transport", "Travel & Transport", "Aviation & Maritime", ("aviation", "airlines", "aircraft", "maritime", "naval", "shipping")),
    TopicRule(11, "education_knowledge", "Education & Knowledge", "Education", ("education", "teaching", "learning", "schools", "university", "universities", "academic", "mathematics", "literacy", "kindergarten", "early childhood education")),
    TopicRule(11, "education_knowledge", "Education & Knowledge", "History", ("history", "historical", "military history", "genealogy")),
    TopicRule(11, "education_knowledge", "Education & Knowledge", "Law & Ideas", ("law", "legal", "philosophy", "ethics", "economics", "sociology")),
    TopicRule(12, "society_identity", "Society & Identity", "Society & Communities", ("society", "community", "social issues", "social work", "child welfare", "activism", "human rights", "nonprofit")),
    TopicRule(12, "society_identity", "Society & Identity", "Identity", ("lgbtq", "gender", "race", "identity", "feminism", "indigenous")),
    TopicRule(12, "society_identity", "Society & Identity", "Personal Voices", ("personal blog", "personal stories", "diary", "life", "memoir")),
    TopicRule(13, "religion_spirituality", "Religion & Spirituality", "Religion", ("religion", "christianity", "catholic", "catholicism", "campus ministry", "islam", "judaism", "hinduism", "buddhism", "theology")),
    TopicRule(13, "religion_spirituality", "Religion & Spirituality", "Spirituality & Esoterica", ("spirituality", "wicca", "esoteric", "occult", "astrology", "meditation", "ufo", "conspiracy")),
    TopicRule(14, "games_hobbies", "Games & Hobbies", "Video Games", ("gaming", "video games", "pc gaming", "console games", "esports", "arcade")),
    TopicRule(14, "games_hobbies", "Games & Hobbies", "Tabletop & Puzzles", ("board games", "tabletop", "chess", "puzzles", "role-playing games", "rpg", "trading card game", "card games", "magic the gathering")),
    TopicRule(14, "games_hobbies", "Games & Hobbies", "Collecting & Hobbies", ("hobbies", "collecting", "collectors", "miniatures", "model making")),
    TopicRule(15, "nature_animals", "Nature & Animals", "Pets", ("pets", "cats", "dogs", "pet care", "aquariums")),
    TopicRule(15, "nature_animals", "Nature & Animals", "Wildlife & Nature", ("nature", "wildlife", "animals", "birds", "conservation", "ecology", "environment", "sustainability", "climate", "zero waste")),
    TopicRule(16, "music_audio", "Music & Audio", "Music", ("music", "musicians", "albums", "songs", "classical music", "jazz", "rock music", "hip hop")),
    TopicRule(16, "music_audio", "Music & Audio", "Podcasts & Audio", ("podcast", "podcasts", "audio", "radio", "audiobooks", "audiophile")),
)

FALLBACK_TOPIC = TopicRule(17, "general_interests", "General Interests", "General", ())

LOW_SIGNAL_TOPIC_KEYWORDS = {"news", "podcast", "podcasts", "audio", "radio"}

GENERIC_TOPIC_KEYWORDS = {
    "art", "business", "culture", "education", "food", "health", "history",
    "gaming", "music", "nature", "research", "science", "society", "sports",
    "technology", "travel",
}

COLLECTION_HINTS = {
    "arts_culture": "arts_culture", "entertainment": "entertainment",
    "fashion": "home_living", "food_drink": "food_drink", "gaming": "games_hobbies",
    "health": "health_wellness", "home_diy": "home_living",
    "industry_business": "business_industry", "knowledge": "education_knowledge",
    "music_audio": "music_audio", "pets": "nature_animals", "sports": "sports",
    "tech_science": "technology_science", "travel": "travel_transport",
}

TAG_ALIASES = {
    "ai": "artificial intelligence", "a.i": "artificial intelligence",
    "tech": "technology", "sci-fi": "science fiction", "scifi": "science fiction",
    "tv": "television", "film reviews": "movies", "book review": "book reviews",
    "podcasting": "podcasts", "podcast episodes": "podcasts",
    "current affairs": "current events", "world affairs": "international relations",
    "cats and kittens": "cats", "dog": "dogs", "cat": "cats",
}

LANGUAGE_ALIASES = {
    "english": "en", "portuguese": "pt", "brazilian portuguese": "pt-BR",
    "spanish": "es", "french": "fr", "german": "de", "italian": "it",
    "dutch": "nl", "japanese": "ja", "korean": "ko", "chinese": "zh",
    "russian": "ru", "arabic": "ar", "hindi": "hi", "turkish": "tr",
    "polish": "pl", "swedish": "sv", "norwegian": "nb", "danish": "da",
    "finnish": "fi", "greek": "el", "hebrew": "he", "indonesian": "id",
    "vietnamese": "vi", "thai": "th", "ukrainian": "uk", "catalan": "ca",
    # Deprecated ISO 639 codes still seen in feed metadata.
    "in": "id", "iw": "he",
}

# BCP 47 subset: language[-script][-region][-variant…].  Script subtags are
# four letters (Hans, Hant, Latn) and must not be mistaken for a region.
LANGUAGE_PATTERN = re.compile(
    r"^([A-Za-z]{2,3})"
    r"(?:[-_]([A-Za-z]{4}))?"
    r"(?:[-_]([A-Za-z]{2}|[0-9]{3}))?"
    r"(?:[-_][A-Za-z0-9]{2,8})*$"
)

CURRENT_SENSITIVE = (
    "news", "current events", "politics", "government", "election", "geopolitics",
    "markets", "stock market", "financial news", "sports", "weather", "gossip",
    "celebrity", "entertainment news", "local news", "journalism",
)
PERSONAL_SENSITIVE = ("personal blog", "diary", "personal stories", "celebrity")
EVERGREEN = (
    "history", "astronomy", "science", "education", "literature", "poetry",
    "philosophy", "architecture", "art", "museums", "archives", "research",
    "recipes", "crafts", "woodworking", "photography", "nature",
)


def clean_text(value: object) -> str:
    if value is None:
        return ""
    return re.sub(r"\s+", " ", str(value)).strip()


def ascii_fold(value: str) -> str:
    return unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode("ascii")


def slug(value: str) -> str:
    value = ascii_fold(value).lower()
    return re.sub(r"[^a-z0-9]+", "_", value).strip("_") or "unknown"


def normalize_tag(value: str) -> str:
    value = ascii_fold(clean_text(value)).lower()
    value = re.sub(r"[&/]", " and ", value)
    value = re.sub(r"[^a-z0-9+#.-]+", " ", value)
    value = re.sub(r"\s+", " ", value).strip(" .-")
    return TAG_ALIASES.get(value, value)


def parse_tags(raw: str) -> list[str]:
    if not clean_text(raw):
        return []
    try:
        values = next(csv.reader([raw]))
    except (csv.Error, StopIteration):
        values = raw.split(",")
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        tag = normalize_tag(value)
        if len(tag) < 2 or tag in seen:
            continue
        seen.add(tag)
        result.append(tag)
    return result[:8]


def normalize_language(value: str | None) -> str | None:
    """Return a normalised BCP 47 tag, or ``None`` when *value* is not a tag.

    Script subtags are preserved (``zh-Hans`` stays ``zh-Hans``), the base
    language is lowercased and the region uppercased.  Text that is not a
    language tag at all (for example ``"english junk"``) yields ``None``
    instead of being sliced down to its first letters.
    """
    value = clean_text(value)
    if not value or value.casefold() in {"nan", "none", "null"}:
        return None
    alias = LANGUAGE_ALIASES.get(value.lower())
    if alias:
        return alias
    match = LANGUAGE_PATTERN.match(value)
    if not match:
        return None
    base = match.group(1).lower()
    script = match.group(2)
    region = match.group(3)
    parts = [base]
    if script:
        parts.append(script.title())
    if region:
        parts.append(region.upper() if region.isalpha() else region)
    return "-".join(parts)


def phrase_present(haystack: str, needle: str) -> bool:
    return bool(re.search(rf"(?<![a-z0-9]){re.escape(needle)}(?![a-z0-9])", haystack))


def classify_topic(
    title: str,
    description: str,
    tags: Sequence[str],
    memberships: Sequence[Membership],
) -> TopicRule:
    tag_text = " | ".join(tags)
    description_text = normalize_tag(description)
    title_text = normalize_tag(title)

    def rule_named(subcategory: str) -> TopicRule:
        return next(rule for rule in TOPIC_RULES if rule.subcategory == subcategory)

    # Localized Google News headline editions are useful country/language
    # sources, but a five-entry sample can be dominated by one transient topic.
    # Their stable source identity is always general headlines.
    if "top stories" in title_text and "google news" in title_text:
        return rule_named("World News")

    fact_check_signals = sum(
        phrase_present(tag_text, keyword)
        for keyword in (
            "fact-checking", "fact checking", "misinformation", "disinformation",
            "fake news", "media literacy", "debunking",
        )
    )
    if fact_check_signals >= 2:
        return rule_named("Fact-Checking & Media Literacy")

    # A general newsroom can look like a sports, fashion, or agriculture feed
    # when the sampled entries happen to cluster around one event. Detect broad
    # section diversity from the analyzed tags before choosing a topical home.
    # Section-specific endpoints still keep their topic because their tags are
    # concentrated in one family (for example a newspaper's /sport/feed/).
    news_signal = any(
        phrase_present(tag_text, signal)
        for signal in ("news", "newspaper", "current affairs", "current events", "headlines")
    )
    news_families = (
        ("politics", "government", "election", "geopolitics", "local government", "municipal government"),
        ("business", "economy", "finance", "markets", "banking", "jobs"),
        ("sports", "football", "basketball", "cricket", "rugby", "formula 1"),
        ("culture", "entertainment", "music", "film", "fashion", "arts", "literature"),
        ("health", "medicine", "public health"),
        ("education", "schools", "university"),
        ("community", "social issues", "crime", "security", "human rights", "diaspora"),
        ("technology", "science", "cybersecurity"),
        ("environment", "agriculture", "weather", "climate"),
        ("travel", "tourism", "automotive", "aviation"),
    )
    family_count = sum(
        any(phrase_present(tag_text, keyword) for keyword in family)
        for family in news_families
    )
    general_news_description = any(
        phrase_present(description_text, phrase)
        for phrase in ("daily newspaper", "news site", "news portal", "general news")
    )
    if news_signal and (family_count >= 3 or (general_news_description and family_count >= 2)):
        if any(
            phrase_present(tag_text, keyword)
            for keyword in ("local government", "municipal government", "city services")
        ):
            return rule_named("Local News")
        if any(
            phrase_present(tag_text, keyword)
            for keyword in ("politics", "government", "election", "geopolitics")
        ):
            return rule_named("Politics & Government")
        return rule_named("World News")

    scores: dict[TopicRule, int] = {}
    tag_evidence: dict[TopicRule, int] = {}
    tag_matches: dict[TopicRule, int] = {}

    for rule in TOPIC_RULES:
        score = 0
        tag_score = 0
        matched_tags = 0
        for keyword in rule.keywords:
            keyword = normalize_tag(keyword)
            if keyword in {"podcast", "podcasts", "audio", "radio"}:
                signal_weight = 0
            elif keyword == "news":
                signal_weight = 5
            elif keyword in GENERIC_TOPIC_KEYWORDS:
                signal_weight = 5
            else:
                signal_weight = 14
            if any(tag == keyword for tag in tags):
                score += signal_weight
                tag_score += signal_weight
                matched_tags += 1
            elif phrase_present(tag_text, keyword):
                partial_weight = max(0, signal_weight - 5)
                score += partial_weight
                tag_score += partial_weight
                matched_tags += 1
            if signal_weight and phrase_present(description_text, keyword):
                score += 3
            if signal_weight and phrase_present(title_text, keyword):
                score += 1
        scores[rule] = score
        tag_evidence[rule] = tag_score
        tag_matches[rule] = matched_tags

    # Existing placement is a prior, never stronger than content-derived tags.
    for membership in memberships:
        hinted_key = COLLECTION_HINTS.get(slug(membership.collection))
        if not hinted_key:
            continue
        candidates = [rule for rule in TOPIC_RULES if rule.key == hinted_key]
        if not candidates:
            continue
        subcategory = normalize_tag(membership.subcategory)
        best_hint = max(
            candidates,
            key=lambda rule: sum(phrase_present(subcategory, normalize_tag(k)) for k in rule.keywords),
        )
        scores[best_hint] += 4

    eligible_rules = [
        rule for rule in TOPIC_RULES
        if tag_matches[rule] >= rule.minimum_tag_matches
    ]
    best = max(eligible_rules, key=lambda rule: (scores[rule], tag_evidence[rule], -rule.order, rule.subcategory))
    # A lone word in prose is too weak to define a feed's menu home (for
    # example, "a space for reflection" is not astronomy). One exact generic
    # tag is enough; prose-only classification needs multiple corroborating
    # signals. Existing OPML placement contributes only a prior of four and
    # therefore cannot override the analyzed content by itself.
    return best if scores[best] >= 5 else FALLBACK_TOPIC


def classify_nature(title: str, description: str, tags: Sequence[str]) -> str:
    text = " | ".join([normalize_tag(title), normalize_tag(description), *tags])
    if any(phrase_present(text, keyword) for keyword in PERSONAL_SENSITIVE):
        return "personal"
    if any(phrase_present(text, keyword) for keyword in CURRENT_SENSITIVE):
        return "current-sensitive"
    if any(phrase_present(text, keyword) for keyword in EVERGREEN):
        return "evergreen"
    if any(phrase_present(text, keyword) for keyword in ("archive", "archives", "historical collection")):
        return "archive"
    return "periodic"


def parse_timestamp(value: str | None) -> datetime | None:
    value = clean_text(value)
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def activity_for(latest_item_at: str | None, articles: int, now: datetime) -> tuple[str, int | None]:
    latest = parse_timestamp(latest_item_at)
    if latest is None:
        return "unknown", None
    if latest.tzinfo is None:
        latest = latest.replace(tzinfo=timezone.utc)
    days = max(0, (now.astimezone(timezone.utc) - latest.astimezone(timezone.utc)).days)
    if days <= 14 and articles >= 20:
        return "prolific", days
    if days <= 90:
        return "active", days
    if days <= 365:
        return "quiet", days
    return "dormant", days


def default_enabled_for(nature: str, days_old: int | None) -> bool:
    if days_old is None:
        return nature in {"evergreen", "archive"}
    if nature == "personal":
        return days_old <= 180
    if nature == "current-sensitive":
        return days_old <= 365
    return True


def quality_score(description: str, tags: Sequence[str], articles: int, activity: str) -> int:
    score = 35
    score += min(20, len(description) // 12)
    score += min(20, len(tags) * 4)
    score += min(15, articles // 2)
    score += {"prolific": 10, "active": 7, "quiet": 3, "dormant": 0, "unknown": -5}[activity]
    return max(0, min(100, score))


def media_kind_for(url: str, tags: Sequence[str], memberships: Sequence[Membership]) -> str:
    claimed = next((m.media_kind for m in memberships if m.media_kind), None)
    if claimed in {"audio", "video", "forum", "text"}:
        return claimed
    lower = url.lower()
    if "youtube.com/feeds" in lower or "video" in tags or "youtube" in tags:
        return "video"
    if any(host in lower for host in ("anchor.fm", "podbean.com", "spreaker.com", "libsyn.com")) or "podcasts" in tags:
        return "audio"
    if "reddit.com/r/" in lower or "forum" in tags:
        return "forum"
    return "text"


def choose_country(memberships: Sequence[Membership]) -> str | None:
    countries = [
        m.country for m in memberships
        if m.country and is_country_collection(m.collection)
    ]
    if not countries:
        return None
    distinct_countries = set(countries)
    # A source repeated across countries is a global/faceted source, not a
    # resident of whichever country happens to sort first in the corpus.
    if len(distinct_countries) > 1:
        return None
    # Country-only sources retain geographic ownership.  A deliberately global
    # topical placement remains primary when present elsewhere in the old tree.
    has_global_editorial_home = any(
        not is_country_collection(m.collection) and slug(m.collection) != "languages"
        and m.region == "global"
        for m in memberships
    )
    if has_global_editorial_home:
        return None
    return next(iter(distinct_countries))


def read_memberships(path: Path) -> dict[str, list[Membership]]:
    connection = duckdb.connect()
    rows = connection.execute(
        """
        SELECT source_id, collection, topic, subcategory, claimed_language,
               region, claimed_country, opml_file, claimed_media_kind
        FROM read_parquet(?)
        ORDER BY source_id, opml_file
        """,
        [str(path)],
    ).fetchall()
    result: dict[str, list[Membership]] = defaultdict(list)
    for row in rows:
        result[row[0]].append(Membership(
            collection=clean_text(row[1]), topic=clean_text(row[2]),
            subcategory=clean_text(row[3]), language=normalize_language(row[4]),
            region=clean_text(row[5]), country=clean_text(row[6]) or None,
            opml_file=clean_text(row[7]), media_kind=clean_text(row[8]) or None,
        ))
    connection.close()
    return result


def read_corpus_dispositions(
    path: Path,
    memberships_by_source: dict[str, list[Membership]],
) -> list[CorpusDisposition]:
    """Read every attempted corpus source and collapse runtime-equivalent URLs.

    Production intentionally consumes only ``done`` rows, but the editorial
    ledger must retain ``empty`` and ``failed`` rows as well.  Keeping this read
    separate makes that distinction explicit and prevents a future production
    filter from silently erasing recovery work.
    """
    connection = duckdb.connect()
    rows = connection.execute(
        """
        SELECT source_id, source_title, xml_url, canonical_xml_url, site_url,
               feed_title, status, error_message, COALESCE(attempt_count, 0),
               http_status, final_url, content_type,
               COALESCE(articles_fetched, 0), CAST(latest_item_at AS VARCHAR)
        FROM read_parquet(?)
        ORDER BY source_id
        """,
        [str(path)],
    ).fetchall()
    connection.close()

    grouped: dict[str, list[CorpusDisposition]] = defaultdict(list)
    for row in rows:
        xml_url = clean_text(row[2]) or clean_text(row[3])
        if not xml_url:
            continue
        raw_http_status = row[9]
        http_status = int(raw_http_status) if raw_http_status is not None else None
        source_id = clean_text(row[0])
        memberships = memberships_by_source.get(source_id, [])
        disposition = CorpusDisposition(
            source_id=source_id,
            title=(
                clean_text(row[5])
                or clean_text(row[1])
                or urllib.parse.urlsplit(xml_url).hostname
                or "Untitled"
            ),
            xml_url=xml_url,
            site_url=clean_text(row[4]) or None,
            status=clean_text(row[6]) or "unknown",
            error_message=clean_text(row[7]) or None,
            attempt_count=int(row[8] or 0),
            http_status=http_status,
            final_url=clean_text(row[10]) or None,
            content_type=clean_text(row[11]) or None,
            articles_fetched=int(row[12] or 0),
            latest_item_at=clean_text(row[13]) or None,
            old_files=sorted({m.opml_file for m in memberships if m.opml_file}),
        )
        grouped[disposition.identity].append(disposition)

    status_rank = {
        "done": 4,
        "empty": 3,
        "failed": 2,
        "excluded_policy": 1,
        "unknown": 0,
    }
    collapsed: list[CorpusDisposition] = []
    for identity, variants in sorted(grouped.items()):
        representative = max(
            variants,
            key=lambda item: (
                status_rank.get(item.status, 0),
                item.articles_fetched,
                item.attempt_count,
                item.http_status is not None,
                item.xml_url.lower().startswith("https://"),
                item.source_id,
            ),
        )
        representative.old_files = sorted({
            old_file for variant in variants for old_file in variant.old_files
        })
        collapsed.append(representative)
    return collapsed


def read_sources(path: Path, memberships_by_source: dict[str, list[Membership]], now: datetime) -> tuple[list[CuratedSource], Counter[str]]:
    connection = duckdb.connect()
    # Probe schema: ai_description / ai_tags columns may not exist yet
    # if the DeepSeek enrichment pass hasn't been run.
    schema_df = connection.execute(
        "DESCRIBE SELECT * FROM read_parquet(?)", [str(path)]
    ).fetchdf()
    schema_cols = set(schema_df.iloc[:, 0].tolist())  # first column = column_name
    has_ai = "ai_description" in schema_cols
    ai_cols = (
        "ai_description, ai_tags"
        if has_ai
        else "NULL AS ai_description, NULL AS ai_tags"
    )
    rows = connection.execute(
        f"""
        SELECT source_id, source_title, xml_url, canonical_xml_url, site_url,
               feed_title, feed_reported_language, status,
               COALESCE(articles_fetched, 0), CAST(latest_item_at AS VARCHAR),
               {ai_cols}
        FROM read_parquet(?)
        ORDER BY source_id
        """,
        [str(path)],
    ).fetchall()
    connection.close()

    # Try to load the contacts parquet if it exists. Its ``source_id`` column
    # holds feed URLs (the catalog_source.key value), not hex digests, while
    # CuratedSource.source_id carries the SHA-256 digest from the corpus
    # parquet — so hash each URL here to make the lookup key comparable.
    # Status is limited to verified/unverified so discarded contacts are never
    # re-promoted.
    contacts_path = path.parent / "feeds_corpus_contacts.parquet"
    contacts_lookup: dict[str, dict] = {}
    if contacts_path.exists():
        import pyarrow.parquet as pq
        ct = pq.read_table(contacts_path).to_pandas()
        for _, row in ct.iterrows():
            if row.get("contact_status") in ("verified", "unverified"):
                raw_sid = str(row["source_id"])
                # Hash URL-based source_id to digest for matching against
                # CuratedSource.source_id (same canonicalizer as the rest of
                # the file). Defensive: keep already-digested rows as-is.
                hashed_sid = raw_sid if re.fullmatch(r"[0-9a-f]{64}", raw_sid) else compute_source_id(raw_sid)
                contacts_lookup[hashed_sid] = {
                    "contact_email": str(row.get("contact_email", "") or ""),
                    "contact_name": str(row.get("contact_name", "") or ""),
                    "contact_source": str(row.get("contact_source", "") or ""),
                    "contact_type": str(row.get("contact_type", "") or ""),
                }

    production: list[CuratedSource] = []
    statuses: Counter[str] = Counter()
    for row in rows:
        status = clean_text(row[7]) or "unknown"
        statuses[status] += 1
        if status != "done":
            continue
        source_id = clean_text(row[0])
        memberships = memberships_by_source.get(source_id, [])
        title = clean_text(row[5]) or clean_text(row[1]) or urllib.parse.urlsplit(clean_text(row[2])).hostname or "Untitled"
        description = clean_text(row[10]) or "Feed curated from analyzed entries."
        tags = parse_tags(clean_text(row[11]))
        topic = classify_topic(title, description, tags, memberships)
        nature = classify_nature(title, description, tags)
        latest = clean_text(row[9]) or None
        articles = int(row[8] or 0)
        activity, days_old = activity_for(latest, articles, now)
        language = normalize_language(row[6]) or next((m.language for m in memberships if m.language), None)
        xml_url = clean_text(row[2]) or clean_text(row[3])
        contact = contacts_lookup.get(source_id, {})
        production.append(CuratedSource(
            source_id=source_id, title=title, xml_url=xml_url,
            site_url=clean_text(row[4]) or None, description=description,
            tags=tags, language=language, status=status,
            articles_fetched=articles, latest_item_at=latest,
            topic_order=topic.order, topic_key=topic.key, topic_label=topic.label,
            subcategory=topic.subcategory, nature=nature, activity=activity,
            quality_score=quality_score(description, tags, articles, activity),
            default_enabled=default_enabled_for(nature, days_old),
            media_kind=media_kind_for(xml_url, tags, memberships),
            country=choose_country(memberships),
            old_files=sorted({m.opml_file for m in memberships if m.opml_file}),
            contact_email=contact.get("contact_email") or None,
            contact_name=contact.get("contact_name") or None,
            contact_source=contact.get("contact_source") or None,
            contact_type=contact.get("contact_type") or None,
        ))
    return deduplicate_runtime_identities(production), statuses


def deduplicate_runtime_identities(sources: Sequence[CuratedSource]) -> list[CuratedSource]:
    """Collapse corpus rows that the app treats as one source.

    Older corpus collection distinguished scheme, ``www`` and tracking URL
    variants. The app intentionally does not. Preserve the best analyzed row,
    merge its audit trail, and prefer a global home when equivalent rows had
    both topical and country placements.
    """
    grouped: dict[str, list[CuratedSource]] = defaultdict(list)
    for source in sources:
        grouped[canonical_url(source.xml_url)].append(source)

    activity_order = {"prolific": 4, "active": 3, "quiet": 2, "dormant": 1, "unknown": 0}
    result: list[CuratedSource] = []
    for identity, variants in sorted(grouped.items()):
        representative = max(variants, key=lambda source: (
            source.articles_fetched,
            source.quality_score,
            activity_order[source.activity],
            len(source.description),
            source.default_enabled,
            source.xml_url.lower().startswith("https://"),
            source.source_id,
        ))
        representative.old_files = sorted({
            old_file for source in variants for old_file in source.old_files
        })
        countries = {source.country for source in variants if source.country}
        if any(source.country is None for source in variants) or len(countries) > 1:
            representative.country = None
        elif countries:
            representative.country = next(iter(countries))
        result.append(representative)
    return result


def source_sort_key(source: CuratedSource) -> tuple[object, ...]:
    activity_order = {"prolific": 0, "active": 1, "quiet": 2, "dormant": 3, "unknown": 4}
    return (
        not source.default_enabled,
        activity_order[source.activity],
        -source.quality_score,
        ascii_fold(source.title).casefold(),
        source.source_id,
    )


def add_source_outline(parent: ET.Element, source: CuratedSource) -> None:
    attributes = {
        "text": source.title,
        "title": source.title,
        "type": "rss",
        "xmlUrl": source.xml_url,
        "description": source.description,
        "language": source.language or "und",
        "category": ",".join(source.tags),
        "feedmineSourceId": source.source_id,
        "feedmineTopic": source.topic_label,
        "feedmineSubcategory": source.subcategory,
        "feedmineNature": source.nature,
        "feedmineActivity": source.activity,
        "feedmineArticlesFetched": str(source.articles_fetched),
        "feedmineQualityScore": str(source.quality_score),
        "feedmineDefaultEnabled": "true" if source.default_enabled else "false",
        "feedmineMediaKind": source.media_kind,
    }
    if source.site_url:
        attributes["htmlUrl"] = source.site_url
    if source.latest_item_at:
        attributes["feedmineLatestItemAt"] = source.latest_item_at
    if source.contact_email:
        attributes["feedmineContactEmail"] = source.contact_email
    if source.contact_name:
        attributes["feedmineContactName"] = source.contact_name
    if source.contact_source:
        attributes["feedmineContactSource"] = source.contact_source
    if source.contact_type:
        attributes["feedmineContactType"] = source.contact_type
    ET.SubElement(parent, "outline", attributes)


def write_opml(path: Path, title: str, sources: Sequence[CuratedSource], country: bool = False) -> None:
    root = ET.Element("opml", {"version": "2.0"})
    head = ET.SubElement(root, "head")
    ET.SubElement(head, "title").text = title
    ET.SubElement(head, "ownerName").text = "Feedmine editorial curation"
    ET.SubElement(head, "docs").text = "https://opml.org/spec2.opml"
    body = ET.SubElement(root, "body")

    if country:
        grouped: dict[tuple[int, str, str], list[CuratedSource]] = defaultdict(list)
        for source in sources:
            grouped[(source.topic_order, source.topic_label, source.subcategory)].append(source)
        top_nodes: dict[tuple[int, str], ET.Element] = {}
        for topic_order, topic_label, subcategory in sorted(grouped):
            key = (topic_order, topic_label)
            top = top_nodes.get(key)
            if top is None:
                top = ET.SubElement(body, "outline", {"text": topic_label, "title": topic_label})
                top_nodes[key] = top
            sub = ET.SubElement(top, "outline", {"text": subcategory, "title": subcategory})
            for source in sorted(grouped[(topic_order, topic_label, subcategory)], key=source_sort_key):
                add_source_outline(sub, source)
    else:
        grouped = defaultdict(list)
        for source in sources:
            grouped[source.subcategory].append(source)
        for subcategory in sorted(grouped, key=lambda value: ascii_fold(value).casefold()):
            sub = ET.SubElement(body, "outline", {"text": subcategory, "title": subcategory})
            for source in sorted(grouped[subcategory], key=source_sort_key):
                add_source_outline(sub, source)

    ET.indent(root, space="  ")
    path.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True, short_empty_elements=True)


def candidate_outlines(feeds_root: Path, known_urls: set[str]) -> tuple[list[dict[str, str]], int]:
    candidates: dict[str, dict[str, str]] = {}
    parse_failures = 0
    for path in sorted(feeds_root.rglob("*.opml")):
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError:
            parse_failures += 1
            continue
        for element in root.iter("outline"):
            url = clean_text(element.attrib.get("xmlUrl"))
            if not url:
                continue
            key = canonical_url(url)
            is_candidate = element.attrib.get("feedmineCandidate", "").lower() == "true"
            if not is_candidate and key in known_urls:
                continue
            candidates.setdefault(key, {
                "title": clean_text(element.attrib.get("title") or element.attrib.get("text")) or url,
                "xml_url": url,
                "html_url": clean_text(element.attrib.get("htmlUrl")),
                "original_file": clean_text(element.attrib.get("feedmineOriginalFile"))
                or path.relative_to(feeds_root).as_posix(),
                "discovery_source": clean_text(element.attrib.get("discoverySource")),
                "query_scope": clean_text(element.attrib.get("queryScope")),
                "query_language": clean_text(element.attrib.get("queryLanguage")),
            })
    return sorted(candidates.values(), key=lambda item: (item["original_file"], item["title"].casefold())), parse_failures


def disposition_for_candidate(candidate: dict[str, str]) -> str:
    status = candidate.get("corpus_status", "")
    if status == "empty":
        return "processed_empty"
    if status == "failed":
        return "processed_failed"
    if status == "excluded_policy":
        return "excluded_policy"
    if candidate.get("discovery_source") == "google-news-search-v3":
        return "unattempted_synthetic"
    return "unattempted_editorial"


def merge_candidate_inventory(
    candidates: Sequence[dict[str, str]],
    corpus: Sequence[CorpusDisposition],
) -> list[dict[str, str]]:
    """Build the complete non-production inventory.

    Existing editorial candidates preserve discovery metadata. Corpus ``empty``
    and ``failed`` identities are then merged in even if the old OPML tree no
    longer contains them. ``done`` identities and synthetic Google News query
    URLs are always excluded from staging.
    """
    corpus_by_identity = {item.identity: item for item in corpus}
    production_identities = {
        item.identity for item in corpus if item.status == "done"
    }
    merged: dict[str, dict[str, str]] = {}

    for original in candidates:
        if disposition_for_candidate(original) == "unattempted_synthetic":
            continue
        identity = canonical_url(original["xml_url"])
        if identity in production_identities:
            continue
        item = dict(original)
        record = corpus_by_identity.get(identity)
        if record is not None:
            item.update({
                "source_id": record.source_id,
                "corpus_status": record.status,
                "attempt_count": str(record.attempt_count),
                "http_status": str(record.http_status or ""),
                "last_error": record.error_message or "",
                "final_url": record.final_url or "",
                "content_type": record.content_type or "",
            })
            if not item.get("html_url") and record.site_url:
                item["html_url"] = record.site_url
        else:
            item.update({
                "source_id": "",
                "corpus_status": "unattempted",
                "attempt_count": "0",
                "http_status": "",
                "last_error": "",
                "final_url": "",
                "content_type": "",
            })
        item["disposition"] = disposition_for_candidate(item)
        item["candidate_kind"] = (
            "synthetic_search"
            if item.get("discovery_source") == "google-news-search-v3"
            else "policy_excluded"
            if item["corpus_status"] == "excluded_policy"
            else "corpus_recovery"
            if item["corpus_status"] in {"empty", "failed"}
            else "editorial_discovery"
        )
        merged.setdefault(identity, item)

    for record in corpus:
        if record.status not in {"empty", "failed", "excluded_policy"}:
            continue
        identity = record.identity
        item = merged.setdefault(identity, {
            "title": record.title,
            "xml_url": record.xml_url,
            "html_url": record.site_url or "",
            "original_file": record.old_files[0] if record.old_files else f"corpus/{record.status}.opml",
            "discovery_source": "",
            "query_scope": "",
            "query_language": "",
        })
        item.update({
            "source_id": record.source_id,
            "corpus_status": record.status,
            "attempt_count": str(record.attempt_count),
            "http_status": str(record.http_status or ""),
            "last_error": record.error_message or "",
            "final_url": record.final_url or "",
            "content_type": record.content_type or "",
            "disposition": (
                "excluded_policy"
                if record.status == "excluded_policy"
                else f"processed_{record.status}"
            ),
            "candidate_kind": (
                "policy_excluded"
                if record.status == "excluded_policy"
                else "corpus_recovery"
            ),
        })

    return sorted(
        merged.values(),
        key=lambda item: (
            item["disposition"], item["original_file"], item["title"].casefold()
        ),
    )


def write_candidates(path: Path, candidates: Sequence[dict[str, str]]) -> None:
    root = ET.Element("opml", {"version": "2.0"})
    head = ET.SubElement(root, "head")
    ET.SubElement(head, "title").text = "Feedmine discovery candidates — not bundled"
    body = ET.SubElement(root, "body")
    grouped: dict[str, dict[str, list[dict[str, str]]]] = defaultdict(lambda: defaultdict(list))
    for candidate in candidates:
        collection = candidate["original_file"].split("/", 1)[0]
        grouped[candidate["disposition"]][collection].append(candidate)
    disposition_order = {
        "unattempted_editorial": 1,
        "processed_empty": 2,
        "processed_failed": 3,
        "excluded_policy": 4,
        "unattempted_synthetic": 90,
    }
    for disposition in sorted(grouped, key=lambda value: (disposition_order.get(value, 50), value)):
        label = disposition.replace("_", " ").title()
        disposition_group = ET.SubElement(body, "outline", {
            "text": label,
            "title": label,
            "feedmineDisposition": disposition,
        })
        for collection in sorted(grouped[disposition]):
            group = ET.SubElement(disposition_group, "outline", {"text": collection, "title": collection})
            for item in grouped[disposition][collection]:
                attrs = {
                    "text": item["title"], "title": item["title"], "type": "rss",
                    "xmlUrl": item["xml_url"], "feedmineCandidate": "true",
                    "feedmineOriginalFile": item["original_file"],
                    "feedmineDisposition": item["disposition"],
                    "feedmineCorpusStatus": item["corpus_status"],
                    "feedmineCandidateKind": item["candidate_kind"],
                    "feedmineAttemptCount": item["attempt_count"],
                }
                if item["html_url"]:
                    attrs["htmlUrl"] = item["html_url"]
                if item["source_id"]:
                    attrs["feedmineSourceId"] = item["source_id"]
                if item["http_status"]:
                    attrs["feedmineHTTPStatus"] = item["http_status"]
                if item["last_error"]:
                    attrs["feedmineLastError"] = item["last_error"][:500]
                if item["final_url"]:
                    attrs["feedmineFinalURL"] = item["final_url"]
                if item["content_type"]:
                    attrs["feedmineContentType"] = item["content_type"]
                if item["discovery_source"]:
                    attrs["discoverySource"] = item["discovery_source"]
                if item["query_scope"]:
                    attrs["queryScope"] = item["query_scope"]
                if item["query_language"]:
                    attrs["queryLanguage"] = item["query_language"]
                ET.SubElement(group, "outline", attrs)
    ET.indent(root, space="  ")
    path.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True, short_empty_elements=True)


def write_disposition_ledger(
    path: Path,
    corpus: Sequence[CorpusDisposition],
    production: Sequence[CuratedSource],
    candidates: Sequence[dict[str, str]],
) -> tuple[int, Counter[str]]:
    """Write one row per runtime source identity across every disposition."""
    production_by_identity = {
        canonical_url(source.xml_url): source for source in production
    }
    candidates_by_identity = {
        canonical_url(candidate["xml_url"]): candidate for candidate in candidates
    }
    corpus_by_identity = {item.identity: item for item in corpus}
    all_identities = sorted(
        set(production_by_identity) | set(candidates_by_identity) | set(corpus_by_identity)
    )
    counts: Counter[str] = Counter()
    path.parent.mkdir(parents=True, exist_ok=True)
    with gzip.open(path, "wt", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow([
            "normalized_identity", "disposition", "candidate_kind", "corpus_status",
            "source_id", "title", "xml_url", "html_url", "old_files",
            "current_file", "discovery_source", "query_scope", "query_language",
            "attempt_count", "http_status", "content_type", "final_url",
            "last_error", "articles_fetched", "latest_item_at",
        ])
        for identity in all_identities:
            curated = production_by_identity.get(identity)
            candidate = candidates_by_identity.get(identity)
            record = corpus_by_identity.get(identity)
            disposition = "production" if curated else (candidate["disposition"] if candidate else "unattempted")
            counts[disposition] += 1
            writer.writerow([
                identity,
                disposition,
                "production" if curated else (candidate["candidate_kind"] if candidate else ""),
                record.status if record else "unattempted",
                record.source_id if record else candidate.get("source_id", ""),
                curated.title if curated else (candidate["title"] if candidate else ""),
                curated.xml_url if curated else (candidate["xml_url"] if candidate else ""),
                (curated.site_url or "") if curated else (candidate.get("html_url", "") if candidate else ""),
                " | ".join(record.old_files) if record else "",
                curated.primary_relative_path.as_posix() if curated else (candidate["original_file"] if candidate else ""),
                "" if curated else (candidate.get("discovery_source", "") if candidate else ""),
                "" if curated else (candidate.get("query_scope", "") if candidate else ""),
                "" if curated else (candidate.get("query_language", "") if candidate else ""),
                record.attempt_count if record else 0,
                record.http_status if record and record.http_status is not None else "",
                record.content_type if record else "",
                record.final_url if record else "",
                record.error_message if record else "",
                record.articles_fetched if record else 0,
                record.latest_item_at if record else "",
            ])
    return len(all_identities), counts


def validate_output(output: Path, sources: Sequence[CuratedSource]) -> dict[str, int]:
    files = sorted(output.rglob("*.opml"))
    seen: Counter[str] = Counter()
    seen_identities: Counter[str] = Counter()
    invalid = 0
    metadata_missing = 0
    identity_mismatch = 0
    placeholder_title = 0
    invalid_language = 0
    escaped_url = 0
    for path in files:
        root = ET.parse(path).getroot()
        if root.attrib.get("version") != "2.0":
            raise RuntimeError(f"{path} is not OPML 2.0")
        for element in root.iter("outline"):
            url = element.attrib.get("xmlUrl")
            if not url:
                if not element.attrib.get("text"):
                    invalid += 1
                continue
            parsed = urllib.parse.urlsplit(url)
            if parsed.scheme not in {"http", "https"} or not parsed.hostname:
                invalid += 1
            seen[element.attrib.get("feedmineSourceId", "")] += 1
            seen_identities[canonical_url(url)] += 1
            if element.attrib.get("feedmineSourceId") != compute_source_id(url):
                identity_mismatch += 1
            if element.attrib.get("title", "").strip().casefold() in {
                "", "valid", "untitled", "unknown", "nan", "none", "rss", "rss feed", "feed",
            }:
                placeholder_title += 1
            if element.attrib.get("language", "").strip().casefold() in {"nan", "none", "null"}:
                invalid_language += 1
            if "&amp;" in url or "&#38;" in url or "&#x26;" in url.casefold():
                escaped_url += 1
            required = ("description", "category", "feedmineNature", "feedmineActivity", "feedmineDefaultEnabled")
            if any(key not in element.attrib for key in required):
                metadata_missing += 1
    expected_ids = {source.source_id for source in sources}
    actual_ids = set(seen) - {""}
    if expected_ids != actual_ids:
        raise RuntimeError(
            f"source mismatch: missing={len(expected_ids - actual_ids)} extra={len(actual_ids - expected_ids)}"
        )
    if invalid or metadata_missing:
        raise RuntimeError(f"invalid={invalid} metadata_missing={metadata_missing}")
    if identity_mismatch or placeholder_title or invalid_language or escaped_url:
        raise RuntimeError(
            "identity_mismatch={} placeholder_title={} invalid_language={} escaped_url={}".format(
                identity_mismatch, placeholder_title, invalid_language, escaped_url
            )
        )
    duplicate_identities = sum(count - 1 for count in seen_identities.values() if count > 1)
    if duplicate_identities:
        raise RuntimeError(f"normalized source identities repeated {duplicate_identities} times")
    return {
        "file_count": len(files), "source_count": len(expected_ids),
        "outline_occurrence_count": sum(seen.values()),
        "duplicate_occurrence_count": duplicate_identities,
        "invalid_outline_count": invalid, "metadata_missing_count": metadata_missing,
        "identity_mismatch_count": identity_mismatch,
        "placeholder_title_count": placeholder_title,
        "invalid_language_count": invalid_language,
        "escaped_url_count": escaped_url,
    }


def write_reports(
    report_dir: Path,
    sources: Sequence[CuratedSource],
    statuses: Counter[str],
    candidates: Sequence[dict[str, str]],
    validation: dict[str, int],
    input_file_count: int,
    candidate_parse_failures: int,
    ledger_count: int,
    ledger_disposition_counts: Counter[str],
) -> dict[str, object]:
    report_dir.mkdir(parents=True, exist_ok=True)
    decisions_path = report_dir / "source-placement-decisions.csv"
    with decisions_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow([
            "source_id", "title", "xml_url", "old_files", "new_file", "topic",
            "subcategory", "country", "language", "media_kind", "nature", "activity",
            "default_enabled", "quality_score", "tags", "description",
        ])
        for source in sorted(sources, key=lambda item: item.source_id):
            writer.writerow([
                source.source_id, source.title, source.xml_url, " | ".join(source.old_files),
                source.primary_relative_path.as_posix(), source.topic_label, source.subcategory,
                source.country or "", source.language or "", source.media_kind, source.nature,
                source.activity, str(source.default_enabled).lower(), source.quality_score,
                ", ".join(source.tags), source.description,
            ])

    disabled = [source for source in sources if not source.default_enabled]
    summary: dict[str, object] = {
        "schema_version": CURATION_SCHEMA_VERSION,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "input": {
            "opml_file_count": input_file_count,
            "corpus_status_counts": dict(sorted(statuses.items())),
            "normalized_identity_collapse_count": statuses["done"] - len(sources),
            "candidate_parse_failures": candidate_parse_failures,
        },
        "output": validation,
        "candidate_count": len(candidates),
        "candidate_disposition_counts": dict(sorted(Counter(
            candidate["disposition"] for candidate in candidates
        ).items())),
        "ledger_identity_count": ledger_count,
        "ledger_disposition_counts": dict(sorted(ledger_disposition_counts.items())),
        "default_disabled_count": len(disabled),
        "activity_counts": dict(sorted(Counter(source.activity for source in sources).items())),
        "nature_counts": dict(sorted(Counter(source.nature for source in sources).items())),
        "media_kind_counts": dict(sorted(Counter(source.media_kind for source in sources).items())),
        "topic_counts": dict(sorted(Counter(source.topic_label for source in sources).items())),
        "country_source_count": sum(source.country is not None for source in sources),
        "language_counts": dict(Counter(source.language or "und" for source in sources).most_common()),
        "artifacts": {
            "decisions_csv": str(decisions_path),
            "candidates_opml": str(report_dir / "staging" / "discovery-candidates.opml"),
            "disposition_ledger": str(report_dir / "source-disposition-ledger.csv.gz"),
        },
    }
    (report_dir / "curation-summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return summary


def prepare_empty_directory(path: Path) -> None:
    if path.exists():
        if path.is_symlink() or not path.is_dir():
            raise RuntimeError(f"refusing to replace non-directory output: {path}")
        shutil.rmtree(path)
    path.mkdir(parents=True)


def build(args: argparse.Namespace) -> dict[str, object]:
    now = datetime.fromisoformat(args.now.replace("Z", "+00:00")) if args.now else datetime.now(timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    prepare_empty_directory(args.output)
    args.report_dir.mkdir(parents=True, exist_ok=True)

    memberships = read_memberships(args.memberships)
    corpus = read_corpus_dispositions(args.sources, memberships)
    sources, statuses = read_sources(args.sources, memberships, now)
    if not sources:
        raise RuntimeError("the corpus produced no valid sources")

    grouped: dict[Path, list[CuratedSource]] = defaultdict(list)
    for source in sources:
        grouped[source.primary_relative_path].append(source)
    for relative_path, group in sorted(grouped.items(), key=lambda item: item[0].as_posix()):
        is_country = is_country_collection(relative_path.parts[0])
        title = group[0].country if is_country else group[0].topic_label
        # Rewrite every country alias to the one production directory.
        out_path = args.output / relative_path
        if is_country:
            out_path = (
                args.output
                / production_collection(relative_path.parts[0])
                / Path(*relative_path.parts[1:])
            )
        write_opml(out_path, title or relative_path.stem, group, country=is_country)

    known_urls = {canonical_url(source.xml_url) for source in sources}
    candidate_roots = [args.feeds_root]
    if args.candidate_input.exists() and args.candidate_input.resolve() != args.feeds_root.resolve():
        candidate_roots.append(args.candidate_input)
    merged_candidates: dict[str, dict[str, str]] = {}
    parse_failures = 0
    for root in candidate_roots:
        root_candidates, root_failures = candidate_outlines(root, known_urls)
        parse_failures += root_failures
        for candidate in root_candidates:
            merged_candidates.setdefault(canonical_url(candidate["xml_url"]), candidate)
    candidates = merge_candidate_inventory(list(merged_candidates.values()), corpus)
    write_candidates(args.report_dir / "staging" / "discovery-candidates.opml", candidates)
    ledger_count, ledger_disposition_counts = write_disposition_ledger(
        args.report_dir / "source-disposition-ledger.csv.gz",
        corpus,
        sources,
        candidates,
    )
    validation = validate_output(args.output, sources)
    input_file_count = sum(1 for _ in args.feeds_root.rglob("*.opml"))
    return write_reports(
        args.report_dir, sources, statuses, candidates, validation,
        input_file_count, parse_failures, ledger_count, ledger_disposition_counts,
    )


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--feeds-root", type=Path, default=Path("feedmine/Resources/Feeds"))
    parser.add_argument(
        "--sources", type=Path,
        default=Path("build/catalog-reconciliation/feeds_corpus_sources.parquet"),
        help="canonical sources produced by reconcile_feed_corpus.py",
    )
    parser.add_argument(
        "--memberships", type=Path,
        default=Path("build/catalog-reconciliation/feeds_corpus_source_memberships.parquet"),
        help="canonical memberships produced by reconcile_feed_corpus.py",
    )
    parser.add_argument("--output", type=Path, default=Path("build/feed-curation/Feeds"))
    parser.add_argument("--report-dir", type=Path, default=Path("build/feed-curation"))
    parser.add_argument(
        "--candidate-input",
        type=Path,
        default=Path("editorial/feed-curation/staging"),
        help="Additional non-production OPML root carried forward between curated releases",
    )
    parser.add_argument("--now", help="ISO-8601 reference time for reproducible freshness classification")
    parser.add_argument("--json", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    for path in (args.feeds_root, args.sources, args.memberships):
        if not path.exists():
            raise SystemExit(f"input not found: {path}")
    summary = build(args)
    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        output = summary["output"]
        print(
            f"Curated {output['source_count']} sources into {output['file_count']} OPML files; "
            f"staged {summary['candidate_count']} candidates; "
            f"default-disabled {summary['default_disabled_count']} stale current-sensitive feeds."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
