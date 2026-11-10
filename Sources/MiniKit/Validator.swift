import Accelerate
import CoreGraphics
import Foundation
import LayoutEngine
import MiniGeometry
import PDFAnalysis
import PDFKit
import PDFWriting

// Invariantes verificados em toda saída. PLAN.md §15.2.

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
    /// "1a", "1b", "2" … "8".
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
public struct Validator: Sendable {
    public var pixelsPerPoint: CGFloat
    /// Pixels de tinta fora das colocações tolerados por página (inv. 1a).
    /// Zero: é o mesmo render, o mesmo limiar e a mesma limpeza que definiram a
    /// caixa de tinta, então um pixel descoberto já é tinta cortada. (Em scan a
    /// caixa ignora linhas/colunas com menos de k pixels; se salpico isolado
    /// virar falso positivo nos scans reais do M4, a folga entra aqui.)
    public var uncoveredTolerancePx: Int
    /// Inv. 1b: diferença tolerada (contagem e pixel a pixel) = max(abs, rel × referência).
    /// As grades coincidem, mas em página girada o arredondamento de ponto flutuante
    /// das duas matrizes muda alguns pixels de borda de glifo (medido: ≤ 19 px em
    /// ~200 mil, 0,01%). 0,1% fica 25× abaixo de uma linha de texto perdida (~2,5%
    /// da tinta da página) e muito abaixo de um deslocamento de 1 px, que troca
    /// quase toda borda de glifo.
    public var writerInkAbsoluteTolerancePx: Int
    public var writerInkRelativeTolerance: Double
    /// Inv. 3: erro relativo de proporção (0,1%).
    public var aspectTolerance: Double
    /// Inv. 5: folga para o ponto de destino (pt).
    public var destinationTolerancePt: CGFloat
    /// Inv. 6: saída ≤ orçamento × origem (§9.3, vetor).
    public var sizeBudget: Double
    /// Tarefas simultâneas de render; `nil` = núcleos ativos.
    public var maxConcurrency: Int?

    public init(pixelsPerPoint: CGFloat = 2, uncoveredTolerancePx: Int = 0,
                writerInkAbsoluteTolerancePx: Int = 4, writerInkRelativeTolerance: Double = 0.001,
                aspectTolerance: Double = 0.001, destinationTolerancePt: CGFloat = 0.5, sizeBudget: Double = 1.1,
                maxConcurrency: Int? = nil) {
        self.pixelsPerPoint = pixelsPerPoint
        self.uncoveredTolerancePx = uncoveredTolerancePx
        self.writerInkAbsoluteTolerancePx = writerInkAbsoluteTolerancePx
        self.writerInkRelativeTolerance = writerInkRelativeTolerance
        self.aspectTolerance = aspectTolerance
        self.destinationTolerancePt = destinationTolerancePt
        self.sizeBudget = sizeBudget
        self.maxConcurrency = maxConcurrency
    }

    public func validate(analysis: DocumentAnalysis, plan: LayoutPlan, source: SourceDocument,
                         output: URL) async throws -> ValidationReport {
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
                                                  outData: outData, outURL: output, outCount: outCount)
        var results: [InvariantResult] = []
        results.append(noCutInPlan(sourceProbes))
        results.append(noCutInOutput(outputProbes, plan: plan, outCount: outCount))
        results.append(legibility(analysis: analysis, plan: plan))
        results.append(aspect(outputProbes, plan: plan, outCount: outCount))
        results.append(InvariantResult(id: "4", title: "Texto", status: .notApplicable,
                                       detail: "só com PlacementWriter (M3): o BoxWriter não toca o content stream"))
        results.append(try navigation(plan: plan, srcData: srcData, password: password, srcURL: srcURL,
                                      outData: outData, outURL: output))
        results.append(fileSize(analysis: analysis, sourceBytes: srcData.count, outputBytes: outData.count))
        results.append(InvariantResult(id: "7", title: "Ida e volta", status: .notApplicable,
                                       detail: "mapa inverso entra com o PlacementWriter (M3)"))
        results.append(corners(outputProbes, plan: plan))
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

    struct OutputProbe: Sendable {
        var index: Int
        var displaySize: CGSize
        var outputInk: Int
        var referenceInk: Int?
        /// Pixels que diferem entre saída e referência (grades alinhadas); `nil` se as dimensões divergem.
        var mismatchedPixels: Int?
        var cornerInk: Int
        var renderFailed: Bool
    }

    private static func open(_ data: Data, password: String?, url: URL, isSource: Bool) throws -> PDFDocument {
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
                              outData: Data, outURL: URL, outCount: Int) async throws -> [OutputProbe] {
        let ppp = pixelsPerPoint
        let corner = plan.profile.cornerRadiusPt
        let probes: [OutputProbe] = try await parallel(outCount) { indices in
            let src = try Self.open(srcData, password: password, url: srcURL, isSource: true)
            let out = try Self.open(outData, password: nil, url: outURL, isSource: false)
            return indices.map { j in
                autoreleasepool {
                    Self.probeOutput(j, out: out, src: src, analysis: analysis, plan: plan, sources: sources,
                                     ppp: ppp, cornerRadius: corner)
                }
            }
        }
        return probes.sorted { $0.index < $1.index }
    }

    /// Inv. 1b, 3 e 8 numa página de saída.
    ///
    /// Referência de 1b: a janela renderizada direto da origem, com a mesma
    /// geometria exibida da página gravada e recortada à área visível da origem.
    /// O PDFKit grava a página com a origem da MediaBox em (0,0) e translada o
    /// conteúdo (SPIKES.md, S2); as duas grades de pixels partem do mesmo canto
    /// da janela, então dá para comparar pixel a pixel, não só a contagem.
    static func probeOutput(_ j: Int, out: PDFDocument, src: PDFDocument, analysis: DocumentAnalysis, plan: LayoutPlan,
                            sources: [SourceProbe], ppp: CGFloat, cornerRadius: CGFloat) -> OutputProbe {
        guard let page = out.page(at: j) else {
            return OutputProbe(index: j, displaySize: .zero, outputInk: 0, referenceInk: nil, mismatchedPixels: nil,
                               cornerInk: 0, renderFailed: true)
        }
        var box = page.bounds(for: .mediaBox).intersection(page.bounds(for: .cropBox))
        if box.isNull || box.isEmpty { box = page.bounds(for: .mediaBox) }
        let og = PageGeometry(effectiveBox: box, rotation: page.rotation)
        let failed = OutputProbe(index: j, displaySize: og.displaySize, outputInk: 0, referenceInk: nil,
                                 mismatchedPixels: nil, cornerInk: 0, renderFailed: true)
        guard let raster = GrayRaster.render(page: page, geometry: og, pixelsPerPoint: ppp) else { return failed }

        // Limiar da página de origem correspondente; sem ela, o da própria saída.
        let placement = j < plan.pages.count && plan.pages[j].placements.count == 1 ? plan.pages[j].placements[0] : nil
        let probe = placement.flatMap { p in sources.first { $0.index == p.sourcePage && !$0.renderFailed } }
        func mask(_ r: GrayRaster) -> InkMask {
            guard let probe else { return InkMask.vector(r, background: InkMask.mode(r.histogram())) }
            // Sem limpeza de componentes: ela depende das bordas do raster, que diferem entre os dois.
            return probe.scan ? InkMask.scan(r, histogram: probe.histogram, background: probe.background)
                              : InkMask.vector(r, background: probe.background)
        }
        let outMask = mask(raster)
        let outInk = Ink.sum(outMask)

        var cornerInk = 0
        if let placement, placement.scale > 0 {
            for sq in og.pageBox.cornerSquares(radius: cornerRadius / placement.scale) {
                let r = raster.mapping.pixelRect(sq)
                cornerInk += Ink.sum(outMask, x0: r.x0, y0: r.y0, x1: r.x1, y1: r.y1)
            }
        }

        var refInk: Int?
        var mismatch: Int?
        if let placement, let probe, let a = analysis.pages.first(where: { $0.index == placement.sourcePage }),
           let srcPage = src.page(at: placement.sourcePage) {
            let window = a.geometry.toUser(placement.sourceRect)
            let rg = PageGeometry(effectiveBox: window, rotation: a.geometry.rotation)
            var clip = window.intersection(probe.visible)
            if clip.isNull { clip = .zero }
            if let ref = GrayRaster.render(page: srcPage, geometry: rg, pixelsPerPoint: ppp, clip: clip) {
                let refMask = mask(ref)
                refInk = Ink.sum(refMask)
                if ref.width == raster.width && ref.height == raster.height {
                    mismatch = Ink.difference(refMask, outMask)
                }
            }
        }
        return OutputProbe(index: j, displaySize: og.displaySize, outputInk: outInk, referenceInk: refInk,
                           mismatchedPixels: mismatch, cornerInk: cornerInk, renderFailed: false)
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

    func noCutInOutput(_ probes: [OutputProbe], plan: LayoutPlan, outCount: Int) -> InvariantResult {
        var bad: [Int] = []
        var notes: [String] = []
        var worstRel = 0.0, worstMismatch = 0, refTotal = 0, outTotal = 0
        if outCount != plan.pages.count {
            return InvariantResult(id: "1b", title: "Nenhuma tinta cortada (saída)", status: .failed,
                                   detail: "saída com \(outCount) páginas; o plano tem \(plan.pages.count)")
        }
        for p in probes {
            guard !p.renderFailed, let ref = p.referenceInk else {
                bad.append(p.index); notes.append("saída p. \(p.index + 1): sem render"); continue
            }
            refTotal += ref
            outTotal += p.outputInk
            let diff = abs(p.outputInk - ref)
            let tol = max(Double(writerInkAbsoluteTolerancePx), writerInkRelativeTolerance * Double(ref))
            let rel = ref > 0 ? Double(diff) / Double(ref) : (diff > 0 ? 1 : 0)
            worstRel = max(worstRel, rel)
            if let m = p.mismatchedPixels { worstMismatch = max(worstMismatch, m) }
            // Pixel a pixel com a mesma tolerância: pega deslocamento que a contagem não vê.
            let mismatchBad = p.mismatchedPixels.map { Double($0) > tol } ?? false
            if Double(diff) > tol || mismatchBad {
                bad.append(p.index)
                notes.append("saída p. \(p.index + 1): \(p.outputInk) px contra \(ref) px na janela de origem"
                             + (p.mismatchedPixels.map { ", \($0) px diferentes" } ?? ""))
            }
        }
        let metrics = [Metric("tinta na saída", Double(outTotal), "px"),
                       Metric("tinta nas janelas de origem", Double(refTotal), "px"),
                       Metric("pior diferença relativa", worstRel * 100, "%"),
                       Metric("pior diferença pixel a pixel", Double(worstMismatch), "px")]
        let ok = bad.isEmpty
        return InvariantResult(id: "1b", title: "Nenhuma tinta cortada (saída)", status: ok ? .passed : .failed,
                               detail: ok ? "cada página gravada tem a mesma tinta da janela de origem" : notes.joined(separator: "; "),
                               metrics: metrics, outputPages: bad)
    }

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
            guard let p = out.placements.first,
                  let a = analysis.pages.first(where: { $0.index == p.sourcePage }), a.inkBox != nil else { continue }
            let mm = Legibility.finalXHeightMM(sourceXHeightPt: Double(body), scale: Double(p.scale))
            minMM = min(minMM, mm)
            if mm < leg.minimumMM { below.append(j) }
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
            detail = "\(below.count) páginas abaixo do mínimo sem aviso no plano"
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

    func fileSize(analysis: DocumentAnalysis, sourceBytes: Int, outputBytes: Int) -> InvariantResult {
        let ratio = sourceBytes > 0 ? Double(outputBytes) / Double(sourceBytes) : 0
        let ok = ratio <= sizeBudget
        var detail = ok ? "saída \(Describe.number(ratio, decimals: 3))× a origem" : "saída \(Describe.number(ratio, decimals: 3))× a origem, acima de \(Describe.number(sizeBudget))×"
        // §9.3 pede ≤ 0,6× em scan colorido, o que exige reamostrar (M4); aqui só o teto de vetor.
        if analysis.kind == .scannedBook { detail += "; meta de scan (≤ 0,6×) depende da reamostragem do M4" }
        return InvariantResult(id: "6", title: "Tamanho", status: ok ? .passed : .failed, detail: detail,
                               metrics: [Metric("origem", Double(sourceBytes), "B"), Metric("saída", Double(outputBytes), "B"),
                                         Metric("razão", ratio)])
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
            // Origem: espaço do usuário; saída: deslocada pela origem da janela gravada (S2).
            if let p = placements.first(where: { $0.sourcePage == s.page }), let sPage = src.page(at: s.page) {
                let g = BoxGeometry.of(sPage)
                let shift = g.toUser(p.sourceRect).origin
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
                let shift = BoxGeometry.of(sPage).toUser(p.sourceRect).origin
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

/// Geometria de página como o BoxWriter a lê (espaço do usuário do PDFKit).
enum BoxGeometry {
    static func of(_ page: PDFPage) -> PageGeometry {
        let media = page.bounds(for: .mediaBox)
        var effective = media.intersection(page.bounds(for: .cropBox))
        if effective.isNull || effective.isEmpty { effective = media }
        return PageGeometry(effectiveBox: effective, rotation: page.rotation)
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
