#!/usr/bin/env bash
# Builds a signed Release MacSpace.app and zips it for a GitHub release.
#
# Signed with your Apple Development certificate (DEVELOPMENT_TEAM in Local.xcconfig), not
# notarized: macOS asks once to "Open Anyway", and Full Disk Access survives updates because the
# signing identity stays the same.
#
# Usage: scripts/release.sh            → build/MacSpace.zip
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "error: uncommitted changes; release from a clean tree" >&2
    exit 1
fi

version=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' project.yml)
build=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' project.yml)
echo "MacSpace $version ($build) at $(git rev-parse --short HEAD)"

out=build
derived="$out/DerivedData"
rm -rf "$out"
mkdir -p "$out"

xcodegen generate --quiet
xcodebuild -project MacSpace.xcodeproj -scheme MacSpace -configuration Release \
    -destination "platform=macOS" -derivedDataPath "$derived" build -quiet

app="$derived/Build/Products/Release/MacSpace.app"
codesign --verify --deep --strict "$app"
codesign -dvv "$app" 2>&1 | grep -E '^(Authority|TeamIdentifier)=' | head -2

shown=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
if [[ "$shown" != "$version" ]]; then
    echo "error: built version $shown, project.yml says $version" >&2
    exit 1
fi

zip="$out/MacSpace.zip"
ditto -c -k --keepParent "$app" "$zip"

check=$(mktemp -d)
trap 'rm -rf "$check"' EXIT
ditto -x -k "$zip" "$check"
codesign --verify --deep --strict "$check/MacSpace.app"

echo "ok: $zip"
shasum -a 256 "$zip"
