import AppCore
import AppKit
import LayoutEngine
import MiniGeometry
import MiniKit
import Observation
import PDFAnalysis
import PDFKit
import PDFWriting
import UniformTypeIdentifiers

/// Um PDF da fila: estado, ajustes, plano atual e cache de imagens da pré-visualização.
@MainActor @Observable
final class DocumentItem: Identifiable {
    let id = UUID()
    let url: URL
    var status: DocumentStatus = .analyzing
    var settings = ConversionSettings() {
        didSet { if settings != oldValue { replan() } }
    }
    private(set) var analysis: DocumentAnalysis?
    private(set) var planned: PlanResult?
    private(set) var badges: [[PageBadge]] = []
    private(set) var planError: String?
    /// Tempo do último replanejamento em processo (§16, alvo ≤ 100 ms).
    private(set) var replanMillis: Double?
    /// Página de saída exibida (o modo "Origem" mostra a página de origem dela).
    var currentPage = 0
    var lastExport: ConversionReport?
    var lastExportURL: URL?
    var exportError: String?
    /// Muda a cada plano aplicado; invalida as imagens em cache.
    private(set) var planVersion = 0

    @ObservationIgnored private(set) var pdf: PDFDocument?
    @ObservationIgnored private var images: [String: CGImage] = [:]
    @ObservationIgnored private var generation = 0

    init(url: URL) { self.url = url }

    var displayName: String { url.deletingPathExtension().lastPathComponent }
    var pageCount: Int { planned?.plan.pages.count ?? 0 }

    /// Resultado do processo filho: análise decodificada + plano inicial.
    func load(_ report: FullPlanReport) {
        // Só abre em processo depois que o filho leu o arquivo sem cair (§14.2).
        guard let doc = PDFDocument(url: url) else {
            status = .failed("o PDFKit não abriu o arquivo para a pré-visualização")
            return
        }
        pdf = doc
        analysis = report.analysis
        apply(report.planResult, millis: nil)
    }

    func fail(_ message: String) { status = .failed(message) }

    private func apply(_ r: PlanResult, millis: Double?) {
        planned = r
        planError = nil
        replanMillis = millis
        badges = PageBadges.compute(plan: r.plan, analysis: r.analysis)
        planVersion += 1
        images.removeAll()
        currentPage = min(currentPage, max(0, r.plan.pages.count - 1))
        if status != .converting { status = DocumentStatus.settled(warnings: DocumentStatus.warningCount(r)) }
    }

    /// Replaneja fora do MainActor a partir da análise já decodificada; descarta resultado velho.
    func replan() {
        guard let analysis else { return }
        generation += 1
        let gen = generation, s = settings
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Replanner.Outcome, any Error> in
                Result { try Replanner.replan(analysis, s) }
            }.value
            guard gen == self.generation else { return }
            switch outcome {
            case .success(let o): self.apply(o.result, millis: o.millis)
            case .failure(let e): self.planError = String(describing: e)
            }
        }
    }

    // MARK: - Imagens

    func outputImage(_ page: Int, ppp: CGFloat) -> CGImage? {
        cached("o\(page)@\(ppp)") { plan, analysis, pdf in
            PlanRenderer.renderOutputPage(page, plan: plan, analysis: analysis, document: pdf, pixelsPerPoint: ppp)
        }
    }

    func sourceImage(forOutput page: Int, ppp: CGFloat) -> (image: CGImage, source: Int)? {
        guard let plan = planned?.plan, plan.pages.indices.contains(page),
              let src = plan.pages[page].placements.first?.sourcePage else { return nil }
        let img = cached("s\(src)h\(page)@\(ppp)") { plan, analysis, pdf in
            PlanRenderer.renderSourcePage(src, plan: plan, analysis: analysis, document: pdf, highlight: page, pixelsPerPoint: ppp)
        }
        return img.map { ($0, src) }
    }

    private func cached(_ key: String, _ make: (LayoutPlan, DocumentAnalysis, PDFDocument) -> CGImage?) -> CGImage? {
        if let i = images[key] { return i }
        guard let r = planned, let pdf else { return nil }
        // Teto simples: a pré-visualização não precisa guardar o livro inteiro.
        if images.count > 160 { images.removeAll() }
        let img = make(r.plan, r.analysis, pdf)
        images[key] = img
        return img
    }

    var allWarnings: [String] {
        guard let r = planned else { return [] }
        return AnalysisSummary(r.analysis).warnings + r.plan.warnings.map(Describe.planWarning)
            + r.chosen.risks.map { "risco: \($0)" }
    }
}

/// Fila de documentos e ações que falam com o processo filho.
@MainActor @Observable
final class Library {
    static let shared = Library()

    var items: [DocumentItem] = []
    var selectionID: DocumentItem.ID?
    var notice: String?
    @ObservationIgnored let client: HelperClient?

    init(client: HelperClient? = HelperClient.locate().map { HelperClient(executable: $0) }) {
        self.client = client
    }

    var selected: DocumentItem? { items.first { $0.id == selectionID } }

    func open(_ urls: [URL]) {
        let pdfs = urls.filter { url in
            (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .pdf)) ?? false
                || url.pathExtension.lowercased() == "pdf"
        }
        if pdfs.count < urls.count { notice = "Só PDFs entram na fila; \(urls.count - pdfs.count) arquivo(s) ignorado(s)." }
        for url in pdfs {
            if let existing = items.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                selectionID = existing.id
                continue
            }
            let item = DocumentItem(url: url)
            items.append(item)
            selectionID = item.id
            analyze(item)
        }
    }

    func analyze(_ item: DocumentItem) {
        item.status = .analyzing
        guard let client else { item.fail(HelperError.notFound.message); return }
        let url = item.url, settings = item.settings
        Task {
            do {
                let report = try await client.plan(input: url, settings: settings)
                item.load(report)
            } catch let e as HelperError {
                item.fail(e.message)
            } catch {
                item.fail(String(describing: error))
            }
        }
    }

    func remove(_ item: DocumentItem) {
        items.removeAll { $0.id == item.id }
        if selectionID == item.id { selectionID = items.last?.id }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Escolha PDFs para adaptar ao iPad mini"
        panel.prompt = "Abrir"
        if panel.runModal() == .OK { open(panel.urls) }
    }

    func export(_ item: DocumentItem) {
        guard let client, item.planned != nil, item.status != .converting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.directoryURL = item.url.deletingLastPathComponent()
        panel.nameFieldStringValue = ExportNaming.defaultFileName(title: item.analysis?.title, sourceURL: item.url)
        panel.message = "Exportar a versão para o iPad mini"
        panel.prompt = "Exportar"
        guard panel.runModal() == .OK, let out = panel.url else { return }
        guard out.standardizedFileURL != item.url.standardizedFileURL else {
            item.exportError = "a saída não pode sobrescrever o PDF de origem"
            return
        }
        item.status = .converting
        item.exportError = nil
        let url = item.url, settings = item.settings
        Task {
            do {
                let report = try await client.convert(input: url, output: out, settings: settings)
                item.lastExport = report
                item.lastExportURL = out
                notice = report.passed ? "Exportado: \(out.lastPathComponent) · validação aprovada"
                                       : "Exportado com falhas de validação: \(out.lastPathComponent)"
            } catch let e as HelperError {
                item.exportError = e.message
            } catch {
                item.exportError = String(describing: error)
            }
            item.status = item.planned.map { DocumentStatus.settled(warnings: DocumentStatus.warningCount($0)) } ?? .ready
        }
    }

    func generateCalibration(_ orientation: Orientation) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "iPDFmini — calibração (\(orientation == .portrait ? "retrato" : "paisagem")).pdf"
        panel.message = "Abra o PDF no leitor do iPad mini e anote as marcas visíveis em cada borda"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Sem entrada do usuário para analisar: gerar em processo é seguro.
            try CalibrationPDF.write(to: url, orientation: orientation)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            notice = "Falha ao gravar o PDF de calibração: \(error.localizedDescription)"
        }
    }
}

enum PreviewMode: String, CaseIterable, Identifiable {
    case source, mini
    var id: String { rawValue }
    var title: String { self == .source ? "Origem" : "Mini" }
}

/// Estado de visualização compartilhado entre a janela e os menus.
@MainActor @Observable
final class ViewState {
    static let shared = ViewState()
    var mode: PreviewMode = .mini
    var realSize = false
    var showInspector = true
    var dropTargeted = false
    /// pt de tela por mm do monitor atual; `nil` = tamanho físico desconhecido.
    var pointsPerMM: CGFloat?
}
