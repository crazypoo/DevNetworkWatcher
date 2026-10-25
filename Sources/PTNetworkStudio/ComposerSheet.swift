import SwiftUI
import Foundation

struct ComposerSheet: View {
    @EnvironmentObject private var store: CaptureStore
    @Environment(\.dismiss) private var dismiss
    @State private var method = "GET"
    @State private var url = "https://httpbin.org/get"
    @State private var requestBody = ""
    @State private var contentType = "application/json"
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Compose Request").font(.title2.bold())
            HStack {
                Picker("Method", selection: $method) {
                    ForEach(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"], id: \.self) { Text($0) }
                }.frame(width: 145)
                TextField("Request URL", text: $url).textFieldStyle(.roundedBorder)
            }
            TextField("Content-Type", text: $contentType).textFieldStyle(.roundedBorder)
            Text("Body").font(.caption.weight(.semibold))
            TextEditor(text: $requestBody).font(.system(.body, design: .monospaced))
                .frame(minHeight: 175)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Text("Composer uses URLSession directly and records its own result. It does not modify traffic captured from other apps.")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(busy ? "Sending…" : "Send") { send() }
                    .disabled(busy).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 700, height: 450)
    }

    private func send() {
        guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else {
            errorMessage = "Enter an absolute http:// or https:// URL"
            return
        }
        var request = URLRequest(url: parsed)
        request.httpMethod = method
        request.timeoutInterval = 25
        if !requestBody.isEmpty && !["GET", "HEAD"].contains(method) {
            request.httpBody = Data(requestBody.utf8)
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        busy = true
        errorMessage = nil
        let started = Date()
        let finalRequest = request
        URLSession.shared.dataTask(with: request) { data, response, error in
            Task { @MainActor in
                store.appendManual(finalRequest, startedAt: started, data: data, response: response, error: error)
                busy = false
                dismiss()
            }
        }.resume()
    }
}
