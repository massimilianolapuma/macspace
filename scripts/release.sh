#!/usr/bin/env bash
# Builds a Release MacSpace.app, signs it ad hoc and zips it for a GitHub release.
#
# Ad-hoc signing carries no name or email (an Apple Development certificate would publish the
# developer's Apple ID in every zip). The cost: the app is not notarized, so macOS asks once per
# version to "Open Anyway", and Full Disk Access must be granted again after each update.
#
# Usage: scripts/release.sh            → build/MacSpace.zip (run on the commit tagged vX.Y.Z)
set -euo pipefail

cd "$(dirname "$0")/.."

fail() { echo "error: $*" >&2; exit 1; }

[[ -z "$(git status --porcelain --untracked-files=no)" ]] || fail "uncommitted changes; release from a clean tree"
# XcodeGen compiles everything under these paths, tracked or not.
[[ -z "$(git ls-files --others --exclude-standard -- App MacSpaceCore project.yml)" ]] \
    || fail "untracked files under App/ or MacSpaceCore/ would end up in the release"

setting() { sed -n "s/^ *$1: *\"\{0,1\}\([^\"# ]*\)\"\{0,1\}.*$/\1/p" project.yml | head -1; }
version=$(setting MARKETING_VERSION)
build=$(setting CURRENT_PROJECT_VERSION)
[[ -n "$version" && -n "$build" ]] || fail "MARKETING_VERSION / CURRENT_PROJECT_VERSION not found in project.yml"

tag=$(git describe --exact-match --tags HEAD 2>/dev/null || true)
[[ "$tag" == "v$version" ]] || echo "warning: HEAD is not tagged v$version (tag: ${tag:-none})" >&2
echo "MacSpace $version ($build) at $(git rev-parse --short HEAD)"

out=build
derived="$out/DerivedData"
rm -rf "$out"
mkdir -p "$out"

xcodegen generate --quiet
xcodebuild -project MacSpace.xcodeproj -scheme MacSpace -configuration Release \
    -destination "platform=macOS" -derivedDataPath "$derived" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    build -quiet

app="$derived/Build/Products/Release/MacSpace.app"
plist="$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "$version" ]] || fail "built version differs from $version"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == "$build" ]] || fail "built build number differs from $build"

verify() {
    codesign --verify --deep --strict "$1"
    local info
    info=$(codesign -dvv "$1" 2>&1)
    grep -q '^Signature=adhoc' <<<"$info" || fail "$1 is not signed ad hoc"
    ! grep -q '^Authority=' <<<"$info" || fail "$1 carries a signing identity"
    grep -q 'flags=.*runtime' <<<"$info" || fail "$1 lacks the hardened runtime"
    ! codesign -d --entitlements - "$1" 2>/dev/null | grep -q 'get-task-allow' || fail "$1 is debuggable (get-task-allow)"
}
verify "$app"

zip="$out/MacSpace.zip"
ditto -c -k --keepParent "$app" "$zip"

check=$(mktemp -d)
trap 'rm -rf "$check"' EXIT
ditto -x -k "$zip" "$check"
verify "$check/MacSpace.app"

echo "ok: $zip (ad hoc, hardened runtime, not debuggable)"
shasum -a 256 "$zip"
