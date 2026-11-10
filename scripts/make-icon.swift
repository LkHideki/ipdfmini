// Gera o ícone do iPDFmini por código (CoreGraphics), sem arquivos-fonte binários.
// Uso: swift scripts/make-icon.swift <diretório>
// Saída: <dir>/AppIcon.iconset (16…1024, @1x/@2x) e <dir>/icon_1024.png.
// O build-app.sh converte o iconset em AppIcon.icns com iconutil.
//
// Desenho: iPad mini em retrato sobre quadrado arredondado (grade do macOS 26),
// com uma página de texto cujas margens foram "aparadas" por marcas de canto na
// cor de destaque. Tamanhos ≤ 32 px usam menos linhas, mais grossas, para não
// virarem um borrão cinza; em 16 px as marcas saem e o destaque vai para a 1ª linha.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("uso: swift make-icon.swift <diretório>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let accent = rgb(1.0, 0.58, 0.0)          // laranja das marcas de corte
let blueTop = rgb(0.27, 0.56, 1.0)
let blueBottom = rgb(0.10, 0.26, 0.78)

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func linearGradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// Desenha em coordenadas de 1024 (y para cima); `pixels` decide o nível de detalhe.
func drawIcon(_ ctx: CGContext, pixels: Int) {
    let small = pixels <= 32
    let tiny = pixels <= 16

    // Quadrado arredondado: 824 px com raio ≈ 185 na grade de 1024.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = roundedRect(tile, 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0, 0, 0, 0.30))
    ctx.addPath(tilePath)
    ctx.setFillColor(blueBottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    linearGradient(ctx, [blueTop, blueBottom], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    // Brilho superior discreto, à moda do vidro do macOS 26.
    linearGradient(ctx, [rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 560))
    ctx.restoreGState()
    if !small {
        ctx.addPath(roundedRect(tile.insetBy(dx: 2, dy: 2), 183))
        ctx.setStrokeColor(rgb(1, 1, 1, 0.28))
        ctx.setLineWidth(4)
        ctx.strokePath()
    }

    // iPad mini 7 em retrato: corpo 134,8 × 195,4 mm, borda ≈ 9,4 mm.
    let bodyH: CGFloat = tiny ? 740 : (small ? 700 : 620)
    let bodyW = bodyH * 134.8 / 195.4
    let body = CGRect(x: 512 - bodyW / 2, y: 512 - bodyH / 2 - 6, width: bodyW, height: bodyH)
    let bezel = bodyH * 9.43 / 195.4 * (small ? 1.15 : 1)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0, 0, 0.1, 0.45))
    ctx.addPath(roundedRect(body, small ? 52 : 44))
    ctx.setFillColor(rgb(0.13, 0.14, 0.17))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(roundedRect(body, small ? 52 : 44))
    ctx.clip()
    linearGradient(ctx, [rgb(0.24, 0.25, 0.29), rgb(0.10, 0.11, 0.13)], from: CGPoint(x: body.minX, y: body.maxY),
                   to: CGPoint(x: body.maxX, y: body.minY))
    ctx.restoreGState()

    let screen = body.insetBy(dx: bezel, dy: bezel)
    ctx.addPath(roundedRect(screen, small ? 18 : 14))
    ctx.setFillColor(rgb(0.985, 0.985, 0.975))
    ctx.fillPath()
    if !small {
        // Câmera frontal na borda curta superior.
        ctx.setFillColor(rgb(0.30, 0.32, 0.38))
        ctx.fillEllipse(in: CGRect(x: body.midX - 6, y: screen.maxY + bezel / 2 - 6, width: 12, height: 12))
    }

    // Mancha de texto: margens estreitas, porque o recorte já tirou as da página.
    let inset: CGFloat = tiny ? 70 : (small ? 60 : 46)
    let text = screen.insetBy(dx: inset, dy: inset + (small ? 6 : 10))
    let ink = rgb(0.36, 0.38, 0.44)
    if tiny {
        // 16 px: sem marcas (viram manchas); três barras, a primeira na cor de destaque.
        let bar: CGFloat = 96, gap: CGFloat = 96
        for i in 0..<3 {
            let y = text.maxY - bar - CGFloat(i) * (bar + gap)
            let w = i == 2 ? text.width * 0.6 : text.width
            ctx.addPath(roundedRect(CGRect(x: text.minX, y: y, width: w, height: bar), bar / 2))
            ctx.setFillColor(i == 0 ? accent : ink)
            ctx.fillPath()
        }
        return
    } else {
        let bar: CGFloat = small ? 40 : 15
        let gap: CGFloat = small ? 40 : 17
        // Título mais grosso, depois parágrafos com linha final curta.
        let title = CGRect(x: text.minX, y: text.maxY - bar * 1.7, width: text.width * 0.62, height: bar * 1.7)
        ctx.addPath(roundedRect(title, bar * 0.85))
        ctx.setFillColor(rgb(0.16, 0.18, 0.24))
        ctx.fillPath()
        var y = title.minY - gap * 1.6 - bar
        var line = 0
        let paragraph = small ? 4 : 5
        while y >= text.minY - 0.5 {
            line += 1
            let last = line % paragraph == 0
            let w = last ? text.width * 0.58 : text.width
            ctx.addPath(roundedRect(CGRect(x: text.minX, y: y, width: w, height: bar), bar / 2))
            y -= bar + gap + (last && !small ? gap : 0)
        }
        ctx.setFillColor(ink)
        ctx.fillPath()
    }

    // Marcas de canto na cor de destaque, logo fora da mancha.
    let off: CGFloat = small ? 26 : 18
    let marks = text.insetBy(dx: -off, dy: -off)
    let len: CGFloat = small ? 100 : 70
    ctx.setStrokeColor(accent)
    ctx.setLineWidth(small ? 44 : 20)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for (p, dx, dy) in [(CGPoint(x: marks.minX, y: marks.minY), 1.0, 1.0), (CGPoint(x: marks.maxX, y: marks.minY), -1.0, 1.0),
                        (CGPoint(x: marks.minX, y: marks.maxY), 1.0, -1.0), (CGPoint(x: marks.maxX, y: marks.maxY), -1.0, -1.0)] {
        ctx.move(to: CGPoint(x: p.x + dx * len, y: p.y))
        ctx.addLine(to: p)
        ctx.addLine(to: CGPoint(x: p.x, y: p.y + dy * len))
    }
    ctx.strokePath()
}

func render(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let s = CGFloat(pixels) / 1024
    ctx.scaleBy(x: s, y: s)
    drawIcon(ctx, pixels: pixels)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "make-icon", code: 2) }
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try writePNG(render(pixels: px), iconset.appendingPathComponent(name))
    }
}
try writePNG(render(pixels: 1024), outDir.appendingPathComponent("icon_1024.png"))
print("iconset gravado em \(iconset.path)")
