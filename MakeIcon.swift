// Gera o ícone do app (1024 px) em PNG.
import AppKit
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(red: 0.98, green: 0.62, blue: 0.20, alpha: 1), NSColor(red: 0.93, green: 0.30, blue: 0.27, alpha: 1)])!
    .draw(in: path, angle: -90)
let cfg = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold).applying(.init(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "sdcard.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let s = sym.size
    sym.draw(in: NSRect(x: (size - s.width) / 2 - 40, y: (size - s.height) / 2 + 30, width: s.width, height: s.height))
}
let cfg2 = NSImage.SymbolConfiguration(pointSize: 230, weight: .bold).applying(.init(paletteColors: [.white, NSColor(red: 0.93, green: 0.30, blue: 0.27, alpha: 1)]))
if let a = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg2) {
    let s = a.size
    NSColor(red: 0.93, green: 0.30, blue: 0.27, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 600 - 12, y: 170 - 12, width: s.width + 24, height: s.height + 24)).fill()
    a.draw(in: NSRect(x: 600, y: 170, width: s.width, height: s.height))
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
