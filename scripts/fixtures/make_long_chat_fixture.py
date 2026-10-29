#!/usr/bin/env python3
"""Writes `synthetic/chat.long.json`: a long imported Chat for transcript performance and
scrolling tests (#196, #197).

Shaped like the long Chat that showed the problem (58 Messages, ~110k characters): Responses of
600 to 16,000 characters with Thinking and tool calls serialized as `<details>` blocks (the web
client's format for imported Chats), headings, lists, tables and code. The text is generated
from a seed, so the file is the same on every run and holds nothing personal.

Usage: scripts/fixtures/make_long_chat_fixture.py
"""
import html
import json
import pathlib
import random

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "Modules/Tests/Fixtures/open-webui-0.12.3/synthetic/chat.long.json"
CHAT_ID = "00000000-0000-4000-8000-00000000c197"
MODEL = "claude-opus-5-5"
START = 1792900000

WORDS = """labyrinth corridor thread minotaur wall junction lantern stone archway passage chamber map
mouse whisker turn left right dead end centre exit loop marker chalk floor ceiling echo draught
spiral courtyard gate hedge path plan route mark trace knot ribbon compass bearing step pace
quiet cold worn smooth narrow wide long short old new hidden open closed first last every each
walks follows notes marks counts finds keeps leaves returns turns reaches crosses climbs avoids
because although while until after before since unless whenever""".split()

# (prompt length, response length, details blocks, tables) per turn; the profile of the original.
TURNS = [
    (416, 16400, 15, 2), (36, 6900, 5, 2), (40, 1460, 1, 2), (79, 1650, 1, 0), (104, 14700, 11, 3),
    (155, 1740, 1, 0), (59, 1580, 1, 0), (378, 9400, 5, 0), (32, 5700, 4, 0), (22, 1290, 1, 1),
    (44, 1040, 1, 0), (59, 1740, 1, 2), (73, 1220, 1, 0), (119, 1600, 1, 0), (39, 3870, 3, 0),
    (144, 1820, 1, 0), (70, 5260, 3, 0), (58, 1530, 1, 1), (36, 1160, 1, 1), (134, 1990, 1, 1),
    (329, 4040, 3, 0), (169, 2770, 2, 2), (11, 1300, 1, 2), (28, 1220, 0, 0), (38, 1410, 1, 0),
    (26, 1070, 0, 0), (15, 1570, 1, 2), (81, 10000, 11, 3), (63, 660, 1, 0),
]


def sentence(rng: random.Random, words: int) -> str:
    text = " ".join(rng.choice(WORDS) for _ in range(words))
    return text[0].upper() + text[1:] + "."


def paragraph(rng: random.Random, chars: int) -> str:
    out = []
    while sum(len(s) + 1 for s in out) < chars:
        out.append(sentence(rng, rng.randint(6, 18)))
    return " ".join(out)


def table(rng: random.Random) -> str:
    columns = rng.randint(3, 5)
    rows = rng.randint(3, 7)
    header = "| " + " | ".join(rng.choice(WORDS).title() for _ in range(columns)) + " |"
    rule = "|" + "|".join("---" for _ in range(columns)) + "|"
    body = ["| " + " | ".join(" ".join(rng.choice(WORDS) for _ in range(rng.randint(1, 4))) for _ in range(columns)) + " |"
            for _ in range(rows)]
    return "\n".join([header, rule, *body])


def tool_call(rng: random.Random, index: int) -> str:
    query = " ".join(rng.choice(WORDS) for _ in range(4))
    if rng.random() < 0.5:
        name, arguments = "web_search", {"query": query}
    else:
        name, arguments = "fetch_url", {"url": f"https://example.com/{'-'.join(query.split())}"}
    result = paragraph(rng, rng.randint(80, 400))
    # The web client writes arguments and results as HTML-escaped JSON strings holding JSON.
    escape = lambda value: html.escape(json.dumps(json.dumps(value) if not isinstance(value, str) else value), quote=True)
    return (f'<details type="tool_calls" done="true" id="toolu_{index:04d}" name="{name}" '
            f'arguments="{escape(arguments)}" result="{escape(result)}" files="">\n'
            "<summary>Tool Executed</summary>\n</details>")


def reasoning(rng: random.Random) -> str:
    lines = [f"> {sentence(rng, rng.randint(8, 16))}" for _ in range(rng.randint(2, 5))]
    return (f'<details type="reasoning" done="true" duration="{rng.randint(1, 12)}">\n'
            f"<summary>Thought</summary>\n" + "\n>\n".join(lines) + "\n</details>")


def response(rng: random.Random, chars: int, blocks: int, tables: int, turn: int) -> str:
    parts = []
    if blocks:
        parts.append(reasoning(rng))
    for index in range(max(0, blocks - 1)):
        parts.append(tool_call(rng, turn * 100 + index))
    sections = []
    budget = chars - sum(len(p) for p in parts)
    tables_left = tables
    while sum(len(s) for s in sections) < budget:
        kind = rng.random()
        if not sections or kind < 0.15:
            sections.append(f"## {sentence(rng, rng.randint(2, 5))[:-1]}")
        elif kind < 0.3:
            sections.append("\n".join(f"- **{rng.choice(WORDS).title()}:** {sentence(rng, rng.randint(5, 14))}"
                                      for _ in range(rng.randint(2, 6))))
        elif kind < 0.38 and tables_left:
            sections.append(table(rng))
            tables_left -= 1
        elif kind < 0.42:
            sections.append("```swift\n" + "\n".join(f"let {rng.choice(WORDS)}{i} = \"{rng.choice(WORDS)}\"" for i in range(rng.randint(3, 8))) + "\n```")
        else:
            sections.append(paragraph(rng, rng.randint(150, 600)))
    for _ in range(tables_left):
        sections.append(table(rng))
    return "\n".join(parts) + ("\n" if parts else "") + "\n\n".join(sections)


def main() -> None:
    rng = random.Random(197)
    messages = {}
    parent = None
    ids = []
    for turn, (prompt_chars, response_chars, blocks, tables) in enumerate(TURNS):
        user_id = f"00000000-0000-4000-8000-{turn * 2:012d}"
        assistant_id = f"00000000-0000-4000-8000-{turn * 2 + 1:012d}"
        messages[user_id] = {
            "id": user_id, "parentId": parent, "childrenIds": [assistant_id], "role": "user",
            "content": paragraph(rng, prompt_chars)[:max(prompt_chars, 8)], "timestamp": START + turn * 60,
            "models": [MODEL],
        }
        messages[assistant_id] = {
            "id": assistant_id, "parentId": user_id, "childrenIds": [], "role": "assistant",
            "content": response(rng, response_chars, blocks, tables, turn), "timestamp": START + turn * 60 + 30,
            "model": MODEL, "modelName": "Claude Opus", "done": True,
        }
        if parent:
            messages[parent]["childrenIds"] = [user_id]
        parent = assistant_id
        ids += [user_id, assistant_id]
    chat = {
        "id": CHAT_ID, "user_id": "00000000-0000-4000-8000-0000000000a1", "title": "A long walk through the labyrinth",
        "chat": {
            "id": CHAT_ID, "title": "A long walk through the labyrinth", "models": [MODEL], "tags": [],
            "timestamp": START * 1000, "history": {"messages": messages, "currentId": parent},
            "messages": [messages[i] for i in ids],
        },
        "updated_at": START + len(TURNS) * 60, "created_at": START, "share_id": None, "archived": False,
        "pinned": False, "meta": {}, "folder_id": None,
    }
    OUT.write_text(json.dumps(chat, indent=1, ensure_ascii=False) + "\n")
    total = sum(len(m["content"]) for m in messages.values())
    print(f"wrote {OUT.relative_to(ROOT)}: {len(messages)} Messages, {total} characters")


if __name__ == "__main__":
    main()
