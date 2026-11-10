import CoreGraphics
import MiniGeometry
import PDFAnalysis
@testable import LayoutEngine

// Análises fabricadas (sem PDF), com geometria conhecida.

enum Fx {
    static let book = CGSize(width: 432, height: 648)        // 6×9 in
    static let a4 = CGSize(width: 595, height: 842)
    /// Mancha de livro 6×9 da tabela §2.3.
    static let mancha = CGSize(width: 324, height: 518)
    /// Corpo de 10 pt (altura-x = 0,47 × corpo).
    static let bodyX10: CGFloat = 4.7

    static func page(_ index: Int, size: CGSize = book, origin: CGPoint = .zero, rotation: Int = 0,
                     ink: CGRect?, body: CGFloat? = bodyX10, smallest: CGFloat? = nil) -> PageAnalysis {
        // `size` é o tamanho exibido; a caixa no arquivo é girada de volta.
        let quarter = rotation % 180 != 0
        let fileBox = CGRect(origin: origin, size: quarter ? CGSize(width: size.height, height: size.width) : size)
        return PageAnalysis(index: index, boxes: PageBoxes(media: fileBox, crop: fileBox),
                            geometry: PageGeometry(effectiveBox: fileBox, rotation: rotation),
                            kind: ink == nil ? .empty : .digitalText, inkBox: ink,
                            bodyXHeightPt: ink == nil ? nil : body, smallestXHeightPt: ink == nil ? nil : smallest)
    }

    /// Mancha de livro: lombada desloca a mancha (ímpar à direita, par à esquerda).
    static func bookInk(_ index: Int, width: CGFloat = mancha.width, height: CGFloat = mancha.height,
                        origin: CGPoint = .zero) -> CGRect {
        let left: CGFloat = index % 2 == 0 ? 63 : 45
        let top: CGFloat = 648 - 65
        return CGRect(x: origin.x + left, y: origin.y + top - height, width: width, height: height)
    }

    static func doc(_ pages: [PageAnalysis], body: CGFloat? = bodyX10) -> DocumentAnalysis {
        DocumentAnalysis(sha256: "fixture", pageCount: pages.count, pages: pages, kind: .book, bodyXHeightPt: body)
    }

    /// Livro de `n` páginas com pequenas variações de largura dentro da classe.
    static func bookDoc(_ n: Int = 20, body: CGFloat? = bodyX10) -> DocumentAnalysis {
        doc((0..<n).map { i in page(i, ink: bookInk(i, width: 324 - CGFloat(i % 3))) }, body: body)
    }
}

extension LayoutPlan {
    var placements: [Placement] { pages.flatMap(\.placements) }

    func placement(_ page: Int) -> Placement { placements.first { $0.sourcePage == page }! }

    var exceptionPages: [Int] {
        warnings.compactMap { if case .scaleException(let p, _, _) = $0 { p } else { nil } }
    }
}

extension CGRect {
    func containsApprox(_ r: CGRect, eps: CGFloat = 1e-6) -> Bool { insetBy(dx: -eps, dy: -eps).contains(r) }
}
