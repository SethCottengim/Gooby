#!/usr/bin/env python3
"""CI check for the static site in public/ (pitch deck, video page).

For every .html file under public/:
- every local file it references (src, href, poster) exists, relative to that page;
- no element id is used twice.
Remote URLs, in-page anchors (#...), data:, mailto: and javascript: links are skipped.

Run with:  python3 ci/check_site.py [public]
Exits 1 and lists every problem if anything is wrong.
"""
import os
import sys
from html.parser import HTMLParser
from urllib.parse import unquote, urlparse

SKIP_SCHEMES = {"http", "https", "data", "mailto", "javascript", "tel"}
LINK_ATTRS = {"src", "href", "poster"}


class PageScanner(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.refs = []   # (line, attr, value)
        self.ids = {}    # id -> first line
        self.duplicates = []

    def handle_starttag(self, tag, attrs):
        line = self.getpos()[0]
        for name, value in attrs:
            if value is None:
                continue
            if name == "id":
                if value in self.ids:
                    self.duplicates.append((line, value, self.ids[value]))
                else:
                    self.ids[value] = line
            elif name in LINK_ATTRS:
                self.refs.append((line, name, value))

    handle_startendtag = handle_starttag


def local_target(page, value):
    """The local file a reference points to, or None if it isn't a local file."""
    value = value.strip()
    if not value or value.startswith("#"):
        return None
    parsed = urlparse(value)
    if parsed.scheme in SKIP_SCHEMES or parsed.netloc:
        return None
    path = unquote(parsed.path)
    if not path:
        return None
    base = os.path.dirname(page)
    target = os.path.normpath(os.path.join(base, path.lstrip("/")) if not path.startswith("/") else path)
    if path.endswith("/"):
        target = os.path.join(target, "index.html")
    return target


def check(root):
    problems, pages = [], 0
    for folder, _, files in os.walk(root):
        for name in sorted(files):
            if not name.endswith(".html"):
                continue
            page = os.path.join(folder, name)
            pages += 1
            scanner = PageScanner()
            with open(page, encoding="utf-8") as f:
                scanner.feed(f.read())
            for line, attr, value in scanner.refs:
                target = local_target(page, value)
                if target and not os.path.exists(target):
                    problems.append(f"{page}:{line}: {attr}=\"{value}\" -> missing {target}")
            for line, value, first in scanner.duplicates:
                problems.append(f"{page}:{line}: id \"{value}\" already used on line {first}")
    return pages, problems


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "public"
    pages, problems = check(root)
    if pages == 0:
        print(f"no .html files under {root}/")
        return 1
    for p in problems:
        print(p)
    print(f"checked {pages} page(s): {'OK' if not problems else f'{len(problems)} problem(s)'}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
