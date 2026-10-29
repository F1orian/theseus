#!/usr/bin/env python3
"""Writes the hand-written `synthetic/chat.claude-import.json` fixture (#180).

A Chat as Open WebUI stores one imported from Claude: no `output` items, Thinking and tool calls
serialized into `message.content` as `<details type="reasoning|tool_calls">` blocks the way the
web client writes them (arguments/results JSON-encoded twice, then HTML-escaped). Titles and
contents are synthetic; nothing comes from a real account.

Usage: scripts/fixtures/make_claude_import_fixture.py
"""
import html
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "Modules/Tests/Fixtures/open-webui-0.12.3/synthetic/chat.claude-import.json")


def attr(value):
    return html.escape(json.dumps(value), quote=True)


def reasoning(text, seconds):
    quoted = "\n".join("> " + line if line else ">" for line in text.split("\n"))
    return f'<details type="reasoning" done="true" duration="{seconds}">\n<summary>Thought for {seconds} seconds</summary>\n{quoted}\n</details>\n'


def tool(call_id, name, arguments, result="OK"):
    return (f'<details type="tool_calls" done="true" id="{call_id}" name="{name}" '
            f'arguments="{attr(json.dumps(arguments))}" result="{attr(result)}" files="">\n'
            f'<summary>Tool Executed</summary>\n</details>\n')


PLAN = """# Garden Plan

A weekend plan for a small vegetable bed.

## Beds
- Tomatoes along the fence
- Lettuce in the shade

## Steps
1. Loosen the soil
2. Add compost
3. Plant seedlings"""

PAGE = """<!DOCTYPE html>
<html><head><title>Watering Timer</title></head>
<body><h1>Watering Timer</h1><button onclick="this.textContent='Started'">Start</button></body></html>"""

SCRIPT = """def water(minutes):
    for minute in range(minutes):
        print(f"Watering… {minute + 1}/{minutes}")

water(3)"""

turns = [
    ("Plan my garden bed.", reasoning("The user wants a garden plan.\n\nA markdown document fits.", 2)
     + tool("toolu_search", "web_search", {"query": "companion planting tomatoes lettuce"}, "3 results")
     + "Here's a plan.\n\n"
     + tool("toolu_create", "artifacts", {"command": "create", "id": "garden_plan", "type": "text/markdown",
                                          "title": "Garden Plan", "language": None, "content": PLAN})
     + "\nIt keeps the tomatoes in the sun."),
    ("Add basil next to the tomatoes.", reasoning("Edit the beds list.", 1)
     + tool("toolu_update", "artifacts", {"command": "update", "id": "garden_plan",
                                          "old_str": "- Tomatoes along the fence", "new_str": "- Tomatoes along the fence, basil between them"})
     + "Added the basil."),
    ("Also mention peppers.", tool("toolu_update_missing", "artifacts", {"command": "update", "id": "garden_plan",
                                                                         "old_str": "- Peppers by the gate", "new_str": "- Peppers by the gate, two rows"})
     + "Done."),
    ("Make a watering timer page and a script.",
     tool("toolu_page", "artifacts", {"command": "create", "id": "watering_timer", "type": "text/html",
                                      "title": "Watering Timer", "content": PAGE})
     + tool("toolu_script", "artifacts", {"command": "create", "id": "water_script", "type": "application/vnd.ant.code",
                                          "title": "water.py", "language": "python", "content": SCRIPT})
     + "Both are ready."),
    ("Rewrite the page in German.",
     tool("toolu_rewrite", "artifacts", {"command": "rewrite", "id": "watering_timer",
                                         "content": PAGE.replace("Watering Timer", "Bewässerungs-Timer").replace("Start", "Los")})
     + "Übersetzt."),
]

messages = {}
order = []
parent = None
time = 1792800000
for number, (prompt, answer) in enumerate(turns, start=1):
    user_id = f"00000000-0000-4000-8000-00000000c{number:03d}"
    assistant_id = f"00000000-0000-4000-8000-00000000a{number:03d}"
    messages[user_id] = {"id": user_id, "parentId": parent, "childrenIds": [assistant_id], "role": "user",
                         "content": prompt, "timestamp": time, "models": ["claude-sonnet-5-5"]}
    messages[assistant_id] = {"id": assistant_id, "parentId": user_id, "childrenIds": [], "role": "assistant",
                              "content": answer, "timestamp": time + 5, "model": "claude-sonnet-5-5", "done": True}
    if parent:
        messages[parent]["childrenIds"] = [user_id]
    order += [user_id, assistant_id]
    parent = assistant_id
    time += 60

chat = {
    "id": "00000000-0000-4000-8000-0000000c1a00",
    "user_id": "00000000-0000-4000-8000-000000000001",
    "title": "Garden plan (imported)",
    "chat": {"id": "00000000-0000-4000-8000-0000000c1a00", "title": "Garden plan (imported)",
             "models": ["claude-sonnet-5-5"], "tags": ["claude-import"], "timestamp": 1792800000000,
             "history": {"currentId": parent, "messages": messages},
             "messages": [messages[i] for i in order]},
    "updated_at": time, "created_at": 1792800000, "share_id": None, "archived": False, "pinned": False,
    "meta": {"tags": ["claude-import"]}, "folder_id": None,
}

with open(OUT, "w", encoding="utf-8") as f:
    json.dump(chat, f, ensure_ascii=False, indent=1)
    f.write("\n")
print(OUT)
