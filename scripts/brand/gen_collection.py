#!/usr/bin/env python3
"""Generates the ArtCollection catalog (`Artwork` constants and slot accessors) from collection.json.

Usage: scripts/brand/gen_collection.py [--import-art <export dir>]

Input: scripts/brand/collection.json (the committed copy of the staged export's collection.json),
plus the app-side additions below: a focal point per artwork (crops keep it in view), the short
artist name for compact plaques, and slots the brand spec assigns that the export doesn't list.
Output: Modules/Sources/ArtCollection/Artwork+Catalog.generated.swift. Never hand-edit it.

`--import-art DIR` first copies DIR/art/*.jpg (byte for byte, never re-encoded) and
DIR/collection.json into the repo. Each artwork's placeholder colour (shown while its image
decodes) is its average colour, computed with ImageMagick when it's installed.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COLLECTION = ROOT / "scripts/brand/collection.json"
ART_DIR = ROOT / "Modules/Sources/ArtCollection/Resources/Art"
OUTPUT = ROOT / "Modules/Sources/ArtCollection/Artwork+Catalog.generated.swift"

# Where the eye should land when a crop can't show the whole work (unit coordinates, 0,0 = top left).
FOCAL = {
    "cole-view-of-florence": (0.62, 0.5),  # the Duomo
    "heade-point-judith": (0.6, 0.55),  # the moon's path on the water
    "zeshin-mouse": (0.5, 0.72),  # the mouse
    "florilegium-labyrinth": (0.4, 0.3),  # the maze
    "barye-theseus-minotaur": (0.5, 0.4),
    "piranesi-drawbridge": (0.5, 0.4),
    "durer-jerome-study": (0.55, 0.5),  # Jerome at his desk
    "yi-books-scholars": (0.5, 0.5),
    "corot-la-cervara": (0.55, 0.55),
    "turner-burning-houses": (0.4, 0.45),  # the fire
    "gifford-haverstraw-bay": (0.47, 0.6),  # the boat
    "lorrain-rest-flight": (0.45, 0.62),
    "roman-sarcophagus-theseus-ariadne": (0.5, 0.5),
    "hammershoi-strandgade": (0.5, 0.4),  # the window
    "renoir-fruits-of-the-midi": (0.5, 0.5),
    "monet-apples-and-grapes": (0.5, 0.4),
    "cezanne-basket-of-apples": (0.5, 0.5),
    "vandijck-cheeses": (0.55, 0.4),
    "peeters-cheeses-almonds-pretzels": (0.45, 0.4),
    "decamps-herring-bread-cheese": (0.5, 0.65),
    "coorte-gooseberries": (0.5, 0.55),
    "vanderhamen-sweets": (0.5, 0.5),
    "chardin-kitchen-utensils": (0.5, 0.55),
}

# The name a compact plaque uses ("COROT · 1830").
SHORT_ARTIST = {
    "cole-view-of-florence": "Cole",
    "heade-point-judith": "Heade",
    "zeshin-mouse": "Zeshin",
    "florilegium-labyrinth": "Florilegium",
    "barye-theseus-minotaur": "Barye",
    "piranesi-drawbridge": "Piranesi",
    "durer-jerome-study": "Dürer",
    "yi-books-scholars": "Yi Taek-gyun",
    "corot-la-cervara": "Corot",
    "turner-burning-houses": "Turner",
    "gifford-haverstraw-bay": "Gifford",
    "lorrain-rest-flight": "Lorrain",
    "roman-sarcophagus-theseus-ariadne": "Roman",
    "hammershoi-strandgade": "Hammershøi",
    "renoir-fruits-of-the-midi": "Renoir",
    "monet-apples-and-grapes": "Monet",
    "cezanne-basket-of-apples": "Cézanne",
    "vandijck-cheeses": "Van Dijck",
    "peeters-cheeses-almonds-pretzels": "Peeters",
    "decamps-herring-bread-cheese": "Decamps",
    "coorte-gooseberries": "Coorte",
    "vanderhamen-sweets": "Van der Hamen",
    "chardin-kitchen-utensils": "Chardin",
}

# Slots from the brand spec's slot map (brand.md §4) that collection.json doesn't carry.
EXTRA_SLOTS = {
    "lorrain-rest-flight": ["projects-empty"],
    # ADR 0173: the paywall's framed treat, with the mouse peeking over it.
    "vanderhamen-sweets": ["pro"],
}

# Slot (collection.json name) → (Swift case name, single?). A single slot gets a typed accessor
# (`Artwork.welcome`, its first work); the others are lists (`Artwork.works(in:)`).
SLOTS = {
    "welcome": ("welcome", True),
    "welcome-dark": ("welcomeDark", True),
    "incognito": ("incognito", True),
    "error": ("error", True),
    "offline": ("offline", True),
    "library-empty": ("libraryEmpty", True),
    "projects-empty": ("projectsEmpty", True),
    "memory": ("memory", True),
    "mascot-origin": ("mascotOrigin", True),
    "onboarding": ("onboarding", True),
    "voice": ("voice", True),
    "pro": ("pro", True),
    "today": ("today", False),
    "project-cover": ("projectCover", False),
    "about": ("about", False),
    "icon": ("icon", False),
}

SLOT_DOCS = {
    "welcome": "Welcome / server connect, light appearance: full-bleed at the top.",
    "welcomeDark": "Welcome, dark appearance.",
    "incognito": "Incognito chats: full-bleed, dark.",
    "error": "Errors (\"Lost in the labyrinth.\"): framed, with the mouse peeking over.",
    "offline": "Offline / server unreachable.",
    "libraryEmpty": "Chats empty, and search with no results.",
    "projectsEmpty": "No Projects yet.",
    "memory": "Memory.",
    "mascotOrigin": "The mouse's lineage on About › The Collection (\"Lineage, not imitation\").",
    "onboarding": "Onboarding.",
    "voice": "Voice mode, subtle behind the orb (optional).",
    "pro": "The Theseus Pro paywall: framed, with the mouse peeking over (ADR 0173).",
}


def swift_identifier(artwork_id: str) -> str:
    parts = re.split(r"[^A-Za-z0-9]+", artwork_id)
    return parts[0] + "".join(p[:1].upper() + p[1:] for p in parts[1:])


def swift_literal(text: str) -> str:
    return json.dumps(text, ensure_ascii=False)


def average_colour(path: Path) -> str | None:
    if shutil.which("magick") is None or not path.exists():
        return None
    out = subprocess.run(
        ["magick", str(path), "-resize", "1x1!", "-depth", "8", "-format", "%[hex:p{0,0}]", "info:"],
        capture_output=True, text=True, check=False,
    ).stdout.strip()
    return out[:6] if re.fullmatch(r"[0-9A-Fa-f]{6,8}", out) else None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--import-art", type=Path, help="the brand export dir (has art/ and collection.json)")
    args = parser.parse_args()

    if args.import_art:
        ART_DIR.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(args.import_art / "collection.json", COLLECTION)
        for jpg in sorted((args.import_art / "art").glob("*.jpg")):
            shutil.copyfile(jpg, ART_DIR / jpg.name)

    works = json.loads(COLLECTION.read_text(encoding="utf-8"))
    ids = [w["id"] for w in works]
    if len(set(ids)) != len(ids):
        raise SystemExit("duplicate artwork ids")
    for key, table in (("focal point", FOCAL), ("short artist", SHORT_ARTIST)):
        missing = set(ids) - set(table)
        if missing:
            raise SystemExit(f"no {key} for {sorted(missing)}")

    out = [
        "// GENERATED by scripts/brand/gen_collection.py from scripts/brand/collection.json. Do not edit.",
        "",
        "import CoreGraphics",
        "import DesignSystem",
        "import SwiftUI",
        "",
        "extension Artwork {",
    ]
    by_slot: dict[str, list[str]] = {name: [] for name in SLOTS}
    for w in works:
        slots = list(dict.fromkeys(w["slots"] + EXTRA_SLOTS.get(w["id"], [])))
        unknown = set(slots) - set(SLOTS)
        if unknown:
            raise SystemExit(f"{w['id']}: unknown slots {sorted(unknown)}")
        for slot in slots:
            by_slot[slot].append(w["id"])
        if not (ART_DIR / w["file"]).exists():
            raise SystemExit(f"{w['id']}: {w['file']} is not in {ART_DIR.relative_to(ROOT)}")
        if not w["url"].startswith("https://") or not w["licence"].strip():
            raise SystemExit(f"{w['id']}: needs an https museum URL and a licence")
        fx, fy = FOCAL[w["id"]]
        placeholder = average_colour(ART_DIR / w["file"]) or "2A2722"
        slot_list = ", ".join(f".{SLOTS[s][0]}" for s in slots)
        out += [
            f"    static let {swift_identifier(w['id'])} = Artwork(",
            f"        id: {swift_literal(w['id'])},",
            f"        title: {swift_literal(w['title'])},",
            f"        artist: {swift_literal(w['artist'])},",
            f"        shortArtist: {swift_literal(SHORT_ARTIST[w['id']])},",
            f"        date: {swift_literal(w['date'])},",
            f"        museum: {swift_literal(w['museum'])},",
            f"        objectNumber: {swift_literal(w['objectNumber'])},",
            f"        licence: {swift_literal(w['licence'])},",
            f"        museumURL: {swift_literal(w['url'])},",
            f"        fileName: {swift_literal(w['file'])},",
            f"        pixelSize: CGSize(width: {w['width']}, height: {w['height']}),",
            f"        slots: [{slot_list}],",
            f"        focal: UnitPoint(x: {fx}, y: {fy}),",
            f"        placeholder: RGBA(hex: 0x{placeholder.upper()})",
            "    )",
            "",
        ]

    out.append("    /// Every artwork in the collection, in catalog order.")
    out.append("    public static let all: [Artwork] = [")
    out += [f"        {swift_identifier(i)}," for i in ids]
    out += ["    ]", ""]

    for slot, (name, single) in SLOTS.items():
        members = by_slot[slot]
        if not members:
            raise SystemExit(f"slot {slot} has no artwork")
        if single:
            out.append(f"    /// {SLOT_DOCS[name]}")
            out.append(f"    public static let {name} = {swift_identifier(members[0])}")
            out.append("")
    out.append("    /// The works carrying `slot`, in catalog order.")
    out.append("    static func generatedWorks(in slot: Slot) -> [Artwork] {")
    out.append("        switch slot {")
    for slot, (name, _) in SLOTS.items():
        members = ", ".join(swift_identifier(i) for i in by_slot[slot])
        out.append(f"        case .{name}: [{members}]")
    out += ["        }", "    }", "}", ""]

    out += [
        "extension Artwork.Slot {",
        "    /// The slot's name in collection.json.",
        "    public var jsonName: String {",
        "        switch self {",
    ]
    for slot, (name, _) in SLOTS.items():
        out.append(f'        case .{name}: "{slot}"')
    out += ["        }", "    }", "}", ""]

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text("\n".join(out), encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(ROOT)} ({len(works)} artworks)")


if __name__ == "__main__":
    main()
