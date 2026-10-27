// Gera o ícone do app (1024 px) em PNG: cartão SD → seta → HD.
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

// Fundo: quadrado arredondado no padrão do macOS, laranja para vermelho
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(red: 0.99, green: 0.64, blue: 0.22, alpha: 1), NSColor(red: 0.91, green: 0.27, blue: 0.27, alpha: 1)])!
    .draw(in: bg, angle: -90)
// Brilho suave no alto
NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
    .draw(in: bg, angle: -90)

/// Desenha um símbolo do sistema centrado num ponto, com sombra leve.
func symbol(_ name: String, size pt: CGFloat, weight: NSFont.Weight, center: NSPoint, color: NSColor = .white) {
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: weight).applying(.init(paletteColors: [color]))
    guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
    let s = sym.size
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 22
    shadow.set()
    sym.draw(in: NSRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height))
    NSGraphicsContext.restoreGraphicsState()
}

// Cartão SD no alto à esquerda, HD embaixo à direita, seta curva ligando os dois
symbol("sdcard.fill", size: 300, weight: .semibold, center: NSPoint(x: 345, y: 650))
symbol("externaldrive.fill", size: 270, weight: .semibold, center: NSPoint(x: 640, y: 335))

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 540, y: 720))
arrow.curve(to: NSPoint(x: 760, y: 455), controlPoint1: NSPoint(x: 690, y: 725), controlPoint2: NSPoint(x: 760, y: 610))
arrow.lineWidth = 44
arrow.lineCapStyle = .round
NSColor.white.setStroke()
NSGraphicsContext.saveGraphicsState()
let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.22); sh.shadowOffset = NSSize(width: 0, height: -10); sh.shadowBlurRadius = 22; sh.set()
arrow.stroke()
// Ponta da seta
let head = NSBezierPath()
head.move(to: NSPoint(x: 690, y: 525))
head.line(to: NSPoint(x: 760, y: 440))
head.line(to: NSPoint(x: 830, y: 525))
head.lineWidth = 44
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()
NSGraphicsContext.restoreGraphicsState()

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
