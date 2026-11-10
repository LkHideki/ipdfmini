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
    /// Caminho resolvido (chave da `BatchQueue`).
    let id: String
    let url: URL
    var status: DocumentStatus = .waiting
    /// Ajustes efetivos (próprios ou o padrão do lote); a `Library` decide qual.
    var settings: ConversionSettings {
        didSet { if settings != oldValue { replan() } }
    }
    private(set) var analysis: DocumentAnalysis?
    private(set) var planned: PlanResult?
    private(set) var badges: [[PageBadge]] = []
    private(set) var planError: String?
    /// Itens do sumário da origem; `nil` até a análise terminar.
    private(set) var sourceOutlineItems: Int?
    /// Tempo do último replanejamento em processo (§16, alvo ≤ 100 ms).
    private(set) var replanMillis: Double?
    /// Página de saída exibida (o modo "Origem" mostra a página de origem dela).
    var currentPage = 0
    var lastExport: ConversionReport?
    var lastExportURL: URL?
    var exportError: String?
    /// Muda a cada plano aplicado; invalida as imagens em cache.
    private(set) var planVersion = 0
    /// Estado de antes da conversão, para voltar a ele se a análise não existir.
    @ObservationIgnored var statusBeforeConversion: DocumentStatus?

    @ObservationIgnored private(set) var pdf: PDFDocument?
    @ObservationIgnored private var images: [String: CGImage] = [:]
    @ObservationIgnored private var generation = 0

    init(entry: QueueEntry, settings: ConversionSettings) {
        id = entry.id
        url = entry.url
        self.settings = settings
    }

    var displayName: String { url.deletingPathExtension().lastPathComponent }
    var pageCount: Int { planned?.plan.pages.count ?? 0 }

    /// Resultado do processo filho: análise decodificada + plano inicial.
    func load(_ report: FullPlanReport, analyzedWith used: ConversionSettings) {
        // Só abre em processo depois que o filho leu o arquivo sem cair (§14.2).
        guard let doc = PDFDocument(url: url) else {
            status = .failed("o PDFKit não abriu o arquivo para a pré-visualização")
            return
        }
        pdf = doc
        analysis = report.analysis
        // CLI antiga não manda a contagem: conta no PDF já aberto.
        sourceOutlineItems = report.sourceOutlineItems ?? NavigationSummary.outlineItems(doc).count
        apply(report.planResult, millis: nil)
        // Ajuste feito enquanto a análise rodava (ou "Usar como padrão"): replaneja com ele.
        if settings != used { replan() }
    }

    func fail(_ message: String) { status = .failed(message) }

    func beginConversion() {
        if status != .converting { statusBeforeConversion = status }
        status = .converting
    }

    func endConversion() {
        if let p = planned {
            status = DocumentStatus.settled(warnings: DocumentStatus.warningCount(p))
        } else {
            status = statusBeforeConversion ?? .ready
        }
        statusBeforeConversion = nil
    }

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

/// Fila de documentos (agrupada por pasta) e ações que falam com o processo filho.
@MainActor @Observable
final class Library {
    static let shared = Library()

    /// Ordem, grupos e opt-out; os `DocumentItem` ficam em `docs` pela mesma chave.
    private(set) var queue = BatchQueue()
    private(set) var docs: [String: DocumentItem] = [:]
    private(set) var store = SettingsStore()
    var selectionID: String? {
        didSet { if let s = selected { s.settings = store.effective(s.id) } }
    }
    var notice: String?
    /// Lote em andamento ou terminado (folha).
    var batch: BatchSession?
    /// Última pasta de destino do lote, só nesta sessão.
    var batchDestination: URL?
    var mirrorSubfolders = true
    /// PDFs do último lote, para compartilhar pela barra.
    private(set) var lastBatchOutputs: [URL] = []
    @ObservationIgnored let client: HelperClient?
    /// Duas análises por vez: uma pasta com centenas de PDFs não abre centenas de processos.
    @ObservationIgnored let analysisLimiter = ConcurrencyLimiter(limit: 2)
    /// Análise em andamento ou na fila, por documento: sair da lista cancela (mata o filho).
    @ObservationIgnored private var analysisTasks: [String: Task<Void, Never>] = [:]
    static let batchConcurrency = 2

    init(client: HelperClient? = HelperClient.locate().map { HelperClient(executable: $0) }) {
        self.client = client
    }

    var items: [DocumentItem] { queue.entries.compactMap { docs[$0.id] } }
    var selected: DocumentItem? { selectionID.flatMap { docs[$0] } }

    // MARK: - Entrada

    /// Arquivos e pastas (arrastados, Dock, "Abrir…"): varre fora do MainActor e soma à fila.
    func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            let result = await Task.detached(priority: .userInitiated) { FolderScanner.scan(urls) }.value
            add(result)
        }
    }

    func add(_ result: ScanResult) {
        let r = queue.add(result.found)
        for e in r.added {
            let item = DocumentItem(entry: e, settings: store.effective(e.id))
            docs[e.id] = item
            analyze(item)
        }
        if let first = r.added.first {
            if selectionID == nil || r.added.count == 1 { selectionID = first.id }
        } else if result.found.count == 1 {
            selectionID = result.found[0].key
        }
        notice = QueueNotice.text(added: r.added.count, duplicates: r.duplicates, rejected: result.rejected.count,
                                  folders: Set(r.added.map(\.found.root.path)).count)
    }

    func analyze(_ item: DocumentItem) {
        guard let client else { item.fail(HelperError.notFound.message); return }
        item.status = .waiting
        let url = item.url, settings = item.settings, limiter = analysisLimiter
        analysisTasks[item.id]?.cancel()
        analysisTasks[item.id] = Task {
            do {
                let report = try await limiter.withPermit { () async throws -> FullPlanReport in
                    // Removido da fila enquanto esperava a vaga: não gasta processo.
                    let alive = await MainActor.run { () -> Bool in
                        guard self.docs[item.id] === item else { return false }
                        item.status = .analyzing
                        return true
                    }
                    guard alive else { throw CancellationError() }
                    return try await client.plan(input: url, settings: settings)
                }
                // Saiu da lista durante a análise: o resultado não vale mais nada.
                guard self.docs[item.id] === item, !Task.isCancelled else { return }
                item.load(report, analyzedWith: settings)
            } catch is CancellationError {
            } catch let e as HelperError {
                guard self.docs[item.id] === item, !Task.isCancelled else { return }
                item.fail(e.message)
            } catch {
                guard self.docs[item.id] === item, !Task.isCancelled else { return }
                item.fail(String(describing: error))
            }
        }
    }

    // MARK: - Fila e opt-out

    func isIncluded(_ id: String) -> Bool { queue.entry(id)?.included ?? false }
    func setIncluded(_ id: String, _ v: Bool) { queue.setIncluded(id, v) }
    func setIncluded(group: QueueGroup, _ v: Bool) { queue.setIncluded(groupRoot: group.root, v) }
    func setAllIncluded(_ v: Bool) { queue.setAllIncluded(v) }

    func removeExcluded() {
        let gone = queue.removeExcluded()
        forget(gone)
        if gone.isEmpty { notice = "Nenhum documento desmarcado." } else {
            notice = "\(gone.count) \(gone.count == 1 ? "documento desmarcado saiu" : "documentos desmarcados saíram") da fila."
        }
    }

    /// Lote em execução com algum documento da pasta: o botão de remover fica desabilitado
    /// até o lote acabar (tirar o documento no meio deixaria o resumo apontando para o nada).
    func folderInRunningBatch(_ group: QueueGroup) -> Bool {
        guard let b = batch, b.phase == .running else { return false }
        let ids = Set(group.entries.map(\.id))
        return b.jobs.contains { ids.contains($0.id) }
    }

    /// Deslista a pasta (e as subpastas que vieram com ela). Nada muda no disco.
    func removeFolder(_ group: QueueGroup) {
        guard !folderInRunningBatch(group) else { return }
        let before = queue.entries.map(\.id)
        let gone = queue.removeGroup(root: group.root)
        let next = BatchQueue.selection(after: Set(gone), current: selectionID, before: before)
        forget(gone)
        selectionID = next
        notice = QueueNotice.folderRemoved(group.title, count: gone.count)
    }

    func remove(_ item: DocumentItem) {
        queue.remove(item.id)
        forget([item.id])
    }

    private func forget(_ ids: [String]) {
        for id in ids {
            docs[id] = nil
            // Cancelar a tarefa mata o processo filho (HelperProcess) e libera a vaga.
            analysisTasks.removeValue(forKey: id)?.cancel()
        }
        store.forget(ids)
        if let s = selectionID, docs[s] == nil { selectionID = queue.entries.last?.id }
    }

    // MARK: - Ajustes por documento

    /// Ajuste vindo do inspetor: vira ajuste próprio do documento.
    func update(_ item: DocumentItem, _ s: ConversionSettings) {
        store.set(item.id, s)
        item.settings = s
    }

    func hasOwnSettings(_ item: DocumentItem) -> Bool { store.hasOverride(item.id) }

    func useAsDefault(_ item: DocumentItem) {
        store.makeDefault(from: item.id)
        // Quem segue o padrão replaneja já, para a fila mostrar avisos coerentes.
        for d in docs.values { d.settings = store.effective(d.id) }
        notice = "Ajustes de \(item.displayName) agora são o padrão do lote."
    }

    func resetToDefault(_ item: DocumentItem) {
        store.reset(item.id)
        item.settings = store.effective(item.id)
    }

    var customizedCount: Int { queue.included.count { store.hasOverride($0.id) } }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Escolha PDFs ou pastas (os PDFs das subpastas também entram) para adaptar ao iPad mini"
        panel.prompt = "Abrir"
        if panel.runModal() == .OK { open(panel.urls) }
    }

    // MARK: - Exportação individual

    func export(_ item: DocumentItem, thenAirDrop: Bool = false) {
        guard let client, item.planned != nil, item.status != .converting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.directoryURL = item.url.deletingLastPathComponent()
        panel.nameFieldStringValue = ExportNaming.defaultFileName(title: item.analysis?.title, sourceURL: item.url)
        panel.message = thenAirDrop ? "Exportar e enviar por AirDrop para o iPad mini" : "Exportar a versão para o iPad mini"
        panel.prompt = thenAirDrop ? "Exportar e enviar" : "Exportar"
        guard panel.runModal() == .OK, let out = panel.url else { return }
        guard out.standardizedFileURL != item.url.standardizedFileURL else {
            item.exportError = "a saída não pode sobrescrever o PDF de origem"
            return
        }
        item.beginConversion()
        item.exportError = nil
        let url = item.url, settings = item.settings
        Task {
            do {
                let report = try await client.convert(input: url, output: out, settings: settings)
                item.lastExport = report
                item.lastExportURL = out
                notice = report.passed ? "Exportado: \(out.lastPathComponent) · validação aprovada"
                                       : "Exportado com falhas de validação: \(out.lastPathComponent)"
                item.endConversion()
                if thenAirDrop { airDrop([out]) }
            } catch let e as HelperError {
                item.exportError = e.message
                item.endConversion()
            } catch {
                item.exportError = String(describing: error)
                item.endConversion()
            }
        }
    }

    // MARK: - Compartilhar

    /// O que a barra compartilha: a última exportação do selecionado ou o último lote.
    var shareCandidates: [URL] {
        if let u = selected?.lastExportURL { return ShareItems.urls([u]) }
        return ShareItems.urls(lastBatchOutputs)
    }

    func airDrop(_ urls: [URL]) {
        if let problem = Sharing.airDrop(ShareItems.urls(urls)) { Sharing.alert(problem) }
    }

    // MARK: - Lote

    func beginBatch() {
        guard batch == nil || batch?.phase.isFinished == true, queue.includedCount > 0 else { return }
        batch = BatchSession(count: queue.includedCount, customized: customizedCount)
    }

    func chooseBatchDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = batchDestination
        panel.message = "Pasta onde os PDFs adaptados serão gravados"
        panel.prompt = "Escolher"
        if panel.runModal() == .OK, let u = panel.url { batchDestination = u }
    }

    func startBatch() {
        guard let session = batch, case .configuring = session.phase, let dest = batchDestination else { return }
        guard let client else { notice = HelperError.notFound.message; return }
        var naming = BatchNaming(destination: dest, mirrorSubfolders: mirrorSubfolders)
        let jobs = queue.included.map { e in
            BatchJob(id: e.id, input: e.url, output: naming.output(for: e.found, title: docs[e.id]?.analysis?.title),
                     settings: store.effective(e.id))
        }
        session.start(jobs: jobs, destination: dest) { [weak self] event in
            guard let self else { return }
            switch event {
            case .started(let id): self.docs[id]?.beginConversion()
            case .finished(let id, let outcome):
                guard let item = self.docs[id] else { return }
                switch outcome {
                case .converted(let r):
                    item.lastExport = r
                    item.lastExportURL = URL(fileURLWithPath: r.output)
                    item.exportError = nil
                case .failed(let m): item.exportError = m
                case .cancelled: break
                }
                item.endConversion()
            }
        } completion: { [weak self] summary in
            self?.lastBatchOutputs = summary.outputs
        }
        session.task = Task {
            await session.run(client: client, maxConcurrent: Self.batchConcurrency)
        }
    }

    func closeBatch() {
        guard let b = batch, b.phase.isFinished || b.phase == .configuring else { return }
        batch = nil
    }

    // MARK: - Calibração

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
