#!/usr/bin/env python3
"""Repository hygiene checks that do not need MATLAB.

Mirrors, in a much weaker form, what the MATLAB suite enforces:
  * every tracked JSON file parses;
  * text files are UTF-8 without BOM and use LF line endings;
  * the banned-claim lexicon appears nowhere in the deliverable text;
  * relative Markdown links in README.md / README.en.md resolve.
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SKIP_DIRS = {"runs", ".git", "slprj"}
TEXT_SUFFIXES = {".m", ".md", ".json", ".csv", ".txt", ".log", ".cff", ".yml", ".yaml"}

failures: list[str] = []


def walk() -> list[pathlib.Path]:
    out: list[pathlib.Path] = []
    for p in ROOT.rglob("*"):
        if p.is_dir():
            continue
        if any(part in SKIP_DIRS for part in p.relative_to(ROOT).parts):
            continue
        out.append(p)
    return sorted(out)


def check_json(files: list[pathlib.Path]) -> None:
    for f in files:
        if f.suffix.lower() != ".json":
            continue
        try:
            json.loads(f.read_text(encoding="utf-8"))
        except Exception as exc:  # noqa: BLE001 - report every parse failure
            failures.append(f"{f.relative_to(ROOT)}: invalid JSON ({exc})")


def check_encoding(files: list[pathlib.Path]) -> None:
    for f in files:
        if f.suffix.lower() not in TEXT_SUFFIXES:
            continue
        raw = f.read_bytes()
        rel = f.relative_to(ROOT)
        if raw[:3] == b"\xef\xbb\xbf":
            failures.append(f"{rel}: starts with a UTF-8 BOM")
            continue
        try:
            raw.decode("utf-8")
        except UnicodeDecodeError:
            # Evidence logs redirected through a console are legitimately not UTF-8;
            # they are declared as such in docs/test_evidence/.
            if not str(rel).startswith("docs/test_evidence/"):
                failures.append(f"{rel}: not valid UTF-8")
            continue
        if b"\r\n" in raw:
            failures.append(f"{rel}: uses CRLF line endings (policy is LF)")


def check_banned_claims(files: list[pathlib.Path]) -> None:
    lexicon = json.loads((ROOT / "config" / "banned_claims.json").read_text(encoding="utf-8"))
    claims = [c for c in lexicon["banned_claims"] if c.strip()]
    exempt = set(lexicon.get("self_exemption", []))
    targets = [ROOT / "README.md", ROOT / "README.en.md"]
    targets += sorted((ROOT / "docs").glob("*.md"))
    targets += sorted((ROOT / "app").rglob("*.m"))
    targets += sorted((ROOT / "src" / "+tepc" / "+report").rglob("*.m"))
    for f in targets:
        if not f.is_file():
            continue
        rel = f.relative_to(ROOT).as_posix()
        if rel in exempt:
            continue
        text = f.read_text(encoding="utf-8")
        for claim in claims:
            if claim in text:
                failures.append(f"{rel}: contains banned claim {claim!r}")


def check_markdown_links(files: list[pathlib.Path]) -> None:
    for name in ("README.md", "README.en.md", "CONTRIBUTING.md"):
        f = ROOT / name
        if not f.is_file():
            continue
        text = f.read_text(encoding="utf-8")
        for target in re.findall(r"\]\(([^)\s]+)\)", text):
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            local = target.split("#", 1)[0]
            if local and not (ROOT / local).exists():
                failures.append(f"{name}: broken relative link -> {target}")


def main() -> int:
    files = walk()
    check_json(files)
    check_encoding(files)
    check_banned_claims(files)
    check_markdown_links(files)
    if failures:
        print("repository checks FAILED:")
        for item in failures:
            print(f"  - {item}")
        return 1
    print(f"repository checks passed ({len(files)} files scanned)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
