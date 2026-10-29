import Foundation
import XCTest
@testable import PTNetworkStudio

final class StudioBonjourAdvertiserTests: XCTestCase {
    func testRendezvousDefaultsAndStableInstallationID() {
        XCTAssertEqual(StudioBonjourAdvertiser.serviceType, "_ptstudio._tcp.")
        let first = StudioBonjourAdvertiser.installationID
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(StudioBonjourAdvertiser.installationID, first)
        XCTAssertTrue(StudioBonjourAdvertiser.defaultHost.hasSuffix(".local"))
    }
}
