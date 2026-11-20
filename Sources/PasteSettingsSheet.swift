import SwiftUI

struct PasteSettingsSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 14) {
            Text("Paste Settings").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Geometry").font(.subheadline).foregroundStyle(.secondary)
                Toggle("Rotation, flip and straighten", isOn: $model.pasteOptions.orientation)
                Toggle("Crop", isOn: $model.pasteOptions.crop)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Inversion").font(.subheadline).foregroundStyle(.secondary)
                Toggle("Film base area (each frame measures its own base)", isOn: $model.pasteOptions.baseArea)
                Toggle("Range and density points (Auto stays Auto)", isOn: $model.pasteOptions.inversion)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Tone").font(.subheadline).foregroundStyle(.secondary)
                Toggle("Exposure", isOn: $model.pasteOptions.exposure)
                Toggle("White balance", isOn: $model.pasteOptions.whiteBalance)
                Toggle("Paper (print curve)", isOn: $model.pasteOptions.paper)
                Toggle("Levels", isOn: $model.pasteOptions.levels)
                Toggle("Curves", isOn: $model.pasteOptions.curves)
                Toggle("Saturation and vibrance", isOn: $model.pasteOptions.presence)
                Toggle("Colour mixer", isOn: $model.pasteOptions.colorMix)
                Toggle("Sharpening", isOn: $model.pasteOptions.sharpen)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Shooting data").font(.subheadline).foregroundStyle(.secondary)
                Toggle("Lens, aperture, shutter, focal length", isOn: $model.pasteOptions.shootingData)
            }

            HStack {
                Button("Cancel", role: .cancel) { model.isPasteSheetShown = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Paste to All \(model.files.count) Frames") { model.pasteSettings(toAll: true) }
                Button("Paste") { model.pasteSettings(toAll: false) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 420)
    }
}
