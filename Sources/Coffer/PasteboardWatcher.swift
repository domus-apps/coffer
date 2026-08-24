import AppKit

/* NSPasteboard offers no change notifications, so every clipboard manager
   polls `changeCount` — cheap enough that a short interval is standard. */
final class PasteboardWatcher {
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private let pasteboard = NSPasteboard.general
    private var changeCount: Int
    private var timer: Timer?
    private let onCopy: (String) -> Void

    init(onCopy: @escaping (String) -> Void) {
        self.onCopy = onCopy
        changeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.poll()
        }
        /* .common keeps polling alive while menus and panels run the
           run loop in a tracking mode. */
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        /* Password managers mark secrets with the de facto standard
           concealed type; a clipboard history must not retain those. */
        if pasteboard.types?.contains(Self.concealed) == true { return }
        guard let string = pasteboard.string(forType: .string), !string.isEmpty else { return }
        onCopy(string)
    }
}
