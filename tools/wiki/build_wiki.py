"""Build the GitHub wiki pages from README.md and docs/GUIDE.md.

Usage, from the repository root:

    python3 tools/wiki/build_wiki.py <output_dir>

The README stays the single source of truth: each of its "## " sections
becomes one wiki page (names in PAGE_NAMES), docs/GUIDE.md becomes the
Walkthrough page, and the hand-written pages in tools/wiki/pages/ (Home,
Roadmap and Status) are copied with {{VERSION}} filled in. Links are
rewritten for the wiki:

* "#anchor" links point at the page that now holds that heading;
* relative file links point at the file on GitHub, images at their raw
  URL, so pictures and source links keep working outside the repository.

.github/workflows/wiki.yml runs this on every push to main and pushes
the result to the wiki repository.
"""

import os
import re
import shutil
import sys

REPO = "owzo/CC-Tweaked-Draconic-Manager"
BLOB = f"https://github.com/{REPO}/blob/main/"
RAW = f"https://raw.githubusercontent.com/{REPO}/main/"
HERE = os.path.dirname(os.path.abspath(__file__))

# README "## " heading (prefix match) -> wiki page name. Sections that
# share a page are appended in README order.
PAGE_NAMES = [
    ("Features", "Features"),
    ("Requirements", "Requirements-and-Wiring"),
    ("Installation", "Installation"),
    ("First run", "First-Run"),
    ("Multiple reactors", "Multiple-Reactors"),
    ("Extreme Reactors", "Extreme-and-Bigger-Reactors"),
    ("Energy storage", "Energy-Storage"),
    ("Mekanism", "Mekanism"),
    ("Alarms", "Alarms"),
    ("System page", "System-Page-and-Updates"),
    ("Menus and monitors", "Menus-and-Monitors"),
    ("Controls", "Controls-and-Theme"),
    ("Configuration", "Configuration"),
    ("Compatibility", "Compatibility"),
    ("How the reactor works", "How-the-Reactor-Works"),
    ("Pushing it to the edge", "Pushing-to-the-Edge"),
    ("Operational notes", "Operational-Notes"),
    ("Logs on a real computer", "Logs-and-Remote-Logging"),
    ("Troubleshooting", "Troubleshooting"),
    ("Development", "Development-and-Testing"),
    ("Disclaimer", "Credits-and-License"),
    ("Credits", "Credits-and-License"),
    ("License", "Credits-and-License"),
]

# Sidebar groups (page names; Home and the Walkthrough are always first).
SIDEBAR = [
    ("Getting started", ["Features", "Requirements-and-Wiring", "Installation",
                         "First-Run", "Walkthrough"]),
    ("Using it", ["Menus-and-Monitors", "Controls-and-Theme", "Multiple-Reactors",
                  "Alarms", "System-Page-and-Updates", "Configuration"]),
    ("Mods", ["Extreme-and-Bigger-Reactors", "Mekanism", "Energy-Storage",
              "Compatibility"]),
    ("Reactor know-how", ["How-the-Reactor-Works", "Pushing-to-the-Edge",
                          "Operational-Notes"]),
    ("Operations", ["Logs-and-Remote-Logging", "Troubleshooting"]),
    ("Project", ["Roadmap-and-Status", "Development-and-Testing",
                 "Credits-and-License"]),
]

HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*$")
LINK = re.compile(r"(!?)\[([^\]]*)\]\(([^)\s]+)\)")


def slug(text):
    """GitHub's heading anchor for `text`."""
    text = re.sub(r"`", "", text).strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def page_for(title):
    for prefix, page in PAGE_NAMES:
        if title.startswith(prefix):
            return page
    return re.sub(r"[^\w]+", "-", title).strip("-")


def split_readme(text):
    """Return (intro, {page: [lines]}, {anchor: page}) for README.md."""
    intro, pages, anchors, current = [], {}, {}, None
    in_code = False
    for line in text.splitlines():
        if line.startswith("```"):
            in_code = not in_code
        match = None if in_code else HEADING.match(line)
        if match and len(match.group(1)) == 2:
            current = page_for(match.group(2))
            anchors[slug(match.group(2))] = (current, None)
            if current in pages:        # a further section on a shared page
                pages[current].append("## " + match.group(2))
            else:
                pages[current] = []
            continue
        if match and len(match.group(1)) > 2 and current:
            anchors[slug(match.group(2))] = (current, slug(match.group(2)))
            line = match.group(1)[1:] + " " + match.group(2)   # one level up
        (pages[current] if current else intro).append(line)
    return intro, pages, anchors


# Every page this script writes; links to them are left as wiki links.
WIKI_PAGES = {page for _, page in PAGE_NAMES} | {"Home", "Walkthrough", "Roadmap-and-Status"}


def rewrite_links(text, base_dir, anchors, own_page=None):
    """Rewrite markdown links of a page for the wiki."""

    def fix(match):
        bang, label, target = match.groups()
        if re.match(r"^[a-z]+:", target):
            return match.group(0)
        if target.startswith("#"):
            anchor = target[1:]
            page, sub = anchors.get(anchor, (own_page, anchor))
            if page == own_page:
                return f"{bang}[{label}](#{sub or anchor})"
            return f"{bang}[{label}]({page}{'#' + sub if sub else ''})"
        path, _, frag = target.partition("#")
        if path in WIKI_PAGES:
            return match.group(0)
        full = os.path.normpath(os.path.join(base_dir, path)).replace(os.sep, "/")
        if full == "docs/GUIDE.md":
            return f"{bang}[{label}](Walkthrough{'#' + frag if frag else ''})"
        if full == "README.md":
            page, sub = anchors.get(frag, ("Home", None))
            return f"{bang}[{label}]({page}{'#' + sub if sub else ''})"
        url = (RAW if bang else BLOB) + full + ("#" + frag if frag else "")
        return f"{bang}[{label}]({url})"

    out, in_code = [], False
    for line in text.splitlines():
        if line.startswith("```"):
            in_code = not in_code
        out.append(line if in_code else LINK.sub(fix, line))
    return "\n".join(out).strip() + "\n"


def version():
    with open("main_control.lua", encoding="utf-8") as handle:
        match = re.search(r'local VERSION = "([^"]+)"', handle.read())
    return match.group(1) if match else "?"


def footer():
    return ("_This wiki is generated from the repository's README and docs by "
            "`tools/wiki/build_wiki.py` on every push to `main`: edit those "
            "files, not the wiki pages, or your change will be overwritten._\n")


def build(out_dir):
    if os.path.isdir(out_dir):
        shutil.rmtree(out_dir)
    os.makedirs(out_dir)
    with open("README.md", encoding="utf-8") as handle:
        intro, pages, anchors = split_readme(handle.read())

    written = {}
    for page, lines in pages.items():
        written[page] = rewrite_links("\n".join(lines), ".", anchors, page)

    with open("docs/GUIDE.md", encoding="utf-8") as handle:
        guide = handle.read().split("\n", 1)[1]      # drop the "# " title
    written["Walkthrough"] = rewrite_links(guide, "docs", anchors, "Walkthrough")

    values = {"VERSION": version(),
              "README_INTRO": rewrite_links("\n".join(intro[1:]), ".", anchors, "Home")}
    for name in sorted(os.listdir(os.path.join(HERE, "pages"))):
        with open(os.path.join(HERE, "pages", name), encoding="utf-8") as handle:
            text = handle.read()
        for key, value in values.items():
            text = text.replace("{{" + key + "}}", value.strip())
        written[name[:-3]] = rewrite_links(text, ".", anchors, name[:-3])

    sidebar = ["**[Home](Home)**", ""]
    for group, names in SIDEBAR:
        sidebar.append(f"**{group}**")
        sidebar.extend(f"- [{n.replace('-', ' ')}]({n})" for n in names if n in written)
        sidebar.append("")
    missing = sorted(set(written) - {n for _, g in SIDEBAR for n in g} - {"Home"})
    if missing:
        sidebar.append("**More**")
        sidebar.extend(f"- [{n.replace('-', ' ')}]({n})" for n in missing)
    written["_Sidebar"] = "\n".join(sidebar).strip() + "\n"
    written["_Footer"] = footer()

    for page, text in written.items():
        with open(os.path.join(out_dir, page + ".md"), "w", encoding="utf-8") as handle:
            handle.write(text)
    return sorted(written)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    for name in build(sys.argv[1]):
        print(name)
