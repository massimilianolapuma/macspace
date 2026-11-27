# macspace

MacSpace is a native macOS disk analyzer: a SwiftUI app (`App/MacSpace`) on top of a UI-free
Swift package, `MacSpaceCore`. Requires macOS 27, Xcode 27 and XcodeGen.

Website: https://massimilianolapuma.github.io/macspace/

## Install

1. Download `MacSpace.zip` from the [latest release](https://github.com/massimilianolapuma/macspace/releases/latest)
   and unzip it; move `MacSpace.app` to Applications.
2. Open it. The app is not notarized by Apple, so macOS blocks it: click «Done» (not «Move to Trash»).
   Then open System Settings › Privacy & Security, scroll to Security and click «Open Anyway» next to
   MacSpace (the button appears only for a while after the blocked attempt). Confirm with your password
   or Touch ID, then click «Open Anyway» once more.
3. Give it Full Disk Access (System Settings › Privacy & Security › Full Disk Access) to see protected
   folders; without it they are marked unreadable.

Each new version repeats steps 2 and 3: the release is signed ad hoc, so macOS treats every version as
a new app.

## Build from source

```sh
cp Local.xcconfig.example Local.xcconfig   # then set DEVELOPMENT_TEAM to your team ID
xcodegen generate                          # creates MacSpace.xcodeproj (not tracked)
open MacSpace.xcodeproj                    # or build from the command line:
xcodebuild -project MacSpace.xcodeproj -scheme MacSpace -configuration Debug build
```

`Local.xcconfig` is untracked; never commit it.

## Tests

```sh
cd MacSpaceCore && swift test
```

Opt-in startup-disk benchmark (whole-disk scan; release build; prints files, duration and
peak memory per file):

```sh
cd MacSpaceCore && MACSPACE_BENCH=1 swift test -c release --filter startupDiskScan
```

## Release

1. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` and the version line in
   `site/index.html`.
2. Tag the commit `vX.Y.Z` and run `scripts/release.sh`. It builds the Release app, signs it ad hoc
   (no developer identity is embedded), checks it is not debuggable, and writes and re-verifies
   `build/MacSpace.zip`.
3. `gh release create vX.Y.Z build/MacSpace.zip`, not as a pre-release: the site links to
   `releases/latest/download/MacSpace.zip`.

## License

MIT, see [LICENSE](LICENSE).
