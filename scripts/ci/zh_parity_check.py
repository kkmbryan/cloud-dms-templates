#!/usr/bin/env python3
"""Structural parity check between English and Simplified Chinese Markdown docs.

Every ``*.zh-CN.md`` file in the repository is paired with its English sibling
(``README.zh-CN.md`` -> ``README.md``) and both are compared structurally:

* heading count and level sequence
* fenced code block count, Mermaid block count
* non-Mermaid code blocks are byte-identical (commands must not be translated)
* Mermaid skeleton: identical after removing quoted labels and edge labels
* table rows and the column count of every table row
* GitHub alerts (``> [!NOTE]`` ...) count and type sequence
* relative link targets: identical after mapping ``X.zh-CN.md`` -> ``X.md``;
  every relative target must exist; the zh-CN doc should link to the zh-CN
  sibling of a linked doc when one exists
* external (http/https/mailto) link targets identical

Usage: python3 scripts/ci/zh_parity_check.py [--root DIR] [--verbose]
Exit code 0 when all pairs match, 1 otherwise.
"""

import argparse
import os
import re
import subprocess
import sys

ZH_SUFFIX = ".zh-CN.md"
SKIP_DIRS = {".git", ".terraform", "node_modules", ".venv", "venv"}

FENCE_RE = re.compile(r"^(\s*)(`{3,}|~{3,})\s*([^`\s]*)")
HEADING_RE = re.compile(r"^(#{1,6})\s+\S")
ALERT_RE = re.compile(r"^\s*>\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]", re.I)
INLINE_CODE_RE = re.compile(r"(`+)(?:(?!\1).)+?\1")
# [text](target "title") and ![alt](target); target without spaces.
LINK_RE = re.compile(r"!?\[(?:[^\[\]]|\[[^\]]*\])*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
REF_DEF_RE = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*<?(\S+?)>?(?:\s+.*)?$")
EXTERNAL_RE = re.compile(r"^(?:[a-z][a-z0-9+.-]*:|//)", re.I)


def repo_root(start):
    try:
        out = subprocess.run(
            ["git", "-C", start, "rev-parse", "--show-toplevel"],
            check=True, capture_output=True, text=True,
        )
        return out.stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return os.path.abspath(start)


def discover(root):
    """Return repo-relative paths of all *.zh-CN.md files (git-tracked if possible)."""
    try:
        out = subprocess.run(
            ["git", "-C", root, "ls-files", "--cached", "--others",
             "--exclude-standard", "*" + ZH_SUFFIX],
            check=True, capture_output=True, text=True,
        )
        files = [f for f in out.stdout.splitlines() if f.endswith(ZH_SUFFIX)]
        if files:
            return sorted(set(files))
    except (OSError, subprocess.CalledProcessError):
        pass
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if name.endswith(ZH_SUFFIX):
                found.append(os.path.relpath(os.path.join(dirpath, name), root))
    return sorted(found)


def analyze(path):
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    doc = {
        "headings": [], "fences": 0, "mermaid": 0, "table_cols": [],
        "alerts": [], "blocks": [], "links": [],
    }
    in_code, fence, lang, cur = False, "", "", []
    for ln in lines:
        m = FENCE_RE.match(ln)
        if in_code:
            if m and m.group(2)[0] == fence[0] and len(m.group(2)) >= len(fence) \
                    and not m.group(3):
                cur.append(ln.strip())
                doc["blocks"].append((lang, "\n".join(cur)))
                doc["fences"] += 1
                in_code = False
            else:
                cur.append(ln)
            continue
        if m:
            in_code, fence, lang = True, m.group(2), m.group(3).lower()
            cur = [ln.strip()]
            doc["fences"] += 1
            if lang == "mermaid":
                doc["mermaid"] += 1
            continue
        s = ln.strip()
        h = HEADING_RE.match(ln)
        if h:
            doc["headings"].append(len(h.group(1)))
        if s.startswith("|"):
            body = s.replace("\\|", "")
            body = INLINE_CODE_RE.sub(lambda mm: mm.group(0).replace("|", ""), body)
            doc["table_cols"].append(body.count("|"))
        a = ALERT_RE.match(ln)
        if a:
            doc["alerts"].append(a.group(1).upper())
        text = INLINE_CODE_RE.sub("", ln)
        doc["links"] += LINK_RE.findall(text)
        r = REF_DEF_RE.match(text)
        if r:
            doc["links"].append(r.group(1))
    if in_code:
        doc["blocks"].append((lang, "\n".join(cur)))
        doc["unclosed"] = True
    return doc


def mermaid_skeleton(block):
    t = re.sub(r'"[^"]*"', '""', block)
    t = re.sub(r"\|[^|\n]*\|", "||", t)
    t = re.sub(r"%%.*", "", t)
    # sequenceDiagram messages / notes: keep the arrow, drop the text after ':'
    t = re.sub(r"^(\s*[^:\n]*(?:->>|-->>|->|-->|-x|--x|-\)|--\)|Note [^:\n]*)):.*$",
               r"\1:", t, flags=re.M)
    return "\n".join(x.rstrip() for x in t.splitlines() if x.strip())


def split_target(target):
    path, _, _anchor = target.partition("#")
    path = path.split("?", 1)[0]
    return path


def to_en_target(target):
    path = split_target(target)
    if path.endswith(ZH_SUFFIX):
        return path[: -len(ZH_SUFFIX)] + ".md"
    return path


def check_pair(root, zh_rel):
    en_rel = zh_rel[: -len(ZH_SUFFIX)] + ".md"
    errors, info = [], []
    en_path, zh_path = os.path.join(root, en_rel), os.path.join(root, zh_rel)
    if not os.path.isfile(en_path):
        return en_rel, [f"missing English sibling {en_rel}"], info
    a, b = analyze(en_path), analyze(zh_path)

    for name, d in ((en_rel, a), (zh_rel, b)):
        if d.get("unclosed"):
            errors.append(f"unclosed code fence in {name}")

    if a["headings"] != b["headings"]:
        errors.append(f"headings: en={len(a['headings'])} {a['headings']} zh={len(b['headings'])} {b['headings']}")
    for key in ("fences", "mermaid"):
        if a[key] != b[key]:
            errors.append(f"{key}: en={a[key]} zh={b[key]}")
    if len(a["table_cols"]) != len(b["table_cols"]):
        errors.append(f"table rows: en={len(a['table_cols'])} zh={len(b['table_cols'])}")
    elif a["table_cols"] != b["table_cols"]:
        diff = [i + 1 for i, (x, y) in enumerate(zip(a["table_cols"], b["table_cols"])) if x != y]
        errors.append(f"table columns differ in table rows {diff[:10]}")
    if a["alerts"] != b["alerts"]:
        errors.append(f"alerts: en={a['alerts']} zh={b['alerts']}")

    code_a = [blk for lang, blk in a["blocks"] if lang != "mermaid"]
    code_b = [blk for lang, blk in b["blocks"] if lang != "mermaid"]
    if len(code_a) != len(code_b):
        errors.append(f"non-Mermaid code blocks: en={len(code_a)} zh={len(code_b)}")
    else:
        for i, (x, y) in enumerate(zip(code_a, code_b)):
            if x != y:
                first = x.splitlines()[0] if x else ""
                errors.append(f"code block #{i + 1} differs ({first[:60]!r})")

    mer_a = [mermaid_skeleton(blk) for lang, blk in a["blocks"] if lang == "mermaid"]
    mer_b = [mermaid_skeleton(blk) for lang, blk in b["blocks"] if lang == "mermaid"]
    for i, (x, y) in enumerate(zip(mer_a, mer_b)):
        if x != y:
            errors.append(f"Mermaid block #{i + 1} skeleton differs")

    # Links. A link from a doc to its own counterpart (EN -> zh-CN sibling,
    # zh-CN -> EN sibling) is the language switcher and is compared as such.
    def is_switch(rel, target, zh):
        path = split_target(target)
        if not path or EXTERNAL_RE.match(target):
            return False
        resolved = os.path.normpath(os.path.join(os.path.dirname(rel), path))
        return resolved == os.path.normpath(en_rel if zh else zh_rel)

    def norm(rel, links, zh):
        out = []
        for t in links:
            if EXTERNAL_RE.match(t):
                out.append(t)
            elif t.startswith("#"):
                continue  # in-page anchors change with translated headings
            elif is_switch(rel, t, zh):
                out.append("<language switcher>")
            else:
                out.append(to_en_target(t) if zh else split_target(t))
        return out

    la, lb = norm(en_rel, a["links"], False), norm(zh_rel, b["links"], True)
    if la != lb:
        only_en = [x for x in la if x not in lb]
        only_zh = [x for x in lb if x not in la]
        if only_en or only_zh:
            errors.append(f"link targets differ: only en={only_en} only zh={only_zh}")
        else:
            errors.append("link targets are the same set but in a different order or count")

    for rel, d, zh in ((en_rel, a, False), (zh_rel, b, True)):
        base = os.path.dirname(os.path.join(root, rel))
        for t in d["links"]:
            if EXTERNAL_RE.match(t) or t.startswith("#"):
                continue
            path = split_target(t)
            if not path:
                continue
            target = os.path.normpath(os.path.join(base, path))
            if not os.path.exists(target):
                errors.append(f"broken link in {rel}: {t}")
                continue
            if is_switch(rel, t, zh):
                continue
            if zh and path.endswith(".md") and not path.endswith(ZH_SUFFIX):
                zh_sibling = target[: -len(".md")] + ZH_SUFFIX
                if os.path.exists(zh_sibling):
                    errors.append(f"{rel} links to {t}; use its zh-CN sibling {os.path.basename(zh_sibling)}")
            if not zh and path.endswith(ZH_SUFFIX):
                errors.append(f"{rel} (English) links to a zh-CN doc: {t}")

    info.append(
        f"headings={len(a['headings'])} fences={a['fences']} mermaid={a['mermaid']} "
        f"table_rows={len(a['table_cols'])} alerts={len(a['alerts'])} "
        f"code_blocks={len(code_a)} links={len(la)}"
    )
    return en_rel, errors, info


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=None, help="repository root (default: git top level of cwd)")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()
    root = os.path.abspath(args.root) if args.root else repo_root(os.getcwd())

    pairs = discover(root)
    if not pairs:
        print("No *.zh-CN.md files found; nothing to check.")
        return 0

    failed = 0
    for zh_rel in pairs:
        en_rel, errors, info = check_pair(root, zh_rel)
        status = "FAIL" if errors else "OK"
        print(f"[{status}] {en_rel} <-> {zh_rel}")
        if args.verbose or errors:
            for line in info:
                print(f"    {line}")
        for e in errors:
            print(f"    - {e}")
        failed += bool(errors)

    print(f"\n{len(pairs) - failed}/{len(pairs)} pairs in parity.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
