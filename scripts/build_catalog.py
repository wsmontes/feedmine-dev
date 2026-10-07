#!/usr/bin/env python3
"""Build Feedmine's derived catalog.sqlite from OPML files.

The OPML files and folder tree remain the editorial source of truth. This
script produces the disposable, read-optimized SQLite index used by FeedEngine.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import time
import unicodedata
import urllib.parse
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

try:
    from scripts.catalog_identity import canonical_url, valid_http_url
except ModuleNotFoundError:  # Direct ``python scripts/...`` execution.
    from catalog_identity import canonical_url, valid_http_url


NODE_TOPIC = 0
NODE_COUNTRY = 1
NODE_REGION = 2
NODE_SUBCATEGORY = 3
NODE_LANGUAGE = 4


@dataclass(frozen=True)
class InputNode:
    key: str
    name: str
    kind: int
    language: str | None = None


@dataclass(frozen=True)
class Occurrence:
    title: str
    declared_url: str
    request_url: str
    media_kind: str
    language: str | None
    node_path: tuple[InputNode, ...]
    opml_file: str
    sort_order: int
    title_override: str | None
    language_override: str | None
    media_kind_override: str | None
    site_url: str | None
    description: str | None
    tags: str | None
    nature: str | None
    activity: str | None
    latest_item_at: str | None
    quality_score: int | None
    default_enabled: bool
    feed_type: str | None = None


def slug(raw: str) -> str:
    folded = unicodedata.normalize("NFKD", raw).encode("ascii", "ignore").decode("ascii")
    folded = folded.lower()
    collapsed = re.sub(r"[^a-z0-9]+", "-", folded).strip("-")
    return collapsed or "untitled"


def display_name(raw: str) -> str:
    raw = re.sub(r"^\d+[ _-]+", "", raw)
    return raw.replace("_", " ").replace("-", " ").title()


def semantic_path_name(raw: str) -> str:
    return re.sub(r"^[\d_]+[ _-]+", "", raw).lower()


def stable_uint32(raw: str, reserved_zero: bool = True) -> int:
    digest = hashlib.sha256(raw.encode("utf-8")).digest()
    value = int.from_bytes(digest[:4], "big", signed=False)
    return 1 if reserved_zero and value == 0 else value


def canonical_url_key(raw: str) -> str:
    return canonical_url(raw)


def display_host(raw: str) -> str | None:
    parsed = urllib.parse.urlsplit(raw.strip())
    return parsed.hostname.lower() if parsed.hostname else None


def source_id(source_key: str) -> int:
    return stable_uint32(source_key)


def node_id(node_key: str) -> int:
    return stable_uint32(node_key)


def media_kind_for_file(file_name: str) -> str:
    lower = file_name.lower()
    if "podcast" in lower:
        return "audio"
    if "youtube" in lower:
        return "video"
    if "reddit" in lower or "forum" in lower:
        return "forum"
    return "text"


def media_kind_for_url(xml_url: str, default: str) -> str:
    lower = xml_url.lower()
    if "youtube.com/feeds" in lower:
        return "video"
    if "anchor.fm" in lower or "spreaker.com" in lower or "podcast" in lower:
        return "audio"
    if "reddit.com/r/" in lower:
        return "forum"
    return default


# Every outline in the tree carries feedmineMediaKind. "text" is the generic
# default the curation pipeline writes for whatever it has not classified, so
# URL/filename evidence still wins for it; audio/video/forum are editorial
# decisions and must not be overridden by the filename/podcast-host guess.
EXPLICIT_MEDIA_KINDS = frozenset({"audio", "video", "forum"})


def declared_media_kind(element: ET.Element) -> str | None:
    """Explicit editorial media kind, when it is more than the generic default."""
    raw = (element.attrib.get("feedmineMediaKind") or "").strip().lower()
    return raw if raw in EXPLICIT_MEDIA_KINDS else None


def append_file_node(nodes: list[InputNode], file_name: str, kind: int) -> None:
    key = slug(file_name)
    if nodes and nodes[-1].key == key:
        return
    nodes.append(InputNode(key=key, name=display_name(file_name), kind=kind))


def folder_nodes(relative_path: str, file_name: str) -> list[InputNode]:
    parts = Path(relative_path).parts[:-1]

    if parts and semantic_path_name(parts[0]) in ("countries", "staging"):
        nodes = [InputNode(key=parts[0], name="Countries", kind=NODE_TOPIC)]
        country_parts = list(parts[1:])
        for index, part in enumerate(country_parts):
            nodes.append(InputNode(
                key=part,
                name=display_name(part),
                kind=NODE_COUNTRY if index == 0 else NODE_REGION,
            ))
        if country_parts:
            country = country_parts[0]
            if file_name == country:
                return nodes
            if file_name.startswith(f"{country}-"):
                append_file_node(nodes, file_name[len(country) + 1:], NODE_REGION)
            else:
                append_file_node(nodes, file_name, NODE_REGION)
        return nodes

    if parts and parts[0] == "languages" and len(parts) >= 2:
        nodes = [InputNode(key="languages", name="Languages", kind=NODE_TOPIC)]
        for index, part in enumerate(parts[1:]):
            nodes.append(InputNode(
                key=part,
                name=display_name(part),
                kind=NODE_LANGUAGE if index == 0 else NODE_SUBCATEGORY,
                language=part if index == 0 else None,
            ))
        append_file_node(nodes, file_name, NODE_SUBCATEGORY)
        return nodes

    if parts:
        nodes = [
            InputNode(
                key=slug(part),
                name=display_name(part),
                kind=NODE_TOPIC if index == 0 else NODE_SUBCATEGORY,
            )
            for index, part in enumerate(parts)
        ]
        append_file_node(nodes, file_name, NODE_SUBCATEGORY)
        return nodes

    return [
        InputNode(key="global", name="Global", kind=NODE_TOPIC),
        InputNode(key=slug(file_name), name=display_name(file_name), kind=NODE_SUBCATEGORY),
    ]


def extract_language(root: ET.Element) -> str | None:
    head = root.find("head")
    if head is None:
        return None
    language = head.findtext("language")
    language = language.strip() if language else ""
    return language or None


def outline_name(element: ET.Element, fallback: str) -> str:
    return (element.attrib.get("title") or element.attrib.get("text") or fallback).strip()


def iter_outline_occurrences(
    element: ET.Element,
    *,
    folder: tuple[InputNode, ...],
    stack: tuple[tuple[str, str | None], ...],
    fallback_category: str,
    opml_file: str,
    file_index: int,
    order: list[int],
    invalid_count: list[int],
    file_language: str | None,
    default_media_kind: str,
) -> Iterable[Occurrence]:
    if element.tag != "outline":
        for child in element:
            yield from iter_outline_occurrences(
                child,
                folder=folder,
                stack=stack,
                fallback_category=fallback_category,
                opml_file=opml_file,
                file_index=file_index,
                order=order,
                invalid_count=invalid_count,
                file_language=file_language,
                default_media_kind=default_media_kind,
            )
        return

    xml_url = (element.attrib.get("xmlUrl") or "").strip()
    name = outline_name(element, fallback_category)
    inherited_language = stack[-1][1] if stack else file_language
    language = element.attrib.get("language") or inherited_language

    if xml_url and valid_http_url(xml_url):
        category_nodes = tuple(
            InputNode(key=slug(label), name=label, kind=NODE_SUBCATEGORY, language=lang)
            for label, lang in stack
        )
        node_path = folder + category_nodes
        title = name or (stack[-1][0] if stack else fallback_category)
        media_kind = declared_media_kind(element) or media_kind_for_url(xml_url, default_media_kind)
        yield Occurrence(
            title=title,
            declared_url=xml_url,
            request_url=xml_url,
            media_kind=media_kind,
            language=language,
            node_path=node_path,
            opml_file=opml_file,
            sort_order=file_index * 1_000_000 + order[0],
            title_override=title,
            language_override=language,
            media_kind_override=media_kind,
            site_url=(element.attrib.get("htmlUrl") or "").strip() or None,
            description=(element.attrib.get("description") or "").strip() or None,
            tags=(element.attrib.get("category") or "").strip() or None,
            nature=(element.attrib.get("feedmineNature") or "").strip() or None,
            activity=(element.attrib.get("feedmineActivity") or "").strip() or None,
            latest_item_at=(element.attrib.get("feedmineLatestItemAt") or "").strip() or None,
            quality_score=int(element.attrib["feedmineQualityScore"]) if element.attrib.get("feedmineQualityScore", "").isdigit() else None,
            default_enabled=element.attrib.get("feedmineDefaultEnabled", "true").lower() != "false",
            feed_type=(element.attrib.get("type") or "").strip() or None,
        )
        order[0] += 1
        return

    if xml_url:
        invalid_count[0] += 1
        return

    next_stack = stack
    if name:
        next_stack = stack + ((name, language),)
    for child in element:
        yield from iter_outline_occurrences(
            child,
            folder=folder,
            stack=next_stack,
            fallback_category=fallback_category,
            opml_file=opml_file,
            file_index=file_index,
            order=order,
            invalid_count=invalid_count,
            file_language=file_language,
            default_media_kind=default_media_kind,
        )


def scan_opml(feeds_root: Path) -> tuple[list[Occurrence], int, int, int]:
    files = sorted(path for path in feeds_root.rglob("*.opml") if path.is_file())
    occurrences: list[Occurrence] = []
    failed_files = 0
    invalid_sources = 0

    for file_index, path in enumerate(files):
        relative_path = path.relative_to(feeds_root).as_posix()
        file_name = path.stem
        default_media_kind = media_kind_for_file(file_name)
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError:
            failed_files += 1
            continue

        file_language = extract_language(root)
        folder = tuple(folder_nodes(relative_path, file_name))
        body = root.find("body")
        if body is None:
            continue

        order = [0]
        invalid_count = [0]
        for child in body:
            occurrences.extend(iter_outline_occurrences(
                child,
                folder=folder,
                stack=(),
                fallback_category=display_name(file_name),
                opml_file=relative_path,
                file_index=file_index,
                order=order,
                invalid_count=invalid_count,
                file_language=file_language,
                default_media_kind=default_media_kind,
            ))
        invalid_sources += invalid_count[0]

    return occurrences, len(files), failed_files, invalid_sources


def create_schema(db: sqlite3.Connection) -> None:
    db.execute("PRAGMA foreign_keys = ON")
    db.executescript("""
    CREATE TABLE catalog_metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    CREATE TABLE catalog_node (
        id INTEGER PRIMARY KEY,
        key TEXT NOT NULL UNIQUE,
        parent_id INTEGER REFERENCES catalog_node(id),
        name TEXT NOT NULL,
        kind INTEGER NOT NULL,
        source_count INTEGER NOT NULL DEFAULT 0,
        child_count INTEGER NOT NULL DEFAULT 0,
        language TEXT
    );
    CREATE INDEX idx_catalog_node_parent_name
        ON catalog_node(parent_id, name COLLATE NOCASE, id);
    CREATE TABLE catalog_source (
        id INTEGER PRIMARY KEY,
        key TEXT NOT NULL UNIQUE,
        title TEXT NOT NULL,
        declared_url TEXT NOT NULL,
        request_url TEXT NOT NULL,
        display_host TEXT,
        media_kind TEXT NOT NULL,
        language TEXT,
        site_url TEXT,
        description TEXT,
        tags TEXT,
        nature TEXT,
        activity TEXT,
        latest_item_at TEXT,
        quality_score INTEGER,
        default_enabled INTEGER NOT NULL DEFAULT 1,
        type TEXT
    );
    CREATE INDEX idx_catalog_source_title
        ON catalog_source(title COLLATE NOCASE, id);
    CREATE TABLE catalog_placement (
        id INTEGER PRIMARY KEY,
        source_id INTEGER NOT NULL REFERENCES catalog_source(id) ON DELETE CASCADE,
        node_id INTEGER NOT NULL REFERENCES catalog_node(id) ON DELETE CASCADE,
        node_name TEXT NOT NULL,
        opml_file TEXT NOT NULL,
        sort_order INTEGER NOT NULL,
        title_override TEXT,
        language_override TEXT,
        media_kind_override TEXT,
        UNIQUE(source_id, node_id, opml_file, sort_order)
    );
    CREATE INDEX idx_catalog_placement_node_order
        ON catalog_placement(node_id, sort_order, source_id);
    CREATE INDEX idx_catalog_placement_source
        ON catalog_placement(source_id);
    CREATE VIRTUAL TABLE catalog_source_fts USING fts5(
        title,
        description,
        tags,
        display_host,
        language,
        media_kind,
        path
    );
    """)


def compile_catalog(occurrences: list[Occurrence], output: Path, file_count: int, failed_files: int, invalid_sources: int) -> dict[str, int | str]:
    output.parent.mkdir(parents=True, exist_ok=True)
    tmp = output.with_name(f".{output.name}.tmp")
    if tmp.exists():
        tmp.unlink()

    source_keys_by_id: dict[int, str] = {}
    node_keys_by_id: dict[int, str] = {0: "root"}
    sources: dict[str, dict[str, object]] = {}
    nodes: dict[str, dict[str, object]] = {
        "root": {"id": 0, "key": "root", "parent_id": None, "name": "Root", "kind": NODE_TOPIC, "language": None}
    }
    placements: list[dict[str, object]] = []
    node_source_sets: dict[int, set[int]] = {}

    for occurrence in occurrences:
        if not occurrence.node_path:
            continue
        skey = canonical_url_key(occurrence.declared_url)
        sid = source_id(skey)
        previous_source_key = source_keys_by_id.get(sid)
        if previous_source_key is not None and previous_source_key != skey:
            raise RuntimeError(f"source id collision {sid}: {previous_source_key} vs {skey}")
        source_keys_by_id[sid] = skey
        if skey in sources:
            previous = sources[skey]
            raise RuntimeError(
                "catalog identity collapse must be reconciled before compilation: "
                f"{previous['opml_file']} ({previous['declared_url']}) and "
                f"{occurrence.opml_file} ({occurrence.declared_url}) -> {skey}"
            )
        sources[skey] = {
            "id": sid,
            "key": skey,
            "title": occurrence.title,
            "declared_url": occurrence.declared_url,
            "request_url": occurrence.request_url,
            "display_host": display_host(occurrence.declared_url),
            "media_kind": occurrence.media_kind,
            "language": occurrence.language,
            "site_url": occurrence.site_url,
            "description": occurrence.description,
            "tags": occurrence.tags,
            "nature": occurrence.nature,
            "activity": occurrence.activity,
            "latest_item_at": occurrence.latest_item_at,
            "quality_score": occurrence.quality_score,
            "default_enabled": 1 if occurrence.default_enabled else 0,
            "type": occurrence.feed_type,
            "opml_file": occurrence.opml_file,
        }

        parent_id = 0
        path_components: list[str] = []
        ancestor_ids = [0]
        for input_node in occurrence.node_path:
            path_components.append(input_node.key)
            nkey = "/".join(path_components)
            nid = node_id(nkey)
            previous_node_key = node_keys_by_id.get(nid)
            if previous_node_key is not None and previous_node_key != nkey:
                raise RuntimeError(f"node id collision {nid}: {previous_node_key} vs {nkey}")
            node_keys_by_id[nid] = nkey
            nodes.setdefault(nkey, {
                "id": nid,
                "key": nkey,
                "parent_id": parent_id,
                "name": input_node.name,
                "kind": input_node.kind,
                "language": input_node.language,
            })
            parent_id = nid
            ancestor_ids.append(nid)

        placements.append({
            "id": len(placements) + 1,
            "source_id": sid,
            "node_id": parent_id,
            "node_name": occurrence.node_path[-1].name,
            "opml_file": occurrence.opml_file,
            "sort_order": occurrence.sort_order,
            "title_override": occurrence.title_override,
            "language_override": occurrence.language_override,
            "media_kind_override": occurrence.media_kind_override,
        })
        for ancestor_id in ancestor_ids:
            node_source_sets.setdefault(ancestor_id, set()).add(sid)

    child_counts: dict[int, int] = {}
    for node in nodes.values():
        parent_id = node["parent_id"]
        if parent_id is not None:
            child_counts[parent_id] = child_counts.get(parent_id, 0) + 1

    paths_by_source: dict[int, list[str]] = {}
    nodes_by_id = {int(node["id"]): node for node in nodes.values()}
    for placement in placements:
        node = nodes_by_id.get(int(placement["node_id"]))
        if node:
            paths_by_source.setdefault(int(placement["source_id"]), []).append(str(node["key"]).replace("/", " "))

    db = sqlite3.connect(tmp)
    try:
        create_schema(db)
        with db:
            metadata = {
                "schema_version": "2",
                "catalog_version": str(round(time.time() * 1_000_000)),
                "source_count": str(len(sources)),
                "node_count": str(len(nodes)),
                "placement_count": str(len(placements)),
                "duplicate_occurrence_count": str(len(placements) - len(sources)),
                "file_count": str(file_count),
                "failed_file_count": str(failed_files),
                "invalid_source_count": str(invalid_sources),
            }
            db.executemany("INSERT INTO catalog_metadata (key, value) VALUES (?, ?)", metadata.items())
            db.executemany("""
                INSERT INTO catalog_source
                    (id, key, title, declared_url, request_url, display_host, media_kind, language,
                     site_url, description, tags, nature, activity, latest_item_at, quality_score, default_enabled, type)
                VALUES (:id, :key, :title, :declared_url, :request_url, :display_host, :media_kind, :language,
                        :site_url, :description, :tags, :nature, :activity, :latest_item_at, :quality_score, :default_enabled, :type)
            """, sorted(sources.values(), key=lambda source: int(source["id"])))
            db.executemany("""
                INSERT INTO catalog_node
                    (id, key, parent_id, name, kind, source_count, child_count, language)
                VALUES (:id, :key, :parent_id, :name, :kind, :source_count, :child_count, :language)
            """, [
                {
                    **node,
                    "source_count": len(node_source_sets.get(int(node["id"]), set())),
                    "child_count": child_counts.get(int(node["id"]), 0),
                }
                for node in sorted(nodes.values(), key=lambda node: (0 if node["parent_id"] is None else str(node["key"]).count("/") + 1, str(node["key"])))
            ])
            db.executemany("""
                INSERT INTO catalog_placement
                    (id, source_id, node_id, node_name, opml_file, sort_order, title_override, language_override, media_kind_override)
                VALUES (:id, :source_id, :node_id, :node_name, :opml_file, :sort_order, :title_override, :language_override, :media_kind_override)
            """, placements)
            db.executemany("""
                INSERT INTO catalog_source_fts
                    (rowid, title, description, tags, display_host, language, media_kind, path)
                VALUES (:rowid, :title, :description, :tags, :display_host, :language, :media_kind, :path)
            """, [
                {
                    "rowid": source["id"],
                    "title": source["title"],
                    "display_host": source["display_host"] or "",
                    "description": source["description"] or "",
                    "tags": source["tags"] or "",
                    "language": source["language"] or "",
                    "media_kind": source["media_kind"],
                    "path": " ".join(paths_by_source.get(int(source["id"]), [])),
                }
                for source in sources.values()
            ])
            db.execute("PRAGMA optimize")
    finally:
        db.close()

    os.replace(tmp, output)
    return {
        "output": str(output),
        "file_count": file_count,
        "failed_file_count": failed_files,
        "invalid_source_count": invalid_sources,
        "source_count": len(sources),
        "node_count": len(nodes),
        "placement_count": len(placements),
        "duplicate_occurrence_count": len(placements) - len(sources),
        "size_bytes": output.stat().st_size,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Build Feedmine catalog.sqlite from OPML files.")
    parser.add_argument("--feeds-root", type=Path, default=Path("feedmine/Resources/Feeds"))
    parser.add_argument("--output", type=Path, default=Path("feedmine/Resources/FeedEngine/catalog.sqlite"))
    parser.add_argument("--manifest-output", type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    occurrences, file_count, failed_files, invalid_sources = scan_opml(args.feeds_root)
    report = compile_catalog(occurrences, args.output, file_count, failed_files, invalid_sources)

    if args.manifest_output:
        args.manifest_output.parent.mkdir(parents=True, exist_ok=True)
        args.manifest_output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(
            "Built {output}: {source_count} sources, {node_count} nodes, "
            "{placement_count} placements, {duplicate_occurrence_count} duplicate placements".format(**report)
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
