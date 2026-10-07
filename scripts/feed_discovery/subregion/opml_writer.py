from __future__ import annotations

import xml.etree.ElementTree as ET
from pathlib import Path

from ..models import Candidate
from ..opml import normalize_url


def read_existing_feeds(opml_path: Path) -> set[str]:
    """Return the set of normalized feed URLs already in the OPML file."""
    if not opml_path.exists():
        return set()
    try:
        tree = ET.parse(str(opml_path))
    except ET.ParseError:
        return set()
    root = tree.getroot()
    body = root.find("body")
    if body is None:
        return set()
    urls: set[str] = set()
    for outline in body.findall(".//outline"):
        xml_url = outline.get("xmlUrl")
        if xml_url:
            urls.add(normalize_url(xml_url))
    return urls


def write_subregion_opml(opml_path: Path, candidates: list[Candidate]) -> int:
    """Write candidates into the sub-region OPML, preserving existing content.

    Feeds already present in the OPML (by normalized URL) and feeds repeated
    inside this batch are skipped. New feeds are grouped by candidate.category
    under <outline text="Category"> elements. Existing category groups are
    preserved; new ones are appended. A malformed existing file is left
    untouched and raises ValueError instead of being replaced by a skeleton.

    Args:
        opml_path: Path to the .opml file (created if missing).
        candidates: List of Candidate objects to add.

    Returns:
        Number of feeds actually written (excluding duplicates).
    """
    existing_urls = read_existing_feeds(opml_path)

    # Parse existing OPML, or create a new one if missing
    try:
        tree = ET.parse(str(opml_path))
    except FileNotFoundError:
        # Create a fresh OPML skeleton
        root = ET.Element("opml")
        root.set("version", "2.0")
        head = ET.SubElement(root, "head")
        ET.SubElement(head, "title").text = "FeedMine Sub-Region Feeds"
        body = ET.SubElement(root, "body")
        # Write the empty skeleton so we can parse it below
        opml_path.parent.mkdir(parents=True, exist_ok=True)
        raw = ET.tostring(root, encoding="unicode")
        opml_path.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n' + raw,
            encoding="utf-8",
        )
        tree = ET.parse(str(opml_path))
    except ET.ParseError as error:
        raise ValueError(
            f"refusing to overwrite malformed OPML {opml_path}: {error}"
        ) from error
    root = tree.getroot()
    body = root.find("body")
    if body is None:
        body = ET.SubElement(root, "body")

    # Index existing category groups by their text attribute
    existing_cats: dict[str, ET.Element] = {}
    for elem in body.findall("outline"):
        text = elem.get("text", "")
        existing_cats[text] = elem

    # Group new candidates by category
    new_by_cat: dict[str, list[Candidate]] = {}
    for c in candidates:
        norm = normalize_url(c.url)
        if norm in existing_urls:
            continue
        # Register the accepted URL so a second candidate with the same feed in
        # this same batch is not written twice.
        existing_urls.add(norm)
        cat = c.category or "Other"
        new_by_cat.setdefault(cat, []).append(c)

    written = 0
    for cat, cands in new_by_cat.items():
        if cat in existing_cats:
            parent = existing_cats[cat]
        else:
            parent = ET.SubElement(body, "outline")
            parent.set("text", cat)

        for c in cands:
            attrs = {
                "title": c.title or "",
                "xmlUrl": c.url,
                "type": "rss",
            }
            if c.genre:
                attrs["category"] = c.genre
            child = ET.SubElement(parent, "outline")
            for k, v in attrs.items():
                child.set(k, v)
            written += 1

    # Pretty-print back to file
    _indent_xml(root)
    raw = ET.tostring(root, encoding="unicode")
    opml_path.write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        + raw.split("?>", 1)[-1].lstrip(),
        encoding="utf-8",
    )
    return written


def _indent_xml(elem: ET.Element, level: int = 0) -> None:
    """Add whitespace indentation to an ElementTree for readability."""
    indent = "\n" + "  " * level
    if len(elem):
        if not elem.text or not elem.text.strip():
            elem.text = indent + "  "
        if not elem.tail or not elem.tail.strip():
            elem.tail = indent
        for sub in elem:
            _indent_xml(sub, level + 1)
        if not elem[-1].tail or not elem[-1].tail.strip():
            elem[-1].tail = indent
    else:
        if level and (not elem.tail or not elem.tail.strip()):
            elem.tail = indent
