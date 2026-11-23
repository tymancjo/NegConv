import SwiftUI

@main
struct NegConvApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About NegConv") { AboutPanel.show() }
            }
            CommandGroup(replacing: .help) {
                HelpMenuButton()
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Roll Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                Divider()
                Button("Export Frame — \(model.exportSettings.summary)") { model.exportCurrentFrame() }
                    .keyboardShortcut("e")
                    .disabled(model.isExporting || model.selection == nil)
                Button("Export Roll — \(model.exportSettings.summary)") { model.exportRoll() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.isExporting || model.files.isEmpty)
                Button("Roll Info…") { model.isRollInfoShown = true }
                    .keyboardShortcut("i")
                    .disabled(model.folderURL == nil)
                Button("Export Settings…") { model.isExportSettingsShown = true }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                Button("Show Exports in Finder") { model.revealExports() }
                    .disabled(model.lastExportFolder == nil)
                Divider()
                RetagMenuButton()
            }
            CommandGroup(before: .sidebar) {
                // Bare G / E are handled by the key monitor (not while typing in a field).
                Button("Grid (G)") { model.viewMode = .grid }
                    .disabled(model.files.isEmpty || model.viewMode == .grid)
                Button("Loupe (E)") { model.viewMode = .loupe }
                    .disabled(model.viewMode == .loupe)
                Divider()
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Copy Settings") { model.copySettings() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.selection == nil)
                Button("Paste Settings…") { model.showPasteSheet() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(model.clipboard == nil)
            }
            CommandMenu("Image") {
                Button("Rotate Left") { model.rotateCounterClockwise() }
                    .keyboardShortcut("[")
                Button("Rotate Right") { model.rotateClockwise() }
                    .keyboardShortcut("]")
                Button("Flip Horizontal") { model.toggleFlip() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Divider()
                Button(model.tool == .crop ? "Finish Crop" : "Crop") { model.toggleTool(.crop) }
                    .keyboardShortcut("k")
                Button("Straighten (Draw Line)") { model.toggleTool(.straighten) }
                    .keyboardShortcut("l")
                Button("Reset Crop") { model.resetCrop() }
                Button("Reset Geometry") { model.resetGeometry() }
                Divider()
                Button(model.actualSize ? "Zoom to Fit" : "Actual Size (100 %)") { model.toggleActualSize() }
                    .keyboardShortcut("1")
                Divider()
                Button("Sample Film Base") { model.toggleTool(.sampleBase) }
                    .keyboardShortcut("b")
                Button("Remove Spots") { model.toggleTool(.spot) }
                    .keyboardShortcut("j")
                Button("Colour Mixer Picker") { model.toggleTool(.colorPick) }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                Button("White Balance Picker") { model.toggleTool(.whiteBalance) }
                    .keyboardShortcut("w", modifiers: [.command, .option])
                Button(model.showNegative ? "Show Positive" : "Show Negative") { model.showNegative.toggle() }
                    .keyboardShortcut("\\")
                Button(model.showClipping ? "Hide Clipping (J)" : "Show Clipping (J)") { model.showClipping.toggle() }
                Divider()
                Button("Set as Reference Frame (⇧R)") { model.setReference() }
                    .disabled(model.selection == nil)
                Button(model.referenceSideBySide ? "Hide Reference" : "Show Reference Side by Side") {
                    model.referenceSideBySide.toggle()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(model.referenceURL == nil)
                Button("Match White Balance to Reference") { model.matchWhiteBalanceToReference() }
                    .keyboardShortcut("w", modifiers: [.command, .option, .shift])
                    .disabled(!model.canMatchReference)
                Button("Clear Reference") { model.clearReference() }
                    .disabled(model.referenceURL == nil)
                Divider()
                Button("Exit Tool") { model.tool = .none }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(model.tool == .none)
            }
        }

        Window(RetagWindow.title, id: RetagWindow.id) {
            RetagView()
        }
        .defaultSize(width: 1320, height: 780)

        Window(HelpWindow.title, id: HelpWindow.id) {
            HelpView()
        }
        .defaultSize(width: 820, height: 640)
    }
}
