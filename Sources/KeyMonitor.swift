import AppKit

/// App-local keyboard/scroll monitor for the loupe (hold Z or Option), tap-Z 1:1 toggle and
/// scroll-to-zoom. SwiftUI's key handling needs focus; this works wherever the cursor is.
@MainActor
final class KeyMonitor {
    private var monitor: Any?

    func start(_ model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged, .scrollWheel, .magnify]
        ) { [weak model] event in
            guard let model else { return event }
            // Local monitors are always called on the main thread.
            let consumed = MainActor.assumeIsolated { model.handle(event) }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
