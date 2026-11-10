import Foundation
import CoreGraphics
import LayoutEngine

/// Operadores PDF das sobreposições e das máscaras, no espaço da página de saída.
///
/// Texto em Helvetica padrão (não embutida, `/IPMHelv` da C API) com larguras da
/// AFM: medir com CoreText exigiria criar CTFont, que trava em paralelo (SPIKES.md S3).
enum OverlayContent {
    static let indicatorGray: CGFloat = 0.45
    static let trackGray: CGFloat = 0.85
    static let barGray: CGFloat = 0.45
    static let markGray: CGFloat = 0.55
    static let markWidth: CGFloat = 0.5
    /// Corpo do indicador relativo à altura do retângulo (6 pt em 7 pt, como o planejador mede).
    static let indicatorFontFraction: CGFloat = 6.0 / 7.0
    /// Descendente da Helvetica (AFM: −207/1000).
    static let helveticaDescent: CGFloat = 0.207

    /// Retângulos brancos por cima do conteúdo (`Placement.hidden`).
    static func masks(_ rects: [CGRect]) -> String {
        guard !rects.isEmpty else { return "" }
        return "q 1 g " + rects.map { "\(n($0.minX)) \(n($0.minY)) \(n($0.width)) \(n($0.height)) re " }.joined() + "f Q\n"
    }

    static func ops(for overlay: Overlay, page: CGSize, cornerRadius: CGFloat) -> String {
        switch overlay {
        case let .pageIndicator(text, rect):
            let r = rect.standardized
            guard r.width > 0, r.height > 0, !text.isEmpty else { return "" }
            let codes = winAnsi(text)
            let units = codes.reduce(0) { $0 + width(of: $1) }
            var size = r.height * indicatorFontFraction
            // Encolhe para caber: o retângulo do planejador é estimado.
            if units > 0 { size = min(size, r.width * 1000 / CGFloat(units)) }
            let w = CGFloat(units) * size / 1000
            let x = r.maxX - w
            let y = r.minY + max(0, (r.height - size) / 2) + helveticaDescent * size
            let hex = codes.map { String(format: "%02X", $0) }.joined()
            return "q \(n(indicatorGray)) g BT /\(IPM.helvetica) \(n(size)) Tf \(n(x)) \(n(y)) Td <\(hex)> Tj ET Q\n"
        case let .progressBar(fraction, rect):
            let r = rect.standardized
            guard r.width > 0, r.height > 0 else { return "" }
            let f = CGFloat(min(max(fraction.isFinite ? fraction : 0, 0), 1))
            var s = "q \(n(trackGray)) g \(n(r.minX)) \(n(r.minY)) \(n(r.width)) \(n(r.height)) re f"
            if f > 0 { s += " \(n(barGray)) g \(n(r.minX)) \(n(r.minY)) \(n(r.width * f)) \(n(r.height)) re f" }
            return s + " Q\n"
        case let .continuityMark(y):
            guard y.isFinite else { return "" }
            // Fora dos quadrados de canto (§15.2.8); tracejado para não parecer conteúdo.
            let x0 = min(cornerRadius, page.width / 2), x1 = max(page.width - cornerRadius, page.width / 2)
            return "q \(n(markGray)) G \(n(markWidth)) w [2 2] 0 d \(n(x0)) \(n(y)) m \(n(x1)) \(n(y)) l S Q\n"
        }
    }

    /// Número decimal independente de locale, até 4 casas, sem zeros à direita.
    static func n(_ v: CGFloat) -> String {
        var s = String(format: "%.4f", Double(v))
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    // MARK: - WinAnsi e larguras

    /// cp1252: Latin-1 coincide em 0xA0–0xFF; o resto vira "?".
    static func winAnsi(_ s: String) -> [UInt8] {
        let extra: [Unicode.Scalar: UInt8] = [
            "€": 0x80, "‚": 0x82, "„": 0x84, "…": 0x85, "‘": 0x91, "’": 0x92, "“": 0x93, "”": 0x94,
            "•": 0x95, "–": 0x96, "—": 0x97,
        ]
        return s.unicodeScalars.map { u in
            if (0x20...0x7E).contains(u.value) || (0xA0...0xFF).contains(u.value) { return UInt8(u.value) }
            return extra[u] ?? 0x3F
        }
    }

    /// Larguras da Helvetica (AFM, milésimos do corpo) para 0x20–0x7E.
    static let ascii: [Int] = [
        278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, // 0x20
        556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556, // 0x30
        1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778, // 0x40
        667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, // 0x50
        333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, // 0x60
        556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584, // 0x70
    ]

    static func width(of code: UInt8) -> Int {
        switch code {
        case 0x20...0x7E: ascii[Int(code) - 0x20]
        case 0xB7: 278   // periodcentered
        case 0x95: 350   // bullet
        case 0x97: 1000  // emdash
        case 0xA0: 278   // espaço sem quebra
        default: 556
        }
    }
}

enum IPM {
    static let helvetica = "IPMHelv"
}
