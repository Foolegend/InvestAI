"""Generate loadable stubs for source files missing from the snapshot.

The published artifact was bundled, so a handful of modules (mostly
feature-gated tools and refactored-out type modules) are absent from the
sourcemap snapshot. Bun resolves `require()`/static imports at load time even
when the branch that uses them never runs, so every referenced path must
exist before the CLI can start.

This script scans `src/` for value imports and requires whose target does not
exist, then writes a clearly-marked stub:

  - `.js` targets get a universal callable Proxy exported under every name
    the importers reference.
  - `.md` / `.txt` targets get a short placeholder (Bun imports these as text).

Existing files are never overwritten. Re-run after adding real modules.
"""

from __future__ import annotations

import os
import pathlib
import re
from collections import defaultdict

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src"

IMPORT_NAMED = re.compile(
    r"import\s+(type\s+)?\{([^}]*)\}\s+from\s+['\"](\.{1,2}/[^'\"]+)['\"]", re.S
)
IMPORT_DEFAULT = re.compile(
    r"import\s+([^;{}]*?)\s+from\s+['\"](\.{1,2}/[^'\"]+)['\"]", re.S
)
REQUIRE_DESTRUCTURE = re.compile(
    r"const\s*\{([^}]*)\}\s*=\s*require\s*\(\s*['\"](\.{1,2}/[^'\"]+)['\"]\s*\)", re.S
)
REQUIRE_MEMBER = re.compile(
    r"require\s*\(\s*['\"](\.{1,2}/[^'\"]+)['\"]\s*\)\s*\.\s*([A-Za-z_$][\w$]*)"
)
REQUIRE_PLAIN = re.compile(r"\brequire\s*\(\s*['\"](\.{1,2}/[^'\"]+)['\"]\s*\)")
DYNAMIC_IMPORT = re.compile(r"\bimport\s*\(\s*['\"](\.{1,2}/[^'\"]+)['\"]\s*\)")
SIDE_EFFECT_IMPORT = re.compile(r"(?m)^\s*import\s+['\"](\.{1,2}/[^'\"]+)['\"]")
EXPORT_FROM = re.compile(
    r"export\s+(type\s+)?(\*|\{([^}]*)\})\s+from\s+['\"](\.{1,2}/[^'\"]+)['\"]", re.S
)


def resolve(base: pathlib.Path) -> pathlib.Path | None:
    candidates = [base]
    s = str(base)
    if s.endswith(".js"):
        candidates += [pathlib.Path(s[:-3] + ".ts"), pathlib.Path(s[:-3] + ".tsx")]
    candidates += [base.with_suffix(".ts"), base.with_suffix(".tsx")]
    candidates += [base / "index.ts", base / "index.tsx", base / "index.js"]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return None


def declared_path(base: pathlib.Path) -> pathlib.Path | None:
    """Return the path that importers expect, or None if it resolves."""
    if resolve(base):
        return None
    s = str(base)
    if base.suffix in {".md", ".txt", ".json", ".wasm", ".node"} or base.name.endswith(
        ".d.ts"
    ):
        return base
    if s.endswith(".js"):
        return base
    if base.suffix == "":
        return base.with_suffix(".js")
    return base


def split_names(body: str) -> list[str]:
    names = []
    for item in body.split(","):
        item = item.strip()
        if not item or item.startswith("type "):
            continue
        item = item.split(" as ")[0].strip()
        if re.fullmatch(r"[A-Za-z_$][\w$]*", item) and item != "default":
            names.append(item)
    return names


def collect() -> tuple[dict[pathlib.Path, set[str]], dict[pathlib.Path, bool]]:
    exports: dict[pathlib.Path, set[str]] = defaultdict(set)
    wants_default: dict[pathlib.Path, bool] = defaultdict(bool)

    files = [p for p in SRC.rglob("*") if p.suffix in {".ts", ".tsx", ".js"}]
    for path in files:
        text = path.read_text(encoding="utf-8", errors="ignore")

        for m in IMPORT_NAMED.finditer(text):
            is_type, body, spec = m.group(1), m.group(2), m.group(3)
            items = [i.strip() for i in body.split(",") if i.strip()]
            if is_type or (items and all(i.startswith("type ") for i in items)):
                continue
            target = declared_path((path.parent / spec).resolve())
            if target:
                exports[target].update(split_names(body))

        for m in IMPORT_DEFAULT.finditer(text):
            clause, spec = m.group(1).strip(), m.group(2)
            if clause.startswith("type "):
                continue
            target = declared_path((path.parent / spec).resolve())
            if target:
                if clause.startswith("{"):
                    exports[target].update(split_names(clause))
                else:
                    wants_default[target] = True
                    if clause.startswith("* as "):
                        pass

        for m in REQUIRE_DESTRUCTURE.finditer(text):
            target = declared_path((path.parent / m.group(2)).resolve())
            if target:
                exports[target].update(split_names(m.group(1)))

        for m in REQUIRE_MEMBER.finditer(text):
            target = declared_path((path.parent / m.group(1)).resolve())
            if target:
                exports[target].add(m.group(2))

        for m in REQUIRE_PLAIN.finditer(text):
            target = declared_path((path.parent / m.group(1)).resolve())
            if target:
                wants_default[target] = True

        for m in DYNAMIC_IMPORT.finditer(text):
            target = declared_path((path.parent / m.group(1)).resolve())
            if target:
                wants_default[target] = True

        for m in SIDE_EFFECT_IMPORT.finditer(text):
            target = declared_path((path.parent / m.group(1)).resolve())
            if target:
                exports.setdefault(target, set())

        for m in EXPORT_FROM.finditer(text):
            is_type, star, body, spec = m.group(1), m.group(2), m.group(3), m.group(4)
            if is_type:
                continue
            target = declared_path((path.parent / spec).resolve())
            if not target:
                continue
            # Touch the entry so an empty module is emitted for `export *`.
            exports.setdefault(target, set())
            if body and not star:
                exports[target].update(split_names(body))

    return exports, wants_default


STUB_HEADER = """// Reconstruction stub: this module is absent from the sourcemap snapshot.
// Generated by scripts/generate-missing-stubs.py. Replace with a real
// implementation when the feature is needed.
"""

PROXY_BODY = """const stub = new Proxy(function () {}, {
  get(_target, prop) {
    if (prop === Symbol.toPrimitive) return () => ''
    if (prop === 'then') return undefined
    if (prop === Symbol.iterator) return function* () {}
    if (prop === 'toString' || prop === 'valueOf') return () => ''
    return stub
  },
  apply() { return stub },
  construct() { return stub },
})
"""


def write_stub(target: pathlib.Path, names: set[str], default: bool) -> bool:
    if target.exists():
        return False
    target.parent.mkdir(parents=True, exist_ok=True)

    if target.suffix in {".md", ".txt"} or target.name.endswith(".d.ts"):
        target.write_text(
            "// Placeholder: absent from the source snapshot.\n"
            if target.name.endswith(".d.ts")
            else "Placeholder content: this file is absent from the source snapshot.\n",
            encoding="utf-8",
        )
        return True

    if target.suffix != ".js":
        return False

    lines = [STUB_HEADER, PROXY_BODY]
    for name in sorted(names):
        lines.append(f"export const {name} = stub")
    if default or not names:
        lines.append("export default stub")
    target.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return True


def main() -> None:
    exports, wants_default = collect()
    created = 0
    for target in sorted(set(exports) | set(wants_default)):
        if write_stub(target, exports.get(target, set()), wants_default.get(target, False)):
            created += 1
    print(f"created {created} stub file(s)")


if __name__ == "__main__":
    main()
