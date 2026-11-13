import MeterCore
import SwiftUI
import UniformTypeIdentifiers

struct TextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

enum ExportKind { case csv, weekly }

struct ExportView: View {
    let model: AppModel
    @State private var from = Date()
    @State private var to = Date()
    @State private var didInit = false
    @State private var kind: ExportKind = .csv
    @State private var document = TextDocument(text: "")
    @State private var fileName = "meter.csv"
    @State private var exporting = false
    @State private var status: String?

    var body: some View {
        Screen {
            Card("CSV for finance") {
                Text("Every dimension with names, tags and basis. Filter on counts_toward_total for totals. Days are UTC.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    DatePicker("From", selection: $from, displayedComponents: .date)
                    DatePicker("To", selection: $to, displayedComponents: .date)
                    Spacer()
                    Button("Export CSV") { exportCSV() }.buttonStyle(.borderedProminent).disabled(rangeDays == nil)
                }
                if rangeDays == nil { Text("The start date must be on or before the end date.").font(.caption).foregroundStyle(.red) }
            }
            Card("Weekly summary") {
                Text("A markdown summary of the last 7 complete days. Provider-reported cost, with Claude Code estimates listed apart.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Weekly summary…") { exportWeekly() }
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear {
            guard !didInit else { return }
            didInit = true
            let today = UTCDay(model.now)
            from = Self.localDate(today.monthStart)
            to = Self.localDate(today)
        }
        .fileExporter(isPresented: $exporting, document: document,
                      contentType: kind == .csv ? .commaSeparatedText : (UTType(filenameExtension: "md") ?? .plainText),
                      defaultFilename: fileName) { result in
            switch result {
            case .success(let url): status = "Saved \(url.lastPathComponent)"
            case .failure(let e): status = "Could not save: \(e.localizedDescription)"
            }
        }
    }

    private var rangeDays: (UTCDay, UTCDay)? {
        let a = Self.utcDay(from), b = Self.utcDay(to)
        return a <= b ? (a, b) : nil
    }

    private func exportCSV() {
        guard let (a, b) = rangeDays else { return }
        document = TextDocument(text: model.csv(from: a, to: b))
        fileName = model.csvFileName(from: a, to: b)
        kind = .csv
        exporting = true
    }

    private func exportWeekly() {
        document = TextDocument(text: model.weeklySummary())
        fileName = model.weeklyFileName
        kind = .weekly
        exporting = true
    }

    /// A date picker works in local calendar days; Meter's days are UTC. The picked calendar date is kept as is.
    static func utcDay(_ d: Date) -> UTCDay {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return UTCDay(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    static func localDate(_ d: UTCDay) -> Date {
        Calendar.current.date(from: DateComponents(year: d.year, month: d.month, day: d.day)) ?? Date()
    }
}
