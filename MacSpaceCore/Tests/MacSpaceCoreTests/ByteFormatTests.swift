import Foundation
import Testing
@testable import MacSpaceCore

@Test func byteFormatMatchesPlanOne() {
    #expect(ByteFormat.string(0) == "0 byte")
    #expect(ByteFormat.string(142_870_000_000).hasPrefix("142,87"))
    #expect(ByteFormat.string(850_500_000).hasPrefix("850,5"))
}

@Test func byteFormatPadsDecimalsPerUnit() {
    // `.file` style drops trailing zeros; sizes keep a fixed number of decimals per unit.
    #expect(ByteFormat.string(2_700_000_000) == "2,70 GB")
    #expect(ByteFormat.string(3_000_000_000) == "3,00 GB")
    #expect(ByteFormat.string(12_000_000) == "12,0 MB")
    #expect(ByteFormat.string(512) == "512 byte")
}
