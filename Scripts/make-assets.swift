#!/usr/bin/env swift
// Generates the app icon (Assets/AppIcon.iconset/*.png + icon-1024.png) and
// the README banner (Assets/banner.png) programmatically, so the artwork is
// reproducible from source. Run: swift Scripts/make-assets.swift
// Then:  iconutil -c icns Assets/AppIcon.iconset -o Assets/AppIcon.icns
//
// Same Liquid Glass icon language as its siblings Oriel, Pharos, and Transom:
// the macOS squircle, frosted-glass forms (real gaussian-blurred backdrop via
// CoreImage), specular rim highlights, and soft layered shadows. Coffer's
// glyph is a clipboard item being kept: a bright glass card — content bars
// and all — sliding down into an open glass coffer, its lower half ghosting
// through the box front as a blurred silhouette.

import AppKit
import CoreImage
import SwiftUI

// MARK: - Helpers

let ciContext = CIContext()

func makeBitmap(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
}

func withContext(_ rep: NSBitmapImageRep, _ draw: (CGContext) -> Void) {
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    draw(ctx.cgContext)
    NSGraphicsContext.current = nil
}

func savePNG(_ rep: NSBitmapImageRep, _ path: String) {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let rgb = CGColorSpaceCreateDeviceRGB()

func linearGradient(_ cg: CGContext, in path: CGPath, colors: [CGColor], from: CGPoint, to: CGPoint) {
    cg.saveGState()
    cg.addPath(path)
    cg.clip()
    let grad = CGGradient(colorsSpace: rgb, colors: colors as CFArray, locations: nil)!
    cg.drawLinearGradient(grad, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.restoreGState()
}

/// The macOS app-icon silhouette: a continuous-corner rounded rect (straight
/// edges, Apple's smooth corner curve) — not a superellipse, whose sides
/// bulge. Radius fitted against the system's live icon mask (measured from
/// Calculator/Notes/Finder at 1024px: 214.5px on the 824px shape, ~0.16px RMS).
func squircle(in rect: CGRect) -> CGPath {
    Path(roundedRect: rect, cornerRadius: rect.width * (214.5 / 824), style: .continuous).cgPath
}

func gaussianBlur(_ image: CGImage, radius: CGFloat) -> CGImage {
    let ci = CIImage(cgImage: image)
    let blurred = ci.clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        .cropped(to: ci.extent)
    return ciContext.createCGImage(blurred, from: ci.extent)!
}

// MARK: - Icon (designed in a 1024x1024 space, bottom-left origin)

let designRect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
let bgRect = CGRect(x: 100, y: 100, width: 824, height: 824) // standard macOS icon grid

/// Background layer: squircle, spring-green gradient, top sheen, outer shadow.
func drawIconBackground(_ cg: CGContext) {
    let shape = squircle(in: bgRect)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 36, color: color(0x000000, 0.28))
    cg.addPath(shape)
    cg.setFillColor(color(0x1EA36A))
    cg.fillPath()
    cg.restoreGState()

    // A single restrained green gradient, in the language of macOS system
    // icons: the background recedes, the glyph is the hero.
    linearGradient(
        cg, in: shape,
        colors: [color(0x4FE3A2), color(0x0FA25F)],
        from: CGPoint(x: 512, y: bgRect.maxY), to: CGPoint(x: 512, y: bgRect.minY)
    )
    // Barely-there top light for depth
    linearGradient(
        cg, in: shape,
        colors: [color(0xFFFFFF, 0.1), color(0xFFFFFF, 0)],
        from: CGPoint(x: 512, y: bgRect.maxY), to: CGPoint(x: 512, y: bgRect.maxY - 320)
    )
}

/// Specular rim: a stroke around `path` that is bright on top, fading below.
func glassRim(_ cg: CGContext, around path: CGPath, width: CGFloat, bounds: CGRect, top: CGFloat, bottom: CGFloat) {
    let stroked = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    linearGradient(
        cg, in: stroked,
        colors: [color(0xFFFFFF, top), color(0xFFFFFF, bottom)],
        from: CGPoint(x: bounds.midX, y: bounds.maxY), to: CGPoint(x: bounds.midX, y: bounds.minY)
    )
}

/// One frosted-glass pane: blurred backdrop, milky tint, specular rim.
func drawGlassPane(
    _ cg: CGContext, path: CGPath, bounds: CGRect, backdrop: CGImage,
    tintTop: CGFloat, tintBottom: CGFloat,
    rimWidth: CGFloat, rimTop: CGFloat, rimBottom: CGFloat,
    shadowBlur: CGFloat, shadowAlpha: CGFloat
) {
    // Drop shadow (opaque fill, replaced by the glass interior right after)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -shadowBlur * 0.4), blur: shadowBlur, color: color(0x06402A, shadowAlpha))
    cg.addPath(path)
    cg.setFillColor(color(0x9AE8C6))
    cg.fillPath()
    cg.restoreGState()

    // Blurred backdrop + milky tint
    cg.saveGState()
    cg.addPath(path)
    cg.clip()
    cg.draw(backdrop, in: designRect)
    linearGradient(
        cg, in: path,
        colors: [color(0xFFFFFF, tintTop), color(0xFFFFFF, tintBottom)],
        from: CGPoint(x: bounds.midX, y: bounds.maxY), to: CGPoint(x: bounds.midX, y: bounds.minY)
    )
    cg.restoreGState()

    glassRim(cg, around: path, width: rimWidth, bounds: bounds, top: rimTop, bottom: rimBottom)
}

// The glyph: a copied card sliding down into an open coffer. The card is the
// bright hero, its content bars visible above the rim; the box in front is
// milkier glass, so the card's lower half shows through only as a blurred
// ghost — kept, not gone.
/* Nudged 22px above geometric center: the box carries the glyph's visual
   weight at the bottom, so true centering reads as sitting low. */
let boxBody = CGRect(x: 252, y: 262, width: 520, height: 300)
let card = CGRect(x: 352, y: 442, width: 320, height: 350)

/// The card leans a few degrees mid-drop — it's falling into the coffer,
/// not feeding out of a printer.
func withCardTilt(_ cg: CGContext, _ body: (CGContext) -> Void) {
    cg.saveGState()
    cg.translateBy(x: card.midX, y: card.midY)
    cg.rotate(by: -0.1)
    cg.translateBy(x: -card.midX, y: -card.midY)
    body(cg)
    cg.restoreGState()
}

func drawCard(_ cg: CGContext, backdrop: CGImage, boost: Bool) {
    withCardTilt(cg) { cg in
        let path = CGPath(roundedRect: card, cornerWidth: 44, cornerHeight: 44, transform: nil)
        drawGlassPane(
            cg, path: path, bounds: card, backdrop: backdrop,
            tintTop: boost ? 0.98 : 0.94, tintBottom: boost ? 0.94 : 0.85,
            rimWidth: 5, rimTop: 1.0, rimBottom: 0.3,
            shadowBlur: 40, shadowAlpha: 0.3
        )
        drawCardContent(cg)
    }
}

/// Ghosted content bars on the card — the copied text. Placed in the card's
/// upper half so they stay visible above the box rim. Shared between the
/// rendered icon and the flat Icon Composer layers.
func drawCardContent(_ cg: CGContext) {
    cg.setFillColor(color(0x1E7F52, 0.32))
    for (i, w) in [CGFloat(184), 128].enumerated() {
        let y = card.maxY - 72 - CGFloat(i) * 58
        let bar = CGRect(x: card.minX + 44, y: y - 14, width: w, height: 28)
        cg.addPath(CGPath(roundedRect: bar, cornerWidth: 14, cornerHeight: 14, transform: nil))
    }
    cg.fillPath()
}

func drawBox(_ cg: CGContext, backdrop: CGImage, boost: Bool) {
    let path = CGPath(roundedRect: boxBody, cornerWidth: 56, cornerHeight: 56, transform: nil)
    drawGlassPane(
        cg, path: path, bounds: boxBody, backdrop: backdrop,
        tintTop: boost ? 0.72 : 0.6, tintBottom: boost ? 0.58 : 0.44,
        rimWidth: 5, rimTop: 0.95, rimBottom: 0.25,
        shadowBlur: 46, shadowAlpha: 0.32
    )
}

/// Renders the complete icon at `px` and returns the bitmap.
func makeIcon(px: Int) -> NSBitmapImageRep {
    let scale = CGFloat(px) / 1024
    let blurRadius = max(36 * scale, 1)
    // Small sizes: more opaque forms keep the glyph legible in the menu bar /
    // Dock, where the frosted subtlety would just vanish.
    let boost = px <= 64

    let bgRep = makeBitmap(px, px)
    withContext(bgRep) { cg in
        cg.scaleBy(x: scale, y: scale)
        drawIconBackground(cg)
    }
    let backdrop = gaussianBlur(bgRep.cgImage!, radius: blurRadius)

    let shape = squircle(in: bgRect)

    /* Clip the glyph to the squircle, and at small sizes optically enlarge
       it (like Apple's small-size icon variants) so it stays prominent in
       the menu bar / Dock. */
    func drawGlyph(_ cg: CGContext, _ body: (CGContext) -> Void) {
        cg.saveGState()
        cg.addPath(shape)
        cg.clip()
        if boost {
            cg.translateBy(x: 512, y: 512)
            cg.scaleBy(x: 1.14, y: 1.14)
            cg.translateBy(x: -512, y: -512)
        }
        body(cg)
        cg.restoreGState()
    }

    // Intermediate scene (background + card), so the box's backdrop blur
    // includes the card sinking into it — the kept copy ghosts through.
    let midRep = makeBitmap(px, px)
    withContext(midRep) { cg in
        cg.scaleBy(x: scale, y: scale)
        cg.draw(bgRep.cgImage!, in: designRect)
        drawGlyph(cg) { drawCard($0, backdrop: backdrop, boost: boost) }
    }
    let midBackdrop = gaussianBlur(midRep.cgImage!, radius: blurRadius)

    let rep = makeBitmap(px, px)
    withContext(rep) { cg in
        cg.scaleBy(x: scale, y: scale)
        cg.draw(midRep.cgImage!, in: designRect)
        drawGlyph(cg) { drawBox($0, backdrop: midBackdrop, boost: boost) }
    }
    return rep
}

// MARK: - Icon Composer layers (macOS 26+ .icon document)

/* The .icon format gets dark/clear/tinted appearances for free: we ship flat
   transparent layers plus a background fill, and the system renders the
   Liquid Glass treatment (and the dark background) at runtime. In a .icon
   document the 1024pt canvas IS the icon shape — the system adds its own
   margins — whereas our design space puts the squircle at 100..924, so the
   glyph is remapped to land at the same visual position. */
func makeIconLayer(_ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = makeBitmap(1024, 1024)
    withContext(rep) { cg in
        cg.scaleBy(x: 1024 / 824, y: 1024 / 824)
        cg.translateBy(x: -100, y: -100)
        draw(cg)
    }
    return rep
}

func drawFlatCard(_ cg: CGContext) {
    withCardTilt(cg) { cg in
        cg.addPath(CGPath(roundedRect: card, cornerWidth: 44, cornerHeight: 44, transform: nil))
        cg.setFillColor(color(0xFFFFFF))
        cg.fillPath()
        drawCardContent(cg)
    }
}

func drawFlatBox(_ cg: CGContext) {
    // Semi-transparent so the system's glass treatment keeps the card's
    // lower half faintly visible through the box front.
    cg.addPath(CGPath(roundedRect: boxBody, cornerWidth: 56, cornerHeight: 56, transform: nil))
    cg.setFillColor(color(0xFFFFFF, 0.72))
    cg.fillPath()
}

// MARK: - Banner (1800 x 600)

func drawBanner(_ cg: CGContext, icon: CGImage) {
    let canvas = CGRect(x: 0, y: 0, width: 1800, height: 600)
    let frame = CGPath(roundedRect: canvas, cornerWidth: 40, cornerHeight: 40, transform: nil)
    linearGradient(
        cg, in: frame,
        colors: [color(0x122E24), color(0x0A1712)],
        from: CGPoint(x: canvas.midX, y: canvas.maxY), to: CGPoint(x: canvas.midX, y: canvas.minY)
    )

    // Faint decorative clipboard-card outlines on the right
    cg.saveGState()
    cg.addPath(frame)
    cg.clip()
    cg.setStrokeColor(color(0xFFFFFF, 0.07))
    cg.setLineWidth(3)
    for (x, y, w, h) in [(1380.0, 250.0, 360.0, 260.0), (1520.0, 60.0, 420.0, 300.0), (1250.0, -80.0, 300.0, 220.0)] {
        cg.addPath(CGPath(
            roundedRect: CGRect(x: x, y: y, width: w, height: h),
            cornerWidth: 26, cornerHeight: 26, transform: nil
        ))
        cg.strokePath()
    }
    cg.restoreGState()

    // App icon on the left
    cg.draw(icon, in: CGRect(x: 100, y: 118, width: 364, height: 364))

    // Wordmark + tagline
    let title = NSAttributedString(string: "Coffer", attributes: [
        .font: NSFont.systemFont(ofSize: 130, weight: .bold),
        .foregroundColor: NSColor.white,
    ])
    title.draw(at: NSPoint(x: 520, y: 268))

    let tagline = NSAttributedString(string: "A clipboard with a long memory", attributes: [
        .font: NSFont.systemFont(ofSize: 46, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.6, green: 0.84, blue: 0.72, alpha: 1),
    ])
    tagline.draw(at: NSPoint(x: 528, y: 186))
}

// MARK: - GitHub social preview (1280 x 640 design space, rendered @2x)

func drawSocialPreview(_ cg: CGContext, icon: CGImage) {
    let canvas = CGRect(x: 0, y: 0, width: 1280, height: 640)
    // Full bleed — GitHub renders the preview edge to edge and rounds the
    // corners itself, so transparent corners would show through as white.
    linearGradient(
        cg, in: CGPath(rect: canvas, transform: nil),
        colors: [color(0x14332A), color(0x0A1712)],
        from: CGPoint(x: canvas.midX, y: canvas.maxY), to: CGPoint(x: canvas.midX, y: canvas.minY)
    )

    // Faint decorative clipboard-card outlines drifting off the corners
    cg.saveGState()
    cg.setStrokeColor(color(0xFFFFFF, 0.06))
    cg.setLineWidth(2.5)
    for (x, y, w, h) in [
        (-90.0, 430.0, 300.0, 210.0), (60.0, 520.0, 260.0, 190.0),
        (1030.0, -60.0, 320.0, 230.0), (1140.0, 90.0, 280.0, 200.0),
    ] {
        cg.addPath(CGPath(
            roundedRect: CGRect(x: x, y: y, width: w, height: h),
            cornerWidth: 22, cornerHeight: 22, transform: nil
        ))
        cg.strokePath()
    }
    cg.restoreGState()

    func drawCentered(_ text: NSAttributedString, y: CGFloat) {
        text.draw(at: NSPoint(x: canvas.midX - text.size().width / 2, y: y))
    }

    // Centered stack: icon, wordmark, tagline — sized up so the card stays
    // legible at the small sizes link previews render at.
    cg.draw(icon, in: CGRect(x: canvas.midX - 125, y: 300, width: 250, height: 250))

    drawCentered(
        NSAttributedString(string: "Coffer", attributes: [
            .font: NSFont.systemFont(ofSize: 100, weight: .bold),
            .foregroundColor: NSColor.white,
        ]), y: 180)

    drawCentered(
        NSAttributedString(string: "A clipboard with a long memory", attributes: [
            .font: NSFont.systemFont(ofSize: 38, weight: .medium),
            .foregroundColor: NSColor(srgbRed: 0.6, green: 0.84, blue: 0.72, alpha: 1),
        ]), y: 118)
}

// MARK: - Main

let fm = FileManager.default
try? fm.createDirectory(atPath: "Assets/AppIcon.iconset", withIntermediateDirectories: true)

// Iconset: render each size directly from vectors (crisper than downscaling)
let iconSizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in iconSizes {
    savePNG(makeIcon(px: px), "Assets/AppIcon.iconset/\(name).png")
}

let master = makeIcon(px: 1024)
savePNG(master, "Assets/icon-1024.png")

// Icon Composer layers for the macOS 26+ .icon document
try? fm.createDirectory(atPath: "Assets/AppIcon.icon/Assets", withIntermediateDirectories: true)
savePNG(makeIconLayer(drawFlatCard), "Assets/AppIcon.icon/Assets/back.png")
savePNG(makeIconLayer(drawFlatBox), "Assets/AppIcon.icon/Assets/front.png")

let bannerIcon = makeIcon(px: 728).cgImage!
let banner = makeBitmap(1800, 600)
withContext(banner) { drawBanner($0, icon: bannerIcon) }
savePNG(banner, "Assets/banner.png")

// GitHub social preview: exactly 1280x640, GitHub's recommended size.
let og = makeBitmap(1280, 640)
withContext(og) { cg in
    drawSocialPreview(cg, icon: bannerIcon)
}
savePNG(og, "Assets/og-image.png")
