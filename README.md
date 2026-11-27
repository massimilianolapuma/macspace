# macspace

MacSpace is a native macOS disk analyzer: a SwiftUI app (`App/MacSpace`) on top of a UI-free
Swift package, `MacSpaceCore`. Requires macOS 27, Xcode 27 and XcodeGen.

Website: https://massimilianolapuma.github.io/macspace/

## Install

1. Download `MacSpace.zip` from the [latest release](https://github.com/massimilianolapuma/macspace/releases/latest)
   and unzip it; move `MacSpace.app` to Applications.
2. The app is signed but not notarized: the first time, macOS blocks it. Open it once, then go to
   System Settings › Privacy & Security and click «Open Anyway» next to MacSpace.
3. Give it Full Disk Access (System Settings › Privacy & Security › Full Disk Access) to see protected
   folders; without it they are marked unreadable. The grant survives updates.

Requires macOS 27.

## Build from source

```sh
cp Local.xcconfig.example Local.xcconfig   # then set DEVELOPMENT_TEAM to your team ID
xcodegen generate                          # creates MacSpace.xcodeproj (not tracked)
open MacSpace.xcodeproj                    # or build from the command line:
xcodebuild -project MacSpace.xcodeproj -scheme MacSpace -configuration Debug build
```

`Local.xcconfig` is untracked; never commit it. Grant MacSpace Full Disk Access
(System Settings › Privacy & Security) to see protected folders; without it they are marked
unreadable.

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

`scripts/release.sh` builds the Release app, signs it with your Apple Development certificate,
verifies it and writes `build/MacSpace.zip`. Tag the commit (`vX.Y.Z`), run the script, then attach
the zip to a GitHub release.

## License

MIT, see [LICENSE](LICENSE).
