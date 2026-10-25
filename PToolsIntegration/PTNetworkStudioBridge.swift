// Copy this file into PooToolsSource/DebugNetwork/ in PTools 5.69.0.
// It compiles in the same module as PTNetworkCaptureStore/Record; no UIKit import.
// Opt-in only. Never ship a hardcoded pairing token in a production binary.
import Foundation
import Security
import CryptoKit

@available(iOS 17.0, *)
public actor PTNetworkStudioBridge {
    public static let shared = PTNetworkStudioBridge()

    private var worker: Task<Void, Never>?
    private var session: URLSession?
    private var destination: URL?
    private var token: String?
    private var delegate: CertificatePinningDelegate?

    public func start(macAddress: String, port: UInt16 = 9443, pairingToken: String,
                      certificateSHA256: String) throws {
        guard !macAddress.isEmpty, !macAddress.contains("/"), !macAddress.contains(":"),
              pairingToken.count >= 20, certificateSHA256.count == 64 else {
            throw URLError(.badURL)
        }
        stop()
        guard let url = URL(string: "https://\(macAddress):\(port)/v1/capture") else { throw URLError(.badURL) }
        let delegate = CertificatePinningDelegate(pin: certificateSHA256)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.destination = url
        self.token = pairingToken
        worker = Task { [weak self] in
            guard let self else { return }
            // Snapshot: do not miss requests that completed before the stream was attached.
            for record in await PTNetworkCaptureStore.shared.records() {
                if Task.isCancelled { return }
                await self.transmit(record)
            }
            let events = await PTNetworkCaptureStore.shared.changes()
            for await change in events {
                if Task.isCancelled { return }
                switch change {
                case let .inserted(id), let .updated(id):
                    if let record = await PTNetworkCaptureStore.shared.record(id: id) {
                        await self.transmit(record)
                    }
                case .removed, .reset: break
                }
            }
        }
    }

    public func stop() {
        worker?.cancel()
        worker = nil
        session?.invalidateAndCancel()
        session = nil
        destination = nil
        delegate = nil
        token = nil
    }

    private func transmit(_ record: PTNetworkCaptureRecord) async {
        guard let url = destination, let token, let session, !Task.isCancelled else { return }
        let safe = record.redacted()
        let requestBody = Self.safeJSON(safe.request.body.previewData)
        let responseBody = Self.safeJSON(safe.response?.body.previewData)
        let entry = PTNetworkStudioWireEntry(id: safe.id, startedAt: safe.request.startedAt,
            method: safe.request.method, url: safe.request.url.absoluteString,
            host: safe.request.url.host ?? "", source: "PTools Live", status: safe.response?.statusCode,
            duration: safe.timing.duration, requestHeaders: safe.request.headers,
            responseHeaders: safe.response?.headers ?? [:], requestBody: requestBody,
            responseBody: responseBody,
            responseSize: max(0, Int(safe.response?.body.totalBytes ?? 0)),
            error: safe.error?.description)
        guard let body = try? JSONEncoder().encode(PTStudioEnvelope(entry: entry)) else { return }
        // Suppress PTools URLProtocol's internal instrumentation for bridge traffic;
        // otherwise bridge POSTs could recursively generate new capture events.
        // Matches the 5.69.0 PTCustomHTTPProtocol requestProperty key.
        let mutable = NSMutableURLRequest(url: url)
        URLProtocol.setProperty(true, forKey: "com.custom.http.protocol", in: mutable)
        var request = mutable as URLRequest
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        // This is diagnostic, best-effort telemetry. It never alters the business request.
        _ = try? await session.data(for: request)
    }

    private static func safeJSON(_ data: Data?) -> String {
        guard let data, data.count <= 65_536,
              let obj = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(obj),
              let safeData = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let result = String(data: safeData, encoding: .utf8) else { return "[body withheld]" }
        return result
    }
}

private struct PTStudioEnvelope: Encodable {
    let entry: PTNetworkStudioWireEntry
}

private struct PTNetworkStudioWireEntry: Codable {
    let id: UUID
    let startedAt: Date
    let method: String
    let url: String
    let host: String
    let source: String
    let status: Int?
    let duration: Double?
    let requestHeaders: [String: String]
    let responseHeaders: [String: String]
    let requestBody: String
    let responseBody: String
    let responseSize: Int
    let error: String?
}

private final class CertificatePinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let pin: String
    init(pin: String) { self.pin = pin.lowercased() }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = SecTrustGetCertificateAtIndex(trust, 0) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        if digest == pin {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
