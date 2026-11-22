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
        // Atualizações encadeadas (sumário + caixas): o /Prev antigo sai, o novo aponta para trás.
        var trailer = trailerDict.replacingOccurrences(of: "/Prev\\s+\\d+", with: "", options: .regularExpression)
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
        // Qualquer espaço em branco entre os tokens: o PDFKit do macOS 27 quebra linhas longas
        // dos dicionários ("/Type\n/Pages").
        guard let pages = text.range(of: "/Type\\s*/Pages(?![A-Za-z])", options: .regularExpression) else {
            fatalError("SyntheticCorpus: árvore de páginas não encontrada")
        }
        let dictStart = text[..<pages.lowerBound].range(of: "<<", options: .backwards)!.lowerBound
        let dict = dictionary(in: text, from: dictStart)
        guard let kids = dict.range(of: "/Kids\\s*\\[[^\\]]*\\]", options: .regularExpression) else {
            fatalError("SyntheticCorpus: /Kids ausente")
        }
        let refs = try! NSRegularExpression(pattern: "(\\d+)\\s+0\\s+R")
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

/// Grava o sumário por atualização incremental, como o `BoxPatcher` faz com as caixas.
///
/// O PDFKit do macOS 27.2 deixou de serializar um `outlineRoot` atribuído em memória
/// (`write`/`dataRepresentation` saem sem `/Outlines`); sumários que já existiam no arquivo
/// continuam preservados. O corpus precisa do sumário na verdade de referência, então ele entra
/// aqui: objetos novos de sumário + catálogo regravado com `/Outlines`. Itens fechados, como o
/// PDFKit fazia por padrão.
extension BoxPatcher {
    struct Outline {
        var title: String
        var page: Int
        var point: CGPoint
        var children: [Outline] = []
    }

    static func applyOutline(_ data: Data, _ items: [Outline]) -> Data {
        guard !items.isEmpty else { return data }
        let text = String(data: data, encoding: .isoLatin1)!
        let pages = pageObjectNumbers(in: text)
        guard let trailerRange = text.range(of: "trailer", options: .backwards),
              let startxrefRange = text.range(of: "startxref", options: .backwards) else {
            fatalError("SyntheticCorpus: PDF sem trailer clássico")
        }
        let prev = Int(text[startxrefRange.upperBound...].split(whereSeparator: { $0.isWhitespace }).first!)!
        let trailerDict = dictionary(in: text, from: trailerRange.upperBound)
        guard let size = intValue("Size", in: trailerDict), let root = refValue("Root", in: trailerDict) else {
            fatalError("SyntheticCorpus: trailer sem /Size ou /Root")
        }

        // Numeração: o dicionário /Outlines é `size`; os itens vêm depois, em pré-ordem.
        var objects: [(Int, String)] = []
        var next = size + 1
        func emit(_ list: [Outline], parent: Int) -> (first: Int, last: Int) {
            let numbers = list.map { _ in defer { next += 1 }; return next }
            for (i, item) in list.enumerated() {
                let n = numbers[i]
                var dict = "<< /Title \(pdfString(item.title)) /Parent \(parent) 0 R"
                dict += " /Dest [\(pages[item.page]) 0 R /XYZ \(num(item.point.x)) \(num(item.point.y)) null]"
                if i > 0 { dict += " /Prev \(numbers[i - 1]) 0 R" }
                if i + 1 < list.count { dict += " /Next \(numbers[i + 1]) 0 R" }
                if !item.children.isEmpty {
                    let (f, l) = emit(item.children, parent: n)
                    dict += " /First \(f) 0 R /Last \(l) 0 R /Count -\(item.children.count)"
                }
                objects.append((n, dict + " >>"))
            }
            return (numbers.first!, numbers.last!)
        }
        let (first, last) = emit(items, parent: size)
        objects.append((size, "<< /Type /Outlines /First \(first) 0 R /Last \(last) 0 R /Count \(items.count) >>"))

        var catalog = dictionary(in: text, from: objectStart(root, in: text))
        catalog = catalog.replacingOccurrences(of: "/Outlines\\s+\\d+\\s+\\d+\\s+R", with: "", options: .regularExpression)
        catalog.removeLast(2)
        objects.append((root, catalog + " /Outlines \(size) 0 R >>"))

        var out = Data(data)
        var offsets: [(Int, Int)] = []
        for (n, dict) in objects {
            offsets.append((n, out.count + 1))
            out.append(Data("\n\(n) 0 obj\n\(dict)\nendobj".utf8))
        }
        out.append(Data("\n".utf8))
        let xrefOffset = out.count
        var xref = "xref\n"
        for (n, offset) in offsets.sorted(by: { $0.0 < $1.0 }) {
            xref += "\(n) 1\n" + String(format: "%010d 00000 n \n", offset)
        }
        var trailer = trailerDict.replacingOccurrences(of: "/Size\\s+\\d+", with: "/Size \(next)", options: .regularExpression)
            .replacingOccurrences(of: "/Prev\\s+\\d+", with: "", options: .regularExpression)
        trailer.removeLast(2)
        xref += "trailer\n\(trailer) /Prev \(prev) >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        out.append(Data(xref.utf8))
        return out
    }

    private static func intValue(_ key: String, in dict: String) -> Int? {
        guard let r = dict.range(of: "/\(key)\\s+\\d+", options: .regularExpression) else { return nil }
        return Int(dict[r].split(whereSeparator: { $0.isWhitespace }).last!)
    }

    private static func refValue(_ key: String, in dict: String) -> Int? {
        guard let r = dict.range(of: "/\(key)\\s+\\d+\\s+\\d+\\s+R", options: .regularExpression) else { return nil }
        return Int(dict[r].split(whereSeparator: { $0.isWhitespace })[1])
    }

    /// Texto em UTF-16BE com BOM (`<FEFF…>`): vale para qualquer título, acentos inclusive.
    private static func pdfString(_ s: String) -> String {
        "<FEFF" + s.utf16.map { String(format: "%04X", $0) }.joined() + ">"
    }
}

/// Destinos "[/#2323N …]" que o PDFKit do macOS 27.2 grava para links criados em memória (N =
/// página 1-based, nome sem /Names: nenhum leitor resolve). Cada objeto afetado é regravado
/// numa atualização incremental com a referência real da página.
extension BoxPatcher {
    static func resolvePageIndexDestinations(_ data: Data) -> Data {
        let text = String(data: data, encoding: .isoLatin1)!
        let marker = try! NSRegularExpression(pattern: "/#2323(\\d+)")
        let all = NSRange(text.startIndex..., in: text)
        let hits = marker.matches(in: text, range: all)
        guard !hits.isEmpty else { return data }
        let pages = pageObjectNumbers(in: text)
        let header = try! NSRegularExpression(pattern: "(?:^|[\\r\\n])(\\d+) 0 obj")

        // Objeto que contém cada ocorrência: o último cabeçalho "N 0 obj" antes dela.
        var numbers = Set<Int>()
        for h in hits {
            let before = NSRange(location: 0, length: h.range.location)
            guard let last = header.matches(in: text, range: before).last,
                  let r = Range(last.range(at: 1), in: text) else { fatalError("SyntheticCorpus: destino fora de objeto") }
            numbers.insert(Int(text[r])!)
        }
        guard let trailerRange = text.range(of: "trailer", options: .backwards),
              let startxrefRange = text.range(of: "startxref", options: .backwards) else {
            fatalError("SyntheticCorpus: PDF sem trailer clássico")
        }
        let prev = Int(text[startxrefRange.upperBound...].split(whereSeparator: { $0.isWhitespace }).first!)!
        let trailerDict = dictionary(in: text, from: trailerRange.upperBound)

        var out = Data(data)
        var offsets: [(Int, Int)] = []
        for n in numbers.sorted() {
            let start = objectStart(n, in: text)
            guard let end = text[start...].range(of: "endobj") else { fatalError("SyntheticCorpus: objeto \(n) sem endobj") }
            let body = String(text[start..<end.lowerBound])
            precondition(!body.contains("stream"), "SyntheticCorpus: destino dentro de stream")
            let ns = NSMutableString(string: body)
            for m in marker.matches(in: body, range: NSRange(body.startIndex..., in: body)).reversed() {
                let k = Int((body as NSString).substring(with: m.range(at: 1)))!
                precondition(k >= 1 && k <= pages.count, "SyntheticCorpus: página \(k) inexistente")
                ns.replaceCharacters(in: m.range, with: "\(pages[k - 1]) 0 R")
            }
            offsets.append((n, out.count + 1))
            out.append(Data("\n\(n) 0 obj\(ns)endobj".utf8))
        }
        out.append(Data("\n".utf8))
        let xrefOffset = out.count
        var xref = "xref\n"
        for (n, offset) in offsets { xref += "\(n) 1\n" + String(format: "%010d 00000 n \n", offset) }
        var trailer = trailerDict.replacingOccurrences(of: "/Prev\\s+\\d+", with: "", options: .regularExpression)
        trailer.removeLast(2)
        xref += "trailer\n\(trailer) /Prev \(prev) >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        out.append(Data(xref.utf8))
        return out
    }
}
