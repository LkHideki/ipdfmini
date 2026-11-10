import Foundation
import CoreGraphics
import PDFKit

struct SpikeError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Resultado de um spike: seção markdown + linhas de resumo para o stdout.
struct SpikeResult {
    var markdown: String
    var summary: [String]
}

/// Acumulador de markdown.
struct Markdown {
    private(set) var lines: [String] = []

    mutating func heading(_ level: Int, _ text: String) {
        lines.append(String(repeating: "#", count: level) + " " + text)
        lines.append("")
    }

    mutating func para(_ text: String) {
        lines.append(text)
        lines.append("")
    }

    mutating func bullets(_ items: [String]) {
        lines.append(contentsOf: items.map { "- " + $0 })
        lines.append("")
    }

    mutating func table(_ header: [String], _ rows: [[String]]) {
        lines.append("| " + header.joined(separator: " | ") + " |")
        lines.append("|" + header.map { _ in "---" }.joined(separator: "|") + "|")
        for r in rows { lines.append("| " + r.joined(separator: " | ") + " |") }
        lines.append("")
    }

    var text: String { lines.joined(separator: "\n") }
}

// MARK: - Formatação

func fmt(_ v: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", v) }
func fmt(_ v: CGFloat, _ digits: Int = 2) -> String { fmt(Double(v), digits) }

func fmtRect(_ r: CGRect?) -> String {
    guard let r else { return "ausente" }
    return "(\(fmt(r.minX)), \(fmt(r.minY)), \(fmt(r.width))×\(fmt(r.height)))"
}

func fmtMB(_ bytes: Int) -> String { fmt(Double(bytes) / 1_048_576, 2) + " MB" }

func close(_ a: CGRect?, _ b: CGRect, tol: CGFloat = 0.01) -> Bool {
    guard let a else { return false }
    return abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol
        && abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
}

// MARK: - Arquivos e contagem de objetos

func fileSize(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
}

func now() -> Double { CFAbsoluteTimeGetCurrent() }

/// Conta ocorrências de uma sequência de bytes.
func countOccurrences(_ needle: String, in data: Data) -> Int {
    let n = Array(needle.utf8)
    return data.withUnsafeBytes { raw -> Int in
        guard let base = raw.baseAddress, raw.count >= n.count else { return 0 }
        var count = 0
        var off = 0
        while off < raw.count, let hit = memmem(base + off, raw.count - off, n, n.count) {
            count += 1
            off = base.distance(to: UnsafeRawPointer(hit)) + n.count
        }
        return count
    }
}

/// Conta "/Chave /Valor" tolerando ausência do espaço (o Quartz e o PDFKit divergem).
func countKey(_ key: String, _ value: String, in data: Data) -> Int {
    countOccurrences("/\(key) /\(value)", in: data) + countOccurrences("/\(key)/\(value)", in: data)
}

/// Contadores estruturais usados em S1 e S2.
struct ObjectCounts {
    var xobjects: Int      // /Type /XObject
    var forms: Int         // /Subtype /Form
    var images: Int        // /Subtype /Image
    var streams: Int       // endstream
    var objects: Int       // endobj
    var dct: Int           // /DCTDecode
    var flate: Int         // /FlateDecode

    init(_ d: Data) {
        xobjects = countKey("Type", "XObject", in: d)
        forms = countKey("Subtype", "Form", in: d)
        images = countKey("Subtype", "Image", in: d)
        streams = countOccurrences("endstream", in: d)
        objects = countOccurrences("endobj", in: d)
        dct = countOccurrences("/DCTDecode", in: d)
        flate = countOccurrences("/FlateDecode", in: d)
    }
}

/// Larguras (/Width N) de todas as imagens do arquivo.
func imageWidths(in data: Data) -> [Int] {
    let key = Array("/Width ".utf8)
    var out: [Int] = []
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var off = 0
        while off < raw.count, let hit = memmem(base + off, raw.count - off, key, key.count) {
            let start = base.distance(to: UnsafeRawPointer(hit)) + key.count
            var end = start
            let bytes = raw.bindMemory(to: UInt8.self)
            while end < raw.count, bytes[end] >= 48, bytes[end] <= 57 { end += 1 }
            if end > start, let s = String(bytes: bytes[start..<end], encoding: .ascii), let v = Int(s) { out.append(v) }
            off = start
        }
    }
    return out
}

// MARK: - Leitura crua de caixas via CGPDF

extension CGPDFPage {
    /// Caixa gravada no dicionário da página (sem herança nem interseção). nil se ausente.
    func rawBox(_ key: String) -> CGRect? {
        guard let dict = dictionary else { return nil }
        var arr: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dict, key, &arr), let a = arr, CGPDFArrayGetCount(a) == 4 else { return nil }
        var v = [CGPDFReal](repeating: 0, count: 4)
        for i in 0..<4 {
            var r: CGPDFReal = 0
            guard CGPDFArrayGetNumber(a, i, &r) else { return nil }
            v[i] = r
        }
        return CGRect(x: min(v[0], v[2]), y: min(v[1], v[3]), width: abs(v[2] - v[0]), height: abs(v[3] - v[1]))
    }

    /// Content stream da página decodificado (concatena o array, se houver).
    func contentData() -> Data {
        guard let dict = dictionary else { return Data() }
        var out = Data()
        func append(_ st: CGPDFStreamRef) {
            var fmt = CGPDFDataFormat.raw
            if let d = CGPDFStreamCopyData(st, &fmt) { out.append(d as Data) }
        }
        var stream: CGPDFStreamRef?
        if CGPDFDictionaryGetStream(dict, "Contents", &stream), let st = stream { append(st) }
        var arr: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dict, "Contents", &arr), let a = arr {
            for i in 0..<CGPDFArrayGetCount(a) {
                var st: CGPDFStreamRef?
                if CGPDFArrayGetStream(a, i, &st), let st { append(st) }
            }
        }
        return out
    }

    /// /Rotate gravado no dicionário (nil se ausente).
    var rawRotate: Int? {
        guard let dict = dictionary else { return nil }
        var r: CGPDFInteger = 0
        return CGPDFDictionaryGetInteger(dict, "Rotate", &r) ? Int(r) : nil
    }
}

let boxNames: [(label: String, key: String, pdfkit: PDFDisplayBox, cg: CGPDFBox)] = [
    ("MediaBox", "MediaBox", .mediaBox, .mediaBox),
    ("CropBox", "CropBox", .cropBox, .cropBox),
    ("TrimBox", "TrimBox", .trimBox, .trimBox),
    ("BleedBox", "BleedBox", .bleedBox, .bleedBox),
    ("ArtBox", "ArtBox", .artBox, .artBox),
]

/// Linhas das tabelas usam "|" como separador; escapa texto livre.
func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|") }

func tokens(in text: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: "P\\d\\dL\\d\\d") else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
}
