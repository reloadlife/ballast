// Renders Ballast's app icon from SwiftUI and writes Resources/AppIcon.icns.
// Run: swift scripts/make-icon.swift
import AppKit
import SwiftUI

/// A ship's ballast weight: a rounded trapezoid with a lifting ring.
struct Weight: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let top = h * 0.30
        var body = Path()
        body.move(to: CGPoint(x: w * 0.30, y: top))
        body.addLine(to: CGPoint(x: w * 0.70, y: top))
        body.addQuadCurve(to: CGPoint(x: w * 0.78, y: top + h * 0.06), control: CGPoint(x: w * 0.76, y: top))
        body.addLine(to: CGPoint(x: w * 0.95, y: h * 0.88))
        body.addQuadCurve(to: CGPoint(x: w * 0.86, y: h), control: CGPoint(x: w * 0.97, y: h))
        body.addLine(to: CGPoint(x: w * 0.14, y: h))
        body.addQuadCurve(to: CGPoint(x: w * 0.05, y: h * 0.88), control: CGPoint(x: w * 0.03, y: h))
        body.addLine(to: CGPoint(x: w * 0.22, y: top + h * 0.06))
        body.addQuadCurve(to: CGPoint(x: w * 0.30, y: top), control: CGPoint(x: w * 0.24, y: top))
        body.closeSubpath()
        return body
    }
}

struct Icon: View {
    var body: some View {
        // Apple's macOS grid: an 824pt body centered on a 1024 canvas.
        let size: CGFloat = 824
        let shape = RoundedRectangle(cornerRadius: 185, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [Color(red: 0.36, green: 0.58, blue: 1.0),
                                               Color(red: 0.13, green: 0.33, blue: 0.86)],
                                      startPoint: .top, endPoint: .bottom))
            shape.fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center))

            ZStack(alignment: .top) {
                Circle()
                    .stroke(.white, lineWidth: 34)
                    .frame(width: size * 0.19, height: size * 0.19)
                    .offset(y: size * 0.035)
                Weight()
                    .fill(LinearGradient(colors: [.white, Color(white: 0.9)], startPoint: .top, endPoint: .bottom))
                    .frame(width: size * 0.52, height: size * 0.52)
            }
            .frame(width: size * 0.52, height: size * 0.56)
            .shadow(color: .black.opacity(0.25), radius: 18, y: 12)
            .offset(y: size * 0.02)

            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.08)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 3)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.3), radius: 22, y: 12)
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
func render() throws {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let image = renderer.cgImage else { throw NSError(domain: "icon", code: 1) }
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let iconset = root.appending(path: ".build/AppIcon.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    let master = NSBitmapImageRep(cgImage: image)
    for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
        let pixels = points * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        master.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appending(path: name))
    }
    try master.representation(using: .png, properties: [:])!.write(to: root.appending(path: "Resources/AppIcon-1024.png"))
}

try FileManager.default.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
try MainActor.assumeIsolated { try render() }
let status = Process()
status.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
status.arguments = ["-c", "icns", ".build/AppIcon.iconset", "-o", "Resources/AppIcon.icns"]
try status.run()
status.waitUntilExit()
print(status.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
