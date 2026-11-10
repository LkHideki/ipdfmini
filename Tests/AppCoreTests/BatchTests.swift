import Foundation
import LayoutEngine
import MiniKit
import PDFKit
import Testing
@testable import AppCore

// MARK: - Varredura de pastas

/// Árvore de teste: PDFs só com o cabeçalho bastam para a varredura (não abre o PDF).
private enum Tree {
    static let pdfBytes = Data("%PDF-1.7\n%âãÏÓ\n".utf8)

    static func make(_ name: String) throws -> URL {
        let root = Scratch.url("tree-\(name)-\(UUID().uuidString.prefix(6))")
        let fm = FileManager.default
        func dir(_ p: String) throws { try fm.createDirectory(at: root.appendingPathComponent(p), withIntermediateDirectories: true) }
        func file(_ p: String, _ d: Data = pdfBytes) throws { try d.write(to: root.appendingPathComponent(p)) }
        try dir("sub/deeper")
        try dir(".oculta")
        try dir("Pacote.app/Contents")
        try file("a.pdf")
        try file("sub/b.pdf")
        try file("sub/deeper/c.pdf")
        try file("sub/notas.txt", Data("texto".utf8))
        try file(".escondido.pdf")
        try file(".oculta/d.pdf")
        try file("Pacote.app/Contents/e.pdf")
        // Texto com extensão .pdf: o tipo bate, o conteúdo não.
        try file("falso.pdf", Data("isto não é um PDF".utf8))
        // PDF de verdade sem extensão: o UTType não diz PDF, fica de fora.
        try file("sem-extensao", pdfBytes)
        // Laço: sub/volta → raiz; e um link de arquivo para a.pdf.
        try fm.createSymbolicLink(at: root.appendingPathComponent("sub/volta"), withDestinationURL: root)
        try fm.createSymbolicLink(at: root.appendingPathComponent("atalho.pdf"), withDestinationURL: root.appendingPathComponent("a.pdf"))
        return root
    }
}

@Suite struct FolderScanTests {
    @Test func recursiveScanSkipsHiddenPackagesAndFakesWithoutLooping() throws {
        let root = try Tree.make("scan")
        let r = FolderScanner.scan([root])
        let real = FolderScanner.resolved(root)
        #expect(r.found.map { $0.url.lastPathComponent } == ["a.pdf", "b.pdf", "c.pdf"])
        #expect(r.found.map(\.relativeDirectory) == ["", "sub", "sub/deeper"])
        #expect(r.found.allSatisfy { $0.root.path == real.path })
        // Chave com symlinks resolvidos (o temporário do macOS mora em /private/var).
        #expect(r.found[0].key == real.appendingPathComponent("a.pdf").path)
        #expect(r.rejected.isEmpty)
    }

    @Test func directFilesAreTypeCheckedAndGroupedByParent() throws {
        let root = try Tree.make("direct")
        let r = FolderScanner.scan([root.appendingPathComponent("falso.pdf"), root.appendingPathComponent("sub/b.pdf"),
                                    root.appendingPathComponent("sub/notas.txt"), root.appendingPathComponent("nao-existe.pdf")])
        #expect(r.found.map { $0.url.lastPathComponent } == ["b.pdf"])
        #expect(r.found[0].root.path == FolderScanner.resolved(root.appendingPathComponent("sub")).path)
        #expect(r.found[0].relativeDirectory == "")
        #expect(r.rejected.map(\.lastPathComponent) == ["falso.pdf", "notas.txt", "nao-existe.pdf"])
        #expect(!FolderScanner.isPDF(root.appendingPathComponent("falso.pdf")))
        #expect(!FolderScanner.isPDF(root.appendingPathComponent("sem-extensao")))
        #expect(FolderScanner.isPDF(root.appendingPathComponent("a.pdf")))
    }

    @Test func addingAgainNeverDuplicates() throws {
        let root = try Tree.make("dedup")
        var q = BatchQueue()
        #expect(q.add(FolderScanner.scan([root]).found).added.count == 3)
        // Mesma pasta, um arquivo dela, o symlink do arquivo e o caminho com "..": nada novo.
        let again = FolderScanner.scan([root, root.appendingPathComponent("sub/b.pdf"), root.appendingPathComponent("atalho.pdf"),
                                        root.appendingPathComponent("sub/../a.pdf")])
        let r = q.add(again.found)
        #expect(r.added.isEmpty)
        // A varredura já descarta os repetidos dentro dela; os 3 que sobram já estavam na fila.
        #expect(again.found.count == 3)
        #expect(r.duplicates == 3)
        #expect(q.entries.count == 3)
        // Outra pasta soma.
        let other = try Tree.make("dedup2")
        let r2 = q.add(FolderScanner.scan([other]).found)
        #expect(r2.added.count == 3 && r2.duplicates == 0)
        #expect(q.entries.count == 6)
        #expect(QueueNotice.text(added: 0, duplicates: 3, rejected: 0, folders: 0) == "Nenhum PDF novo · 3 já estavam na fila.")
        #expect(QueueNotice.text(added: 6, duplicates: 0, rejected: 1, folders: 2)
                == "6 PDFs adicionados de 2 pastas · 1 item ignorado (não é PDF).")
    }
}

// MARK: - Fila, grupos e opt-out

@Suite struct QueueTests {
    private func found(_ root: String, _ name: String, _ rel: String = "") -> FoundPDF {
        let r = URL(fileURLWithPath: root)
        let dir = rel.isEmpty ? r : r.appendingPathComponent(rel)
        return FoundPDF(url: dir.appendingPathComponent(name), root: r, relativeDirectory: rel)
    }

    @Test func groupsByOriginFolderInArrivalOrder() {
        var q = BatchQueue()
        q.add([found("/x/Artigos", "a.pdf"), found("/x/Artigos", "b.pdf", "2024"), found("/y/Livros", "c.pdf")])
        q.add([found("/x/Artigos", "d.pdf")])
        let g = q.groups
        #expect(g.map(\.title) == ["Artigos", "Livros"])
        #expect(g[0].entries.map(\.displayName) == ["a", "b", "d"])
        #expect(g.map(\.countLabel) == ["3", "1"])
    }

    @Test func optOutAndBulkActions() {
        var q = BatchQueue()
        q.add([found("/x/A", "1.pdf"), found("/x/A", "2.pdf"), found("/x/A", "3.pdf"), found("/x/B", "4.pdf")])
        #expect(q.includedCount == 4)   // marcados por padrão
        q.setIncluded("/x/A/2.pdf", false)
        #expect(q.groups[0].countLabel == "2 de 3")
        #expect(q.included.map(\.displayName) == ["1", "3", "4"])
        q.setIncluded(groupRoot: URL(fileURLWithPath: "/x/A"), false)
        #expect(q.included.map(\.displayName) == ["4"])
        q.setIncluded(groupRoot: URL(fileURLWithPath: "/x/A"), true)
        #expect(q.includedCount == 4)
        q.setAllIncluded(false)
        #expect(q.includedCount == 0)
        q.setIncluded("/x/B/4.pdf", true)
        q.setIncluded("/x/A/1.pdf", true)
        let gone = q.removeExcluded()
        #expect(Set(gone) == ["/x/A/2.pdf", "/x/A/3.pdf"])
        #expect(q.entries.map(\.displayName) == ["1", "4"])
        #expect(q.entries.allSatisfy { $0.included })
    }

    @Test func perDocumentSettingsOverrideTheDefault() {
        var s = SettingsStore()
        let cols = ConversionSettings(mode: .columns)
        s.set("a", cols)
        #expect(s.effective("a") == cols && s.hasOverride("a"))
        #expect(s.effective("b") == ConversionSettings())
        // Igual ao padrão deixa de ser próprio.
        s.set("a", ConversionSettings())
        #expect(!s.hasOverride("a"))
        s.set("a", cols)
        s.set("c", ConversionSettings(marginMM: 5))
        s.makeDefault(from: "a")
        #expect(s.defaults == cols && !s.hasOverride("a"))
        #expect(s.effective("b") == cols)
        #expect(s.effective("c").marginMM == 5)
        s.reset("c")
        #expect(s.effective("c") == cols)
    }
}

// MARK: - Nomes de saída

@Suite struct BatchNamingTests {
    @Test func namesNeverCollideAndMirrorSubfolders() throws {
        let dest = Scratch.url("dest-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data().write(to: dest.appendingPathComponent("Livro — mini.pdf"))
        let root = URL(fileURLWithPath: "/origem")
        let a = FoundPDF(url: root.appendingPathComponent("a.pdf"), root: root)
        let b = FoundPDF(url: root.appendingPathComponent("x/y/b.pdf"), root: root, relativeDirectory: "x/y")

        var flat = BatchNaming(destination: dest, mirrorSubfolders: false)
        #expect(flat.output(for: a, title: "Livro").lastPathComponent == "Livro — mini 2.pdf")   // existe no disco
        #expect(flat.output(for: b, title: "Livro").lastPathComponent == "Livro — mini 3.pdf")   // reservado no lote
        #expect(flat.output(for: a, title: nil).lastPathComponent == "a — mini.pdf")             // sem título: nome do arquivo
        #expect(flat.output(for: b, title: "Microsoft Word - b.docx").deletingLastPathComponent().path == dest.path)

        var mirror = BatchNaming(destination: dest, mirrorSubfolders: true)
        let out = mirror.output(for: b, title: "Livro")
        #expect(out.path == dest.appendingPathComponent("x/y/Livro — mini.pdf").path)
        #expect(mirror.output(for: a, title: "Livro").lastPathComponent == "Livro — mini 2.pdf")

        // Reserva sem distinção de maiúsculas, como o volume padrão do macOS (disco falso, vazio).
        var fake = BatchNaming(destination: URL(fileURLWithPath: "/destino"), mirrorSubfolders: false, exists: { _ in false })
        #expect(fake.output(for: a, title: "Livro").lastPathComponent == "Livro — mini.pdf")
        #expect(fake.output(for: b, title: "LIVRO").lastPathComponent == "LIVRO — mini 2.pdf")
        // Nunca devolve o próprio arquivo de origem.
        let selfNamed = FoundPDF(url: URL(fileURLWithPath: "/destino/X — mini.pdf"), root: URL(fileURLWithPath: "/destino"))
        #expect(fake.output(for: selfNamed, title: "X").lastPathComponent == "X — mini 2.pdf")
    }
}

// MARK: - Lote com a CLI real

@MainActor
private final class EventLog {
    var running = 0, peak = 0
    var events: [BatchEvent] = []
    func record(_ e: BatchEvent) {
        events.append(e)
        switch e {
        case .started: running += 1; peak = max(peak, running)
        case .finished: running -= 1
        }
    }
}

@Suite struct BatchRunnerTests {
    @Test func realHelperBatchWithCorruptPDF() async throws {
        let client = try Helper.client()
        let dest = Scratch.url("lote-\(UUID().uuidString.prefix(6))")
        let bad = Scratch.url("lote-corrompido.pdf")
        try Data("%PDF-1.7\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\nlixo \u{0}\u{1}".utf8).write(to: bad)
        var inputs: [URL] = []
        for s in ["navigation", "book6x9", "a4Report", "cropMarks"] { inputs.append(try await CorpusFiles.shared.pdf(s)) }
        inputs.insert(bad, at: 2)
        var naming = BatchNaming(destination: dest, mirrorSubfolders: false)
        let jobs = inputs.map { u in
            BatchJob(id: u.path, input: u, output: naming.output(for: FoundPDF(url: u, root: u.deletingLastPathComponent()), title: nil),
                     settings: ConversionSettings(classMode: .all))
        }
        let log = EventLog()
        let clock = ContinuousClock()
        let start = clock.now
        let results = await BatchRunner.run(jobs, client: client, maxConcurrent: 2) { log.record($0) }
        let elapsed = clock.now - start
        print("lote de \(jobs.count) PDFs do corpus (2 processos): \(elapsed)")

        #expect(results.map(\.job) == jobs)   // ordem dos pedidos, não de chegada
        #expect(await log.peak <= 2)
        #expect(await log.events.count == 2 * jobs.count)
        let s = BatchSummary(results)
        #expect(s.convertedCount == 4)
        #expect(s.failures.map(\.name) == ["lote-corrompido"])
        #expect(s.failures[0].text.contains("PDF"))
        #expect(s.cancelled == 0)
        #expect(s.headline == "4 convertidos de 5 · 1 falha")
        #expect(!FileManager.default.fileExists(atPath: jobs[2].output.path))   // nada parcial da falha
        for o in s.outputs { #expect(FileManager.default.fileExists(atPath: o.path)) }
        #expect(s.shareItems == s.outputs)
        // O de navegação chega com o sumário inteiro e o relatório traz as contagens.
        guard case .converted(let nav) = results[0].outcome else { Issue.record("navigation não converteu"); return }
        let n = try #require(nav.navigation)
        #expect(n.sourceOutlineItems > 0 && n.outlinePreserved)
        #expect(OutlineDisplay.preserved(n) == "\(n.sourceOutlineItems) de \(n.sourceOutlineItems) preservados")
        #expect(NavigationSummary.outlineItemCount(url: jobs[0].output) == n.sourceOutlineItems)
        guard case .converted(let book) = results[1].outcome else { Issue.record("book6x9 não converteu"); return }
        #expect(book.navigation?.sourceOutlineItems == 0)
        #expect(OutlineDisplay.preserved(try #require(book.navigation)) == "sem sumário na origem")
    }

    @Test func cancellingKillsRunningChildrenAndSkipsTheRest() async throws {
        let exe = try Scratch.script("lote-hang.sh", "exec sleep 30")
        let client = HelperClient(executable: exe, convertTimeout: 60)
        let dest = Scratch.url("lote-cancel-\(UUID().uuidString.prefix(6))")
        let jobs = (0..<5).map { i in
            BatchJob(id: "\(i)", input: Scratch.url("x\(i).pdf"), output: dest.appendingPathComponent("x\(i) — mini.pdf"),
                     settings: ConversionSettings())
        }
        let log = EventLog()
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task { await BatchRunner.run(jobs, client: client, maxConcurrent: 2) { log.record($0) } }
        // Espera os dois primeiros começarem (sem sleep fixo: no máximo 5 s).
        while await log.peak < 2, clock.now - start < .seconds(5) { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))   // filhos de fato no ar
        task.cancel()
        let results = await task.value
        #expect(clock.now - start < .seconds(10))   // SIGTERM no sleep, não os 30 s
        #expect(results.allSatisfy { $0.outcome == .cancelled })
        #expect(await log.peak == 2)
        #expect(BatchSummary(results).cancelled == 5)
        #expect(BatchSummary(results).headline == "0 convertidos de 5 · 5 cancelados")
        #expect(!FileManager.default.fileExists(atPath: jobs[0].output.path))
    }

    @Test func limiterCapsConcurrency() async {
        let limiter = ConcurrencyLimiter(limit: 2)
        let counter = Counter()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<8 {
                g.addTask {
                    await limiter.withPermit {
                        await counter.enter()
                        try? await Task.sleep(for: .milliseconds(30))
                        await counter.leave()
                    }
                }
            }
        }
        #expect(await counter.peak == 2)
        #expect(await counter.total == 8)
    }

    @Test func shareItemsKeepExistingUniqueFiles() throws {
        let a = Scratch.url("share-a.pdf"), b = Scratch.url("share-b.pdf")
        try Tree.pdfBytes.write(to: a)
        try Tree.pdfBytes.write(to: b)
        let link = Scratch.url("share-link.pdf")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        #expect(ShareItems.urls([a, nil, Scratch.url("nao-existe.pdf"), b, a, link]) == [a, b])
        #expect(ShareItems.urls([]).isEmpty)
    }
}

private actor Counter {
    var now = 0, peak = 0, total = 0
    func enter() { now += 1; total += 1; peak = max(peak, now) }
    func leave() { now -= 1 }
}

// MARK: - Relatório da CLI (mudança aditiva)

@Suite struct ReportCompatibilityTests {
    /// Remove uma chave de primeiro nível do JSON, como uma CLI de antes da mudança
    /// mandaria. Edição textual: reserializar com JSONSerialization poderia mexer nos
    /// números e a comparação com o original deixaria de ser exata.
    private func dropping(_ key: String, _ data: Data) throws -> Data {
        let text = String(decoding: data, as: UTF8.self)
        let value = #"(\{[^{}]*\}|-?[0-9.eE+-]+|null)"#
        let re = try Regex("\"\(key)\":\(value),?")
        let edited = text.replacing(re, with: "").replacingOccurrences(of: ",}", with: "}")
        #expect(edited != text, "a chave \(key) deveria estar no JSON novo")
        return Data(edited.utf8)
    }

    @Test func oldJSONWithoutNavigationStillDecodes() async throws {
        let client = try Helper.client()
        let pdf = try await CorpusFiles.shared.pdf("navigation")
        let report = try await client.convert(input: pdf, output: Scratch.url("compat — mini.pdf"), settings: ConversionSettings(classMode: .all))
        let n = try #require(report.navigation)
        let old = try HelperClient.decode(ConversionReport.self, try dropping("navigation", JSONEncoder().encode(report)))
        #expect(old.navigation == nil)
        #expect(old.validation == report.validation)
        // Sem o campo, a interface tira as contagens do invariante 5.
        #expect(OutlineDisplay.counts(old)?.sourceOutlineItems == n.sourceOutlineItems)
        #expect(OutlineDisplay.counts(old)?.preservedOutlineItems == n.sourceOutlineItems)
        #expect(OutlineDisplay.counts(report) == n)

        let plan = try await client.plan(input: pdf, settings: ConversionSettings())
        #expect(plan.sourceOutlineItems == n.sourceOutlineItems)
        let oldPlan = try HelperClient.decode(FullPlanReport.self, try dropping("sourceOutlineItems", JSONEncoder().encode(plan)))
        #expect(oldPlan.sourceOutlineItems == nil)
        #expect(oldPlan.planResult == plan.planResult)
        #expect(OutlineDisplay.source(nil) == nil)
        #expect(OutlineDisplay.source(0) == "sem sumário na origem")
        #expect(OutlineDisplay.source(1) == "Sumário: 1 item")
        #expect(OutlineDisplay.source(9) == "Sumário: 9 itens")
    }
}

// MARK: - Sumário ponta a ponta pelos dois escritores

@Suite struct OutlineEndToEndTests {
    /// O arxivTwoColumn do corpus não tem sumário: grava uma cópia com um item por
    /// página (e um filho), destino no meio do texto. PDFKit em processo, como o
    /// BoxWriter faz nos testes dele; sem CoreText (nenhuma fonte criada aqui).
    static func arxivWithOutline() async throws -> URL {
        let src = try await CorpusFiles.shared.pdf("arxivTwoColumn")
        let out = Scratch.url("arxivTwoColumn-sumario.pdf")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let doc = try #require(PDFDocument(url: src))
        let root = PDFOutline()
        for i in 0..<doc.pageCount {
            let page = try #require(doc.page(at: i))
            let box = page.bounds(for: .cropBox)
            let node = PDFOutline()
            node.label = "Seção \(i + 1)"
            node.destination = PDFDestination(page: page, at: CGPoint(x: box.minX + 90, y: box.maxY - 140))
            root.insertChild(node, at: root.numberOfChildren)
            if i == 0 {
                let child = PDFOutline()
                child.label = "Seção 1.1"
                child.destination = PDFDestination(page: page, at: CGPoint(x: box.midX + 40, y: box.midY))
                node.insertChild(child, at: 0)
            }
        }
        doc.outlineRoot = root
        let tmp = Scratch.url("arxiv-\(UUID().uuidString).pdf")
        #expect(doc.write(to: tmp))
        try? FileManager.default.moveItem(at: tmp, to: out)
        return out
    }

    struct Case: Sendable, CustomTestStringConvertible {
        var scenario: String
        var mode: ConversionMode
        var writer: WriterKind
        var testDescription: String { "\(scenario)-\(mode.rawValue)" }
    }

    static let cases: [Case] = [
        Case(scenario: "navigation", mode: .crop, writer: .box),
        Case(scenario: "navigation", mode: .portraitSlices, writer: .placement),
        Case(scenario: "arxivTwoColumn", mode: .crop, writer: .box),
        Case(scenario: "arxivTwoColumn", mode: .columns, writer: .placement),
    ]

    @Test(arguments: cases)
    func outlineSurvivesWithRightDestinationPages(_ c: Case) async throws {
        let client = try Helper.client()
        let input = c.scenario == "arxivTwoColumn" ? try await Self.arxivWithOutline() : try await CorpusFiles.shared.pdf(c.scenario)
        let output = Scratch.url("e2e-\(c.testDescription) — mini.pdf")
        let r = try await client.convert(input: input, output: output, settings: ConversionSettings(mode: c.mode, classMode: .all))
        #expect(WriterKind(strategy: r.plan.recipe.strategy) == c.writer)
        let inv5 = try #require(r.validation?.result("5"))
        #expect(inv5.status == .passed, "\(inv5.detail)")

        // Contagem: relatório e leitura independente com PDFKit.
        let src = try #require(PDFDocument(url: input)), out = try #require(PDFDocument(url: output))
        let si = NavigationSummary.outlineItems(src), oi = NavigationSummary.outlineItems(out)
        #expect(si.count >= (c.scenario == "navigation" ? 5 : 4))
        #expect(oi.count == si.count)
        let n = try #require(r.navigation)
        #expect(n.sourceOutlineItems == si.count && n.outputOutlineItems == si.count && n.preservedOutlineItems == si.count)
        #expect(n.outputInternalLinks >= n.sourceInternalLinks)

        // Página de destino: a saída apontada vem da página de origem do item, e é a
        // primeira saída dessa página que contém o ponto (ou a mais próxima).
        for (s, o) in zip(si, oi) {
            #expect(s.label == o.label)
            let sd = try #require(s.destination ?? (s.action as? PDFActionGoTo)?.destination)
            let od = try #require(o.destination ?? (o.action as? PDFActionGoTo)?.destination, "\(s.label ?? "")")
            let sp = src.index(for: try #require(sd.page)), op = out.index(for: try #require(od.page))
            let sources = r.plan.pages[op].placements.map(\.sourcePage)
            #expect(sources.contains(sp), "\(s.label ?? ""): saída p. \(op + 1) vem de \(sources), esperado \(sp)")
            #expect(op == r.plan.pages.firstIndex { $0.placements.contains { $0.sourcePage == sp } }
                    || c.writer == .placement, "BoxWriter: uma saída por página de origem")
        }
    }
}
