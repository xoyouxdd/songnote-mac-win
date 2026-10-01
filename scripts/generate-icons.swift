import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = NSImage(contentsOf: root.appendingPathComponent("assets/songnote-icon-master.png"))!
let output = root.appendingPathComponent("build/SongNote.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func render(_ size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for logical in [16, 32, 128, 256, 512] {
    try render(logical).write(to: output.appendingPathComponent("icon_\(logical)x\(logical).png"))
    try render(logical * 2).write(to: output.appendingPathComponent("icon_\(logical)x\(logical)@2x.png"))
}
for size in [16, 24, 32, 48, 64, 128, 256] {
    try render(size).write(to: output.appendingPathComponent("windows-\(size).png"))
}
try render(512).write(to: root.appendingPathComponent("assets/songnote-icon.png"))
print("ICON_PNGS_OK: transparent image master exported to native icon sizes")
