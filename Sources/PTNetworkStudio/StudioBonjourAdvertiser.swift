import Foundation

/// Bonjour only advertises a rendezvous hint. The pairing token and leaf pin
/// are intentionally never placed in the service name or TXT record.
final class StudioBonjourAdvertiser: NSObject, NetServiceDelegate {
    static let serviceType = "_ptstudio._tcp."

    /// Use a stable .local hostname so address changes do not rotate the TLS
    /// leaf certificate. The developer can override this in Bridge settings.
    static var defaultHost: String {
        let raw = ProcessInfo.processInfo.hostName
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let component = raw.split(separator: ".").first.map(String.init) ?? "localhost"
        if raw.lowercased().hasSuffix(".local") { return raw }
        return component + ".local"
    }

    /// A per-installation public identifier; it is not an authentication key.
    static var installationID: String {
        let key = "PTNetworkStudio.BonjourInstallationID"
        if let existing = UserDefaults.standard.string(forKey: key),
           UUID(uuidString: existing) != nil { return existing.lowercased() }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    private let service: NetService
    var onFailure: ((String) -> Void)?

    init(port: Int, tlsHost: String) {
        let name = "PTNetworkStudio-" + Self.installationID
        service = NetService(domain: "local.", type: Self.serviceType,
                             name: name, port: Int32(port))
        super.init()
        service.delegate = self
        let txt = ["v": Data("1".utf8),
                   "id": Data(Self.installationID.utf8),
                   "host": Data(tlsHost.utf8)]
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
    }

    func start() { service.publish() }
    func stop() { service.stop(); service.delegate = nil }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        onFailure?("Bonjour advertisement failed: \(errorDict)")
    }
}
