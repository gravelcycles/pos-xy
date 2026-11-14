import SwiftUI

struct ExportView: View {
    enum Span: String, CaseIterable, Identifiable {
        case today = "Today", week = "Last 7 days", month = "Last 30 days", all = "Everything", custom = "Custom…"
        var id: String { rawValue }
    }

    struct ExportResult {
        let url: URL
        let points: Int
        let bytes: Int
    }

    @State private var span: Span = .week
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var encrypt = true
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var result: ExportResult?
    @State private var errorText: String?

    nonisolated private static var exportDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
    }

    private static let lastExportKey = "export.lastCreated"
    /// When an export file was last created (shown as a backup reminder).
    static var lastExport: Date? { UserDefaults.standard.object(forKey: lastExportKey) as? Date }

    /// Exports are temporary copies; clean them up on launch.
    nonisolated static func removeOldExports() {
        try? FileManager.default.removeItem(at: exportDir)
    }

    var body: some View {
        Form {
            Section("What to export") {
                Picker("Range", selection: $span) {
                    ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
                }
                if span == .custom {
                    DatePicker("From", selection: $from, displayedComponents: .date)
                    DatePicker("To", selection: $to, displayedComponents: .date)
                }
            }

            Section {
                Toggle("Lock with a passphrase", isOn: $encrypt)
                if encrypt {
                    SecureField("Passphrase (6+ characters)", text: $passphrase)
                    SecureField("Repeat passphrase", text: $confirm)
                    if !confirm.isEmpty && confirm != passphrase {
                        Text("Passphrases don't match").font(.footnote).foregroundStyle(.red)
                    }
                }
            } footer: {
                Text(encrypt
                     ? "Encrypted with AES-256-GCM using a key derived from your passphrase. The Mac viewer asks for it. A forgotten passphrase can't be recovered."
                     : "The file will be plain JSON. Anyone who gets it can read your history.")
            }

            Section {
                Button {
                    Task { await makeFile() }
                } label: {
                    HStack {
                        Text("Create export file")
                        Spacer()
                        if working { ProgressView() }
                    }
                }
                .disabled(!canExport || working)
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                }
            }

            if let result {
                Section {
                    LabeledContent("Points", value: "\(result.points)")
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(result.bytes), countStyle: .file))
                    ShareLink(item: result.url) {
                        Label("Send via AirDrop…", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text(result.url.lastPathComponent)
                } footer: {
                    Text("Pick your Mac in the share sheet. The file lands in Downloads. Open it with Pos XY Viewer.")
                }
            }
        }
        .navigationTitle("Export")
        .onChange(of: span) { _, _ in result = nil }
        .onChange(of: encrypt) { _, _ in result = nil }
        .onChange(of: passphrase) { _, _ in result = nil }
        .onChange(of: from) { _, _ in result = nil }
        .onChange(of: to) { _, _ in result = nil }
    }

    private var canExport: Bool {
        !encrypt || (passphrase.count >= 6 && passphrase == confirm)
    }

    private func bounds() -> (Date, Date) {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        switch span {
        case .today: return (today, now)
        case .week: return (cal.date(byAdding: .day, value: -6, to: today) ?? today, now)
        case .month: return (cal.date(byAdding: .day, value: -29, to: today) ?? today, now)
        case .all: return (.distantPast, .distantFuture)
        case .custom:
            let a = cal.startOfDay(for: min(from, to))
            let b = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(from, to))) ?? now
            return (a, b.addingTimeInterval(-0.001))
        }
    }

    @MainActor
    private func makeFile() async {
        working = true
        errorText = nil
        result = nil
        let (start, end) = bounds()
        let pass: String? = encrypt ? passphrase : nil
        let dir = Self.exportDir
        do {
            result = try await Task.detached(priority: .userInitiated) { () throws -> ExportResult in
                let points = PointStore.shared.points(from: start, to: end)
                guard let first = points.first, let last = points.last else { throw ExportError.nothingToExport }
                let motion = MotionStore.shared.spans(from: min(start, first.t), to: max(end == .distantFuture ? last.t : end, last.t))
                let json = try ExportCodec.makeJSON(points, motion: motion)
                let data: Data
                let ext: String
                if let pass {
                    data = try ExportCodec.encrypt(json, passphrase: pass)
                    ext = "pxy"
                } else {
                    data = json
                    ext = "json"
                }
                let a = PointStore.dayKey(first.t), b = PointStore.dayKey(last.t)
                let name = a == b ? "PosXY \(a)" : "PosXY \(a) to \(b)"
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent("\(name).\(ext)")
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                return ExportResult(url: url, points: points.count, bytes: data.count)
            }.value
            UserDefaults.standard.set(Date(), forKey: Self.lastExportKey)
        } catch {
            errorText = error.localizedDescription
        }
        working = false
    }
}
