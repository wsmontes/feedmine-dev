#!/usr/bin/env python3
"""Merge new curated OPMLs into existing curated OPML tree."""
import xml.etree.ElementTree as ET
from pathlib import Path
import shutil

# Entries of the source tree that are scratch input, never merge output.
SKIPPED_ENTRIES = {'_incoming_librivox', 'opml_manifest.json'}


def _skip_scratch_input(directory, names):
    return {name for name in names if name in SKIPPED_ENTRIES}


def merge_outline(new_el, parent, existing_urls):
    """Append *new_el* (or its feed descendants) to *parent*.

    Returns the number of feed outlines added.  Group outlines are flattened
    into *parent* — that is the historical behaviour of this script — so the
    return value must be accumulated through the recursion.
    """
    xml_url = (new_el.get('xmlUrl') or '').strip()
    if xml_url:
        if xml_url not in existing_urls:
            parent.append(new_el)
            existing_urls.add(xml_url)
            return 1
        return 0
    added = 0
    for child in list(new_el):
        added += merge_outline(child, parent, existing_urls)
    return added


def main():
    existing = Path('feedmine/Resources/Feeds')
    new = Path('build/feed-curation/Feeds')
    merged = Path('build/feed-curation/Feeds-merged')

    # Copy existing to merged, leaving the source tree untouched.
    shutil.copytree(existing, merged, dirs_exist_ok=True, ignore=_skip_scratch_input)

    added_total = 0
    for new_path in sorted(new.rglob('*.opml')):
        rel = new_path.relative_to(new)
        merged_path = merged / rel

        if not merged_path.exists():
            merged_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(new_path, merged_path)
            continue

        new_tree = ET.parse(str(new_path))
        existing_tree = ET.parse(str(merged_path))
        new_body = new_tree.getroot().find('body')
        existing_body = existing_tree.getroot().find('body')
        if new_body is None or existing_body is None:
            continue

        existing_urls = {el.get('xmlUrl', '').strip() for el in existing_tree.getroot().iter('outline') if el.get('xmlUrl')}
        added = 0
        for child in list(new_body):
            added += merge_outline(child, existing_body, existing_urls)

        if added > 0:
            ET.indent(existing_tree.getroot(), space='  ')
            existing_tree.write(str(merged_path), encoding='utf-8', xml_declaration=True)
        added_total += added

    total_files = len(list(merged.rglob('*.opml')))
    total_sources = len({
        el.get('xmlUrl')
        for p in merged.rglob('*.opml')
        for el in ET.parse(str(p)).getroot().iter('outline')
        if el.get('xmlUrl')
    })
    print(f'Merge complete: {added_total} new sources added across {total_files} OPML files, {total_sources} unique sources')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
