import tempfile
import unittest
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path

from scripts.curate_opml_catalog import (
    CorpusDisposition,
    CuratedSource,
    Membership,
    activity_for,
    canonical_url,
    classify_nature,
    classify_topic,
    compute_source_id,
    default_enabled_for,
    deduplicate_runtime_identities,
    choose_country,
    merge_candidate_inventory,
    normalize_language,
    parse_tags,
    validate_output,
    write_opml,
)


class CurateOPMLCatalogTests(unittest.TestCase):
    def test_content_tags_override_misleading_cat_title(self):
        memberships = [Membership("Pets", "cats", "Cats", "en", "global", None, "Pets/cats.opml", None)]
        rule = classify_topic(
            "The Cats of Politics",
            "Analysis of elections, government and international policy.",
            ["politics", "government", "elections", "international relations"],
            memberships,
        )
        self.assertEqual(rule.key, "news_current_affairs")
        self.assertEqual(rule.subcategory, "Politics & Government")

    def test_broad_newsroom_is_not_owned_by_a_transient_sports_sample(self):
        benin = classify_topic(
            "BENIN WEB TV",
            "A national news site covering politics, economy, sports, and culture.",
            ["news", "sports", "football", "politics", "entertainment"],
            [],
        )
        kaieteur = classify_topic(
            "Kaieteur News",
            "A daily newspaper covering local and regional news, crime, politics, sports, and opinion.",
            ["guyanese news", "caribbean", "crime", "sports", "opinion"],
            [],
        )
        sports_section = classify_topic(
            "N1 Sport",
            "A newspaper's dedicated sports feed.",
            ["bosnian news", "sports", "football", "national team"],
            [],
        )
        environmental_news = classify_topic(
            "Climate Central News",
            "Specialized reporting about climate science and the environment.",
            ["climate change", "environment", "science", "news", "sustainability"],
            [],
        )
        self.assertEqual(benin.subcategory, "Politics & Government")
        self.assertEqual(kaieteur.subcategory, "World News")
        self.assertEqual(sports_section.subcategory, "Football")
        self.assertEqual(environmental_news.subcategory, "Wildlife & Nature")

    def test_stable_google_headlines_do_not_follow_one_sampled_topic(self):
        rule = classify_topic(
            "Top stories - Google News",
            "Aggregated headlines currently dominated by automotive stories.",
            ["news aggregation", "technology", "entertainment", "sports", "automotive"],
            [],
        )
        self.assertEqual(rule.subcategory, "World News")

    def test_recovered_academic_sources_keep_their_semantic_home(self):
        cognitive = classify_topic(
            "Cognitive Science Society",
            "Research updates from the Cognitive Science Society, including occasional AI applications.",
            ["cognitive science", "research", "society news", "indigenous science", "artificial intelligence"],
            [],
        )
        mathematics = classify_topic(
            "Matematikk for livet",
            "Research-backed mathematics education for everyday life.",
            ["mathematics", "inclusive education", "podcast", "everyday life", "research"],
            [],
        )
        social_work = classify_topic(
            "Kafé Student",
            "University research about social work and child welfare.",
            ["social work", "child welfare", "podcast", "research", "university"],
            [],
        )
        self.assertEqual(cognitive.subcategory, "Earth & Life Sciences")
        self.assertEqual(mathematics.subcategory, "Education")
        self.assertEqual(social_work.subcategory, "Society & Communities")

    def test_finance_and_ecotourism_are_not_captured_by_incidental_topics(self):
        finance = classify_topic(
            "Finanza",
            "Italian personal finance coverage about taxes and energy prices.",
            ["personal finance", "italy", "economics", "taxes", "energy prices"],
            [],
        )
        ecotourism = classify_topic(
            "Green Global Travel",
            "Sustainable destination guides and wildlife conservation advice for travelers.",
            ["ecotourism", "sustainable travel", "travel guides", "wildlife conservation", "travel gear"],
            [],
        )
        culture = classify_topic(
            "Culture Archives",
            "Cultural news and heritage coverage with occasional tourism updates.",
            ["laos culture", "lao news", "heritage", "tourism", "arts"],
            [],
        )
        self.assertEqual(finance.subcategory, "Economy & Markets")
        self.assertEqual(ecotourism.subcategory, "Travel")
        self.assertEqual(culture.subcategory, "Culture & Heritage")

    def test_medium_is_not_mistaken_for_topic(self):
        rule = classify_topic(
            "What's Up Podcast", "A tour of the night sky and telescopes.",
            ["astronomy", "podcast", "telescopes"], [],
        )
        self.assertEqual(rule.subcategory, "Space & Astronomy")

    def test_incidental_description_word_does_not_define_topic(self):
        rule = classify_topic(
            "Interview Show", "Spontaneous conversations offering a space for reflection.",
            ["podcast", "interviews", "reflection"], [],
        )
        self.assertEqual(rule.subcategory, "General")

    def test_fact_checking_is_not_misclassified_as_mythology(self):
        snopes = classify_topic(
            "Snopes.com",
            "Fact-checking and debunking of urban legends, myths, rumors, and misinformation.",
            ["fact-checking", "urban legends", "misinformation", "rumors", "myths"],
            [],
        )
        health_explainer = classify_topic(
            "Health Evidence",
            "Medical explanations grounded in public-health research.",
            ["health", "medical", "fact-checking"],
            [],
        )
        science_debunking = classify_topic(
            "Science vs. Claims",
            "Science coverage confronting viral claims about health and the environment.",
            ["science", "misinformation", "fake news", "health", "environment"],
            [],
        )
        self.assertEqual(snopes.subcategory, "Fact-Checking & Media Literacy")
        self.assertEqual(health_explainer.subcategory, "Medicine & Public Health")
        self.assertEqual(science_debunking.subcategory, "Fact-Checking & Media Literacy")

    def test_specialized_topics_keep_meaningful_menu_homes(self):
        acoustics = classify_topic(
            "Acoustics Today", "Research in sound and hearing.",
            ["acoustics", "science", "research"], [],
        )
        mythology = classify_topic(
            "Sententiae Antiquae", "Stories from Greek and Roman mythology.",
            ["mythology", "classics", "folklore"], [],
        )
        tabletop = classify_topic(
            "Card Kingdom", "News and strategy for Magic: The Gathering.",
            ["gaming", "trading card game", "magic the gathering"], [],
        )
        true_crime = classify_topic(
            "Case Files", "Unsolved murders and crime stories.",
            ["true crime", "crime stories", "podcast"], [],
        )
        self.assertEqual(acoustics.subcategory, "Acoustics & Sound")
        self.assertEqual(mythology.subcategory, "Mythology & Folklore")
        self.assertEqual(tabletop.subcategory, "Tabletop & Puzzles")
        self.assertEqual(true_crime.subcategory, "True Crime & Mystery")

    def test_dormant_astronomy_remains_enabled(self):
        nature = classify_nature("Deep Sky Archive", "Astronomy observations", ["astronomy", "science"])
        self.assertEqual(nature, "evergreen")
        self.assertTrue(default_enabled_for(nature, 1_800))

    def test_dormant_news_and_personal_feeds_are_default_disabled(self):
        self.assertFalse(default_enabled_for("current-sensitive", 366))
        self.assertFalse(default_enabled_for("personal", 181))
        self.assertTrue(default_enabled_for("current-sensitive", 120))

    def test_activity_distinguishes_prolific_from_merely_active(self):
        now = datetime(2026, 7, 20, tzinfo=timezone.utc)
        self.assertEqual(activity_for("2026-07-19T00:00:00+00:00", 25, now)[0], "prolific")
        self.assertEqual(activity_for("2026-07-19T00:00:00+00:00", 3, now)[0], "active")
        self.assertEqual(activity_for("2024-01-01T00:00:00+00:00", 30, now)[0], "dormant")

    def test_tag_and_language_normalization(self):
        self.assertEqual(parse_tags("AI, Tech, A.I., Book Review"), ["artificial intelligence", "technology", "book reviews"])
        self.assertEqual(normalize_language("Portuguese"), "pt")
        self.assertEqual(normalize_language("pt_br"), "pt-BR")

    def test_language_scripts_survive_normalization(self):
        self.assertEqual(normalize_language("zh-Hans"), "zh-Hans")
        self.assertEqual(normalize_language("zh-Hant"), "zh-Hant")
        self.assertEqual(normalize_language("zh-hant-HK"), "zh-Hant-HK")
        self.assertEqual(normalize_language("sr-Latn"), "sr-Latn")
        self.assertEqual(normalize_language("en-US"), "en-US")
        self.assertEqual(normalize_language("es-419"), "es-419")
        self.assertEqual(normalize_language("eng"), "eng")
        # Deprecated ISO 639 spellings are mapped to their current form.
        self.assertEqual(normalize_language("in"), "id")
        self.assertEqual(normalize_language("iw"), "he")

    def test_non_language_text_is_not_sliced_into_a_tag(self):
        self.assertEqual(normalize_language("english junk"), None)
        self.assertEqual(normalize_language("nan"), None)
        self.assertEqual(normalize_language(""), None)
        self.assertEqual(normalize_language(None), None)

    def test_source_identity_matches_runtime_normalization(self):
        variants = [
            "http://www.Example.com/feed/",
            "https://example.com/feed",
            "https://example.com/feed/?utm_source=newsletter#latest",
        ]
        self.assertEqual({canonical_url(value) for value in variants}, {"https://example.com/feed"})

    def test_runtime_duplicate_rows_collapse_to_one_global_editorial_home(self):
        global_source = CuratedSource(
            source_id="global", title="Example", xml_url="https://example.com/feed",
            site_url="https://example.com", description="Global analyzed source",
            tags=["science"], language="en", status="done", articles_fetched=10,
            latest_item_at="2026-07-01T00:00:00+00:00", topic_order=4,
            topic_key="technology_science", topic_label="Technology & Science",
            subcategory="Earth & Life Sciences", nature="evergreen", activity="active",
            quality_score=70, default_enabled=True, media_kind="text", country=None,
            old_files=["Science/science.opml"],
        )
        country_variant = replace(
            global_source,
            source_id="country",
            xml_url="http://www.example.com/feed/",
            articles_fetched=20,
            country="Ireland",
            old_files=["countries/ireland.opml"],
        )

        result = deduplicate_runtime_identities([country_variant, global_source])

        self.assertEqual(len(result), 1)
        self.assertIsNone(result[0].country)
        self.assertEqual(
            result[0].old_files,
            ["Science/science.opml", "countries/ireland.opml"],
        )

    def test_country_collections_do_not_assign_multi_country_fanout_arbitrarily(self):
        canada = Membership("90_countries", "canada", "", "en", "global", "canada", "90_countries/canada/canada.opml", None)
        usa = Membership("90_countries", "usa", "", "en", "global", "usa", "90_countries/usa/usa.opml", None)
        self.assertEqual(choose_country([canada]), "canada")
        self.assertIsNone(choose_country([canada, usa]))

    def test_global_topic_membership_supersedes_single_country_home(self):
        canada = Membership("90_countries", "canada", "", "en", "global", "canada", "90_countries/canada/canada.opml", None)
        science = Membership("04_Technology_&_Science", "science", "", "en", "global", None, "04_Technology_&_Science/science.opml", None)
        self.assertIsNone(choose_country([canada, science]))

    def test_candidate_inventory_excludes_synthetic_search_queries(self):
        def corpus(status: str, suffix: str) -> CorpusDisposition:
            return CorpusDisposition(
                source_id=f"source-{suffix}", title=f"Source {suffix}",
                xml_url=f"https://example.com/{suffix}.xml", site_url=None,
                status=status, error_message="broken" if status == "failed" else None,
                attempt_count=3 if status == "failed" else 1,
                http_status=500 if status == "failed" else 200,
                final_url=None, content_type="application/rss+xml",
                articles_fetched=1 if status == "done" else 0,
                latest_item_at=None, old_files=[f"Legacy/{suffix}.opml"],
            )

        existing = [
            {
                "title": "Existing empty", "xml_url": "https://example.com/empty.xml",
                "html_url": "", "original_file": "Legacy/empty.opml",
                "discovery_source": "", "query_scope": "", "query_language": "",
            },
            {
                "title": "Synthetic", "xml_url": "https://news.google.com/rss/search?q=test",
                "html_url": "", "original_file": "languages/en/test.opml",
                "discovery_source": "google-news-search-v3", "query_scope": "topic",
                "query_language": "en",
            },
            {
                "title": "Editorial", "xml_url": "https://editorial.example/feed",
                "html_url": "", "original_file": "countries/example.opml",
                "discovery_source": "", "query_scope": "", "query_language": "",
            },
        ]

        result = merge_candidate_inventory(
            existing,
            [
                corpus("done", "done"), corpus("empty", "empty"),
                corpus("failed", "failed"), corpus("excluded_policy", "excluded"),
            ],
        )
        by_disposition = {item["disposition"]: item for item in result}

        self.assertEqual(len(result), 4)
        self.assertNotIn("production", by_disposition)
        self.assertEqual(by_disposition["processed_empty"]["attempt_count"], "1")
        self.assertEqual(by_disposition["processed_failed"]["last_error"], "broken")
        self.assertNotIn("unattempted_synthetic", by_disposition)
        self.assertEqual(by_disposition["unattempted_editorial"]["corpus_status"], "unattempted")
        self.assertEqual(by_disposition["excluded_policy"]["candidate_kind"], "policy_excluded")

    def test_written_opml_is_enriched_and_valid(self):
        source = CuratedSource(
            source_id=compute_source_id("https://example.com/feed.xml"),
            title="Example", xml_url="https://example.com/feed.xml",
            site_url="https://example.com", description="A useful feed", tags=["science"],
            language="en", status="done", articles_fetched=10,
            latest_item_at="2026-07-01T00:00:00+00:00", topic_order=4,
            topic_key="technology_science", topic_label="Technology & Science",
            subcategory="Earth & Life Sciences", nature="evergreen", activity="active",
            quality_score=75, default_enabled=True, media_kind="text", country=None,
            old_files=["Old/science.opml"],
        )
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            write_opml(output / source.primary_relative_path, source.topic_label, [source])
            report = validate_output(output, [source])
            self.assertEqual(report["source_count"], 1)
            self.assertEqual(report["file_count"], 1)
            self.assertEqual(report["identity_mismatch_count"], 0)
            self.assertEqual(report["placeholder_title_count"], 0)

    def test_validation_rejects_a_source_id_from_an_old_formula(self):
        source = CuratedSource(
            source_id="old-formula", title="Example", xml_url="https://example.com/feed.xml",
            site_url=None, description="A useful feed", tags=["science"], language="en",
            status="done", articles_fetched=10, latest_item_at=None, topic_order=4,
            topic_key="technology_science", topic_label="Technology & Science",
            subcategory="Earth & Life Sciences", nature="evergreen", activity="active",
            quality_score=75, default_enabled=True, media_kind="text", country=None,
            old_files=[],
        )
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            write_opml(output / source.primary_relative_path, source.topic_label, [source])
            with self.assertRaisesRegex(RuntimeError, "identity_mismatch"):
                validate_output(output, [source])


if __name__ == "__main__":
    unittest.main()
