import XCTest
@testable import MacScope

final class DiagnosticLogicTests: XCTestCase {
    func testPercentRejectsInvalidValues() {
        for value in [Double.nan, .infinity, -.infinity, -1, 101] { XCTAssertNil(DiagnosticLogic.percent(value)) }
        XCTAssertNil(DiagnosticLogic.percent(nil))
        XCTAssertEqual(DiagnosticLogic.percent(0), 0)
        XCTAssertEqual(DiagnosticLogic.percent(100), 100)
    }
    func testRatioNormalizesAndRejectsMissingOrInvalidData() {
        XCTAssertEqual(DiagnosticLogic.ratio(40, 80), 50)
        XCTAssertNil(DiagnosticLogic.ratio(1, 0))
        XCTAssertNil(DiagnosticLogic.ratio(nil, 1))
        XCTAssertNil(DiagnosticLogic.ratio(1, nil))
        XCTAssertNil(DiagnosticLogic.ratio(-1, 10))
        XCTAssertNil(DiagnosticLogic.ratio(11, 10))
    }
    func testBatteryThresholdBoundaries() {
        XCTAssertEqual(DiagnosticLogic.batteryStatus(nil), .unsupported)
        XCTAssertEqual(DiagnosticLogic.batteryStatus(.nan), .unsupported)
        XCTAssertEqual(DiagnosticLogic.batteryStatus(101), .unsupported)
        XCTAssertEqual(DiagnosticLogic.batteryStatus(100), .good)
        XCTAssertEqual(DiagnosticLogic.batteryStatus(80), .good)
        XCTAssertEqual(DiagnosticLogic.batteryStatus(79.9), .warning)
        XCTAssertEqual(DiagnosticLogic.batteryStatus(60), .warning)
        XCTAssertEqual(DiagnosticLogic.batteryStatus(59.9), .critical)
        XCTAssertEqual(DiagnosticLogic.batteryStatus(0), .critical)
    }
    func testStorageThresholdsAndInvalidCapacities() {
        XCTAssertEqual(DiagnosticLogic.storageStatus(total: 1000, available: 150), .good)
        XCTAssertEqual(DiagnosticLogic.storageStatus(total: 1000, available: 149), .warning)
        XCTAssertEqual(DiagnosticLogic.storageStatus(total: 1000, available: 50), .warning)
        XCTAssertEqual(DiagnosticLogic.storageStatus(total: 1000, available: 49), .critical)
        XCTAssertEqual(DiagnosticLogic.storageStatus(total: 1000, available: 0), .critical)
        XCTAssertEqual(DiagnosticLogic.storageStatus(total: nil, available: 50), .unsupported)
        XCTAssertEqual(DiagnosticLogic.storageStatus(total: 0, available: 0), .unsupported)
        XCTAssertEqual(DiagnosticLogic.storageStatus(total: 1000, available: -1), .unsupported)
        XCTAssertEqual(DiagnosticLogic.storageStatus(total: 1000, available: 1001), .unsupported)
    }
    func testRatesHandleResetsAndFirstSample() {
        XCTAssertEqual(DiagnosticLogic.rate(current: 300, previous: 100, elapsed: 2), 100)
        XCTAssertEqual(DiagnosticLogic.rate(current: 100, previous: 100, elapsed: 2), 0)
        XCTAssertNil(DiagnosticLogic.rate(current: 90, previous: 100, elapsed: 2))
        XCTAssertNil(DiagnosticLogic.rate(current: 300, previous: 100, elapsed: 0))
        XCTAssertNil(DiagnosticLogic.rate(current: 300, previous: 100, elapsed: .infinity))
    }
    func testCommonIdentifiersAreRedacted() {
        let raw = "/Users/alice/Library /home/bob/log 192.168.1.2 aa:bb:cc:dd:ee:ff 12345678-abcd-1234-abcd-123456789012"
        let redacted = DiagnosticLogic.redacted(raw)
        for secret in ["alice", "bob", "192.168.1.2", "aa:bb", "12345678"] { XCTAssertFalse(redacted.contains(secret)) }
        XCTAssertEqual(DiagnosticLogic.redacted("Normal diagnostic text"), "Normal diagnostic text")
    }
    func testMissingBytesAreNotZero() {
        XCTAssertEqual(DiagnosticLogic.bytes(nil), "Unavailable")
        XCTAssertEqual(DiagnosticLogic.bytes(-1), "Unavailable")
        XCTAssertNotEqual(DiagnosticLogic.bytes(0), "Unavailable")
    }
    func testNewTestsAreNotReportedAsPassed() {
        for kind in TestKind.allCases {
            let result = DiagnosticResult(kind: kind)
            XCTAssertEqual(result.state, .notTested)
            XCTAssertNil(result.date)
        }
        XCTAssertEqual(TestKind.allCases.count, 12)
    }
    func testResultRoundTripPreservesEvidence() throws {
        let original = DiagnosticResult(kind: .battery, state: .unsupported, detail: "No internal battery", date: Date(timeIntervalSince1970: 100))
        let decoded = try JSONDecoder().decode(DiagnosticResult.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.kind, original.kind)
        XCTAssertEqual(decoded.state, original.state)
        XCTAssertEqual(decoded.detail, original.detail)
        XCTAssertEqual(decoded.date, original.date)
    }
}
