import CoreGraphics
import MiniGeometry
import LayoutEngine

/// Mapa origem ↔ saída derivado do plano.
///
/// Espaços: na origem, o espaço de página da geometria da página (o mesmo de
/// `Placement.sourceRect`); na saída, o espaço do usuário da página gravada
/// (MediaBox com origem em (0,0) e sem `/Rotate`, então igual ao de página).
/// Links, sumário, anotações e a devolução de anotações ao original passam
/// todos por aqui, para que o escritor e o validador não divirjam.
public struct PlanMapping: Sendable {
    struct Entry: Sendable {
        var outputPage: Int
        var sourcePage: Int
        var sourceRect: CGRect
        /// Espaço de página canônico da origem → saída.
        var transform: CGAffineTransform
        var inverse: CGAffineTransform
        /// `transform(sourceRect)`, eixo-alinhado.
        var outputRect: CGRect
        /// Geometria própria da colocação (pode diferir da canônica da página).
        var geometry: PageGeometry
    }

    let entries: [Entry]
    let bySource: [Int: [Int]]
    let byOutput: [Int: [Int]]
    let geometries: [Int: PageGeometry]

    /// Folga de contenção nas bordas (pontos sobre a borda pertencem à colocação).
    static let edgeTolerance: CGFloat = 1e-6

    /// `sourceGeometries` completa colocações sem `sourceGeometry`; sem nenhuma das
    /// duas, espaço de página = espaço do usuário.
    public init(plan: LayoutPlan, sourceGeometries: [Int: PageGeometry] = [:]) {
        var canon: [Int: PageGeometry] = [:]
        var list: [Entry] = []
        for (o, page) in plan.pages.enumerated() {
            for p in page.placements {
                let g = p.sourceGeometry ?? sourceGeometries[p.sourcePage]
                    ?? PageGeometry(effectiveBox: p.sourceRect, rotation: 0)
                let c = canon[p.sourcePage] ?? g
                canon[p.sourcePage] = c
                // Geometria própria diferente da canônica: converte pelo espaço do usuário.
                let toOwn = g == c ? CGAffineTransform.identity : c.pageToUser.concatenating(g.userToPage)
                let t = toOwn.concatenating(p.transform)
                // Retângulo da colocação levado ao espaço canônico.
                let rect = g == c ? p.sourceRect : p.sourceRect.applying(toOwn.inverted()).standardized
                list.append(Entry(outputPage: o, sourcePage: p.sourcePage, sourceRect: rect, transform: t,
                                  inverse: t.inverted(), outputRect: rect.applying(t).standardized, geometry: g))
            }
        }
        entries = list
        geometries = canon
        bySource = Dictionary(grouping: list.indices, by: { list[$0].sourcePage })
        byOutput = Dictionary(grouping: list.indices, by: { list[$0].outputPage })
    }

    /// Geometria que define o espaço de página da origem `page` (a da 1ª colocação).
    public func geometry(ofSourcePage page: Int) -> PageGeometry? { geometries[page] }

    /// Páginas de origem presentes no plano.
    public var sourcePages: [Int] { bySource.keys.sorted() }

    /// Todas as ocorrências do ponto na saída: uma por colocação cujo `sourceRect`
    /// o contém, na ordem das páginas de saída.
    public func map(point: CGPoint, fromSourcePage page: Int) -> [(outputPage: Int, point: CGPoint)] {
        (bySource[page] ?? []).compactMap { i in
            let e = entries[i]
            guard Self.contains(e.sourceRect, point) else { return nil }
            return (e.outputPage, point.applying(e.transform))
        }
    }

    /// Mapa inverso. Com colocações sobrepostas na saída, vale a desenhada
    /// por último (a que aparece). `nil` fora de toda colocação.
    public func unmap(point: CGPoint, onOutputPage page: Int) -> (sourcePage: Int, point: CGPoint)? {
        for i in (byOutput[page] ?? []).reversed() {
            let e = entries[i]
            guard Self.contains(e.outputRect, point) else { continue }
            return (e.sourcePage, point.applying(e.inverse))
        }
        return nil
    }

    /// Destino de navegação: 1ª ocorrência; ponto fora de toda colocação (ex.:
    /// topo da página, acima da 1ª linha) vai para a colocação mais próxima, com o
    /// ponto preso à borda dela. `nil` se a página não está no plano.
    public func destination(point: CGPoint, fromSourcePage page: Int) -> (outputPage: Int, point: CGPoint)? {
        if let first = map(point: point, fromSourcePage: page).first { return first }
        guard let i = nearestEntry(point, page) else { return nil }
        let e = entries[i]
        return (e.outputPage, Self.clamp(point, e.sourceRect).applying(e.transform))
    }

    /// Retângulo recortado por colocação: um pedaço por colocação que ele toca
    /// com área positiva (link que cai em duas colocações vira dois).
    public func map(rect: CGRect, fromSourcePage page: Int) -> [(outputPage: Int, rect: CGRect)] {
        pieces(of: rect, page).map { (entries[$0.entry].outputPage, $0.rect.applying(entries[$0.entry].transform).standardized) }
    }

    // MARK: - Interno

    /// Interseções com área positiva, por colocação (índice em `entries`).
    func pieces(of rect: CGRect, _ page: Int) -> [(entry: Int, rect: CGRect)] {
        let r = rect.standardized
        return (bySource[page] ?? []).compactMap { i in
            let x = r.intersection(entries[i].sourceRect)
            guard !x.isNull, x.width > 0, x.height > 0 else { return nil }
            return (i, x)
        }
    }

    func nearestEntry(_ p: CGPoint, _ page: Int) -> Int? {
        (bySource[page] ?? []).min { a, b in
            Self.distance(p, entries[a].sourceRect) < Self.distance(p, entries[b].sourceRect)
        }
    }

    /// Colocação que leva o ponto (1ª que o contém, senão a mais próxima).
    func entryFor(point p: CGPoint, _ page: Int) -> Int? {
        (bySource[page] ?? []).first { Self.contains(entries[$0].sourceRect, p) } ?? nearestEntry(p, page)
    }

    static func contains(_ r: CGRect, _ p: CGPoint) -> Bool {
        let t = edgeTolerance
        return p.x >= r.minX - t && p.x <= r.maxX + t && p.y >= r.minY - t && p.y <= r.maxY + t
    }

    static func clamp(_ p: CGPoint, _ r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let c = clamp(p, r)
        return hypot(p.x - c.x, p.y - c.y)
    }
}
