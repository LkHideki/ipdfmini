import CoreGraphics

/// Classe do documento, mínima para o M1.
/// Só escolhe padrões; o usuário pode trocar. Quadrinhos, partitura,
/// formulário e scan de página dupla ficam para depois.
enum DocumentClassifier {
    static func classify(_ pages: [PageWork]) -> DocumentKind {
        let content = pages.filter { $0.analysis.kind != .empty }
        guard !content.isEmpty else { return .unknown }
        let scans = content.filter { $0.analysis.kind == .scan }.count
        if Double(scans) >= 0.6 * Double(content.count) { return .scannedBook }

        let sizes = content.map { $0.analysis.pageBox.size }
        let w = median(sizes.map(\.width)), h = median(sizes.map(\.height))
        guard w > 0, h > 0 else { return .unknown }
        if w / h >= 1.2 { return .slides }

        let texty = content.filter { $0.analysis.kind == .digitalText || $0.analysis.kind == .mixed }
        // colunas reais do XY-cut (calha que passou nos critérios do segmentador)
        let twoCol = texty.filter { $0.columns >= 2 }.count
        if !texty.isEmpty && Double(twoCol) >= 0.5 * Double(texty.count) { return .twoColumnArticle }

        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 0.04 * b }
        let a4 = near(w, 595.28) && near(h, 841.89)
        let letter = near(w, 612) && near(h, 792)
        if a4 || letter { return .a4Report }

        let aspect = h / w
        if aspect >= 1.38 && aspect <= 1.70 && w <= 520 { return .book }
        return .unknown
    }

    private static func median(_ v: [CGFloat]) -> CGFloat {
        let s = v.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }
}
