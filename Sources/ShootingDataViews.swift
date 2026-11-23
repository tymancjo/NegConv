import SwiftUI

/// Roll-level shooting data (⌘I). Written into every exported frame of the roll.
struct RollInfoSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            Text("Roll Info").font(.headline).padding([.horizontal, .top], 20)
            Text("What was shot — written into the exports (EXIF / IPTC). The scan camera is not.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.top, 2)

            Form {
                RollMetadataSections(meta: $model.rollMeta)
            }
            .formStyle(.grouped)

            HStack {
                Text(model.rollMeta.isEmpty ? "Nothing set yet" : summary)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Done") { model.isRollInfoShown = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 460, height: 640)
    }

    private var summary: String {
        [model.rollMeta.cameraSummary, model.rollMeta.filmSummary].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The roll-level fields (camera, film, when & where, credits, notes) — used by the Roll Info
/// sheet and by the Retag window.
struct RollMetadataSections: View {
    @Binding var meta: RollMetadata

    var body: some View {
        Section("Camera") {
            TextField("Make", text: $meta.cameraMake, prompt: Text("Nikon"))
            TextField("Model", text: $meta.cameraModel, prompt: Text("FM2"))
            TextField("Lens", text: $meta.lens, prompt: Text("Nikkor 50mm f/1.4 AI-S"))
            TextField("Focal length (mm)", value: $meta.focalLength, format: .number,
                      prompt: Text("50"))
        }
        Section("Film") {
            TextField("Film stock", text: $meta.filmStock, prompt: Text("Kodak Portra 400"))
            TextField("Format", text: $meta.filmFormat, prompt: Text("35mm"))
            TextField("Box ISO", value: $meta.boxISO, format: .number.grouping(.never),
                      prompt: Text("400"))
            TextField("Shot at EI", value: $meta.exposureIndex, format: .number.grouping(.never),
                      prompt: Text("same as box"))
            TextField("Development", text: $meta.development,
                      prompt: Text("C-41, home, Tetenal kit"))
        }
        Section("When & where") {
            OptionalDatePicker(title: "Date shot", date: $meta.date, components: .date)
            TextField("Location", text: $meta.location, prompt: Text("Kraków"))
        }
        Section("Credits") {
            TextField("Photographer", text: $meta.photographer)
            TextField("Copyright", text: $meta.copyright, prompt: Text("© 2026 …"))
        }
        Section("Notes") {
            TextField("Keywords", text: $meta.keywords, prompt: Text("comma, separated"))
            TextField("Roll notes", text: $meta.notes, axis: .vertical)
                .lineLimit(2...4)
        }
    }
}

/// Per-frame shooting data; empty fields fall back to the roll (shown as placeholders).
struct ShootingDataSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let roll = model.rollMeta
        Section {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(roll.cameraSummary.isEmpty ? "No roll info" : roll.cameraSummary)
                    if !roll.filmSummary.isEmpty {
                        Text(roll.filmSummary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Roll Info…") { model.isRollInfoShown = true }
                    .help("Camera, film, ISO, development, date, credits for the whole roll (⌘I)")
            }

            OptionalDatePicker(title: "Date & time", date: $model.recipe.meta.date,
                               components: [.date, .hourAndMinute],
                               fallback: roll.date.map { $0.formatted(date: .abbreviated, time: .omitted) })
            TextField("Aperture  f/", value: $model.recipe.meta.aperture, format: .number,
                      prompt: Text("8"))
            TextField("Shutter", text: $model.recipe.meta.shutter, prompt: Text("1/125"))
            if !model.recipe.meta.shutter.isEmpty, model.recipe.meta.exposureTime == nil {
                Text("Use 1/125, 1/2, 2 or 2s").font(.caption).foregroundStyle(.orange)
            }
            TextField("Lens", text: $model.recipe.meta.lens,
                      prompt: Text(roll.lens.isEmpty ? "roll lens" : roll.lens))
            TextField("Focal length (mm)", value: $model.recipe.meta.focalLength, format: .number,
                      prompt: Text(roll.focalLength.map { "\(Int($0))" } ?? "mm"))
            TextField("Caption", text: $model.recipe.meta.caption, axis: .vertical)
                .lineLimit(1...3)
        } header: {
            Text("Shooting Data")
        } footer: {
            Text("Written into the export instead of the scan's EXIF. Empty fields use the roll info. Paste copies lens, aperture, shutter and focal length if chosen.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A date that may be unset: a checkbox enables the picker.
struct OptionalDatePicker: View {
    let title: String
    @Binding var date: Date?
    var components: DatePickerComponents
    /// Shown greyed out while unset (e.g. the roll value it falls back to).
    var fallback: String? = nil

    var body: some View {
        HStack {
            Toggle(title, isOn: Binding(get: { date != nil },
                                        set: { date = $0 ? (date ?? Date()) : nil }))
            Spacer()
            if let d = date {
                DatePicker("", selection: Binding(get: { d }, set: { date = $0 }),
                           displayedComponents: components)
                    .labelsHidden()
                    .datePickerStyle(.field)
            } else if let fallback {
                Text(fallback).foregroundStyle(.secondary)
            }
        }
    }
}
