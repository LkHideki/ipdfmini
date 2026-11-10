import CoreGraphics
import Foundation
import LayoutEngine
import MiniGeometry
import PDFAnalysis
import PDFKit

/// Desenho da pré-visualização direto do plano, sem gravar arquivo (§13).
///
/// PDFDocument não é seguro entre threads: quem chama usa uma instância por
/// thread (o app desenha tudo no MainActor). O PDF só é aberto em processo
/// depois que o filho o analisou sem cair.
public enum PlanRenderer {
    /// Cores dos sobrepostos do modo "Origem".
    public static let windowColor = CGColor(srgbRed: 1.0, green: 0.55, blue: 0.0, alpha: 1)
    public static let removedColor = CGColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1)
    static let hatchColor = CGColor(gray: 0.35, alpha: 0.55)

    // MARK: - Página de saída

    /// Desenha a página de saída `index` num contexto cujo espaço é o da página de
    /// saída (pt, y para cima, origem no canto inferior esquerdo).
    public static func drawOutputPage(_ index: Int, plan: LayoutPlan, analysis: DocumentAnalysis,
                                      document: PDFDocument, in ctx: CGContext) {
        guard plan.pages.indices.contains(index) else { return }
        let out = plan.pages[index]
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: out.sizePt))
        for p in out.placements {
            guard let page = document.page(at: p.sourcePage) else { continue }
            guard let geometry = p.sourceGeometry ?? analysis.pages.first(where: { $0.index == p.sourcePage })?.geometry else { continue }
            ctx.saveGState()
            ctx.concatenate(p.transform)
            ctx.clip(to: p.sourceRect)
            drawSource(page, geometry: geometry, in: ctx)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            for h in p.hidden { ctx.fill(h) }
            ctx.restoreGState()
        }
    }

    public static func renderOutputPage(_ index: Int, plan: LayoutPlan, analysis: DocumentAnalysis,
                                        document: PDFDocument, pixelsPerPoint ppp: CGFloat) -> CGImage? {
        guard plan.pages.indices.contains(index) else { return nil }
        let size = plan.pages[index].sizePt
        return bitmap(size: size, ppp: ppp) { ctx in
            drawOutputPage(index, plan: plan, analysis: analysis, document: document, in: ctx)
        }
    }

    // MARK: - Página de origem com sobrepostos

    /// Área desenhada no modo "Origem": a página mais as janelas que saem dela (E0 expande a janela).
    public static func sourceCanvas(_ sourceIndex: Int, plan: LayoutPlan, analysis: DocumentAnalysis) -> CGRect? {
        guard let a = analysis.pages.first(where: { $0.index == sourceIndex }) else { return nil }
        return windows(sourceIndex, plan: plan).reduce(a.pageBox) { $0.union($1.rect) }
    }

    /// Janelas de recorte da página de origem, com a página de saída de cada uma.
    public static func windows(_ sourceIndex: Int, plan: LayoutPlan) -> [(output: Int, rect: CGRect)] {
        plan.pages.enumerated().flatMap { j, out in
            out.placements.filter { $0.sourcePage == sourceIndex }.map { (j, $0.sourceRect) }
        }
    }

    /// Página de origem com: área fora das janelas hachurada, cabeçalho/rodapé removido
    /// (E2) e máscaras em vermelho, janelas em laranja (a da página de saída `highlight` mais grossa).
    public static func renderSourcePage(_ sourceIndex: Int, plan: LayoutPlan, analysis: DocumentAnalysis,
                                        document: PDFDocument, highlight: Int?, pixelsPerPoint ppp: CGFloat) -> CGImage? {
        guard let a = analysis.pages.first(where: { $0.index == sourceIndex }),
              let page = document.page(at: sourceIndex),
              let canvas = sourceCanvas(sourceIndex, plan: plan, analysis: analysis) else { return nil }
        let wins = windows(sourceIndex, plan: plan)
        let removed: [CGRect] = (plan.recipe.strategy == .aggressiveCrop ? a.removedHeaderFooter : [])
            + plan.pages.flatMap { $0.placements.filter { $0.sourcePage == sourceIndex }.flatMap(\.hidden) }
        return bitmap(size: canvas.size, ppp: ppp) { ctx in
            ctx.translateBy(x: -canvas.minX, y: -canvas.minY)
            ctx.setFillColor(CGColor(gray: 0.82, alpha: 1))
            ctx.fill(canvas)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(a.pageBox)
            ctx.saveGState()
            drawSource(page, geometry: a.geometry, in: ctx)
            ctx.restoreGState()

            // Medidas em pt de página: a imagem é exibida perto de 1 pt de tela por pt.
            let line: CGFloat = 0.75
            // Hachura em camada própria; as janelas são apagadas dela com .clear,
            // o que funciona mesmo quando janelas se sobrepõem (fatias, M3).
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            hatch(canvas, spacing: 8, color: hatchColor, lineWidth: line, in: ctx)
            ctx.setBlendMode(.clear)
            for w in wins { ctx.fill(w.rect) }
            ctx.setBlendMode(.normal)
            ctx.endTransparencyLayer()

            for r in removed {
                ctx.saveGState()
                ctx.clip(to: r)
                ctx.setFillColor(removedColor.copy(alpha: 0.12)!)
                ctx.fill(r)
                hatch(r, spacing: 5, color: removedColor.copy(alpha: 0.6)!, lineWidth: line, in: ctx)
                ctx.restoreGState()
            }
            for w in wins {
                let current = w.output == highlight
                ctx.setStrokeColor(windowColor.copy(alpha: current ? 1 : 0.55)!)
                ctx.setLineWidth(current ? 2.5 : 1.2)
                if !current { ctx.setLineDash(phase: 0, lengths: [6, 4]) }
                ctx.stroke(w.rect)
                ctx.setLineDash(phase: 0, lengths: [])
                if current { cornerMarks(w.rect, length: 16, lineWidth: 3.5, in: ctx) }
            }
        }
    }

    // MARK: - Primitivas

    /// Conteúdo da página em espaço de página (o da análise e do plano), como `GrayRaster.render`.
    static func drawSource(_ page: PDFPage, geometry: PageGeometry, in ctx: CGContext) {
        ctx.concatenate(geometry.userToPage)
        ctx.clip(to: geometry.effectiveBox)
        ctx.concatenate(page.transform(for: .cropBox).inverted())
        page.draw(with: .cropBox, to: ctx)
    }

    static func hatch(_ r: CGRect, spacing: CGFloat, color: CGColor, lineWidth: CGFloat, in ctx: CGContext) {
        guard spacing > 0, r.width > 0, r.height > 0 else { return }
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(lineWidth)
        var x = r.minX - r.height
        while x < r.maxX {
            ctx.move(to: CGPoint(x: x, y: r.minY))
            ctx.addLine(to: CGPoint(x: x + r.height, y: r.maxY))
            x += spacing
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Marcas de canto (o motivo do ícone): mostram onde a página foi "aparada".
    static func cornerMarks(_ r: CGRect, length l: CGFloat, lineWidth: CGFloat, in ctx: CGContext) {
        ctx.setStrokeColor(windowColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        for (p, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                            (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
            ctx.move(to: CGPoint(x: p.x + dx * l, y: p.y))
            ctx.addLine(to: p)
            ctx.addLine(to: CGPoint(x: p.x, y: p.y + dy * l))
        }
        ctx.strokePath()
    }

    /// Bitmap sRGB com o espaço em pontos (y para cima) já escalado.
    static func bitmap(size: CGSize, ppp: CGFloat, draw: (CGContext) -> Void) -> CGImage? {
        // Teto de pixels: página gigante (pôster) não pode estourar memória na pré-visualização.
        var s = ppp
        let maxPixels: CGFloat = 40_000_000
        if size.width * size.height * s * s > maxPixels { s = (maxPixels / (size.width * size.height)).squareRoot() }
        let w = Int((size.width * s).rounded(.up)), h = Int((size.height * s).rounded(.up))
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: s, y: s)
        draw(ctx)
        return ctx.makeImage()
    }
}
