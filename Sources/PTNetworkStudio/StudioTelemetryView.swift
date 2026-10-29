import SwiftUI
import Charts

/// Read-only logs and metrics; host explicitly opts into categories and sampling.
@MainActor
struct StudioTelemetryView: View {
    enum Domain: String { case logging, performance }
    let domain: Domain
    @ObservedObject var bridge: StudioBridgeController
    @ObservedObject var diagnostics: StudioDiagnosticStore
    @State private var filter = ""

    private var entries: [StudioDiagnosticEntry] {
        let rows = diagnostics.latest[domain.rawValue + ".list"] ?? []
        guard !filter.isEmpty else { return rows }
        return rows.filter {
            $0.name.localizedCaseInsensitiveContains(filter) ||
            ($0.detail ?? "").localizedCaseInsensitiveContains(filter)
        }
    }

    private var points: [MetricPoint] {
        entries.compactMap { row -> MetricPoint? in
            guard let raw = row.attributes["value"], let value = Double(raw), value.isFinite,
                  let time = Double(row.attributes["timestamp"]) else { return nil }
            return MetricPoint(id: row.id, name: row.name, value: value, time: time)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(domain == .logging ? "Console" : "Performance").font(.title2.bold())
                Spacer()
                TextField("Search", text: $filter)
                    .textFieldStyle(.roundedBorder).frame(width: 235)
                Button("Refresh") {
                    diagnostics.request(domain.rawValue, operation: "list", bridge: bridge)
                }.disabled(bridge.diagnosticSessions.isEmpty)
            }.padding(14)
            Divider()
            if domain == .performance && !points.isEmpty {
                Chart(points) { point in
                    LineMark(x: .value("Time", Date(timeIntervalSince1970: point.time)),
                             y: .value("Value", point.value),
                             series: .value("Metric", point.name))
                    .interpolationMethod(.linear)
                }
                .chartXAxisLabel("Captured time")
                .frame(height: 210)
                .padding()
                Divider()
            }
            if entries.isEmpty {
                ContentUnavailableView(
                    domain == .logging ? "No approved logs" : "No metric samples",
                    systemImage: domain == .logging ? "terminal" : "chart.xyaxis.line",
                    description: Text("Enable diagnostics in the iOS Debug host, then refresh. No monitoring starts automatically.")
                )
            } else {
                List(entries) { row in
                    HStack(alignment: .top, spacing: 12) {
                        Text(row.name).font(.caption.monospaced()).frame(width: 140, alignment: .leading)
                        Text(row.detail ?? row.attributes["value"] ?? "")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        if let timestamp = Double(row.attributes["timestamp"] ?? "") {
                            Text(Date(timeIntervalSince1970: timestamp), style: .time)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let error = diagnostics.lastError {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
    }

    private struct MetricPoint: Identifiable {
        var id: String
        var name: String
        var value: Double
        var time: Double
    }
}
