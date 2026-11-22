import Foundation

/// Regrava o `Producer` por atualização incremental.
///
/// O Quartz sobrescreve o `Producer` em todo `PDFDocument.write` (verificado:
/// o valor em `documentAttributes` é ignorado), e a devolução de anotações ao original depende dele para
/// vincular a saída à receita. Em vez de reescrever o arquivo, acrescenta-se ao
/// final uma nova revisão do objeto Info, com xref e trailer próprios (`/Prev`).
/// Só atua em arquivos com xref clássica (o que o Quartz grava); nos demais
/// devolve `false` e o arquivo fica intacto.
enum InfoPatch {
    static func setProducer(_ producer: String, in url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let tailLength = min(size, 2048)
            try handle.seek(toOffset: size - tailLength)
            let tail = latin1(try handle.read(upToCount: Int(tailLength)) ?? Data())

            // Último startxref → posição da xref.
            guard let sx = tail.range(of: "startxref", options: .backwards) else { return false }
            let afterSX = tail[sx.upperBound...].split(whereSeparator: { $0.isWhitespace })
            guard let xrefOffset = afterSX.first.flatMap({ UInt64($0) }), xrefOffset < size else { return false }

            try handle.seek(toOffset: xrefOffset)
            let section = latin1(try handle.readToEnd() ?? Data())
            guard section.hasPrefix("xref"),
                  let trailerRange = section.range(of: "trailer"),
                  let startxrefRange = section.range(of: "startxref", options: .backwards) else { return false }

            // Entradas da xref: token a token, imune a fim de linha.
            let tokens = section[section.index(section.startIndex, offsetBy: 4)..<trailerRange.lowerBound]
                .split(whereSeparator: { $0.isWhitespace }).map(String.init)
            var entries: [Int: (offset: UInt64, gen: Int)] = [:]
            var i = 0
            while i + 1 < tokens.count {
                guard let first = Int(tokens[i]), let count = Int(tokens[i + 1]), count >= 0 else { return false }
                i += 2
                for k in 0..<count {
                    guard i + 2 < tokens.count, let off = UInt64(tokens[i]), let gen = Int(tokens[i + 1]) else { return false }
                    if tokens[i + 2] == "n" { entries[first + k] = (off, gen) }
                    i += 3
                }
            }

            var trailer = String(section[trailerRange.upperBound..<startxrefRange.lowerBound])
            trailer = trailer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trailer.hasPrefix("<<"), trailer.hasSuffix(">>"), !trailer.contains("/Encrypt"),
                  let sizeValue = firstMatch(#"/Size\s+(\d+)"#, in: trailer).flatMap({ Int($0) }) else { return false }
            trailer = replacing(#"/Prev\s+\d+"#, in: trailer, with: "")

            let encoded = pdfString(producer)
            var infoNumber = sizeValue
            var infoGen = 0
            var infoBody = "<< /Producer \(encoded) >>"
            var newSize = sizeValue + 1

            if let ref = firstMatch(#"/Info\s+(\d+)\s+(\d+)\s+R"#, in: trailer, group: 1).flatMap({ Int($0) }),
               let entry = entries[ref] {
                // Revisa o Info existente: troca só o Producer.
                try handle.seek(toOffset: entry.offset)
                let head = latin1(try handle.read(upToCount: 4096) ?? Data())
                guard head.hasPrefix("\(ref) \(entry.gen) obj"), let end = head.range(of: "endobj") else { return false }
                let body = head[head.index(head.startIndex, offsetBy: "\(ref) \(entry.gen) obj".count)..<end.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard body.hasPrefix("<<"), body.hasSuffix(">>") else { return false }
                let producerPattern = #"/Producer\s*(\((?:\\.|[^\\)])*\)|<[0-9A-Fa-f\s]*>)"#
                if firstMatch(producerPattern, in: body) != nil {
                    infoBody = replacing(producerPattern, in: body, with: "/Producer \(encoded)")
                } else {
                    infoBody = "<< /Producer \(encoded) " + body.dropFirst(2)
                }
                infoNumber = ref
                infoGen = entry.gen
                newSize = sizeValue
            } else {
                trailer = trailer.dropLast(2) + " /Info \(infoNumber) 0 R >>"
            }
            trailer = replacing(#"/Size\s+\d+"#, in: trailer, with: "/Size \(newSize)")
            trailer = trailer.dropLast(2) + " /Prev \(xrefOffset) >>"

            // Bytes, não UTF-8: o Info herdado pode ter bytes PDFDocEncoding (> 0x7F).
            var out = bytes("\n")
            let objectOffset = size + UInt64(out.count)
            out += bytes("\(infoNumber) \(infoGen) obj\n\(infoBody)\nendobj\n")
            let newXref = size + UInt64(out.count)
            out += bytes("xref\n\(infoNumber) 1\n" + String(format: "%010llu %05d n \n", objectOffset, infoGen))
            out += bytes("trailer\n\(trailer)\nstartxref\n\(newXref)\n%%EOF\n")

            try handle.seek(toOffset: size)
            try handle.write(contentsOf: Data(out))
            return true
        } catch {
            return false
        }
    }

    // MARK: - Texto

    /// Latin-1 mapeia byte a byte, sem perda, o que o trecho binário exige.
    private static func latin1(_ d: Data) -> String { String(decoding: d.map { UInt16($0) }, as: UTF16.self) }

    private static func bytes(_ s: String) -> [UInt8] { s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) } }

    /// ASCII vira literal com escape; o resto, UTF-16BE em hexadecimal.
    static func pdfString(_ s: String) -> String {
        if s.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 }) {
            let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "(", with: "\\(")
                .replacingOccurrences(of: ")", with: "\\)")
            return "(\(escaped))"
        }
        let hex = (Array("\u{FEFF}".utf16) + Array(s.utf16)).map { String(format: "%04X", $0) }.joined()
        return "<\(hex)>"
    }

    private static func firstMatch(_ pattern: String, in s: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        guard group < m.numberOfRanges, let r = Range(m.range(at: group), in: s) else { return "" }
        return String(s[r])
    }

    private static func replacing(_ pattern: String, in s: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                           withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }
}
