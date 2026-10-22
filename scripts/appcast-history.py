#!/usr/bin/env python3
# Tesserae: a disk-space visualizer.
# Copyright (C) 2026 Stephen de la Vega
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.


import pathlib
import sys
import xml.etree.ElementTree as ET
from xml.parsers import expat

NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def parse(data):
    parser = expat.ParserCreate()
    stack, spans = [], []
    start = None
    channel_end = None

    def begin(name, attrs):
        nonlocal start
        stack.append(name)
        if stack == ["rss", "channel", "item"]:
            start = parser.CurrentByteIndex

    def end(name):
        nonlocal channel_end
        if stack == ["rss", "channel", "item"]:
            finish = data.index(b">", parser.CurrentByteIndex) + 1
            spans.append((start, finish))
        if stack == ["rss", "channel"]:
            channel_end = parser.CurrentByteIndex
        stack.pop()

    parser.StartElementHandler, parser.EndElementHandler = begin, end
    parser.StartDoctypeDeclHandler = lambda *args: sys.exit("Appcast DTD refused")
    parser.Parse(data, True)
    tree = ET.fromstring(data)
    if tree.tag != "rss" or len(tree.findall("channel")) != 1:
        sys.exit("Appcast must have exactly one channel")
    items = tree.findall("./channel/item")
    if len(items) != len(spans) or channel_end is None:
        sys.exit("Invalid appcast item structure")
    return tree, items, spans, channel_end


def version(item):
    enclosure = item.find("enclosure")
    return item.findtext(NS + "version") or (enclosure.get(NS + "version") if enclosure is not None else None)


def shape(element):
    # XML serializers can change indentation and namespace prefixes. All actual
    # content, attributes, ordering and non-whitespace text must remain intact.
    return (element.tag, sorted(element.attrib.items()),
            element.text if element.text and element.text.strip() else "",
            tuple((shape(child), child.tail if child.tail and child.tail.strip() else "") for child in element))


def process(mode, baseline, candidate, build):
    data = pathlib.Path(candidate).read_bytes()
    tree, items, spans, _ = parse(data)
    current = [i for i, item in enumerate(items) if version(item) == build]
    if len(current) != 1:
        sys.exit("Appcast must contain exactly one item for VERSION")
    index = current[0]
    item = items[index]
    # Sparkle also accepts legacy literal qualified names outside its URI.
    # Reject ambiguous release controls rather than letting a second client-
    # visible enclosure or delta hide behind an unrelated namespace.
    rss_controls = {"enclosure", "url", "length", "description"}
    sparkle_controls = {"version", "shortVersionString", "minimumSystemVersion", "edSignature", "format"}
    enclosures = []
    for element in item.iter():
        local = element.tag.rsplit("}", 1)[-1]
        if local == "enclosure":
            enclosures.append(element)
        for name in [element.tag, *element.attrib]:
            local = name.rsplit("}", 1)[-1]
            if local in {"deltas", "deltaFrom"}:
                sys.exit("Appcast new item must have one enclosure and no deltas")
            if ((local in rss_controls and name != local)
                    or (local in sparkle_controls and name != NS + local)):
                sys.exit("Appcast release control has an unexpected namespace")
    if len(enclosures) != 1 or item.find("enclosure") is None:
        sys.exit("Appcast new item must have one enclosure and no deltas")
    old = pathlib.Path(baseline).read_bytes()
    if not old:
        if len(items) != 1:
            sys.exit("Appcast has unexpected items")
        return
    old_tree, old_items, old_spans, insert = parse(old)
    if data == old:
        return  # Idempotent verification after an interrupted publish.
    if any(version(entry) == build for entry in old_items):
        sys.exit("Appcast changes an already published version")
    remaining = items[:index] + items[index + 1:]
    if len(remaining) != len(old_items):
        sys.exit("Appcast has extra or missing historical items")
    if mode == "merge":
        if [shape(e) for e in remaining] != [shape(e) for e in old_items]:
            sys.exit("Appcast altered published history")
    else:
        historical = [data[a:b] for i, (a, b) in enumerate(spans) if i != index]
        if historical != [old[a:b] for a, b in old_spans]:
            sys.exit("Appcast historical item bytes changed")
    tree.find("channel").remove(item)
    if shape(tree) != shape(old_tree):
        sys.exit("Appcast changed published metadata")
    if mode == "check":
        a, b = spans[index]
        if data[:a] + data[b:] != old:
            sys.exit("Appcast changed bytes outside the new item")
    if mode == "merge":
        # Keep the entire published document byte-for-byte and insert only the
        # new signed item, with its namespace declarations made self-contained.
        item.tail = None
        new_item = ET.tostring(item, encoding="utf-8")
        pathlib.Path(candidate).write_bytes(old[:insert] + new_item + old[insert:])


if __name__ == "__main__":
    process(*sys.argv[1:])
