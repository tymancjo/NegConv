import Foundation

/// `<name>.NEF.negconv.json` next to each NEF: the frame's recipe plus the roll decode settings
/// it was made with (the measured film base depends on them).
struct SidecarFile: Codable {
    var app = "NegConv"
    var version = 1
    var decode: DecodeSettings
    var recipe: EditRecipe
}

enum Sidecar {
    static func url(for nef: URL) -> URL {
        nef.appendingPathExtension("negconv.json")
    }

    static func load(for nef: URL) -> SidecarFile? {
        guard let data = try? Data(contentsOf: url(for: nef)) else { return nil }
        return try? JSONDecoder().decode(SidecarFile.self, from: data)
    }

    static func save(_ file: SidecarFile, for nef: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(file).write(to: url(for: nef), options: .atomic)
    }
}
