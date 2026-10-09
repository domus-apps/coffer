import AppKit
import UniformTypeIdentifiers

/* What dragging an item out of the history carries, from its row or its
   preview: the text itself, the files themselves (one dragged item per
   file, as Finder drags a selection), or an image that lands as data in
   apps that take images and as a PNG file in a Finder folder. */
enum ItemDrag {
    static func writers(for item: ClipboardItem) -> [NSPasteboardWriting] {
        switch item {
        case .text(let string):
            return [string as NSString]
        case .files(let urls):
            return urls.map { $0.absoluteURL as NSURL }
        case .image(let data):
            return [ImagePromiseProvider(png: data)]
        }
    }
}

/* A file promise that also offers the pixels directly: Finder fulfils the
   promise (a PNG written into the drop folder), while a message field or
   an image editor reads the PNG or TIFF data without any file. */
private final class ImagePromiseProvider: NSFilePromiseProvider {
    /* The provider's delegate is weak; this one lives for the app. */
    private static let writer = ImagePromiseWriter()
    let png: Data

    init(png: Data) {
        self.png = png
        super.init()
        fileType = UTType.png.identifier
        delegate = Self.writer
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.png, .tiff]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .png:
            return png
        case .tiff:
            return NSBitmapImageRep(data: png)?.tiffRepresentation
        default:
            return super.pasteboardPropertyList(forType: type)
        }
    }
}

private final class ImagePromiseWriter: NSObject, NSFilePromiseProviderDelegate {
    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String
    ) -> String {
        "\(L("Image")).png"
    }

    /* Never over another file: a second drop into the same folder lands
       as "Image 2.png", as Finder names a duplicate. */
    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let provider = filePromiseProvider as? ImagePromiseProvider else {
            completionHandler(CocoaError(.fileWriteUnknown))
            return
        }
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        var target = url
        var number = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) \(number).png")
            number += 1
        }
        do {
            try provider.png.write(to: target, options: .withoutOverwriting)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}
