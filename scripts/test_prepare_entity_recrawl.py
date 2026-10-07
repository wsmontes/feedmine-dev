"""Tests for P0-02 and P1-03: recrawl evidence clearing + stable key resolution."""

import io
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pyarrow as pa
import pyarrow.parquet as pq

from scripts.prepare_entity_recrawl import prepare
from scripts.catalog_identity import compute_source_id, canonical_url, request_url


class PrepareEntityRecrawlTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.sources = self.tmp / "sources.parquet"
        self.quarantine = self.tmp / "quarantine.csv"
        self.output = self.tmp / "output.parquet"

    def _make_fixture_parquet(self):
        """Create a minimal parquet with old fetch evidence for 2 rows."""
        schema = pa.schema([
            ("source_id", pa.string()),
            ("xml_url", pa.string()),
            ("canonical_xml_url", pa.string()),
            ("status", pa.string()),
            ("error_message", pa.string()),
            ("final_url", pa.string()),
            ("attempt_count", pa.int32()),
            ("feed_title", pa.string()),
            ("feed_description", pa.string()),
            ("site_url", pa.string()),
            ("feed_reported_language", pa.string()),
            ("articles_fetched", pa.int32()),
            ("latest_item_at", pa.string()),
            ("http_status", pa.int32()),
            ("content_type", pa.string()),
        ])
        data = [
            {
                "source_id": "old-id-abc",
                "xml_url": "https://example.com/feed&#x2F;rss",
                "canonical_xml_url": "https://example.com/feed/rss",
                "status": "done",
                "error_message": None,
                "final_url": "https://example.com/feed/rss",
                "attempt_count": 1,
                "feed_title": "Old Feed Title",
                "feed_description": "Old description from escaped URL",
                "site_url": "https://example.com",
                "feed_reported_language": "en",
                "articles_fetched": 10,
                "latest_item_at": "2024-01-01T00:00:00",
                "http_status": 200,
                "content_type": "application/rss+xml",
            },
            {
                "source_id": "other-id-xyz",
                "xml_url": "https://other.com/feed",
                "canonical_xml_url": "https://other.com/feed",
                "status": "done",
                "error_message": None,
                "final_url": "https://other.com/feed",
                "attempt_count": 2,
                "feed_title": "Other Feed",
                "feed_description": "Another feed",
                "site_url": "https://other.com",
                "feed_reported_language": "fr",
                "articles_fetched": 20,
                "latest_item_at": "2024-06-01T00:00:00",
                "http_status": 200,
                "content_type": "application/atom+xml",
            },
        ]
        table = pa.Table.from_pylist(data, schema=schema)
        pq.write_table(table, self.sources, compression="zstd")

    def _write_quarantine(self, *lines: str):
        header = "row_index,old_source_id,xml_url,reason\n"
        self.quarantine.write_text(header + "\n".join(lines))

    # ── P0-02: evidence clearing ──

    def test_clears_all_fetch_evidence(self):
        self._make_fixture_parquet()
        self._write_quarantine(
            '0,old-id-abc,https://example.com/feed&#x2F;rss,url_entities_decoded_requires_refetch'
        )

        count = prepare(self.sources, self.quarantine, self.output)
        self.assertEqual(count, 1)

        result = pq.read_table(self.output).to_pylist()[0]
        self.assertIsNone(result["feed_title"])
        self.assertIsNone(result["feed_description"])
        self.assertIsNone(result["site_url"])
        self.assertIsNone(result["feed_reported_language"])
        self.assertIsNone(result["articles_fetched"])
        self.assertIsNone(result["latest_item_at"])
        self.assertIsNone(result["http_status"])
        self.assertIsNone(result["content_type"])
        self.assertEqual(result["status"], "pending")
        self.assertIsNone(result["error_message"])
        self.assertEqual(result["attempt_count"], 0)

    def test_unmatched_row_preserved(self):
        """Row not in quarantine keeps its old evidence."""
        self._make_fixture_parquet()
        self._write_quarantine(
            '0,old-id-abc,https://example.com/feed&#x2F;rss,url_entities_decoded_requires_refetch'
        )

        prepare(self.sources, self.quarantine, self.output)
        result = pq.read_table(self.output).to_pylist()
        # Row 0 cleared, row 1 untouched
        self.assertIsNone(result[0]["feed_title"])
        self.assertEqual(result[1]["feed_title"], "Other Feed")

    # ── P1-03: stable key resolution ──

    def test_resolves_by_old_source_id_not_row_index(self):
        """CSV row_index is ignored; resolution is by old_source_id."""
        self._make_fixture_parquet()
        # CSV says row_index=5 but old_source_id matches row 0
        self._write_quarantine(
            '5,old-id-abc,https://example.com/feed&#x2F;rss,url_entities_decoded_requires_refetch'
        )

        count = prepare(self.sources, self.quarantine, self.output)
        self.assertEqual(count, 1)

    def test_fails_on_unmatched_old_source_id(self):
        self._make_fixture_parquet()
        self._write_quarantine(
            '0,nonexistent-id,https://example.com/feed,url_entities_decoded_requires_refetch'
        )

        with self.assertRaises(ValueError) as ctx:
            prepare(self.sources, self.quarantine, self.output)
        self.assertIn("could not be resolved", str(ctx.exception))

    def test_fails_on_xml_url_mismatch(self):
        self._make_fixture_parquet()
        # old_source_id matches but xml_url doesn't
        self._write_quarantine(
            '0,old-id-abc,https://different-url.com/feed,url_entities_decoded_requires_refetch'
        )

        with self.assertRaises(ValueError) as ctx:
            prepare(self.sources, self.quarantine, self.output)
        self.assertIn("xml_url mismatch", str(ctx.exception))

    def test_reordered_parquet_still_resolves(self):
        """Same CSV against a reordered parquet resolves correctly by key."""
        schema = pa.schema([
            ("source_id", pa.string()),
            ("xml_url", pa.string()),
            ("canonical_xml_url", pa.string()),
            ("status", pa.string()),
            ("error_message", pa.string()),
            ("final_url", pa.string()),
            ("attempt_count", pa.int32()),
            ("feed_title", pa.string()),
            ("articles_fetched", pa.int32()),
            ("http_status", pa.int32()),
        ])
        # Row 0 has old-id-B, row 1 has old-id-A — deliberately reordered
        defaults = {
            "canonical_xml_url": "", "status": "done", "error_message": None,
            "final_url": "", "feed_title": "", "attempt_count": 1,
            "http_status": 200, "articles_fetched": 99,
        }
        data = [
            {"source_id": "old-id-B", "xml_url": "https://b.com/feed", **defaults},
            {"source_id": "old-id-A", "xml_url": "https://a.com/feed", **defaults},
        ]
        table = pa.Table.from_pylist(data, schema=schema)
        pq.write_table(table, self.sources, compression="zstd")

        self._write_quarantine(
            '0,old-id-A,https://a.com/feed,url_entities_decoded_requires_refetch'
        )

        count = prepare(self.sources, self.quarantine, self.output)
        self.assertEqual(count, 1)
        result = pq.read_table(self.output).to_pylist()
        # Row at index 1 (old-id-A) gets cleared; row 0 (old-id-B) untouched
        self.assertIsNone(result[1]["feed_title"])
        self.assertEqual(result[1]["status"], "pending")
        self.assertEqual(result[0]["feed_title"], "")

    def test_no_partial_write_on_error(self):
        self._make_fixture_parquet()
        self._write_quarantine(
            '0,nonexistent-id,https://example.com/bad,url_entities_decoded_requires_refetch'
        )

        with self.assertRaises(ValueError):
            prepare(self.sources, self.quarantine, self.output)
        self.assertFalse(self.output.exists())

    def test_no_queue_when_nothing_matches(self):
        self._make_fixture_parquet()
        # All rows have wrong reason
        self.quarantine.write_text(
            "row_index,old_source_id,xml_url,reason\n"
            '0,old-id-abc,https://example.com/feed,some_other_reason\n'
        )
        count = prepare(self.sources, self.quarantine, self.output)
        self.assertEqual(count, 0)

    def test_new_identity_set_correctly(self):
        self._make_fixture_parquet()
        self._write_quarantine(
            '0,old-id-abc,https://example.com/feed&#x2F;rss,url_entities_decoded_requires_refetch'
        )

        prepare(self.sources, self.quarantine, self.output)
        result = pq.read_table(self.output).to_pylist()[0]
        expected_url = request_url("https://example.com/feed&#x2F;rss")
        self.assertEqual(result["xml_url"], expected_url)
        self.assertEqual(result["source_id"], compute_source_id(expected_url))
        self.assertEqual(result["canonical_xml_url"], canonical_url(expected_url))

    def test_provenance_fields_set(self):
        self._make_fixture_parquet()
        self._write_quarantine(
            '0,old-id-abc,https://example.com/feed&#x2F;rss,url_entities_decoded_requires_refetch'
        )

        prepare(self.sources, self.quarantine, self.output)
        result = pq.read_table(self.output).to_pylist()[0]
        self.assertEqual(result["recrawl_reason"], "url_entities_decoded_requires_refetch")
        self.assertEqual(result["previous_source_id"], "old-id-abc")
        self.assertIsNotNone(result["prepared_at"])
        self.assertIsNotNone(result["input_digest"])

    # ── P1-08: identity collision detection ──

    def _write_two_row_parquet(self, second_source_id: str, second_xml_url: str = "https://other.com/feed"):
        schema = pa.schema([
            ("source_id", pa.string()),
            ("xml_url", pa.string()),
            ("canonical_xml_url", pa.string()),
            ("status", pa.string()),
            ("error_message", pa.string()),
            ("final_url", pa.string()),
            ("attempt_count", pa.int32()),
            ("feed_title", pa.string()),
            ("articles_fetched", pa.int32()),
            ("http_status", pa.int32()),
        ])
        defaults = {
            "canonical_xml_url": "", "status": "done", "error_message": None,
            "final_url": "", "feed_title": "F", "attempt_count": 1,
            "http_status": 200, "articles_fetched": 1,
        }
        data = [
            {"source_id": "old-0", "xml_url": "https://example.com/feed&#x2F;rss", **defaults},
            {"source_id": second_source_id, "xml_url": second_xml_url, **defaults},
        ]
        pq.write_table(pa.Table.from_pylist(data, schema=schema), self.sources, compression="zstd")

    def test_collision_with_last_row_is_detected(self):
        """The new identity of row 0 already belongs to the final row."""
        new_id = compute_source_id(request_url("https://example.com/feed&#x2F;rss"))
        self._write_two_row_parquet(second_source_id=new_id)
        self._write_quarantine(
            '0,old-0,https://example.com/feed&#x2F;rss,url_entities_decoded_requires_refetch'
        )

        with self.assertRaises(ValueError) as ctx:
            prepare(self.sources, self.quarantine, self.output)
        self.assertIn("collision", str(ctx.exception))
        self.assertFalse(self.output.exists())
        self.assertTrue(self.output.with_suffix(".collisions.csv").exists())

    def test_collision_with_first_row_is_detected(self):
        """A queued row later in the corpus collides with row 0."""
        new_id = compute_source_id(request_url("https://example.com/feed&#x2F;rss"))
        schema = pa.schema([
            ("source_id", pa.string()),
            ("xml_url", pa.string()),
            ("canonical_xml_url", pa.string()),
            ("status", pa.string()),
        ])
        data = [
            {"source_id": new_id, "xml_url": "https://example.com/feed/rss",
             "canonical_xml_url": "", "status": "done"},
            {"source_id": "old-1", "xml_url": "https://example.com/feed&#x2F;rss",
             "canonical_xml_url": "", "status": "done"},
        ]
        pq.write_table(pa.Table.from_pylist(data, schema=schema), self.sources, compression="zstd")
        self._write_quarantine(
            '1,old-1,https://example.com/feed&#x2F;rss,url_entities_decoded_requires_refetch'
        )

        with self.assertRaises(ValueError):
            prepare(self.sources, self.quarantine, self.output)

    def test_two_queued_rows_collapsing_is_detected(self):
        schema = pa.schema([
            ("source_id", pa.string()),
            ("xml_url", pa.string()),
            ("canonical_xml_url", pa.string()),
            ("status", pa.string()),
        ])
        data = [
            {"source_id": "old-0", "xml_url": "https://example.com/feed&#x2F;rss",
             "canonical_xml_url": "", "status": "done"},
            {"source_id": "old-1", "xml_url": "https://example.com/feed/rss",
             "canonical_xml_url": "", "status": "done"},
        ]
        pq.write_table(pa.Table.from_pylist(data, schema=schema), self.sources, compression="zstd")
        self._write_quarantine(
            '0,old-0,https://example.com/feed&#x2F;rss,url_entities_decoded_requires_refetch',
            '1,old-1,https://example.com/feed/rss,url_entities_decoded_requires_refetch',
        )

        with self.assertRaises(ValueError) as ctx:
            prepare(self.sources, self.quarantine, self.output)
        self.assertIn("collision", str(ctx.exception))

    def test_requeued_row_keeping_its_own_id_is_not_a_collision(self):
        """A queued row whose identity does not change must not self-conflict."""
        url = "https://example.com/feed"
        schema = pa.schema([
            ("source_id", pa.string()),
            ("xml_url", pa.string()),
            ("canonical_xml_url", pa.string()),
            ("status", pa.string()),
        ])
        data = [{
            "source_id": compute_source_id(url), "xml_url": url,
            "canonical_xml_url": canonical_url(url), "status": "done",
        }]
        pq.write_table(pa.Table.from_pylist(data, schema=schema), self.sources, compression="zstd")
        self._write_quarantine(
            f'0,{compute_source_id(url)},{url},url_entities_decoded_requires_refetch'
        )

        count = prepare(self.sources, self.quarantine, self.output)
        self.assertEqual(count, 1)
        self.assertTrue(self.output.exists())

    def test_collision_detection_scales_linearly(self):
        """Queued rows are indexed once; large corpora do not multiply work."""
        size = 400
        new_id = compute_source_id(request_url("https://example.com/feed&#x2F;rss"))
        schema = pa.schema([
            ("source_id", pa.string()),
            ("xml_url", pa.string()),
            ("canonical_xml_url", pa.string()),
            ("status", pa.string()),
        ])
        data = [
            {"source_id": "old-0", "xml_url": "https://example.com/feed&#x2F;rss",
             "canonical_xml_url": "", "status": "done"},
        ]
        data += [
            {"source_id": f"untouched-{i}", "xml_url": f"https://example.com/feed/{i}",
             "canonical_xml_url": "", "status": "done"}
            for i in range(size - 2)
        ]
        # Final row already owns the proposed identity.
        data.append({"source_id": new_id, "xml_url": "https://example.com/feed/rss",
                     "canonical_xml_url": "", "status": "done"})
        pq.write_table(pa.Table.from_pylist(data, schema=schema), self.sources, compression="zstd")
        self._write_quarantine(
            '0,old-0,https://example.com/feed&#x2F;rss,url_entities_decoded_requires_refetch'
        )

        with self.assertRaises(ValueError):
            prepare(self.sources, self.quarantine, self.output)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
