import CoreGraphics
import Foundation

/// Grava as caixas de página por atualização incremental do PDF.
///
/// Nem o CGContext de PDF nem o `PDFPage.setBounds` do PDFKit produzem uma MediaBox com origem
/// diferente de (0,0): ao serializar, ambos normalizam a origem para zero e deslocam as outras
/// caixas (verificado com PDFKit do macOS 26). Como o corpus precisa de origem não nula (PLAN.md
/// §5.1), as caixas são reescritas nos objetos de página por um trailer incremental: os bytes
/// originais não mudam e o arquivo continua válido (xref clássica + /Prev).
/// Caixas que o PDFKit inventa (TrimBox/BleedBox/ArtBox iguais à CropBox) também são removidas,
/// para que o arquivo contenha só o que a verdade declara.
enum BoxPatcher {
    struct Boxes {
        var media: CGRect
        var crop: CGRect?
        var trim: CGRect?
        var bleed: CGRect?
    }

    static func apply(_ data: Data, boxes: [Boxes]) -> Data {
        // ISO Latin-1 mapeia byte a byte: índices da String = deslocamentos no arquivo.
        let text = String(data: data, encoding: .isoLatin1)!
        let pageObjects = pageObjectNumbers(in: text)
        guard pageObjects.count == boxes.count else {
            fatalError("SyntheticCorpus: \(pageObjects.count) páginas no arquivo, \(boxes.count) esperadas")
        }
        guard let trailerRange = text.range(of: "trailer", options: .backwards),
              let startxrefRange = text.range(of: "startxref", options: .backwards) else {
            fatalError("SyntheticCorpus: PDF sem trailer clássico")
        }
        let afterStartxref = text[startxrefRange.upperBound...].split(whereSeparator: { $0.isWhitespace }).first!
        let prev = Int(afterStartxref)!
        let trailerDict = dictionary(in: text, from: trailerRange.upperBound)

        var out = Data(data)
        var offsets: [(Int, Int)] = []
        for (number, b) in zip(pageObjects, boxes) {
            let start = objectStart(number, in: text)
            var dict = dictionary(in: text, from: start)
            for key in ["MediaBox", "CropBox", "TrimBox", "BleedBox", "ArtBox"] {
                dict = dict.replacingOccurrences(of: "/\(key)\\s*\\[[^\\]]*\\]", with: "", options: .regularExpression)
            }
            var extra = " /MediaBox \(array(b.media))"
            if let c = b.crop { extra += " /CropBox \(array(c))" }
            if let t = b.trim { extra += " /TrimBox \(array(t))" }
            if let bl = b.bleed { extra += " /BleedBox \(array(bl))" }
            dict.removeLast(2)  // ">>"
            dict += extra + " >>"
            offsets.append((number, out.count + 1))
            out.append(Data("\n\(number) 0 obj\n\(dict)\nendobj".utf8))
        }
        out.append(Data("\n".utf8))
        let xrefOffset = out.count
        var xref = "xref\n"
        for (number, offset) in offsets.sorted(by: { $0.0 < $1.0 }) {
            xref += "\(number) 1\n" + String(format: "%010d 00000 n \n", offset)
        }
        var trailer = trailerDict
        trailer.removeLast(2)
        xref += "trailer\n\(trailer) /Prev \(prev) >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        out.append(Data(xref.utf8))
        return out
    }

    private static func array(_ r: CGRect) -> String {
        "[\(num(r.minX)) \(num(r.minY)) \(num(r.maxX)) \(num(r.maxY))]"
    }

    private static func num(_ v: CGFloat) -> String {
        let s = String(format: "%.4f", Double(v))
        return s.contains(".") ? s.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression) : s
    }

    /// Números dos objetos de página, na ordem de /Kids da árvore (plana) de páginas.
    private static func pageObjectNumbers(in text: String) -> [Int] {
        guard let pages = text.range(of: "/Type /Pages") ?? text.range(of: "/Type/Pages") else {
            fatalError("SyntheticCorpus: árvore de páginas não encontrada")
        }
        let dictStart = text[..<pages.lowerBound].range(of: "<<", options: .backwards)!.lowerBound
        let dict = dictionary(in: text, from: dictStart)
        guard let kids = dict.range(of: "/Kids\\s*\\[[^\\]]*\\]", options: .regularExpression) else {
            fatalError("SyntheticCorpus: /Kids ausente")
        }
        let refs = try! NSRegularExpression(pattern: "(\\d+) 0 R")
        let body = String(dict[kids])
        return refs.matches(in: body, range: NSRange(body.startIndex..., in: body)).map {
            Int(body[Range($0.range(at: 1), in: body)!])!
        }
    }

    private static func objectStart(_ number: Int, in text: String) -> String.Index {
        guard let r = text.range(of: "\n\(number) 0 obj") ?? text.range(of: "\r\(number) 0 obj") else {
            fatalError("SyntheticCorpus: objeto \(number) não encontrado")
        }
        return r.upperBound
    }

    /// Dicionário `<< ... >>` (com aninhamento) que começa em ou depois de `from`.
    private static func dictionary(in text: String, from: String.Index) -> String {
        let open = text[from...].range(of: "<<")!.lowerBound
        var depth = 0
        var i = open
        while i < text.endIndex {
            if text[i...].hasPrefix("<<") { depth += 1; i = text.index(i, offsetBy: 2); continue }
            if text[i...].hasPrefix(">>") {
                depth -= 1
                i = text.index(i, offsetBy: 2)
                if depth == 0 { return String(text[open..<i]) }
                continue
            }
            i = text.index(after: i)
        }
        fatalError("SyntheticCorpus: dicionário sem fechamento")
    }
}
