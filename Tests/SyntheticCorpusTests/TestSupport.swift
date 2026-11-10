import CoreGraphics
import Foundation
import MiniGeometry
import PDFKit
@testable import SyntheticCorpus

/// Cada cenário é gerado uma vez por processo de teste.
enum Fixtures {
    static let docs: [Scenario: SyntheticDocument] = {
        var d: [Scenario: SyntheticDocument] = [:]
        for s in Scenario.allCases { d[s] = Corpus.make(s) }
        return d
    }()

    static func doc(_ s: Scenario) -> SyntheticDocument { docs[s]! }
}

func union(_ rs: [CGRect]) -> CGRect? { rs.dropFirst().reduce(rs.first) { $0?.union($1) } }

func wordCounts<S: Sequence>(_ words: S) -> [String: Int] where S.Element == String {
    var m: [String: Int] = [:]
    for w in words { m[w, default: 0] += 1 }
    return m
}

func extractedWords(_ data: Data) -> [String] {
    guard let doc = PDFDocument(data: data), let s = doc.string else { return [] }
    return s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
}

func cgDocument(_ data: Data) -> CGPDFDocument? {
    CGDataProvider(data: data as CFData).flatMap { CGPDFDocument($0) }
}

func close(_ a: CGRect, _ b: CGRect, tol: CGFloat) -> Bool {
    abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol
        && abs(a.maxX - b.maxX) <= tol && abs(a.maxY - b.maxY) <= tol
}

/// Renderiza a CropBox a 2 px/pt (com /Rotate aplicado) e devolve a caixa dos pixels
/// mais escuros que `threshold`, em espaço do usuário. Nulo se a página está em branco.
func rasterInkBox(of page: CGPDFPage, threshold: UInt8 = 200) -> CGRect? {
    let crop = page.getBoxRect(.cropBox)
    let geometry = PageGeometry(effectiveBox: crop, rotation: Int(page.rotationAngle))
    let size = geometry.displaySize
    let mapping = RasterMapping(pageBox: geometry.pageBox, pixelsPerPoint: 2)
    let w = mapping.width, h = mapping.height
    var pixels = [UInt8](repeating: 255, count: w * h)
    pixels.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.scaleBy(x: 2, y: 2)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                 rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
    }
    var x0 = w, x1 = -1, y0 = h, y1 = -1
    for y in 0..<h {
        for x in 0..<w where pixels[y * w + x] < threshold {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        }
    }
    guard x1 >= 0 else { return nil }
    let pageRect = mapping.pageRect(pixelX: x0, y: y0, toX: x1 + 1, toY: y1 + 1)
    return geometry.toUser(pageRect)
}

/// Total de itens de sumário (recursivo).
func outlineTotal(_ o: PDFOutline) -> Int {
    (0..<o.numberOfChildren).reduce(0) { $0 + 1 + outlineTotal(o.child(at: $1)!) }
}
