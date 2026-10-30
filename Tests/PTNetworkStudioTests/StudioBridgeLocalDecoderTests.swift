import Foundation
import XCTest
@testable import PTNetworkStudio

final class StudioBridgeLocalDecoderTests: XCTestCase {
    private func dictionary(_ entry: CaptureEntry) throws -> [String: Any] {
        let data = try JSONEncoder().encode(entry)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testLegacyEntryAndBoundedBatchPreserveOrderAndIdentity() throws {
        let entries = (0..<24).map { i in
            CaptureEntry(method: "GET", url: "https://example.test/\(i)",
                         host: "example.test", status: 200)
        }
        let objects = try entries.map(dictionary)
        let batch = StudioBridgeLocalDecoder.entries(from: [
            "type": "entryBatch", "entries": objects
        ])
        XCTAssertEqual(batch.map(\.id), entries.map(\.id))
        XCTAssertEqual(batch.map(\.url), entries.map(\.url))
        let single = StudioBridgeLocalDecoder.entries(from: [
            "type": "entry", "entry": objects[0]
        ])
        XCTAssertEqual(single.map(\.id), [entries[0].id])
    }

    func testMalformedOversizeAndControlMessagesAreNotDecodedAsNetworkEntries() throws {
        let sample = try dictionary(CaptureEntry(
            method: "GET", url: "https://example.test", host: "example.test"))
        XCTAssertTrue(StudioBridgeLocalDecoder.entries(from: [
            "type": "entryBatch", "entries": Array(repeating: sample, count: 25)
        ]).isEmpty)
        XCTAssertTrue(StudioBridgeLocalDecoder.entries(from: [
            "type": "entryBatch", "entries": []
        ]).isEmpty)
        XCTAssertTrue(StudioBridgeLocalDecoder.entries(from: [
            "type": "entry", "entry": ["bad": true]
        ]).isEmpty)
        XCTAssertTrue(StudioBridgeLocalDecoder.entries(from: [
            "type": "bridgeReset", "sessionID": UUID().uuidString
        ]).isEmpty)
    }
}
