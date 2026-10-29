#!/usr/bin/env bash
# One-time (and after every project.yml change) setup: tools, package resolution, Xcode project.
#
# Usage: scripts/bootstrap.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

step() { printf '\n==> %s\n' "$*"; }

step "Checking Xcode"
xcodebuild -version | head -1
swift --version 2>&1 | head -1

step "Checking XcodeGen"
if ! command -v xcodegen >/dev/null; then
  if command -v brew >/dev/null; then
    brew install xcodegen
  else
    echo "XcodeGen is missing and Homebrew isn't installed. Install XcodeGen: https://github.com/yonaskolb/XcodeGen" >&2
    exit 1
  fi
fi
xcodegen --version

step "Resolving Swift packages (Modules/)"
swift package --package-path Modules resolve

step "Generating Theseus.xcodeproj from project.yml"
xcodegen generate --quiet

if [[ ! -f .env ]]; then
  echo
  echo "Note: no .env found. Copy .env.example to .env to enable fixture recording and integration tests."
fi

echo
echo "Bootstrap complete. Next: scripts/test.sh"
