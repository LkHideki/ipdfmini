import Accelerate
import CoreGraphics
import Foundation
import LayoutEngine
import MiniGeometry
import PDFAnalysis
import PDFKit
import PDFWriting

// Invariantes verificados em toda saída.

public enum InvariantStatus: String, Codable, Sendable {
    case passed, failed, notApplicable
}

public struct Metric: Codable, Sendable, Equatable {
    public var name: String
    public var value: Double
    public var unit: String

    public init(_ name: String, _ value: Double, _ unit: String = "") {
        self.name = name
        self.value = value
        self.unit = unit
    }
}

public struct InvariantResult: Codable, Sendable, Equatable {
    /// "1a", "1b", "2" … "9".
    public var id: String
    public var title: String
    public var status: InvariantStatus
    public var detail: String
    public var metrics: [Metric]
    /// Páginas de origem afetadas (base 0).
    public var sourcePages: [Int]
    /// Páginas de saída afetadas (base 0).
    public var outputPages: [Int]

    public init(id: String, title: String, status: InvariantStatus, detail: String, metrics: [Metric] = [],
                sourcePages: [Int] = [], outputPages: [Int] = []) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.metrics = metrics
        self.sourcePages = sourcePages
        self.outputPages = outputPages
    }

    public func metric(_ name: String) -> Double? { metrics.first { $0.name == name }?.value }
}

public struct ValidationReport: Codable, Sendable, Equatable {
    public var results: [InvariantResult]

    public init(results: [InvariantResult]) { self.results = results }

    public var passed: Bool { !results.contains { $0.status == .failed } }
    public var failures: [InvariantResult] { results.filter { $0.status == .failed } }
    public func result(_ id: String) -> InvariantResult? { results.first { $0.id == id } }
}

public enum ValidatorError: Error, Equatable, Sendable {
    case cannotOpenSource(URL)
    case cannotOpenOutput(URL)
}

/// Verifica a saída contra a origem, a análise e o plano.
///
/// Toda medida de tinta usa o raster da análise (`GrayRaster`/`InkMask`, 2 px/pt,
/// mesmo limiar), para "tinta" significar a mesma coisa nas duas pontas.
/// Planos com várias colocações por página (E3+, `PlacementWriter`) são verificados
/// colocação a colocação.
public struct Validator: Sendable {
    public var pixelsPerPoint: CGFloat
    /// Pixels de tinta fora das colocações tolerados por página (inv. 1a).
    /// Zero: é o mesmo render, o mesmo limiar e a mesma limpeza que definiram a
    /// caixa de tinta, então um pixel descoberto já é tinta cortada. (Em scan a
    /// caixa ignora linhas/colunas com menos de k pixels; se salpico isolado
    /// virar falso positivo nos scans reais do M4, a folga entra aqui.)
    public var uncoveredTolerancePx: Int
    /// Inv. 1b: pixels diferentes tolerados por colocação = max(abs, rel × tinta da referência).
    /// As grades coincidem, mas em página girada o arredondamento de ponto flutuante
    /// das duas matrizes muda alguns pixels de borda de glifo (medido: ≤ 19 px em
    /// ~200 mil, 0,01%). 0,1% fica 25× abaixo de uma linha de texto perdida (~2,5%
    /// da tinta da página) e muito abaixo de um deslocamento de 1 px, que troca
    /// quase toda borda de glifo.
    public var writerInkAbsoluteTolerancePx: Int
    public var writerInkRelativeTolerance: Double
    /// Inv. 1b em página escaneada: a imagem é reamostrada de novo quando desenhada
    /// pelo Form XObject, com outro alinhamento de pixel, e o ruído do papel vira
    /// diferença real de cinza na borda das letras (medido: 0,15% no scannedPage a
    /// escala 1,196). 0,5% ainda fica 5× abaixo de uma linha perdida (~2,5%), e o
    /// 1a (plano) prova a cobertura independentemente.
    public var scanInkRelativeTolerance: Double
    /// Inv. 1b: pixel diferente = |Δcinza| > isto. Com limiar binário, 0,24–2,17% dos
    /// pixels trocam de lado só por antialiasing (Form XObject × desenho direto difere
    /// até 4 níveis); corte e deslocamento trocam pixels inteiros (Δ até 255).
    public var grayTolerance: Int
    /// Inv. 3: erro relativo de proporção (0,1%).
    public var aspectTolerance: Double
    /// Inv. 5: folga para o ponto de destino e o retângulo de link (pt).
    public var destinationTolerancePt: CGFloat
    /// Inv. 6: saída ≤ orçamento × origem. BoxWriter: 1,1× (vetor).
    public var boxSizeBudget: Double
    /// Inv. 6 com PlacementWriter: 1,3× (critério do M3).
    public var placementSizeBudget: Double
    /// Inv. 7: erro máximo de ida e volta (pt).
    public var roundTripTolerancePt: CGFloat
    /// Tarefas simultâneas de render; `nil` = núcleos ativos.
    public var maxConcurrency: Int?

    public init(pixelsPerPoint: CGFloat = 2, uncoveredTolerancePx: Int = 0,
                writerInkAbsoluteTolerancePx: Int = 4, writerInkRelativeTolerance: Double = 0.001, scanInkRelativeTolerance: Double = 0.005,
                grayTolerance: Int = 32, aspectTolerance: Double = 0.001, destinationTolerancePt: CGFloat = 0.5,
                boxSizeBudget: Double = 1.1, placementSizeBudget: Double = 1.3, roundTripTolerancePt: CGFloat = 0.01,
                maxConcurrency: Int? = nil) {
        self.pixelsPerPoint = pixelsPerPoint
        self.uncoveredTolerancePx = uncoveredTolerancePx
        self.writerInkAbsoluteTolerancePx = writerInkAbsoluteTolerancePx
        self.writerInkRelativeTolerance = writerInkRelativeTolerance
        self.scanInkRelativeTolerance = scanInkRelativeTolerance
        self.grayTolerance = grayTolerance
        self.aspectTolerance = aspectTolerance
        self.destinationTolerancePt = destinationTolerancePt
        self.boxSizeBudget = boxSizeBudget
        self.placementSizeBudget = placementSizeBudget
        self.roundTripTolerancePt = roundTripTolerancePt
        self.maxConcurrency = maxConcurrency
    }

    /// `writer`: quem gravou `output`; `nil` = o da estratégia do plano.
    /// `allowSplitting`: a divisão de páginas foi permitida (inv. 9 não se aplica);
    /// `nil` = deduz da estratégia do plano (E3+ só existe com divisão).
    public func validate(analysis: DocumentAnalysis, plan: LayoutPlan, source: SourceDocument,
                         output: URL, writer: WriterKind? = nil, allowSplitting: Bool? = nil) async throws -> ValidationReport {
        let writer = writer ?? WriterKind(strategy: plan.recipe.strategy)
        let allowSplitting = allowSplitting ?? StrategyID.splitsPages(plan.recipe.strategy)
        let srcData = try Data(contentsOf: source.url, options: .mappedIfSafe)
        let outData = try Data(contentsOf: output, options: .mappedIfSafe)
        let password = source.password
        let srcURL = source.url
        // Abre já aqui para falhar cedo com erro claro.
        _ = try Self.open(srcData, password: password, url: srcURL, isSource: true)
        let outCount = try Self.open(outData, password: nil, url: output, isSource: false).pageCount

        let sourceProbes = try await probeSources(analysis: analysis, plan: plan, data: srcData, password: password, url: srcURL)
        let outputProbes = try await probeOutputs(analysis: analysis, plan: plan, sources: sourceProbes,
                                                  srcData: srcData, password: password, srcURL: srcURL,
                                                  outData: outData, outURL: output, outCount: outCount, writer: writer)
        var results: [InvariantResult] = []
        results.append(noCutInPlan(sourceProbes))
        let scanPages = Set(analysis.pages.filter { $0.kind == .scan }.map(\.index))
        results.append(noCutInOutput(outputProbes, plan: plan, outCount: outCount, scanPages: scanPages))
        results.append(legibility(analysis: analysis, plan: plan))
        results.append(aspect(outputProbes, plan: plan, outCount: outCount))
        switch writer {
        case .box:
            results.append(InvariantResult(id: "4", title: "Texto", status: .notApplicable,
                                           detail: "BoxWriter não toca o content stream: o texto é o da origem"))
            results.append(try navigation(plan: plan, srcData: srcData, password: password, srcURL: srcURL,
                                          outData: outData, outURL: output))
        case .placement:
            results.append(try text(analysis: analysis, plan: plan, source: source, srcData: srcData, outData: outData,
                                    outURL: output))
            results.append(try placementNavigation(plan: plan, srcData: srcData, password: password, srcURL: srcURL,
                                                   outData: outData, outURL: output))
        }
        results.append(fileSize(analysis: analysis, sourceBytes: srcData.count, outputBytes: outData.count,
                                budget: writer == .box ? boxSizeBudget : placementSizeBudget))
        switch writer {
        case .box:
            results.append(InvariantResult(id: "7", title: "Ida e volta", status: .notApplicable,
                                           detail: "BoxWriter: a saída é a origem transladada (S2), sem mapa de colocações"))
        case .placement:
            results.append(roundTrip(plan: plan))
        }
        results.append(corners(outputProbes, plan: plan))
        results.append(onePagePerPage(analysis: analysis, plan: plan, outCount: outCount, allowSplitting: allowSplitting))
        return ValidationReport(results: results)
    }

    // MARK: - Sondas por página

    struct SourceProbe: Sendable {
        var index: Int
        var visible: CGRect
        var histogram: [Int]
        var background: Int
        var scan: Bool
        var totalInk: Int
        var uncoveredInk: Int
        /// Caixa (espaço de página da análise) da tinta descoberta, para a mensagem.
        var uncoveredBox: CGRect?
        var renderFailed: Bool
    }

    struct PlacementProbe: Sendable {
        /// Índice na página de saída.
        var placement: Int
        var referenceInk: Int
        var outputInk: Int
        /// Pixels com |Δcinza| acima da tolerância; `nil` = sem comparação (ver `note`).
        var mismatched: Int?
        var note: String?
    }

    struct OutputProbe: Sendable {
        var index: Int
        var displaySize: CGSize
        var outputInk: Int
        var placements: [PlacementProbe]
        var cornerInk: Int
        var renderFailed: Bool
    }

    static func open(_ data: Data, password: String?, url: URL, isSource: Bool) throws -> PDFDocument {
        guard let doc = PDFDocument(data: data) else {
            throw isSource ? ValidatorError.cannotOpenSource(url) : ValidatorError.cannotOpenOutput(url)
        }
        if doc.isLocked && !doc.unlock(withPassword: password ?? "") {
            throw isSource ? ValidatorError.cannotOpenSource(url) : ValidatorError.cannotOpenOutput(url)
        }
        return doc
    }

    private func workers(_ n: Int) -> Int {
        max(1, min(maxConcurrency ?? ProcessInfo.processInfo.activeProcessorCount, n))
    }

    /// Distribui `count` índices entre tarefas; cada tarefa abre as próprias
    /// instâncias de documento (PDFDocument não é seguro entre threads).
    private func parallel<T: Sendable>(_ count: Int, _ body: @escaping @Sendable (_ indices: [Int]) throws -> [T]) async throws -> [T] {
        let w = workers(count)
        return try await withThrowingTaskGroup(of: [T].self) { group in
            for k in 0..<w {
                let idx = Array(stride(from: k, to: count, by: w))
                group.addTask { try body(idx) }
            }
            var all: [T] = []
            for try await chunk in group { all += chunk }
            return all
        }
    }

    private func probeSources(analysis: DocumentAnalysis, plan: LayoutPlan, data: Data, password: String?,
                              url: URL) async throws -> [SourceProbe] {
        let ppp = pixelsPerPoint
        let probes: [SourceProbe] = try await parallel(analysis.pages.count) { indices in
            let doc = try Self.open(data, password: password, url: url, isSource: true)
            return indices.map { i in
                autoreleasepool { Self.probeSource(analysis.pages[i], doc: doc, plan: plan, ppp: ppp) }
            }
        }
        return probes.sorted { $0.index < $1.index }
    }

    /// Inv. 1a: renderiza a área visível, zera as colocações e as remoções pedidas, conta o resto.
    static func probeSource(_ a: PageAnalysis, doc: PDFDocument, plan: LayoutPlan, ppp: CGFloat) -> SourceProbe {
        let g = a.geometry
        var visible = a.boxes.crop.intersection(a.boxes.media)
        if visible.isNull || visible.isEmpty { visible = a.boxes.media }
        // g0: mesma geometria do raster da análise (área visível)
        let g0 = PageGeometry(effectiveBox: visible, rotation: g.rotation)
        func toG0(_ r: CGRect) -> CGRect { g0.toPage(g.toUser(r)) }
        guard let page = doc.page(at: a.index),
              let raster = GrayRaster.render(page: page, geometry: g0, pixelsPerPoint: ppp) else {
            return SourceProbe(index: a.index, visible: visible, histogram: [], background: 255, scan: false,
                               totalInk: 0, uncoveredInk: 0, uncoveredBox: nil, renderFailed: true)
        }
        let map = raster.mapping
        let hist = raster.histogram()
        let bg = InkMask.mode(hist)
        let scan = a.kind == .scan
        var mask = scan ? InkMask.scan(raster, histogram: hist, background: bg) : InkMask.vector(raster, background: bg)
        // Mesma limpeza da análise: em scan, salpico e faixa de scanner não são tinta.
        if scan { mask.clean(minArea: max(2, Int((map.pixelsPerPoint * map.pixelsPerPoint).rounded()))) }
        let total = Ink.sum(mask)
        // Em scan a caixa da análise vai da primeira à última linha e coluna com ≥ k pixels
        // (k = 1,5 px/pt): fio de 1 px que passa dela (medido: 8 px num scan real, 4 pt além
        // da caixa) não é tinta para a análise e não pode ser "tinta cortada" aqui.
        if scan, let b = Ink.boxWithAtLeast(mask, k: max(2, (1.5 * map.pixelsPerPoint).rounded())) {
            mask.clear(x0: 0, y0: 0, x1: mask.width, y1: b.y0)
            mask.clear(x0: 0, y0: b.y1, x1: mask.width, y1: mask.height)
            mask.clear(x0: 0, y0: b.y0, x1: b.x0, y1: b.y1)
            mask.clear(x0: b.x1, y0: b.y0, x1: mask.width, y1: b.y1)
        }

        for out in plan.pages {
            for p in out.placements where p.sourcePage == a.index {
                let r = map.pixelRect(toG0(p.sourceRect))
                mask.clear(x0: r.x0, y0: r.y0, x1: r.x1, y1: r.y1)
            }
        }
        for w in a.warnings {
            guard case let .ignoredRegion(region, reason) = w else { continue }
            let r = map.pixelRect(toG0(region))
            if reason == "cropMarks" {
                // A região de marcas de corte é a caixa que une as quatro faixas e
                // por isso atravessa a TrimBox; descartada é só a parte fora dela.
                let e = map.pixelRect(toG0(g.pageBox))
                mask.clear(x0: r.x0, y0: r.y0, x1: r.x1, y1: e.y0)
                mask.clear(x0: r.x0, y0: e.y1, x1: r.x1, y1: r.y1)
                mask.clear(x0: r.x0, y0: e.y0, x1: e.x0, y1: e.y1)
                mask.clear(x0: e.x1, y0: e.y0, x1: r.x1, y1: e.y1)
            } else {
                mask.clear(x0: r.x0, y0: r.y0, x1: r.x1, y1: r.y1)
            }
        }
        // E2: cabeçalho/rodapé removido é descarte pedido, como as regiões ignoradas.
        if plan.recipe.strategy == .aggressiveCrop {
            for region in a.removedHeaderFooter {
                let r = map.pixelRect(toG0(region))
                mask.clear(x0: r.x0, y0: r.y0, x1: r.x1, y1: r.y1)
            }
        }
        let left = Ink.sum(mask)
        var box: CGRect?
        if left > 0, let b = Ink.bounds(mask) {
            box = g.toPage(g0.toUser(map.pageRect(pixelX: b.x0, y: b.y0, toX: b.x1, toY: b.y1)))
        }
        return SourceProbe(index: a.index, visible: visible, histogram: hist, background: bg, scan: scan,
                           totalInk: total, uncoveredInk: left, uncoveredBox: box, renderFailed: false)
    }

    private func probeOutputs(analysis: DocumentAnalysis, plan: LayoutPlan, sources: [SourceProbe],
                              srcData: Data, password: String?, srcURL: URL,
                              outData: Data, outURL: URL, outCount: Int, writer: WriterKind) async throws -> [OutputProbe] {
        let ppp = pixelsPerPoint
        let corner = plan.profile.cornerRadiusPt
        let gray = grayTolerance
        let probes: [OutputProbe] = try await parallel(outCount) { indices in
            let src = try Self.open(srcData, password: password, url: srcURL, isSource: true)
            let out = try Self.open(outData, password: nil, url: outURL, isSource: false)
            return indices.map { j in
                autoreleasepool {
                    Self.probeOutput(j, out: out, src: src, analysis: analysis, plan: plan, sources: sources,
                                     ppp: ppp, cornerRadius: corner, writer: writer, grayTolerance: gray)
                }
            }
        }
        return probes.sorted { $0.index < $1.index }
    }

    /// Inv. 1b, 3 e 8 numa página de saída.
    ///
    /// Referência de 1b, por colocação: a janela renderizada direto da origem, na
    /// escala da colocação e recortada à área visível da origem. Região comparada:
    /// - BoxWriter: a página exibida inteira (escala 1), na grade da própria caixa (a origem
    ///   fica na janela pelo qpdf, ou vai a (0,0) quando o PDFKit grava);
    /// - PlacementWriter: `transform(sourceRect)` na página de saída.
    /// As duas grades de pixels partem do mesmo canto da janela, então dá para
    /// comparar pixel a pixel, não só a contagem.
    static func probeOutput(_ j: Int, out: PDFDocument, src: PDFDocument, analysis: DocumentAnalysis, plan: LayoutPlan,
                            sources: [SourceProbe], ppp: CGFloat, cornerRadius: CGFloat, writer: WriterKind,
                            grayTolerance: Int) -> OutputProbe {
        guard let page = out.page(at: j) else {
            return OutputProbe(index: j, displaySize: .zero, outputInk: 0, placements: [], cornerInk: 0, renderFailed: true)
        }
        var box = page.bounds(for: .mediaBox).intersection(page.bounds(for: .cropBox))
        if box.isNull || box.isEmpty { box = page.bounds(for: .mediaBox) }
        let og = PageGeometry(effectiveBox: box, rotation: page.rotation)
        let failed = OutputProbe(index: j, displaySize: og.displaySize, outputInk: 0, placements: [], cornerInk: 0,
                                 renderFailed: true)
        guard let raster = GrayRaster.render(page: page, geometry: og, pixelsPerPoint: ppp) else { return failed }
        let out = j < plan.pages.count ? plan.pages[j] : nil
        let placements = out?.placements ?? []

        // Limiar da página de origem da 1ª colocação; sem ela, o da própria saída.
        let firstProbe = placements.first.flatMap { p in sources.first { $0.index == p.sourcePage && !$0.renderFailed } }
        func mask(_ r: GrayRaster, _ probe: SourceProbe?) -> InkMask {
            guard let probe else { return InkMask.vector(r, background: InkMask.mode(r.histogram())) }
            // Sem limpeza de componentes: ela depende das bordas do raster, que diferem entre os dois.
            return probe.scan ? InkMask.scan(r, histogram: probe.histogram, background: probe.background)
                              : InkMask.vector(r, background: probe.background)
        }
        let outMask = mask(raster, firstProbe)
        let outInk = Ink.sum(outMask)

        // Quadrados de canto do perfil na página exibida: no BoxWriter a página tem a
        // escala da origem, então o raio vai dividido pela escala da colocação.
        var cornerInk = 0
        if let out, out.sizePt.width > 0 {
            let k = og.displaySize.width / out.sizePt.width
            for sq in og.pageBox.cornerSquares(radius: cornerRadius * k) {
                // Só pixels inteiros dentro do quadrado: o pixel de borda mistura cobertura de
                // dentro e de fora, e tinta que só encosta na borda (indicador de página; aba
                // de índice que o recorte deixa rente ao quadrado, fora da grade de pixels)
                // acendia o pixel sem ter nada dentro do quadrado. Tinta de verdade lá dentro
                // ocupa pixels inteiros.
                let m = raster.mapping, s = m.pixelsPerPoint
                let eps: CGFloat = 1e-6
                let x0 = Int(((sq.minX - m.pageBox.minX) * s - eps).rounded(.up))
                let x1 = Int(((sq.maxX - m.pageBox.minX) * s + eps).rounded(.down))
                let y0 = Int(((m.pageBox.maxY - sq.maxY) * s - eps).rounded(.up))
                let y1 = Int(((m.pageBox.maxY - sq.minY) * s + eps).rounded(.down))
                // Sem a fileira de pixels da borda da página: ali cai o antialias do recorte e
                // da imagem reamostrada que a janela corta (medido: página de anúncio O'Reilly,
                // 24 px de cinza 212–234 numa linha e numa coluna, iguais na origem renderizada
                // com a mesma janela). Glifo ou traço no canto ocupa mais que essa fileira.
                cornerInk += Ink.sum(outMask, x0: max(x0, 1), y0: max(y0, 1),
                                     x1: min(x1, outMask.width - 1), y1: min(y1, outMask.height - 1))
            }
        }

        // Sobreposições do escritor (indicador de página, marca de continuidade) podem cair
        // dentro da região de uma colocação (E0 de página vazia ocupa a tela toda): fora da comparação.
        // O BoxWriter não desenha sobreposições (e a página dele não está no espaço do plano).
        let excluded: [CGRect] = writer == .box ? [] : (out?.overlays ?? []).compactMap {
            switch $0 {
            case .continuityMark(let y): CGRect(x: -1e6, y: y - 1.5, width: 2e6, height: 3)
            case .pageIndicator(_, let r), .progressBar(_, let r): r.insetBy(dx: -1, dy: -1)
            }
        }

        var results: [PlacementProbe] = []
        for (k, p) in placements.enumerated() {
            var r = PlacementProbe(placement: k, referenceInk: 0, outputInk: 0, mismatched: nil, note: nil)
            guard let probe = sources.first(where: { $0.index == p.sourcePage && !$0.renderFailed }),
                  let a = analysis.pages.first(where: { $0.index == p.sourcePage }),
                  let srcPage = src.page(at: p.sourcePage) else {
                r.note = "origem p. \(p.sourcePage + 1) sem render"
                results.append(r)
                continue
            }
            let g = p.sourceGeometry ?? a.geometry
            let window = g.toUser(p.sourceRect)
            let rg = PageGeometry(effectiveBox: window, rotation: g.rotation)
            var clip = window.intersection(probe.visible)
            if clip.isNull { clip = .zero }

            // Região de saída (espaço de página exibida) e escala da referência.
            let region: CGRect, refScale: CGFloat, outRaster: GrayRaster?
            switch writer {
            case .box:
                region = og.pageBox
                refScale = 1
                outRaster = raster
            case .placement:
                let t = p.transform
                // Fatias e colunas só escalam e transladam; outra matriz pede outra referência.
                guard abs(t.b) < 1e-9, abs(t.c) < 1e-9, t.a > 0, abs(t.a - t.d) <= 1e-9 * t.a else {
                    r.note = "matriz com rotação ou cisalhamento: comparação não suportada"
                    results.append(r)
                    continue
                }
                region = p.sourceRect.applying(t).standardized
                refScale = t.a
                outRaster = GrayRaster.render(page: page, geometry: PageGeometry(effectiveBox: og.toUser(region),
                                                                                rotation: page.rotation),
                                              pixelsPerPoint: ppp)
            }
            guard var ref = GrayRaster.render(page: srcPage, geometry: rg, pixelsPerPoint: ppp * refScale, clip: clip),
                  let outR = outRaster else {
                r.note = "falha ao renderizar"
                results.append(r)
                continue
            }
            // Região oculta: o escritor pinta de branco; na referência também.
            for h in p.hidden {
                let x = h.standardized.intersection(p.sourceRect)
                guard !x.isNull, x.width > 0, x.height > 0 else { continue }
                let pr = ref.mapping.pixelRect(rg.toPage(g.toUser(x)))
                for y in pr.y0..<max(pr.y0, pr.y1) { for xx in pr.x0..<max(pr.x0, pr.x1) { ref.pixels[y * ref.width + xx] = 255 } }
            }
            // Mesma grade a menos de arredondamento de ponto flutuante no tamanho (ceil).
            guard abs(ref.width - outR.width) <= 1, abs(ref.height - outR.height) <= 1 else {
                r.note = "grades divergem (\(ref.width)×\(ref.height) contra \(outR.width)×\(outR.height) px)"
                results.append(r)
                continue
            }
            let w = min(ref.width, outR.width), h = min(ref.height, outR.height)
            var outC = outR
            for e in excluded where e.intersects(region) {
                // Grades alinhadas: o mesmo retângulo de pixels nas duas.
                let pr = outR.mapping.pixelRect(og.toPage(og.toUser(e.intersection(region))))
                for y in pr.y0..<min(h, max(pr.y0, pr.y1)) {
                    for x in pr.x0..<min(w, max(pr.x0, pr.x1)) {
                        ref.pixels[y * ref.width + x] = 255
                        outC.pixels[y * outC.width + x] = 255
                    }
                }
            }
            let refMask = mask(ref, probe), regionMask = mask(outC, probe)
            r.referenceInk = Ink.sum(refMask, x0: 0, y0: 0, x1: w, y1: h)
            r.outputInk = Ink.sum(regionMask, x0: 0, y0: 0, x1: w, y1: h)
            r.mismatched = Gray.mismatched(ref, outC, width: w, height: h, tolerance: grayTolerance)
            results.append(r)
        }
        return OutputProbe(index: j, displaySize: og.displaySize, outputInk: outInk, placements: results,
                           cornerInk: cornerInk, renderFailed: false)
    }

    // MARK: - Invariantes

    func noCutInPlan(_ probes: [SourceProbe]) -> InvariantResult {
        var bad: [Int] = []
        var worst = 0, total = 0, failedRenders: [Int] = []
        var notes: [String] = []
        for p in probes {
            if p.renderFailed { failedRenders.append(p.index); continue }
            total += p.uncoveredInk
            worst = max(worst, p.uncoveredInk)
            if p.uncoveredInk > uncoveredTolerancePx {
                bad.append(p.index)
                let where_ = p.uncoveredBox.map { " em \(Describe.rect($0))" } ?? ""
                notes.append("p. \(p.index + 1): \(p.uncoveredInk) px\(where_)")
            }
        }
        let metrics = [Metric("tinta descoberta (total)", Double(total), "px"),
                       Metric("tinta descoberta (pior página)", Double(worst), "px"),
                       Metric("ε", Double(uncoveredTolerancePx), "px")]
        let ok = bad.isEmpty && failedRenders.isEmpty
        var detail = ok ? "toda tinta da origem está dentro de alguma colocação" : "tinta fora das colocações: " + notes.joined(separator: "; ")
        if !failedRenders.isEmpty { detail += (ok ? "" : "; ") + "falha ao renderizar origem: p. " + failedRenders.map { "\($0 + 1)" }.joined(separator: ", ") }
        return InvariantResult(id: "1a", title: "Nenhuma tinta cortada (plano)", status: ok ? .passed : .failed,
                               detail: detail, metrics: metrics, sourcePages: (bad + failedRenders).sorted())
    }

    func noCutInOutput(_ probes: [OutputProbe], plan: LayoutPlan, outCount: Int, scanPages: Set<Int> = []) -> InvariantResult {
        var bad: [Int] = []
        var notes: [String] = []
        var worstRel = 0.0, worstMismatch = 0, refTotal = 0, outTotal = 0, compared = 0
        if outCount != plan.pages.count {
            return InvariantResult(id: "1b", title: "Nenhuma tinta cortada (saída)", status: .failed,
                                   detail: "saída com \(outCount) páginas; o plano tem \(plan.pages.count)")
        }
        for p in probes {
            guard !p.renderFailed else {
                bad.append(p.index); notes.append("saída p. \(p.index + 1): sem render"); continue
            }
            var pageBad = false
            for c in p.placements {
                let tag = plan.pages[p.index].placements.count > 1 ? " colocação \(c.placement + 1)" : ""
                guard let m = c.mismatched else {
                    pageBad = true
                    notes.append("saída p. \(p.index + 1)\(tag): \(c.note ?? "sem comparação")")
                    continue
                }
                compared += 1
                refTotal += c.referenceInk
                outTotal += c.outputInk
                let rel = c.referenceInk > 0 ? Double(m) / Double(c.referenceInk) : (m > 0 ? 1 : 0)
                worstRel = max(worstRel, rel)
                worstMismatch = max(worstMismatch, m)
                let source = plan.pages[p.index].placements[c.placement].sourcePage
                let rel0 = scanPages.contains(source) ? scanInkRelativeTolerance : writerInkRelativeTolerance
                let tol = max(Double(writerInkAbsoluteTolerancePx), rel0 * Double(c.referenceInk))
                if Double(m) > tol {
                    pageBad = true
                    notes.append("saída p. \(p.index + 1)\(tag): \(m) px diferentes (tinta \(c.outputInk) px contra \(c.referenceInk) px na janela de origem)")
                }
            }
            if pageBad { bad.append(p.index) }
        }
        let metrics = [Metric("tinta na saída", Double(outTotal), "px"),
                       Metric("tinta nas janelas de origem", Double(refTotal), "px"),
                       Metric("colocações comparadas", Double(compared)),
                       Metric("pior diferença relativa", worstRel * 100, "%"),
                       Metric("pior diferença pixel a pixel", Double(worstMismatch), "px")]
        let ok = bad.isEmpty
        return InvariantResult(id: "1b", title: "Nenhuma tinta cortada (saída)", status: ok ? .passed : .failed,
                               detail: ok ? "cada colocação gravada tem a mesma tinta da janela de origem"
                                          : notes.prefix(8).joined(separator: "; "),
                               metrics: metrics, outputPages: bad)
    }

    /// Colocação mostra texto do tamanho do corpo (`BodyText.band`)? Com blocos, só as
    /// linhas de blocos de texto (rótulo dentro de figura não é corpo, como no plano);
    /// sem blocos, as linhas da página; página com tinta e sem linhas (scan sem OCR)
    /// conta como corpo, como antes do M3: melhor avisar demais.
    static func showsBody(_ p: Placement, page a: PageAnalysis, body: CGFloat) -> Bool {
        let lines = a.blocks.isEmpty ? a.lines : a.blocks.filter { !$0.isAtomic }.flatMap(\.lines)
        guard !lines.isEmpty else { return a.blocks.isEmpty }
        return lines.contains { l in
            p.sourceRect.contains(CGPoint(x: l.rect.midX, y: l.rect.midY)) && BodyText.isBodySized(l.xHeightPt, body: body)
        }
    }

    /// Inv. 2: toda colocação que mostra texto do tamanho do corpo o mostra ≥ mínimo,
    /// ou o plano avisa. Em E5, resumo de largura total reduzido conta (é corpo).
    func legibility(analysis: DocumentAnalysis, plan: LayoutPlan) -> InvariantResult {
        let leg = plan.recipe.legibility
        let warned = plan.warnings.contains { if case .belowMinimumLegibility = $0 { true } else { false } }
        guard let body = Self.bodyXHeightPt(analysis) else {
            return InvariantResult(id: "2", title: "Legibilidade", status: warned ? .passed : .notApplicable,
                                   detail: "sem altura-x do corpo na análise")
        }
        var minMM = Double.infinity
        var below: [Int] = []
        for (j, out) in plan.pages.enumerated() {
            var pageBelow = false
            for p in out.placements {
                guard let a = analysis.pages.first(where: { $0.index == p.sourcePage }), a.inkBox != nil,
                      Self.showsBody(p, page: a, body: body) else { continue }
                let mm = Legibility.finalXHeightMM(sourceXHeightPt: Double(body), scale: Double(p.scale))
                minMM = min(minMM, mm)
                if mm < leg.minimumMM { pageBelow = true }
            }
            if pageBelow { below.append(j) }
        }
        guard minMM.isFinite else {
            return InvariantResult(id: "2", title: "Legibilidade", status: .notApplicable, detail: "nenhuma página com tinta")
        }
        let pt = Legibility.pointSizeEquivalent(xHeightMM: minMM)
        let metrics = [Metric("altura-x final mínima", minMM, "mm"), Metric("corpo equivalente mínimo", pt, "pt"),
                       Metric("mínimo do perfil", leg.minimumMM, "mm")]
        let status: InvariantStatus
        let detail: String
        if below.isEmpty {
            status = .passed
            detail = "corpo ≥ mínimo em todas as páginas (\(Describe.number(pt)) pt equivalente no pior caso)"
        } else if warned {
            status = .passed
            detail = "\(below.count) páginas abaixo do mínimo, com aviso no plano"
        } else {
            status = .failed
            detail = "\(below.count) páginas abaixo do mínimo sem aviso no plano (\(Describe.number(pt)) pt equivalente no pior caso)"
        }
        return InvariantResult(id: "2", title: "Legibilidade", status: status, detail: detail, metrics: metrics, outputPages: below)
    }

    /// Mesma regra das estimativas: a do documento; sem ela, a mediana das páginas.
    static func bodyXHeightPt(_ doc: DocumentAnalysis) -> CGFloat? {
        if let b = doc.bodyXHeightPt, b > 0 { return b }
        let v = doc.pages.compactMap(\.bodyXHeightPt).filter { $0 > 0 }.sorted()
        return v.isEmpty ? nil : v[v.count / 2]
    }

    func aspect(_ probes: [OutputProbe], plan: LayoutPlan, outCount: Int) -> InvariantResult {
        let target = Double(plan.profile.aspect)
        var worst = 0.0
        var bad: [Int] = []
        for p in probes {
            let s = p.displaySize
            guard s.width > 0, s.height > 0 else { bad.append(p.index); continue }
            let err = abs(Double(s.height / s.width) / target - 1)
            worst = max(worst, err)
            if err > aspectTolerance { bad.append(p.index) }
        }
        let ok = bad.isEmpty && outCount == plan.pages.count
        let metrics = [Metric("proporção do viewport", target), Metric("pior erro relativo", worst * 100, "%"),
                       Metric("tolerância", aspectTolerance * 100, "%")]
        return InvariantResult(id: "3", title: "Proporção", status: ok ? .passed : .failed,
                               detail: ok ? "todas as páginas exibidas têm a proporção do viewport"
                                          : "\(bad.count) páginas fora da proporção", metrics: metrics, outputPages: bad)
    }

    func fileSize(analysis: DocumentAnalysis, sourceBytes: Int, outputBytes: Int, budget: Double) -> InvariantResult {
        let ratio = sourceBytes > 0 ? Double(outputBytes) / Double(sourceBytes) : 0
        let ok = ratio <= budget
        var detail = "saída \(Describe.number(ratio, decimals: 3))× a origem"
            + (ok ? " (meta ≤ \(Describe.number(budget))×)" : ", acima de \(Describe.number(budget))×")
        // A meta é ≤ 0,6× em scan colorido, o que exige reamostrar (M4); aqui só o teto de vetor.
        if analysis.kind == .scannedBook { detail += "; meta de scan (≤ 0,6×) depende da reamostragem do M4" }
        return InvariantResult(id: "6", title: "Tamanho", status: ok ? .passed : .failed, detail: detail,
                               metrics: [Metric("origem", Double(sourceBytes), "B"), Metric("saída", Double(outputBytes), "B"),
                                         Metric("razão", ratio), Metric("orçamento", budget)])
    }

    func corners(_ probes: [OutputProbe], plan: LayoutPlan) -> InvariantResult {
        var bad: [Int] = [], total = 0
        for p in probes where p.renderFailed || p.cornerInk > 0 {
            bad.append(p.index)
        }
        for p in probes { total += p.cornerInk }
        let ok = bad.isEmpty
        return InvariantResult(id: "8", title: "Cantos", status: ok ? .passed : .failed,
                               detail: ok ? "quadrados de canto sem tinta em todas as páginas" : "tinta nos cantos em \(bad.count) páginas",
                               metrics: [Metric("raio do perfil", Double(plan.profile.cornerRadiusPt), "pt"),
                                         Metric("tinta nos cantos", Double(total), "px")],
                               outputPages: bad)
    }

    /// Inv. 9: sem divisão permitida, a página de saída j mostra só a página de origem j.
    /// O `LayoutPlan` não tem como declarar página omitida (página vazia sai inteira, com
    /// aviso), então a contagem esperada é a da origem.
    func onePagePerPage(analysis: DocumentAnalysis, plan: LayoutPlan, outCount: Int,
                        allowSplitting: Bool) -> InvariantResult {
        let title = "Uma página por página"
        let n = analysis.pages.count
        let metrics = [Metric("páginas de origem", Double(n)), Metric("páginas no plano", Double(plan.pages.count)),
                       Metric("páginas de saída", Double(outCount))]
        guard !allowSplitting else {
            return InvariantResult(id: "9", title: title, status: .notApplicable,
                                   detail: "divisão de páginas permitida: uma página de origem pode ocupar várias telas",
                                   metrics: metrics)
        }
        var badOut: [Int] = [], badSrc = Set<Int>()
        for (j, page) in plan.pages.enumerated() {
            let sources = Set(page.placements.map(\.sourcePage))
            let expected = j < n ? analysis.pages[j].index : nil
            if sources.count != 1 || sources.first != expected {
                badOut.append(j)
                badSrc.formUnion(sources)
            }
        }
        // Página de origem sem página de saída própria (plano curto).
        if plan.pages.count < n { for k in plan.pages.count..<n { badSrc.insert(analysis.pages[k].index) } }
        let ok = badOut.isEmpty && plan.pages.count == n && outCount == n
        let detail: String
        if ok {
            detail = "\(n) páginas de origem → \(outCount) páginas de saída, cada uma com a própria página, na ordem"
        } else if !badOut.isEmpty {
            detail = "\(badOut.count) páginas de saída fora da regra 1 → 1 (origem misturada, repetida ou fora de ordem)"
        } else {
            detail = "\(n) páginas de origem, \(plan.pages.count) no plano e \(outCount) na saída"
        }
        return InvariantResult(id: "9", title: title, status: ok ? .passed : .failed, detail: detail, metrics: metrics,
                               sourcePages: badSrc.sorted(), outputPages: badOut)
    }

    // MARK: - Navegação (inv. 5)

    struct NavTarget {
        var page: Int
        var point: CGPoint?
    }

    struct OutlineEntry {
        var label: String
        var target: NavTarget?
    }

    static func target(_ dest: PDFDestination?, in doc: PDFDocument) -> NavTarget? {
        guard let dest, let page = dest.page else { return nil }
        let idx = doc.index(for: page)
        guard idx != NSNotFound else { return nil }
        let p = dest.point
        // kPDFDestinationUnspecifiedValue: coordenada livre (o leitor mantém a atual)
        let unspecified = abs(p.x) >= kPDFDestinationUnspecifiedValue / 2 || abs(p.y) >= kPDFDestinationUnspecifiedValue / 2
        return NavTarget(page: idx, point: unspecified ? nil : p)
    }

    static func outline(_ doc: PDFDocument) -> [OutlineEntry] {
        var out: [OutlineEntry] = []
        func walk(_ o: PDFOutline) {
            for i in 0..<o.numberOfChildren {
                guard let c = o.child(at: i) else { continue }
                let dest = c.destination ?? (c.action as? PDFActionGoTo)?.destination
                out.append(OutlineEntry(label: c.label ?? "", target: target(dest, in: doc)))
                walk(c)
            }
        }
        if let root = doc.outlineRoot { walk(root) }
        return out
    }

    static func links(_ page: PDFPage) -> [PDFAnnotation] { page.annotations.filter { $0.type == "Link" } }

    func navigation(plan: LayoutPlan, srcData: Data, password: String?, srcURL: URL, outData: Data,
                    outURL: URL) throws -> InvariantResult {
        let src = try Self.open(srcData, password: password, url: srcURL, isSource: true)
        let out = try Self.open(outData, password: nil, url: outURL, isSource: false)
        var problems: [String] = []
        var badOut = Set<Int>()
        let tol = destinationTolerancePt

        // Destino na saída: página que veio da página de destino da origem, ponto dentro
        // dela e no lugar certo (ponto da origem menos a origem da janela gravada).
        func check(_ s: NavTarget?, _ o: NavTarget?, what: String) {
            guard let s else {
                if o != nil { problems.append("\(what): destino surgiu na saída") }
                return
            }
            guard let o else { problems.append("\(what): destino perdido"); return }
            guard o.page < plan.pages.count else { problems.append("\(what): página de saída \(o.page + 1) fora do plano"); return }
            let placements = plan.pages[o.page].placements
            guard placements.contains(where: { $0.sourcePage == s.page }) else {
                badOut.insert(o.page)
                problems.append("\(what): aponta para a saída p. \(o.page + 1), que não vem da origem p. \(s.page + 1)")
                return
            }
            guard let sp = s.point else { return }
            guard let op = o.point else { problems.append("\(what): ponto de destino perdido"); return }
            let page = out.page(at: o.page)!
            let bounds = page.bounds(for: .cropBox).insetBy(dx: -tol, dy: -tol)
            if !bounds.contains(op) {
                badOut.insert(o.page)
                problems.append("\(what): ponto \(Describe.point(op)) fora da saída p. \(o.page + 1)")
                return
            }
            // Origem: espaço do usuário; saída: a origem da janela gravada vai para a origem
            // da caixa de saída ((0,0) quando o PDFKit grava, S2; a própria janela pelo qpdf).
            if let p = placements.first(where: { $0.sourcePage == s.page }), let sPage = src.page(at: s.page) {
                let shift = Self.boxShift(p, source: sPage, output: page)
                let expected = CGPoint(x: sp.x - shift.x, y: sp.y - shift.y)
                if abs(expected.x - op.x) > tol || abs(expected.y - op.y) > tol {
                    badOut.insert(o.page)
                    problems.append("\(what): ponto \(Describe.point(op)), esperado \(Describe.point(expected))")
                }
            }
        }

        let so = Self.outline(src), oo = Self.outline(out)
        if so.count != oo.count { problems.append("sumário: \(oo.count) itens, origem \(so.count)") }
        for (i, (s, o)) in zip(so, oo).enumerated() {
            if s.label != o.label { problems.append("sumário item \(i + 1): rótulo mudou") }
            check(s.target, o.target, what: "sumário \"\(s.label)\"")
        }

        var srcLinks = 0, outLinks = 0, srcAnnots = 0, outAnnots = 0, internalChecked = 0
        for (j, op) in plan.pages.enumerated() {
            guard let p = op.placements.first, let sPage = src.page(at: p.sourcePage), let oPage = out.page(at: j) else { continue }
            let sl = Self.links(sPage), ol = Self.links(oPage)
            srcLinks += sl.count
            outLinks += ol.count
            let sa = sPage.annotations.count - sl.count, oa = oPage.annotations.count - ol.count
            srcAnnots += sa
            outAnnots += oa
            if sl.count != ol.count { badOut.insert(j); problems.append("saída p. \(j + 1): \(ol.count) links, origem \(sl.count)") }
            if sa != oa { badOut.insert(j); problems.append("saída p. \(j + 1): \(oa) anotações, origem \(sa)") }
            for (k, (s, o)) in zip(sl, ol).enumerated() {
                let sd = s.destination ?? (s.action as? PDFActionGoTo)?.destination
                let od = o.destination ?? (o.action as? PDFActionGoTo)?.destination
                let su = s.url ?? (s.action as? PDFActionURL)?.url
                let ou = o.url ?? (o.action as? PDFActionURL)?.url
                if su != ou { badOut.insert(j); problems.append("saída p. \(j + 1) link \(k + 1): URL mudou") }
                // Área clicável no mesmo lugar do conteúdo (o PDFKit a translada junto, S2).
                let shift = Self.boxShift(p, source: sPage, output: oPage)
                let want = s.bounds.offsetBy(dx: -shift.x, dy: -shift.y), got = o.bounds
                if abs(want.minX - got.minX) > tol || abs(want.minY - got.minY) > tol
                    || abs(want.width - got.width) > tol || abs(want.height - got.height) > tol {
                    badOut.insert(j)
                    problems.append("saída p. \(j + 1) link \(k + 1): retângulo \(Describe.rect(got)), esperado \(Describe.rect(want))")
                }
                if sd != nil || od != nil {
                    internalChecked += 1
                    check(Self.target(sd, in: src), Self.target(od, in: out), what: "saída p. \(j + 1) link \(k + 1)")
                }
            }
        }
        let metrics = [Metric("itens de sumário", Double(oo.count)), Metric("itens de sumário na origem", Double(so.count)),
                       Metric("links", Double(outLinks)), Metric("links esperados", Double(srcLinks)),
                       Metric("links internos verificados", Double(internalChecked)),
                       Metric("anotações", Double(outAnnots)), Metric("anotações esperadas", Double(srcAnnots))]
        let ok = problems.isEmpty
        return InvariantResult(id: "5", title: "Navegação", status: ok ? .passed : .failed,
                               detail: ok ? "sumário, links e anotações preservados, destinos nas páginas certas"
                                          : problems.prefix(8).joined(separator: "; "),
                               metrics: metrics, outputPages: badOut.sorted())
    }
}

extension Validator {
    /// Deslocamento origem → saída do BoxWriter: origem da janela menos a da caixa gravada.
    static func boxShift(_ p: Placement, source: PDFPage, output: PDFPage) -> CGPoint {
        let w = BoxGeometry.of(source).toUser(p.sourceRect).standardized.origin
        let o = output.bounds(for: .cropBox).origin
        return CGPoint(x: w.x - o.x, y: w.y - o.y)
    }
}

/// Geometria de página como o BoxWriter a lê (espaço do usuário do PDFKit).
enum BoxGeometry {
    static func of(_ page: PDFPage) -> PageGeometry {
        let media = page.bounds(for: .mediaBox)
        var effective = media.intersection(page.bounds(for: .cropBox))
        if effective.isNull || effective.isEmpty { effective = media }
        return PageGeometry(effectiveBox: effective, rotation: page.rotation)
    }
}

/// Comparação de rasters cinza (mesma grade).
enum Gray {
    /// Pixels de `a` e `b` com |Δ| > `tolerance`, nos primeiros
    /// `width` × `height` pixels de cada um.
    static func mismatched(_ a: GrayRaster, _ b: GrayRaster, width w: Int, height h: Int, tolerance: Int) -> Int {
        guard w > 0, h > 0 else { return 0 }
        var fa = [Float](repeating: 0, count: w), fb = [Float](repeating: 0, count: w), d = [Float](repeating: 0, count: w)
        var threshold = Float(tolerance) + 0.5, one: Float = 1
        var total = 0
        for y in 0..<h {
            a.pixels.withUnsafeBufferPointer { vDSP_vfltu8($0.baseAddress! + y * a.width, 1, &fa, 1, vDSP_Length(w)) }
            b.pixels.withUnsafeBufferPointer { vDSP_vfltu8($0.baseAddress! + y * b.width, 1, &fb, 1, vDSP_Length(w)) }
            vDSP_vsub(fa, 1, fb, 1, &d, 1, vDSP_Length(w))
            vDSP_vabs(d, 1, &d, 1, vDSP_Length(w))
            // ±1 por pixel: soma = acima − abaixo.
            vDSP_vlim(d, 1, &threshold, &one, &d, 1, vDSP_Length(w))
            var s: Float = 0
            vDSP_sve(d, 1, &s, vDSP_Length(w))
            total += (Int(s.rounded()) + w) / 2
        }
        return total
    }
}

/// Contagens sobre `InkMask` (valores 0/1 em Float).
enum Ink {
    static func sum(_ m: InkMask) -> Int {
        var s: Float = 0
        m.values.withUnsafeBufferPointer { vDSP_sve($0.baseAddress!, 1, &s, vDSP_Length($0.count)) }
        return Int(s.rounded())
    }

    static func sum(_ m: InkMask, x0: Int, y0: Int, x1: Int, y1: Int) -> Int {
        let x0 = max(0, x0), y0 = max(0, y0), x1 = min(m.width, x1), y1 = min(m.height, y1)
        guard x0 < x1, y0 < y1 else { return 0 }
        var total: Float = 0
        m.values.withUnsafeBufferPointer { b in
            for y in y0..<y1 {
                var s: Float = 0
                vDSP_sve(b.baseAddress! + y * m.width + x0, 1, &s, vDSP_Length(x1 - x0))
                total += s
            }
        }
        return Int(total.rounded())
    }

    /// Primeira/última linha e coluna com ≥ `k` pixels (inclusivo-exclusivo), a regra da
    /// caixa de tinta da análise em scan.
    static func boxWithAtLeast(_ m: InkMask, k: CGFloat) -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
        var rows = [Float](repeating: 0, count: m.height), cols = [Float](repeating: 0, count: m.width)
        m.values.withUnsafeBufferPointer { b in
            cols.withUnsafeMutableBufferPointer { c in
                for y in 0..<m.height {
                    let row = b.baseAddress! + y * m.width
                    var s: Float = 0
                    vDSP_sve(row, 1, &s, vDSP_Length(m.width))
                    rows[y] = s
                    vDSP_vadd(c.baseAddress!, 1, row, 1, c.baseAddress!, 1, vDSP_Length(m.width))
                }
            }
        }
        let t = Float(k)
        guard let y0 = rows.firstIndex(where: { $0 >= t }), let y1 = rows.lastIndex(where: { $0 >= t }),
              let x0 = cols.firstIndex(where: { $0 >= t }), let x1 = cols.lastIndex(where: { $0 >= t }) else { return nil }
        return (x0, y0, x1 + 1, y1 + 1)
    }

    /// Pixels em que as duas máscaras (mesmas dimensões) divergem.
    static func difference(_ a: InkMask, _ b: InkMask) -> Int {
        precondition(a.values.count == b.values.count)
        var d = [Float](repeating: 0, count: a.values.count)
        vDSP_vsub(a.values, 1, b.values, 1, &d, 1, vDSP_Length(d.count))
        var s: Float = 0
        vDSP_svemg(d, 1, &s, vDSP_Length(d.count))
        return Int(s.rounded())
    }

    /// Caixa (pixels, inclusivo-exclusivo) de toda a tinta da máscara.
    static func bounds(_ m: InkMask) -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
        var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
        m.values.withUnsafeBufferPointer { b in
            for y in 0..<m.height {
                var mx: Float = 0
                vDSP_maxv(b.baseAddress! + y * m.width, 1, &mx, vDSP_Length(m.width))
                guard mx > 0 else { continue }
                y0 = min(y0, y); y1 = y + 1
                for x in 0..<m.width where b[y * m.width + x] > 0 {
                    x0 = min(x0, x); x1 = max(x1, x + 1)
                }
            }
        }
        return x1 < 0 ? nil : (x0, y0, x1, y1)
    }
}

extension Describe {
    static func point(_ p: CGPoint) -> String { "(\(number(Double(p.x))); \(number(Double(p.y))))" }
    static func rect(_ r: CGRect) -> String {
        "[\(number(Double(r.minX))); \(number(Double(r.minY))) – \(number(Double(r.maxX))); \(number(Double(r.maxY)))]"
    }
}
