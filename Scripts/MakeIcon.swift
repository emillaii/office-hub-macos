import AppKit
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
for (size, name) in [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),(128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")] {
    let s = CGFloat(size); let image = NSImage(size: NSSize(width: s, height: s)); image.lockFocus()
    NSColor(calibratedRed: 0.03, green: 0.065, blue: 0.045, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: s*0.03, y: s*0.03, width: s*0.94, height: s*0.94), xRadius: s*0.22, yRadius: s*0.22).fill()
    let text = ">_" as NSString
    let font = NSFont.monospacedSystemFont(ofSize: s*0.42, weight: .bold)
    text.draw(at: NSPoint(x: s*0.20, y: s*0.24), withAttributes: [.font: font, .foregroundColor: NSColor(calibratedRed: 0.46, green: 0.96, blue: 0.63, alpha: 1)])
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("icon_\(name).png"))
}
