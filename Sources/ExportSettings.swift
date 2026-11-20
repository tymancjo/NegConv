import Foundation
import SwiftUI

/// User's export choices; persisted in UserDefaults.
struct ExportSettings: Codable, Equatable {
    enum Format: String, Codable, CaseIterable, Identifiable {
        case tiff16, jpeg
        var id: String { rawValue }
        var label: String {
            switch self {
            case .tiff16: return "TIFF 16-bit · Adobe RGB"
            case .jpeg: return "JPEG 8-bit · sRGB"
            }
        }
        var fileExtension: String { self == .jpeg ? "jpg" : "tif" }
    }

    var format: Format = .tiff16
    /// 0…1, JPEG only.
    var jpegQuality: Double = 0.9
    /// Long edge in pixels; 0 = full resolution.
    var maxLongEdge: Int = 0

    static let longEdgeChoices: [Int] = [0, 6000, 4000, 3000, 2048, 1600]

    private static let key = "NegConv.exportSettings"

    static func load() -> ExportSettings {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(ExportSettings.self, from: d) else { return ExportSettings() }
        return s
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    var summary: String {
        var s = format == .jpeg ? "JPEG \(Int(jpegQuality * 100))" : "TIFF 16-bit"
        s += maxLongEdge > 0 ? " · \(maxLongEdge) px" : " · full size"
        return s
    }
}

struct ExportSettingsSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 14) {
            Text("Export Settings").font(.headline)

            Picker("Format", selection: $model.exportSettings.format) {
                ForEach(ExportSettings.Format.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)

            if model.exportSettings.format == .jpeg {
                HStack {
                    Text("Quality")
                    Slider(value: $model.exportSettings.jpegQuality, in: 0.5...1.0, step: 0.01)
                    Text("\(Int(model.exportSettings.jpegQuality * 100))")
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                }
            }

            Picker("Size", selection: $model.exportSettings.maxLongEdge) {
                ForEach(ExportSettings.longEdgeChoices, id: \.self) { e in
                    Text(e == 0 ? "Full resolution" : "Long edge \(e) px").tag(e)
                }
            }

            Text(model.exportSettings.format == .jpeg
                 ? "sRGB, 8-bit: ready for web, phones and sharing. Keep TIFF for printing or further editing."
                 : "Adobe RGB, 16-bit, uncompressed: the master file for printing and further editing.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Done") { model.isExportSettingsShown = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
