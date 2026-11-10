import Accelerate
import CoreGraphics
import MiniGeometry
import PDFKit

// Passadas por pixel vão por vImage/vDSP: além de rápidas em release, laço
// escalar em build de debug custa ~100 ns/pixel (2 M pixels por página A4).

/// Raster cinza 8 bits da área visível, em espaço de página. PLAN.md §5.3.
struct GrayRaster {
    let mapping: RasterMapping
    let width: Int
    let height: Int
    var pixels: [UInt8]

    /// Teto de pixels: páginas gigantes (até 14400 pt) baixam a resolução.
    static let maxPixels = 24_000_000

    /// Renderiza com `PDFPage.draw(with:to:)`: inclui anotações e aplica
    /// `/Rotate` (`CGContext.drawPDFPage` ignora anotações). O PDFKit aplica
    /// internamente `transform(for:)`; desfazê-lo e aplicar
    /// `PageGeometry.userToPage` mantém um único caminho de conversão.
    static func render(page: PDFPage, geometry: PageGeometry, pixelsPerPoint: CGFloat) -> GrayRaster? {
        let box = geometry.pageBox
        guard box.width > 0, box.height > 0 else { return nil }
        var s = pixelsPerPoint
        let area = Double(box.width * box.height) * Double(s * s)
        if area > Double(maxPixels) { s *= CGFloat((Double(maxPixels) / area).squareRoot()) }
        let mapping = RasterMapping(pageBox: box, pixelsPerPoint: s)
        let w = mapping.width, h = mapping.height
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 255, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setShouldSmoothFonts(false)
            ctx.setAllowsFontSubpixelQuantization(false)
            ctx.setShouldSubpixelQuantizeFonts(false)
            ctx.concatenate(geometry.userToPage.concatenating(mapping.pageToContext))
            ctx.clip(to: geometry.effectiveBox)
            ctx.concatenate(page.transform(for: .cropBox).inverted())
            page.draw(with: .cropBox, to: ctx)
            return true
        }
        return ok ? GrayRaster(mapping: mapping, width: w, height: h, pixels: pixels) : nil
    }

    func histogram() -> [Int] {
        var hist = [vImagePixelCount](repeating: 0, count: 256)
        var pixels = pixels
        pixels.withUnsafeMutableBytes { buf in
            var src = vImage_Buffer(data: buf.baseAddress, height: vImagePixelCount(height),
                                    width: vImagePixelCount(width), rowBytes: width)
            _ = hist.withUnsafeMutableBufferPointer { h in
                vImageHistogramCalculation_Planar8(&src, h.baseAddress!, vImage_Flags(kvImageNoFlags))
            }
        }
        return hist.map { Int($0) }
    }

    /// Tabela 256 → UInt8 aplicada a todos os pixels, convertida para Float.
    func lookup(_ table: [UInt8]) -> [Float] {
        var src = pixels
        var dst = [UInt8](repeating: 0, count: pixels.count)
        src.withUnsafeMutableBytes { s in
            dst.withUnsafeMutableBytes { d in
                var a = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                var b = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                _ = vImageTableLookUp_Planar8(&a, &b, table, vImage_Flags(kvImageNoFlags))
            }
        }
        var out = [Float](repeating: 0, count: dst.count)
        vDSP_vfltu8(dst, 1, &out, 1, vDSP_Length(dst.count))
        return out
    }
}

/// Máscara de tinta (1 = tinta) em Float, para os perfis saírem do vDSP.
struct InkMask {
    let width: Int
    let height: Int
    var values: [Float]
    let background: Int

    /// Vetor: diferença fixa em relação ao fundo; cobre fundos não brancos.
    static func vector(_ r: GrayRaster, background bg: Int, delta: Int = 20) -> InkMask {
        let lut = (0..<256).map { UInt8(abs($0 - bg) > delta ? 1 : 0) }
        return InkMask(width: r.width, height: r.height, values: r.lookup(lut), background: bg)
    }

    /// Scan: Otsu global. M4 troca por Sauvola (papel não uniforme, §5.3 passo 2).
    static func scan(_ r: GrayRaster, histogram: [Int], background bg: Int, minContrast: Int = 40) -> InkMask {
        let t = otsu(histogram)
        // contraste mínimo: página de papel limpo não vira "tinta" pelo Otsu
        let darkInk = bg > t
        let cut = darkInk ? min(t, bg - minContrast) : max(t, bg + minContrast)
        let lut = (0..<256).map { UInt8((darkInk ? $0 <= cut : $0 >= cut) ? 1 : 0) }
        return InkMask(width: r.width, height: r.height, values: r.lookup(lut), background: bg)
    }

    static func mode(_ h: [Int]) -> Int { h.indices.max { h[$0] < h[$1] } ?? 255 }

    static func otsu(_ h: [Int]) -> Int {
        let total = Double(h.reduce(0, +))
        guard total > 0 else { return 128 }
        var sumAll = 0.0
        for i in 0..<256 { sumAll += Double(i * h[i]) }
        var wB = 0.0, sumB = 0.0, best = 0.0, t = 128
        for i in 0..<256 {
            wB += Double(h[i])
            if wB == 0 { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += Double(i * h[i])
            let mB = sumB / wB, mF = (sumAll - sumB) / wF
            let between = wB * wF * (mB - mF) * (mB - mF)
            if between > best { best = between; t = i }
        }
        return t
    }

    /// Zera a máscara num retângulo de pixels (inclusivo-exclusivo).
    mutating func clear(x0: Int, y0: Int, x1: Int, y1: Int) {
        let x0 = max(0, x0), y0 = max(0, y0), x1 = min(width, x1), y1 = min(height, y1)
        guard x0 < x1, y0 < y1 else { return }
        let w = width
        values.withUnsafeMutableBufferPointer { b in
            for y in y0..<y1 { vDSP_vclr(b.baseAddress! + y * w + x0, 1, vDSP_Length(x1 - x0)) }
        }
    }

    /// Zera tudo fora do retângulo.
    mutating func keepOnly(x0: Int, y0: Int, x1: Int, y1: Int) {
        clear(x0: 0, y0: 0, x1: width, y1: y0)
        clear(x0: 0, y0: y1, x1: width, y1: height)
        clear(x0: 0, y0: y0, x1: x0, y1: y1)
        clear(x0: x1, y0: y0, x1: width, y1: y1)
    }

    /// Caixa (inclusivo-exclusivo) da tinta dentro de um retângulo; nil se não há.
    func bounds(x0: Int, y0: Int, x1: Int, y1: Int) -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
        let x0 = max(0, x0), y0 = max(0, y0), x1 = min(width, x1), y1 = min(height, y1)
        guard x0 < x1, y0 < y1 else { return nil }
        let n = x1 - x0, w = width
        var colMax = [Float](repeating: 0, count: n)
        var firstRow = -1, lastRow = -1
        values.withUnsafeBufferPointer { b in
            for y in y0..<y1 {
                let row = b.baseAddress! + y * w + x0
                var m: Float = 0
                vDSP_maxv(row, 1, &m, vDSP_Length(n))
                guard m > 0 else { continue }
                if firstRow < 0 { firstRow = y }
                lastRow = y
                colMax.withUnsafeMutableBufferPointer { c in
                    vDSP_vmax(row, 1, c.baseAddress!, 1, c.baseAddress!, 1, vDSP_Length(n))
                }
            }
        }
        guard firstRow >= 0, let a = colMax.firstIndex(where: { $0 > 0 }),
              let z = colMax.lastIndex(where: { $0 > 0 }) else { return nil }
        return (x0 + a, firstRow, x0 + z + 1, lastRow + 1)
    }

    // MARK: limpeza (scan)

    struct Component {
        var area = 0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        var touchesBorder = false
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
    }

    /// Remove componentes (8-conexos) que tocam a borda e são alongados
    /// (faixa de scanner, sombra de lombada) e salpicos com área < `minArea`.
    /// Furos de fichário ficam para o M4.
    mutating func clean(minArea: Int) {
        let w = width, h = height
        var labels = [Int32](repeating: 0, count: w * h)
        var comps: [Component] = []
        var stack: [Int32] = []
        stack.reserveCapacity(1 << 14)
        values.withUnsafeBufferPointer { m in
            labels.withUnsafeMutableBufferPointer { L in
                // só visita linhas com tinta: a maior parte do papel é pulada pelo vDSP
                for y in 0..<h {
                    var rowMax: Float = 0
                    vDSP_maxv(m.baseAddress! + y * w, 1, &rowMax, vDSP_Length(w))
                    guard rowMax > 0 else { continue }
                    for start in (y * w)..<(y * w + w) where m[start] != 0 && L[start] == 0 {
                        let id = Int32(comps.count + 1)
                        var c = Component()
                        L[start] = id
                        stack.append(Int32(start))
                        while let p = stack.popLast() {
                            let i = Int(p), x = i % w, yy = i / w
                            c.area += 1
                            if x < c.minX { c.minX = x }
                            if x > c.maxX { c.maxX = x }
                            if yy < c.minY { c.minY = yy }
                            if yy > c.maxY { c.maxY = yy }
                            if x == 0 || yy == 0 || x == w - 1 || yy == h - 1 { c.touchesBorder = true }
                            for ny in max(0, yy - 1)...min(h - 1, yy + 1) {
                                for nx in max(0, x - 1)...min(w - 1, x + 1) {
                                    let j = ny * w + nx
                                    if m[j] != 0 && L[j] == 0 { L[j] = id; stack.append(Int32(j)) }
                                }
                            }
                        }
                        comps.append(c)
                    }
                }
            }
        }
        let remove = comps.map { c -> Bool in
            if c.area < minArea { return true }
            guard c.touchesBorder else { return false }
            let long = max(c.width, c.height), short = min(c.width, c.height)
            let span = c.height >= c.width ? Double(c.height) / Double(h) : Double(c.width) / Double(w)
            return long >= 4 * short && span >= 0.15
        }
        guard remove.contains(true) else { return }
        for (i, c) in comps.enumerated() where remove[i] {
            let id = Int32(i + 1)
            labels.withUnsafeBufferPointer { L in
                values.withUnsafeMutableBufferPointer { b in
                    for y in c.minY...c.maxY {
                        for x in c.minX...c.maxX where L[y * w + x] == id { b[y * w + x] = 0 }
                    }
                }
            }
        }
    }

    // MARK: perfis de projeção

    /// Pixels de tinta por linha e por coluna (produto pela matriz de uns).
    func profiles() -> (rows: [Float], cols: [Float]) {
        var rows = [Float](repeating: 0, count: height)
        var cols = [Float](repeating: 0, count: width)
        let onesW = [Float](repeating: 1, count: width), onesH = [Float](repeating: 1, count: height)
        vDSP_mmul(values, 1, onesW, 1, &rows, 1, vDSP_Length(height), 1, vDSP_Length(width))
        vDSP_mmul(onesH, 1, values, 1, &cols, 1, 1, vDSP_Length(width), vDSP_Length(height))
        return (rows, cols)
    }

    /// Primeira/última linha e coluna com ≥ k pixels de tinta.
    static func inkBox(rows: [Float], cols: [Float], k: Float) -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
        guard let y0 = rows.firstIndex(where: { $0 >= k }), let y1 = rows.lastIndex(where: { $0 >= k }),
              let x0 = cols.firstIndex(where: { $0 >= k }), let x1 = cols.lastIndex(where: { $0 >= k })
        else { return nil }
        return (x0, y0, x1 + 1, y1 + 1)
    }
}

/// "Escuridão" |v − fundo| por pixel; em scan, só onde a máscara tem tinta,
/// para o ruído do papel não pesar. Base da medida de altura-x.
struct DarknessMap {
    let width: Int
    var values: [Float]

    init(_ r: GrayRaster, background bg: Int, mask: InkMask?) {
        width = r.width
        var f = [Float](repeating: 0, count: r.pixels.count)
        let n = vDSP_Length(f.count)
        var shift = -Float(bg)
        f.withUnsafeMutableBufferPointer { b in
            let p = b.baseAddress!
            vDSP_vfltu8(r.pixels, 1, p, 1, n)
            vDSP_vsadd(p, 1, &shift, p, 1, n)
            vDSP_vabs(p, 1, p, 1, n)
            if let mask { vDSP_vmul(p, 1, mask.values, 1, p, 1, n) }
        }
        values = f
    }

    /// Soma por linha de pixel num retângulo (perfil horizontal de cobertura).
    func rowProfile(x0: Int, y0: Int, x1: Int, y1: Int) -> [Float] {
        let height = values.count / max(1, width)
        let x0 = max(0, x0), y0 = max(0, y0), x1 = min(width, x1), y1 = min(height, y1)
        guard x0 < x1, y0 < y1 else { return [] }
        var out = [Float](repeating: 0, count: y1 - y0)
        values.withUnsafeBufferPointer { b in
            for y in y0..<y1 {
                var s: Float = 0
                vDSP_sve(b.baseAddress! + y * width + x0, 1, &s, vDSP_Length(x1 - x0))
                out[y - y0] = s
            }
        }
        return out
    }
}
