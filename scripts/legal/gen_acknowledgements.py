#!/usr/bin/env python3
"""Settings › About › Acknowledgements: every third-party component in the app, with its licence.

The MIT, BSD, Apache and OFL licences of the bundled code and fonts require their notices to ship
with the app (docs/research/app-store-release.md, B6).

  gen_acknowledgements.py --refresh   collect the licence texts again (needs the SwiftPM checkouts,
                                      i.e. one `swift build`/`swift test` or Xcode build, plus npm and
                                      network for Mermaid's bundled packages), then regenerate
  gen_acknowledgements.py             regenerate the Swift file from scripts/legal/acknowledgements.json
  gen_acknowledgements.py --check     exit 1 if the Swift file, Package.resolved or the vendored Mermaid
                                      version disagree with acknowledgements.json (offline; preflight)

Outputs: scripts/legal/acknowledgements.json (the collected texts, committed so --check is offline)
and Modules/Sources/SettingsFeature/Acknowledgement+Catalog.generated.swift. Never hand-edit either.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RESOLVED = ROOT / "Modules/Package.resolved"
DATA = ROOT / "scripts/legal/acknowledgements.json"
SWIFT = ROOT / "Modules/Sources/SettingsFeature/Acknowledgement+Catalog.generated.swift"
MERMAID_DIR = ROOT / "Modules/Sources/ArtifactsFeature/Resources/mermaid"
DEPARTURE_MONO = ROOT / "Modules/Sources/DesignSystem/Resources/Fonts/DepartureMono-LICENSE.txt"

# What each SwiftPM package is called in the app and which licence it carries.
PACKAGES = {
    "grdb.swift": ("GRDB.swift", "MIT"),
    "swift-markdown": ("Swift Markdown", "Apache-2.0"),
    "swift-cmark": ("cmark-gfm (swift-cmark)", "BSD-2-Clause and others"),
    "swiftmath": ("SwiftMath", "MIT"),
}
LICENCE_FILE = re.compile(r"^(LICEN[CS]E|COPYING|NOTICE)(\.(txt|md))?$", re.IGNORECASE)


def pins() -> dict[str, dict]:
    data = json.loads(RESOLVED.read_text())
    return {pin["identity"]: pin for pin in data["pins"]}


def mermaid_version() -> str:
    match = re.search(r"mermaid (\S+)", (MERMAID_DIR / "SOURCE.txt").read_text())
    if not match:
        sys.exit("error: no version in mermaid/SOURCE.txt")
    return match.group(1)


def checkout_dirs() -> list[Path]:
    candidates = [ROOT / "Modules/.build/checkouts", ROOT / "build/DerivedData/SourcePackages/checkouts"]
    candidates += [Path(p) for p in glob.glob(str(Path.home() / "Library/Developer/Xcode/DerivedData/Theseus-*/SourcePackages/checkouts"))]
    return [c for c in candidates if c.is_dir()]


def find_checkout(identity: str) -> Path:
    for base in checkout_dirs():
        for child in base.iterdir():
            if child.name.lower() == identity:
                return child
    sys.exit(f"error: no checkout for {identity}; run `swift build --package-path Modules` first")


def licence_texts(directory: Path) -> str:
    files = sorted(f for f in directory.iterdir() if f.is_file() and LICENCE_FILE.match(f.name))
    # LICENSE before NOTICE: the licence first, then its notices.
    files.sort(key=lambda f: (f.name.upper().startswith("NOTICE"), f.name))
    if not files:
        sys.exit(f"error: no licence file in {directory}")
    return "\n\n".join(f.read_text(encoding="utf-8", errors="replace").strip() for f in files)


def mermaid_bundled(version: str) -> list[dict]:
    """Every runtime package of mermaid@version: the minified build bundles all of them."""
    with tempfile.TemporaryDirectory() as tmp:
        run = lambda *args: subprocess.run(args, cwd=tmp, check=True, capture_output=True)  # noqa: E731
        run("npm", "init", "-y")
        run("npm", "install", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund", f"mermaid@{version}")
        found = {}
        for manifest in glob.glob(f"{tmp}/node_modules/**/package.json", recursive=True):
            package_dir = Path(manifest).parent
            relative = str(package_dir).split("node_modules/")[-1]
            meta = json.loads(Path(manifest).read_text())
            name = meta.get("name")
            if name != relative or name == "mermaid":
                continue
            licence = meta.get("license") or ""
            if isinstance(licence, dict):
                licence = licence.get("type", "")
            files = [f for f in package_dir.iterdir() if f.is_file() and re.match(r"^(LICEN[CS]E|COPYING)", f.name, re.I)]
            text = "\n\n".join(f.read_text(encoding="utf-8", errors="replace").strip() for f in sorted(files))
            if not licence and "MIT License" in text:
                licence = "MIT"
            if not text:
                text = f"Licensed under {licence or 'its own terms'}; see https://www.npmjs.com/package/{name}."
            found[name] = {"name": name, "licence": licence, "text": text}
        return [found[k] for k in sorted(found)]


def refresh() -> dict:
    resolved = pins()
    unknown = set(resolved) - set(PACKAGES)
    if unknown:
        sys.exit(f"error: add {sorted(unknown)} to PACKAGES in {Path(__file__).name}")
    entries = []
    for identity, (name, licence) in PACKAGES.items():
        pin = resolved[identity]
        checkout = find_checkout(identity)
        entries.append({
            "id": identity,
            "name": name,
            "version": pin["state"].get("version", pin["state"].get("revision", "")[:12]),
            "url": pin["location"].removesuffix(".git"),
            "licence": licence,
            "text": licence_texts(checkout),
        })
        if identity == "swiftmath":
            fonts = checkout / "Sources/SwiftMath/mathFonts.bundle"
            # SwiftMath is a port of iosMath, whose MIT licence ships in the font bundle.
            if (fonts / "LICENSE").exists():
                entries[-1]["text"] += "\n\nSwiftMath is based on iosMath:\n\n" + (fonts / "LICENSE").read_text().strip()
            names = sorted(p.stem for p in fonts.glob("*.otf"))
            texts = [(fonts / f).read_text(encoding="utf-8", errors="replace").strip()
                     for f in ("OFL.txt", "GUST-FONT-LICENSE.txt") if (fonts / f).exists()]
            entries.append({
                "id": "swiftmath-fonts",
                "name": "Math fonts (bundled with SwiftMath)",
                "version": pin["state"].get("version", ""),
                "url": pin["location"].removesuffix(".git"),
                "licence": "SIL OFL 1.1 / GUST Font License",
                "text": "Fonts: " + ", ".join(names) + ".\n\n" + "\n\n".join(texts),
            })
    version = mermaid_version()
    bundled = mermaid_bundled(version)
    parts = [(MERMAID_DIR / "LICENSE.txt").read_text().strip(),
             f"Mermaid's build bundles these {len(bundled)} packages:"]
    parts += [f"— {b['name']} ({b['licence'] or 'see licence'})\n\n{b['text']}" for b in bundled]
    entries.append({
        "id": "mermaid",
        "name": "Mermaid and the libraries it bundles",
        "version": version,
        "url": "https://github.com/mermaid-js/mermaid",
        "licence": "MIT; bundled: MIT, ISC, BSD-3-Clause, Apache-2.0, MPL-2.0/Apache-2.0, Unlicense",
        "text": "\n\n".join(parts),
    })
    entries.append({
        "id": "departure-mono",
        "name": "Departure Mono",
        "version": "",
        "url": "https://departuremono.com",
        "licence": "SIL OFL 1.1",
        "text": DEPARTURE_MONO.read_text().strip(),
    })
    return {"entries": entries}


def swift_literal(text: str) -> str:
    if '"""#' in text:
        sys.exit("error: a licence text contains the raw-string terminator")
    body = "\n".join(("        " + line) if line else "" for line in text.splitlines())
    return '#"""\n' + body + '\n        """#'


def render(data: dict) -> str:
    out = [
        "// Generated by scripts/legal/gen_acknowledgements.py from scripts/legal/acknowledgements.json.",
        "// Do not edit. Run the script (with --refresh after a dependency update) instead.",
        "",
        "import Foundation",
        "",
        "extension Acknowledgement {",
        "    static let all: [Acknowledgement] = [",
    ]
    for entry in data["entries"]:
        out += [
            "        Acknowledgement(",
            f"            name: {json.dumps(entry['name'], ensure_ascii=False)},",
            f"            version: {json.dumps(entry['version'])},",
            f"            url: URL(string: {json.dumps(entry['url'])}),",
            f"            licenseName: {json.dumps(entry['licence'], ensure_ascii=False)},",
            f"            license: {swift_literal(entry['text'])}",
            "        ),",
        ]
    out += ["    ]", "}", ""]
    return "\n".join(out)


def check(data: dict) -> list[str]:
    problems = []
    by_id = {e["id"]: e for e in data["entries"]}
    for identity, pin in pins().items():
        entry = by_id.get(identity)
        version = pin["state"].get("version")
        if entry is None:
            problems.append(f"{identity} isn't acknowledged")
        elif version and entry["version"] != version:
            problems.append(f"{identity} is {version} but acknowledged as {entry['version']}")
    if by_id.get("mermaid", {}).get("version") != mermaid_version():
        problems.append("the vendored Mermaid version changed")
    if not SWIFT.exists() or SWIFT.read_text() != render(data):
        problems.append(f"{SWIFT.relative_to(ROOT)} is out of date")
    return problems


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--refresh", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.refresh:
        DATA.write_text(json.dumps(refresh(), indent=1, ensure_ascii=False) + "\n")
    data = json.loads(DATA.read_text())
    if args.check:
        problems = check(data)
        for problem in problems:
            print(f"error: {problem} (run scripts/legal/gen_acknowledgements.py --refresh)", file=sys.stderr)
        sys.exit(1 if problems else 0)
    SWIFT.write_text(render(data))
    print(f"{len(data['entries'])} acknowledgements → {SWIFT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
