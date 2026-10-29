#!/usr/bin/env python3
"""Replaces the server-generated ids left in recorded fixtures with placeholders.

The recorders already replace the Account's user id, the Chats they create, tokens, emails and the host. Every
other id the server or the model provider generated (message, file, task and skill version ids, provider
`msg_…`/`toolu_…` ids) still names an object on the recording deployment, so this pass swaps each one for a
placeholder, consistently across all fixtures and the tests that quote them:

  uuid          -> 00000000-0000-4000-8000-0000000eNNNN
  msg_<random>  -> msg_000000000000000000000NNN   (toolu_ alike)

Ids are numbered by first appearance (files in name order), so re-running is a no-op and a re-recording maps the
same scenario to the same placeholders. Run it after scripts/record-fixtures or scripts/record-stream-fixtures:

  scripts/fixtures/scrub_ids.py            # rewrite in place
  scripts/fixtures/scrub_ids.py --check    # exit 1 if a real-looking id is left (used by the export gate too)
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "Modules/Tests/Fixtures"
# Tests quote fixture ids; they get the same replacement.
TEST_DIRS = [ROOT / "Modules/Tests", ROOT / "App/Tests", ROOT / "App/UITests"]

UUID = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")
PROVIDER_ID = re.compile(r"\b(msg|toolu)_([A-Za-z0-9]{16,})\b")
# Placeholders and the RFC 6455 WebSocket GUID.
ALLOWED_UUID = re.compile(r"^(00000000-|258eafa5-e914-47da-95ca-c5ab0dc85b11$)", re.I)


def is_placeholder_provider_id(match: re.Match) -> bool:
    return match.group(2).isdigit() and match.group(2).lstrip("0") != "" and len(match.group(2).lstrip("0")) <= 4


def fixture_files():
    return sorted(p for p in FIXTURES.rglob("*") if p.is_file() and p.suffix in {".json", ".jsonl", ".txt"})


def real_ids(text: str):
    for m in UUID.finditer(text):
        if not ALLOWED_UUID.match(m.group(0)):
            yield m.group(0).lower()
    for m in PROVIDER_ID.finditer(text):
        if not is_placeholder_provider_id(m):
            yield m.group(0)


def leftovers(paths) -> list[str]:
    found = []
    for path in paths:
        text = path.read_text(encoding="utf-8")
        for number, line in enumerate(text.splitlines(), 1):
            if next(real_ids(line), None):
                found.append(f"{path}:{number}")
    return found


def main():
    if "--check" in sys.argv:
        found = leftovers(fixture_files())
        if found:
            print("scrub_ids: real-looking ids left (run scripts/fixtures/scrub_ids.py):\n" + "\n".join(found))
        sys.exit(1 if found else 0)

    mapping: dict[str, str] = {}
    counters = {"uuid": 0, "msg": 0, "toolu": 0}
    for path in fixture_files():
        for rid in real_ids(path.read_text(encoding="utf-8")):
            if rid in mapping:
                continue
            if "_" in rid:
                prefix = rid.split("_", 1)[0]
                counters[prefix] += 1
                mapping[rid] = f"{prefix}_{counters[prefix]:024d}"
            else:
                counters["uuid"] += 1
                mapping[rid] = f"00000000-0000-4000-8000-0000000e{counters['uuid']:04d}"
    if counters["uuid"] > 9999:
        sys.exit("scrub_ids: more than 9999 ids; widen the placeholder range")
    if not mapping:
        print("scrub_ids: nothing to replace")
        return

    files = fixture_files() + sorted({p for d in TEST_DIRS if d.exists() for p in d.rglob("*.swift")})
    changed = 0
    for path in files:
        text = path.read_text(encoding="utf-8")
        new = UUID.sub(lambda m: mapping.get(m.group(0).lower(), m.group(0)), text)
        new = PROVIDER_ID.sub(lambda m: mapping.get(m.group(0), m.group(0)), new)
        if new != text:
            path.write_text(new, encoding="utf-8")
            changed += 1
    print(f"scrub_ids: {len(mapping)} ids replaced in {changed} files "
          f"({counters['uuid']} uuids, {counters['msg']} msg_, {counters['toolu']} toolu_)")


if __name__ == "__main__":
    main()
