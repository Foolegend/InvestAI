"""Rewrite `from 'bun:bundle'` imports to the runtime compat module.

Bun only exposes `bun:bundle` inside `bun build`, and its `feature()` calls
must be static. To run the snapshot directly we map the import to
`cc-feature`, a runtime feature-flag lookup (see compat/feature.ts and the
`paths` entry in tsconfig.json).

Idempotent: files already rewritten are left alone.
"""

from __future__ import annotations

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
PATTERN = re.compile(r"""(from\s+)(['"])bun:bundle\2""")


def main() -> None:
    changed = 0
    for path in SRC.rglob("*"):
        if path.suffix not in {".ts", ".tsx", ".js"}:
            continue
        text = path.read_text(encoding="utf-8")
        new = PATTERN.sub(r"\1'cc-feature'", text)
        if new != text:
            path.write_text(new, encoding="utf-8")
            changed += 1
    print(f"rewrote {changed} file(s)")


if __name__ == "__main__":
    main()
