import Darwin
import Foundation
import Testing
@testable import MacSpaceCore

// MARK: - Who holds a file open (#25)

private typealias Record = OpenFileSet.ProcessRecord

private func holder(_ pid: pid_t, _ records: [pid_t: Record]) -> OpenFileHolder? {
    OpenFileSet.holder(of: pid) { records[$0] }
}

@Test func aProcessInsideAnAppIsNamedByTheOutermostApp() {
    let xpc = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/"
        + "sourcekitd.framework/Versions/A/XPCServices/SourceKitService.xpc/Contents/MacOS/SourceKitService"
    #expect(holder(9, [9: Record(parent: 1, name: "SourceKitService", executable: xpc)])
        == .app(path: "/Applications/Xcode.app"))
    let helper = "/Applications/Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"
    #expect(holder(9, [9: Record(parent: 1, name: "Code Helper", executable: helper)])
        == .app(path: "/Applications/Code.app"))
    #expect(holder(9, [9: Record(parent: 1, name: "X", executable: "/Applications/X.APP/Contents/MacOS/X")])
        == .app(path: "/Applications/X.APP"))
}

@Test func aProcessOutsideAnyAppIsNamedByTheFirstParentInsideOne() {
    let records: [pid_t: Record] = [
        50: Record(parent: 40, name: "node", executable: "/opt/homebrew/bin/node"),
        40: Record(parent: 30, name: "zsh", executable: "/bin/zsh"),
        30: Record(parent: 20, name: "login", executable: "/usr/bin/login"),
        20: Record(parent: 1, name: "Terminal",
                   executable: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
    ]
    #expect(holder(50, records) == .app(path: "/System/Applications/Utilities/Terminal.app"))
}

@Test func aProcessWithNoAppAboveIsNamedByItself() {
    let git = Record(parent: 1, name: "git", executable: "/Users/u/Library/Caches/copilot/libexec/git-core/git")
    #expect(holder(7, [7: git]) == .process(name: "git"))
    // No short name: the executable's file name.
    let unnamed = Record(parent: 1, name: "", executable: "/usr/local/bin/tool")
    #expect(holder(7, [7: unnamed]) == .process(name: "tool"))
    // A parent that cannot be read ends the walk.
    #expect(holder(7, [7: Record(parent: 99, name: "git", executable: nil)]) == .process(name: "git"))
    // A bare ".app" or a name with no stem is not an app.
    #expect(holder(7, [7: Record(parent: 1, name: "t", executable: "/x/.app/t")]) == .process(name: "t"))
}

@Test func aProcessThatCannotBeReadHasNoHolder() {
    #expect(holder(7, [:]) == nil)
    #expect(holder(7, [7: Record(parent: 1, name: "", executable: nil)]) == nil)
}

@Test func aParentLoopEnds() {
    let records: [pid_t: Record] = [
        5: Record(parent: 6, name: "a", executable: "/bin/a"),
        6: Record(parent: 5, name: "b", executable: "/bin/b"),
    ]
    #expect(holder(5, records) == .process(name: "a"))
}

@Test func theOwnProcessIsInsideAnAppOrNamed() {
    // Live: this test process, read as `current` reads it.
    let record = OpenFileSet.processRecord(getpid())
    #expect(record != nil && record?.parent == getppid())
    #expect(OpenFileSet.holder(of: getpid(), record: OpenFileSet.processRecord) != nil)
}

private let xcode = OpenFileHolder.app(path: "/Applications/Xcode.app")
private let git = OpenFileHolder.process(name: "git")

@Test func useOfAFileSaysWhoHoldsIt() {
    let set = OpenFileSet.collect(pids: [1, 2, 3]) { pid in
        .listed(paths: pid == 3 ? ["/u/other"] : ["/u/a/f"], truncated: false)
    } holder: { pid in
        [1: xcode, 2: git][pid]
    }
    #expect(set.use(of: "/u/a/f", isDirectory: false) == OpenUse(holders: [xcode, git], onlyInside: false))
    // Open, but its holder could not be named.
    #expect(set.use(of: "/u/other", isDirectory: false) == OpenUse(holders: [], onlyInside: false))
    #expect(set.use(of: "/u/a/g", isDirectory: false) == nil)
    // A file is never "under" itself.
    #expect(set.use(of: "/u/a", isDirectory: false) == nil)
}

@Test func useOfAFolderGathersWhatIsOpenInside() {
    let set = OpenFileSet.collect(pids: [1, 2, 3]) { pid in
        switch pid {
        case 1: .listed(paths: ["/u/p/a/x"], truncated: false)
        case 2: .listed(paths: ["/u/p/b/y", "/u/q"], truncated: false)
        default: .listed(paths: ["/u/pp/z"], truncated: false)
        }
    } holder: { pid in
        [1: xcode, 2: git, 3: .process(name: "other")][pid]
    }
    #expect(set.use(of: "/u/p", isDirectory: true) == OpenUse(holders: [xcode, git], onlyInside: true))
    #expect(set.use(of: "/u/p/a", isDirectory: true) == OpenUse(holders: [xcode], onlyInside: true))
    #expect(set.use(of: "/u/p/c", isDirectory: true) == nil)
    // The folder itself open (a descriptor on it): not only inside.
    #expect(set.use(of: "/u/q", isDirectory: true) == OpenUse(holders: [git], onlyInside: false))
}

@Test func holdersFollowCanonicalPaths() {
    let set = OpenFileSet.collect(pids: [1, 2]) { pid in
        .listed(paths: [pid == 1 ? "/tmp/f" : "/private/tmp/f"], truncated: false)
    } holder: { pid in
        [1: xcode, 2: git][pid]
    }
    #expect(set.use(of: "/private/tmp/f", isDirectory: false)?.holders == [xcode, git])
    #expect(set.use(of: "/tmp", isDirectory: true)?.holders == [xcode, git])
}

@Test func setsWithoutHoldersStillReportUse() {
    #expect(OpenFileSet(paths: ["/a/b"]).use(of: "/a", isDirectory: true) == OpenUse(holders: [], onlyInside: true))
}
