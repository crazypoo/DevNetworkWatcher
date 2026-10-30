import XCTest
import Combine
@testable import PTNetworkStudio

@MainActor
final class StudioCapturePerformanceTests: XCTestCase {
    func testThousandRequestsAreBoundedAndIndexed() async throws {
        let store = CaptureStore()
        for i in 0..<1_100 {
            let entry = CaptureEntry(method: "GET", url: "https://host\(i % 8).test/",
                                     host: "host\(i % 8).test")
            store.upsert(entry)
        }
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(store.entries.count, 1_000)
        XCTAssertEqual(store.statistics.hosts.reduce(0) { $0 + $1.count }, 1_000)
        XCTAssertEqual(store.statistics.httpsCount, 1_000)
        for entry in store.entries {
            XCTAssertEqual(store.entry(id: entry.id)?.id, entry.id)
        }
    }

    func testLatestUpdateWinsAndRemovalIsScopedToLiveTraffic() async throws {
        let store = CaptureStore()
        var live = CaptureEntry(method: "GET", url: "https://test.dev/a", host: "test.dev")
        live.source = "PTools Live"
        let proxied = CaptureEntry(method: "GET", url: "http://test.dev/b", host: "test.dev")
        store.upsert(live)
        store.upsert(proxied)
        live.status = 503
        store.upsert(live)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(store.entry(id: live.id)?.status, 503)
        XCTAssertEqual(store.statistics.errorCount, 1)
        store.removeLiveRequest(live.id)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertNil(store.entry(id: live.id))
        XCTAssertNotNil(store.entry(id: proxied.id))
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.statistics.hosts.isEmpty)
    }

    func testBurstPublishesOneCaptureSnapshotWithMatchingStatistics() async throws {
        let store = CaptureStore()
        var publishedSnapshots = 0
        let subscription = store.$entries.dropFirst().sink { snapshot in
            publishedSnapshots += 1
            XCTAssertEqual(store.statistics.httpsCount, snapshot.count)
        }
        for index in 0..<500 {
            store.add(CaptureEntry(method: "GET",
                url: "https://server\(index % 5).example/api",
                host: "server\(index % 5).example"))
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(publishedSnapshots, 1)
        XCTAssertEqual(store.entries.count, 500)
        XCTAssertEqual(store.statistics.hosts.reduce(0) { $0 + $1.count }, 500)
        withExtendedLifetime(subscription) {}
    }

    func testConnectTunnelsAreCountedInHTTPSStatistics() async throws {
        let store = CaptureStore()
        store.add(CaptureEntry(method: "CONNECT", url: "example.net:443",
                               host: "example.net"))
        store.add(CaptureEntry(method: "GET", url: "https://example.net/a",
                               host: "example.net"))
        store.add(CaptureEntry(method: "GET", url: "http://example.net/b",
                               host: "example.net"))
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(store.statistics.httpsCount, 2)
        XCTAssertEqual(store.statistics.httpCount, 1)
        XCTAssertEqual(store.statistics.hosts.first?.count, 3)
    }

    func testClearCancelsPendingBatchWithoutGhostRows() async throws {
        let store = CaptureStore()
        store.add(CaptureEntry(method: "GET", url: "https://test.dev/", host: "test.dev"))
        store.clear()
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(store.entries.count, 0)
    }
}
