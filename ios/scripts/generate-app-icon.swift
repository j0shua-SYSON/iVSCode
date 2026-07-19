#!/usr/bin/env xcrun swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
	fputs("usage: generate-app-icon.swift source.png output.png\n", stderr)
	exit(64)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = NSImage(contentsOf: sourceURL),
	let bitmap = NSBitmapImageRep(
		bitmapDataPlanes: nil,
		pixelsWide: 1024,
		pixelsHigh: 1024,
		bitsPerSample: 8,
		samplesPerPixel: 3,
		hasAlpha: false,
		isPlanar: false,
		colorSpaceName: .deviceRGB,
		bytesPerRow: 0,
		bitsPerPixel: 24
	),
	let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
	fputs("error: could not create the app icon canvas\n", stderr)
	exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

let bounds = NSRect(x: 0, y: 0, width: 1024, height: 1024)
let background = NSGradient(colors: [
	NSColor(calibratedRed: 0.025, green: 0.055, blue: 0.105, alpha: 1),
	NSColor(calibratedRed: 0.075, green: 0.130, blue: 0.225, alpha: 1)
])!
background.draw(in: bounds, angle: -52)

NSColor(calibratedWhite: 1, alpha: 0.035).setStroke()
for offset in stride(from: -512, through: 1536, by: 128) {
	let line = NSBezierPath()
	line.move(to: NSPoint(x: offset, y: 0))
	line.line(to: NSPoint(x: offset + 512, y: 1024))
	line.lineWidth = 2
	line.stroke()
}

let glowRect = NSRect(x: 108, y: 108, width: 808, height: 808)
NSColor(calibratedRed: 0.10, green: 0.55, blue: 1.0, alpha: 0.10).setFill()
NSBezierPath(roundedRect: glowRect, xRadius: 220, yRadius: 220).fill()

source.draw(
	in: NSRect(x: 142, y: 142, width: 740, height: 740),
	from: .zero,
	operation: .sourceOver,
	fraction: 1,
	respectFlipped: true,
	hints: [.interpolation: NSImageInterpolation.high]
)

let badgeRect = NSRect(x: 726, y: 718, width: 180, height: 180)
let badge = NSGradient(colors: [
	NSColor(calibratedRed: 0.12, green: 0.78, blue: 1.0, alpha: 1),
	NSColor(calibratedRed: 0.08, green: 0.42, blue: 0.95, alpha: 1)
])!
let badgePath = NSBezierPath(ovalIn: badgeRect)
badge.draw(in: badgePath, angle: -45)
NSColor(calibratedWhite: 1, alpha: 0.42).setStroke()
badgePath.lineWidth = 4
badgePath.stroke()

let badgeText = "i" as NSString
let badgeFont = NSFont.monospacedSystemFont(ofSize: 126, weight: .bold)
let badgeAttributes: [NSAttributedString.Key: Any] = [
	.font: badgeFont,
	.foregroundColor: NSColor.white
]
let badgeSize = badgeText.size(withAttributes: badgeAttributes)
badgeText.draw(
	at: NSPoint(
		x: badgeRect.midX - badgeSize.width / 2,
		y: badgeRect.midY - badgeSize.height / 2 + 4
	),
	withAttributes: badgeAttributes
)

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [.compressionFactor: 1]) else {
	fputs("error: could not encode the app icon\n", stderr)
	exit(1)
}
do {
	try png.write(to: outputURL, options: .atomic)
} catch {
	fputs("error: could not write the app icon: \(error.localizedDescription)\n", stderr)
	exit(1)
}
