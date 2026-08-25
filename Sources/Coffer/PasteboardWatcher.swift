import AppKit

/* NSPasteboard offers no change notifications, so every clipboard manager
   polls `changeCount` — cheap enough that a short interval is standard. */
final class PasteboardWatcher {
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /* Raw image copies above this are dropped rather than retained: a
       history of a few dozen full-size screenshots is one thing, hundreds
       of megabytes of raster data is another. */
    private static let maxImageBytes = 20 * 1024 * 1024

    private let pasteboard = NSPasteboard.general
    private var changeCount: Int
    private var timer: Timer?
    private let onCopy: (ClipboardItem) -> Void

    init(onCopy: @escaping (ClipboardItem) -> Void) {
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

        /* Priority order mirrors what a paste would use: copied files (a
           Finder copy also carries the path as a string) beat raster data
           (image copies often carry both flavors), which beats plain text. */
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !urls.isEmpty
        {
            onCopy(.files(urls))
            return
        }
        if let data = imageData() {
            if data.count <= Self.maxImageBytes {
                onCopy(.image(data))
            }
            return
        }
        guard let string = pasteboard.string(forType: .string), !string.isEmpty else { return }
        onCopy(.text(string))
    }

    /* PNG-normalized, so the same pixels dedup no matter which raster
       flavor the source app put up first. */
    private func imageData() -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        if let tiff = pasteboard.data(forType: .tiff),
            let rep = NSBitmapImageRep(data: tiff)
        {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }
}
