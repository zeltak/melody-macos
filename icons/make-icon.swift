// SPDX-License-Identifier: GPL-3.0-only
//
// Draws an app icon: Melody's vinyl bird on a macOS rounded-square tile,
// with rings like the record's grooves spreading behind it -- and, for the
// engine's menu-bar app, a green status light: the engine, answering.
//
//   make-icon BIRD.svg OUT.png SIZE [light]

import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 3, let bird = NSImage(contentsOfFile: arguments[1]) else {
    FileHandle.standardError.write(Data("usage: make-icon.swift BIRD.svg OUT.png [SIZE]\n".utf8))
    exit(2)
}
let size = arguments.count > 3 ? Int(arguments[3])! : 1024
let withLight = arguments.count > 4 && arguments[4] == "light"
let scale = CGFloat(size) / 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let cream = color(0xFFF3D5)
let orange = color(0xF15A13)
let ink = color(0x201F1D)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = context
context.imageInterpolation = .high
let cg = context.cgContext
cg.scaleBy(x: scale, y: scale)

// Apple's grid: an 824-point tile centred on the 1024 canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

// The tile's shadow, as the Dock draws its neighbours'.
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 28
shadow.set()
cream.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
shape.addClip()
// Warm light from the top, to a deeper cream and a touch of the beak's
// orange at the bottom.
NSGradient(colors: [color(0xFFF8E6), cream, color(0xF9D9A8)],
           atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
    .draw(in: tile, angle: -90)

// Grooves spreading from the record at the bird's heart.
let centre = NSPoint(x: 512, y: 429)
for (index, radius) in [250.0, 320, 390, 460, 530].enumerated() {
    let ring = NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius,
                                           width: radius * 2, height: radius * 2))
    ring.lineWidth = 14
    orange.withAlphaComponent(0.20 - CGFloat(index) * 0.035).setStroke()
    ring.stroke()
}

// A soft highlight across the top edge.
let gloss = NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
gloss.lineWidth = 4
NSColor.white.withAlphaComponent(0.55).setStroke()
gloss.stroke()
NSGraphicsContext.restoreGraphicsState()

// The bird, lifted off the tile.
NSGraphicsContext.saveGraphicsState()
let lift = NSShadow()
lift.shadowColor = ink.withAlphaComponent(0.35)
lift.shadowOffset = NSSize(width: 0, height: -14)
lift.shadowBlurRadius = 24
lift.set()
bird.draw(in: NSRect(x: 172, y: 150, width: 680, height: 680))
NSGraphicsContext.restoreGraphicsState()

// The status light: green, in a cream bezel, at the bottom right.
let light = NSPoint(x: 772, y: 252)
if withLight {
NSGraphicsContext.saveGraphicsState()
let bezelShadow = NSShadow()
bezelShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
bezelShadow.shadowOffset = NSSize(width: 0, height: -6)
bezelShadow.shadowBlurRadius = 12
bezelShadow.set()
cream.setFill()
NSBezierPath(ovalIn: NSRect(x: light.x - 82, y: light.y - 82, width: 164, height: 164)).fill()
NSGraphicsContext.restoreGraphicsState()
let lamp = NSRect(x: light.x - 60, y: light.y - 60, width: 120, height: 120)
NSGradient(colors: [color(0x7BE07F), color(0x2EAE4A), color(0x1C7D33)],
           atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: NSBezierPath(ovalIn: lamp), relativeCenterPosition: NSPoint(x: -0.3, y: 0.35))
// Its glint.
NSColor.white.withAlphaComponent(0.65).setFill()
NSBezierPath(ovalIn: NSRect(x: light.x - 34, y: light.y + 10, width: 40, height: 28)).fill()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: arguments[2]))
