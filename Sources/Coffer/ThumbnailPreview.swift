import AppKit

/* The larger look at an image or file row: a native popover, its arrow
   on the row at the history card's edge, as Calendar's event popover
   points at its event. Opened by resting the pointer on a row's thumbnail
   (or by the row menu's Preview), closed by the history panel; the
   popover's own transient closing is off, as a click elsewhere in the
   panel is the panel's business. It opens left of the card, or right
   when the screen has no room on the left. The image can be dragged out
   of it, carrying the same thing a drag of the row would. */
final class ThumbnailPreview {
    private let popover = NSPopover()
    private let content = PreviewContentView()
    private let imageView = NSImageView()

    /* Image to the popover's edge; the image's radius sits inside the
       popover's own rounding. */
    private static let inset: CGFloat = 8
    private static let imageCornerRadius: CGFloat = 8
    /* The popover hugs the image, shrunk to fit maxSide; only an image
       smaller than minSide is scaled up to it, so an icon-sized copy
       still reads as a preview rather than a dot. */
    private static let maxSide: CGFloat = 280
    private static let minSide: CGFloat = 64
    /* What the popover adds beside its content on the anchored side: the
       arrow and the gap before it. */
    private static let arrowAllowance: CGFloat = 20

    /* Open as far as the panel is concerned: false from the moment hide()
       starts the close, while `isShown` stays true through the fade, so a
       second Escape pressed during it reaches the panel instead of
       closing the preview again. */
    private(set) var isVisible = false
    var isPointerInside: Bool { content.isPointerInside }
    var isDragging: Bool { content.isDragging }
    /* The pointer entering or leaving the popover, which the panel's own
       tracking can't see: it lives in a window of its own. */
    var onPointerInsideChange: ((Bool) -> Void)? {
        get { content.onPointerInsideChange }
        set { content.onPointerInsideChange = newValue }
    }
    /* A drag out of the preview finished; `.copy` when something took it. */
    var onDragEnded: ((NSDragOperation) -> Void)? {
        get { content.onDragEnded }
        set { content.onDragEnded = newValue }
    }

    init() {
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = Self.imageCornerRadius
        imageView.layer?.masksToBounds = true
        content.addSubview(imageView)
        content.imageView = imageView
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.behavior = .applicationDefined
        popover.animates = true
    }

    /* Points the arrow at `rowRect`'s height on `card`'s left edge, or its
       right edge when the left one leaves too little screen for the
       popover (both rects in `view`'s coordinates). The side is chosen
       here rather than left to AppKit, whose own flip would point from
       the anchor's far side, inside the card. Shown again while open, the
       popover jumps there at the new image's size: with animation on, it
       slid and resized while already showing the new image, which read as
       wobbling from one item to the next. The animation comes back for the
       eventual close. `makeWriters` supplies what a drag out carries. */
    func show(
        _ image: NSImage, beside card: NSRect, rowRect: NSRect, of view: NSView,
        makeWriters: @escaping () -> [NSPasteboardWriting]
    ) {
        let natural = image.size
        let longest = max(natural.width, natural.height, 1)
        let scale = min(max(1, Self.minSide / longest), Self.maxSide / longest)
        let fitted = NSSize(
            width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
        let size = NSSize(width: fitted.width + Self.inset * 2, height: fitted.height + Self.inset * 2)
        imageView.frame = NSRect(origin: NSPoint(x: Self.inset, y: Self.inset), size: fitted)
        imageView.image = image
        content.makeWriters = makeWriters

        var roomOnLeft = true
        if let window = view.window, let screen = window.screen ?? NSScreen.main {
            let cardOnScreen = window.convertToScreen(view.convert(card, to: nil))
            roomOnLeft =
                cardOnScreen.minX - screen.visibleFrame.minX >= size.width + Self.arrowAllowance
        }
        let anchor = NSRect(
            x: roomOnLeft ? card.minX : card.maxX - 1, y: rowRect.minY,
            width: 1, height: rowRect.height)

        isVisible = true
        let switching = popover.isShown
        if switching { popover.animates = false }
        popover.contentSize = size
        popover.show(relativeTo: anchor, of: view, preferredEdge: roomOnLeft ? .minX : .maxX)
        if switching { popover.animates = true }
    }

    /* For the panel's own close: the popover goes at once, fade or not.
       Closing the panel under a popover still fading out (a second Escape
       right after the first) left the panel inactive on screen until the
       fade finished. */
    func hideNow() {
        isVisible = false
        guard popover.isShown else { return }
        popover.animates = false
        popover.close()
        popover.contentViewController?.view.window?.orderOut(nil)
        popover.animates = true
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        popover.close()
    }
}

/* The popover's content: the image, and the drag source for it. Takes
   every click over the image (the image view would otherwise swallow
   them) and starts a drag once the pointer has moved a few points. */
private final class PreviewContentView: NSView, NSDraggingSource {
    weak var imageView: NSImageView?
    var makeWriters: (() -> [NSPasteboardWriting])?
    var onPointerInsideChange: ((Bool) -> Void)?
    var onDragEnded: ((NSDragOperation) -> Void)?
    private(set) var isPointerInside = false
    private(set) var isDragging = false
    private var mouseDownEvent: NSEvent?
    private var hoverArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        /* Always active: Coffer is never the active app. */
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        onPointerInsideChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        onPointerInsideChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let start = down.locationInWindow, now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) >= 3 else { return }
        mouseDownEvent = nil
        guard let writers = makeWriters?(), !writers.isEmpty, let imageView else { return }
        let items = writers.map { writer in
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(imageView.frame, contents: imageView.image)
            return item
        }
        isDragging = true
        beginDraggingSession(with: items, event: down, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        /* Copy only: a drop into a Finder folder duplicates a file rather
           than moving the original out from under the history. */
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        isDragging = false
        onDragEnded?(operation)
    }
}
