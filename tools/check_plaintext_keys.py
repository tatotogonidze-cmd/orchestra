#!/usr/bin/env python3
"""Pre-commit scan for accidentally committed plaintext credentials.

Blocks the commit when any staged file contains a pattern that looks like a
real API key. Designed to be called from .githooks/pre-commit.

Exit codes:
  0 — no suspicious content found
  1 — at least one match found; commit should be rejected

Patterns covered (best-effort, not exhaustive):
  - OpenAI / Anthropic / generic ``sk-`` keys
  - Google / Firebase ``AIza...`` keys
  - AWS ``AKIA...`` access key ids
  - Tripo / ElevenLabs / Replicate style provider-prefixed tokens
  - Obvious variable assignments like ``api_key = "..."``

False positives can be suppressed by adding the comment::

    # allow-plaintext-key

on the same line. Use sparingly, and only for fixtures that are clearly not
secrets.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ALLOW_MARKER = "allow-plaintext-key"

# Paths we never scan (binary, vendored, tests that intentionally use fake keys).
SKIP_DIRS = {".git", ".godot", "addons", "node_modules", "__pycache__"}
SKIP_SUFFIXES = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg",
    ".mp3", ".wav", ".ogg",
    ".glb", ".gltf", ".fbx", ".obj",
    ".enc",  # our own encrypted credential store
    ".pck", ".exe", ".dll", ".so", ".dylib",
    ".ico",
}

PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("openai/anthropic-style key",
     re.compile(r"sk-[A-Za-z0-9_\-]{20,}")),
    ("google-style key",
     re.compile(r"AIza[0-9A-Za-z_\-]{30,}")),
    ("aws access key id",
     re.compile(r"AKIA[0-9A-Z]{16}")),
    ("replicate-style token",
     re.compile(r"r8_[A-Za-z0-9]{30,}")),
    ("elevenlabs-style token",
     re.compile(r"xi-api-key[:=]\s*['\"]?[A-Za-z0-9]{24,}")),
    ("tripo-style token",
     re.compile(r"tripo[_\-][A-Za-z0-9]{20,}")),
    ("obvious assignment",
     re.compile(r"""(?ix)
        \b(api[_-]?key|secret|token|password)\b
        \s*[:=]\s*
        ['"][^'"\s]{16,}['"]
     """)),
]


def _staged_files() -> list[Path]:
    """Return the list of staged text files to scan."""
    try:
        out = subprocess.check_output(
            ["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR"],
            text=True,
        )
    except subprocess.CalledProcessError:
        return []
    files: list[Path] = []
    for line in out.splitlines():
        p = Path(line.strip())
        if not line.strip():
            continue
        if any(part in SKIP_DIRS for part in p.parts):
            continue
        if p.suffix.lower() in SKIP_SUFFIXES:
            continue
        if not p.exists():  # staged delete
            continue
        files.append(p)
    return files


def _scan_file(path: Path) -> list[tuple[int, str, str]]:
    """Return list of (line_no, pattern_name, matched_text) hits."""
    hits: list[tuple[int, str, str]] = []
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return hits
    for lineno, line in enumerate(text.splitlines(), start=1):
        if ALLOW_MARKER in line:
            continue
        for name, pat in PATTERNS:
            m = pat.search(line)
            if m:
                snippet = m.group(0)
                if len(snippet) > 60:
                    snippet = snippet[:57] + "..."
                hits.append((lineno, name, snippet))
    return hits


def main() -> int:
    files = _staged_files()
    if not files:
        return 0

    any_hits = False
    for f in files:
        hits = _scan_file(f)
        if not hits:
            continue
        any_hits = True
        print(f"\n  {f}:")
        for lineno, name, snippet in hits:
            print(f"    line {lineno}: {name}  ->  {snippet}")

    if any_hits:
        print(
            "\nCommit blocked: possible plaintext credentials found.\n"
            "  - If this is a real secret, remove it and use the encrypted "
            "CredentialStore (scripts/credential_store.gd).\n"
            f"  - If this is a false positive, add the marker "
            f"'{ALLOW_MARKER}' on the same line.\n"
        )
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
