import Testing
@testable import MacSpaceCore

@Test func packageBuilds() { #expect(MacSpaceCore.version == "0.1.0") }
