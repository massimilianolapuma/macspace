# macspace

MacSpace is a native macOS disk analyzer: a SwiftUI app (`App/MacSpace`) on top of a UI-free
Swift package, `MacSpaceCore`. Requires macOS 27, Xcode 27 and XcodeGen.

## Setup

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
