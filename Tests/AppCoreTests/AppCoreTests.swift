import ArgumentParser
import CoreGraphics
import Foundation
import LayoutEngine
import MiniGeometry
import MiniKit
import PDFAnalysis
import PDFKit
import Testing
@testable import AppCore
@testable import ipdfmini_cli

// MARK: - Processo filho (isolamento do §14.2)

@Suite struct HelperIsolationTests {
    @Test func realHelperPlanDecodesAndMatchesInProcessReplan() async throws {
        let client = try Helper.client()
        let pdf = try await CorpusFiles.shared.pdf("book6x9")
        let settings = ConversionSettings()
        let report = try await client.plan(input: pdf, settings: settings)
        #expect(report.analysis.pageCount == 12)
        // Auto do M3 (E0–E5 × orientação): fatias podem dar mais de uma tela por página.
        #expect(report.plan.pages.count >= 12)
        #expect(!report.candidates.isEmpty)
        // Replanejar a análise decodificada dá o mesmo plano que a CLI: a pré-visualização não mente.
        let again = try Replanner.replan(report.analysis, settings)
        #expect(again.result.plan == report.plan)
        #expect(again.result.candidates == report.candidates)
        print("replanejamento em processo (debug): \(String(format: "%.2f", again.millis)) ms")
        #expect(again.millis < 1000)
    }

    @Test func realHelperConvertReturnsValidationReport() async throws {
        let client = try Helper.client()
        let pdf = try await CorpusFiles.shared.pdf("navigation")
        let out = Scratch.url("navigation — mini.pdf")
        let r = try await client.convert(input: pdf, output: out, settings: ConversionSettings(classMode: .all))
        #expect(FileManager.default.fileExists(atPath: out.path))
        let v = try #require(r.validation)
        #expect(v.results.contains { $0.id == "5" })
        #expect(r.passed)
    }

    @Test func corruptPDFBecomesFailureNotCrash() async throws {
        let client = try Helper.client()
        let bad = Scratch.url("corrompido.pdf")
        try Data("%PDF-1.7\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\nlixo \u{0}\u{1}\u{2}".utf8).write(to: bad)
        let result: Result<FullPlanReport, HelperError>
        do {
            result = .success(try await client.plan(input: bad, settings: ConversionSettings()))
        } catch let e as HelperError {
            result = .failure(e)
        }
        guard case .failure(.failed(let code, let message)) = result else {
            Issue.record("esperava falha da CLI, veio \(result)")
            return
        }
        #expect(code == 2)
        #expect(message.contains("PDF"))
        #expect(DocumentStatus.after(result).isFailure)
    }

    @Test func crashingHelperMarksDocumentFailed() async throws {
        let exe = try Scratch.script("crash.sh", "kill -SEGV $$")
        let client = HelperClient(executable: exe)
        do {
            _ = try await client.plan(input: Scratch.url("x.pdf"), settings: ConversionSettings())
            Issue.record("esperava queda do processo filho")
        } catch let e as HelperError {
            #expect(e == .crashed(signal: SIGSEGV))
            let status = DocumentStatus.after(.failure(e))
            #expect(status.isFailure)
            #expect(e.message.contains("caiu"))
            #expect(e.message.contains("SIGSEGV"))
        }
    }

    @Test func hangingHelperIsKilledAtTimeout() async throws {
        let exe = try Scratch.script("hang.sh", "exec sleep 30")
        let client = HelperClient(executable: exe, planTimeout: 0.5)
        let start = Date()
        do {
            _ = try await client.plan(input: Scratch.url("x.pdf"), settings: ConversionSettings())
            Issue.record("esperava limite de tempo")
        } catch let e as HelperError {
            if case .timedOut = e {} else { Issue.record("esperava timedOut, veio \(e)") }
        }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func garbageOutputIsUndecodable() async throws {
        let exe = try Scratch.script("garbage.sh", "echo 'isto não é JSON'")
        do {
            _ = try await HelperClient(executable: exe).plan(input: Scratch.url("x.pdf"), settings: ConversionSettings())
            Issue.record("esperava erro de decodificação")
        } catch let e as HelperError {
            if case .undecodable = e {} else { Issue.record("esperava undecodable, veio \(e)") }
        }
    }

    @Test func missingExecutableFailsToLaunch() async throws {
        let client = HelperClient(executable: Scratch.url("nao-existe"))
        do {
            _ = try await client.plan(input: Scratch.url("x.pdf"), settings: ConversionSettings())
            Issue.record("esperava falha ao iniciar")
        } catch let e as HelperError {
            if case .launchFailed = e {} else { Issue.record("esperava launchFailed, veio \(e)") }
        }
    }

    @Test func largeOutputOnBothPipesDoesNotDeadlock() async throws {
        let exe = try Scratch.script("big.sh", "head -c 3000000 /dev/zero | tr '\\0' a; head -c 200000 /dev/zero | tr '\\0' b >&2")
        let o = await HelperProcess.run(executable: exe, arguments: [], timeout: 30)
        #expect(o.termination == .exited(0))
        #expect(o.stdout.count == 3_000_000)
        #expect(o.stderr.count == 200_000)
    }

    @Test func validationFailureExitCodeStillDecodes() throws {
        let report = Data("{}".utf8)
        let ok = try HelperClient.check(ProcessOutcome(termination: .exited(1), stdout: report, stderr: Data()),
                                        timeout: 1, acceptValidationFailure: true)
        #expect(ok == report)
        #expect(throws: HelperError.failed(code: 1, message: "o processo auxiliar terminou com código 1")) {
            try HelperClient.check(ProcessOutcome(termination: .exited(1), stdout: report, stderr: Data()),
                                   timeout: 1, acceptValidationFailure: false)
        }
        #expect(HelperClient.errorMessage(Data("ipdfmini: não foi possível ler o PDF\n".utf8)) == "não foi possível ler o PDF")
    }
}

// MARK: - JSON da CLI

@Suite struct CLIJSONTests {
    @Test func fullPlanJSONFromCLIEncoderRoundTrips() async throws {
        let pdf = try await CorpusFiles.shared.pdf("cropMarks")
        let r = try await Converter().plan(input: pdf, options: ConversionSettings().options)
        // Mesmo codificador da CLI (`Output.json`), decodificado como o app decodifica.
        let json = try Output.json(FullPlanReport(r))
        let decoded = try HelperClient.decode(FullPlanReport.self, Data(json.utf8))
        #expect(decoded.planResult == r)
        #expect(decoded.analysis.pages.count == r.analysis.pages.count)
    }

    @Test func planFullFlagParses() throws {
        let c = try #require(try IPDFMini.parseAsRoot(["plan", "x.pdf", "--json", "--full"]) as? ipdfmini_cli.Plan)
        #expect(c.full && c.json)
    }

    @Test func settingsArgumentsMatchCLIOptions() throws {
        for s in [ConversionSettings(),
                  ConversionSettings(profileID: "books.landscape.fullscreen", mode: .crop, marginMM: 3.5, classMode: .all),
                  ConversionSettings(profileID: "safearea.portrait", mode: .aggressiveCrop, marginMM: 0, classMode: .bySize),
                  ConversionSettings(mode: .passthrough, marginMM: 10),
                  ConversionSettings(mode: .landscapeSlices, allowSplitting: true),
                  ConversionSettings(mode: .portraitSlices, marginMM: 1, allowSplitting: true),
                  ConversionSettings(profileID: "fullscreen.landscape", mode: .columns, classMode: .all, allowSplitting: true),
                  ConversionSettings(allowSplitting: true),
                  // Modo de fatias sem a divisão: vai como automático (o interruptor manda).
                  ConversionSettings(mode: .columns)] {
            let c = try #require(try IPDFMini.parseAsRoot(["plan", "x.pdf"] + s.cliArguments) as? ipdfmini_cli.Plan)
            #expect(try c.conversion.options() == s.options, "\(s)")
            #expect(try c.conversion.options().splittingAllowed == s.allowSplitting, "\(s)")
        }
    }

    /// INC-22: interruptor desligado por padrão; nenhum caminho do app divide páginas sem ele.
    @Test func splittingToggleGatesEveryPath() async throws {
        let off = ConversionSettings(mode: .columns)
        #expect(!ConversionSettings().allowSplitting)
        #expect(off.effectiveMode == .auto && off.options.mode == .auto && !off.options.splittingAllowed)
        #expect(!off.cliArguments.contains("--allow-split") && off.cliArguments.contains("auto"))
        var s = ConversionSettings(mode: .portraitSlices, allowSplitting: true)
        #expect(s.effectiveMode == .portraitSlices && s.cliArguments.contains("--allow-split"))
        s.setAllowSplitting(false)
        #expect(s.mode == .auto && !s.allowSplitting)
        s.setAllowSplitting(true)
        #expect(s.mode == .auto && s.allowSplitting)

        // Seletor de modo: Paisagem, Fatias em retrato e Colunas só com o interruptor.
        #expect(Labels.modes(allowSplitting: false) == [.auto, .crop, .aggressiveCrop, .passthrough])
        #expect(Set(Labels.modes(allowSplitting: true)) == Set(ConversionMode.allCases))

        // Replanejamento em processo (pré-visualização, clique em candidato) e processo filho
        // (exportação, lote) partem destes ajustes: 1 → 1 sem o interruptor.
        let pdf = try await CorpusFiles.shared.pdf("arxivTwoColumn")
        let analysis = try await Converter().analyze(input: pdf)
        let r = try Replanner.replan(analysis, ConversionSettings()).result
        #expect(r.plan.pages.count == analysis.pages.count)
        #expect(!r.candidates.contains { StrategyID.splitsPages($0.strategy) })
        for c in r.candidates {
            let forced = try #require(ConversionSettings().forcing(c))
            #expect(try Replanner.replan(analysis, forced).result.plan.pages.count == analysis.pages.count, "\(c.strategy)")
        }
        let split = try Replanner.replan(analysis, ConversionSettings(allowSplitting: true)).result
        #expect(split.plan.pages.count > analysis.pages.count)
        let client = try Helper.client()
        let out = Scratch.url("split-off — mini.pdf")
        let report = try await client.convert(input: pdf, output: out, settings: ConversionSettings(mode: .columns))
        #expect(!report.allowSplitting && report.write.outputPageCount == analysis.pages.count)
        #expect(report.validation?.result("9")?.status == .passed)
        #expect(try #require(PDFDocument(url: out)).pageCount == analysis.pages.count)
    }

    @Test func settingsWithoutAllowSplittingDecodeAsOff() throws {
        let json = #"{"profileID":"books.portrait.fullscreen","mode":"columns","marginMM":2,"classMode":"oddEven"}"#
        let s = try JSONDecoder().decode(ConversionSettings.self, from: Data(json.utf8))
        #expect(!s.allowSplitting && s.effectiveMode == .auto)
        let on = ConversionSettings(allowSplitting: true)
        #expect(try JSONDecoder().decode(ConversionSettings.self, from: JSONEncoder().encode(on)) == on)
    }
}

// MARK: - Tamanho real

@Suite struct PhysicalScaleTests {
    @Test func studioDisplayGivesPhysicalMiniSize() throws {
        // 27" 5K: 596,7 × 335,6 mm, "parece 2560 × 1440".
        let k = try #require(PhysicalScale.pointsPerMM(screenSizeMM: CGSize(width: 596.7, height: 335.6),
                                                       screenFramePoints: CGSize(width: 2560, height: 1440)))
        #expect(abs(k - 4.2903) < 0.002)
        let screen = PhysicalScale.size(mm: PhysicalScale.screenMM, pointsPerMM: k)
        #expect(abs(screen.width - 115.94 * k) < 1e-9)
        #expect(abs(screen.height - 176.55 * k) < 1e-9)
        // A página canônica em 1:1 ocupa exatamente a tela desenhada.
        let ptScale = PhysicalScale.pointsPerPDFPoint(pointsPerMM: k)
        #expect(abs(MiniPage.fullPortrait.width * ptScale - screen.width) < 0.05)
        #expect(abs(MiniPage.fullPortrait.height * ptScale - screen.height) < 0.05)
    }

    @Test func implausibleDisplaySizesAreRejected() {
        #expect(PhysicalScale.pointsPerMM(screenSizeMM: .zero, screenFramePoints: CGSize(width: 1920, height: 1080)) == nil)
        // Direções incoerentes (adaptador que inventa o tamanho).
        #expect(PhysicalScale.pointsPerMM(screenSizeMM: CGSize(width: 300, height: 300),
                                          screenFramePoints: CGSize(width: 1000, height: 500)) == nil)
        // Densidade absurda.
        #expect(PhysicalScale.pointsPerMM(screenSizeMM: CGSize(width: 60, height: 40),
                                          screenFramePoints: CGSize(width: 5000, height: 3333)) == nil)
    }
}

// MARK: - Textos e selos

@Suite struct PresentationTests {
    @Test func defaultExportName() {
        let src = URL(fileURLWithPath: "/tmp/relatório final.pdf")
        #expect(ExportNaming.defaultFileName(title: "Meu Livro", sourceURL: src) == "Meu Livro — mini.pdf")
        #expect(ExportNaming.defaultFileName(title: nil, sourceURL: src) == "relatório final — mini.pdf")
        #expect(ExportNaming.defaultFileName(title: "   ", sourceURL: src) == "relatório final — mini.pdf")
        #expect(ExportNaming.defaultFileName(title: "Microsoft Word - tese.docx", sourceURL: src) == "tese — mini.pdf")
        #expect(ExportNaming.defaultFileName(title: "untitled", sourceURL: src) == "relatório final — mini.pdf")
        #expect(ExportNaming.defaultFileName(title: "A/B: notas", sourceURL: src) == "A-B- notas — mini.pdf")
    }

    @Test func warningsMapToBadges() {
        let box = CGRect(x: 0, y: 0, width: 400, height: 600)
        let geo = PageGeometry(effectiveBox: box, rotation: 0)
        func page(_ i: Int, ink: Bool, body: CGFloat?) -> PageAnalysis {
            PageAnalysis(index: i, boxes: PageBoxes(media: box, crop: box), geometry: geo, kind: ink ? .digitalText : .empty,
                         inkBox: ink ? box.insetBy(dx: 40, dy: 40) : nil, bodyXHeightPt: body)
        }
        // p0 normal (4,7 pt × 1 = 1,66 mm), p1 vazia, p2 exceção de escala, p3 corpo pequeno (× 0,5 = 0,83 mm).
        let doc = DocumentAnalysis(sha256: "", pageCount: 4,
                                   pages: [page(0, ink: true, body: 4.7), page(1, ink: false, body: nil),
                                           page(2, ink: true, body: 4.7), page(3, ink: true, body: nil)],
                                   kind: .book, bodyXHeightPt: 4.7)
        func out(_ i: Int, scale s: CGFloat) -> OutputPage {
            OutputPage(sizePt: MiniPage.fullPortrait, placements: [
                Placement(sourcePage: i, sourceRect: box, transform: CGAffineTransform(scaleX: s, y: s)),
            ])
        }
        let plan = LayoutPlan(profile: .booksPortrait, pages: [out(0, scale: 1), out(1, scale: 1), out(2, scale: 1.05), out(3, scale: 0.5)],
                              recipe: Recipe(),
                              warnings: [.emptyPage(page: 1), .scaleException(page: 2, classScale: 1, pageScale: 1.05),
                                         .belowMinimumLegibility(xHeightMM: 0.83)])
        let b = PageBadges.compute(plan: plan, analysis: doc)
        #expect(b == [[], [.emptyPage], [.scaleException], [.smallText]])
        #expect(PageBadge.smallText.title == "Letra pequena")
        #expect(PageBadge.scaleException.title == "Exceção de escala")
        #expect(PageBadge.emptyPage.title == "Página vazia")
    }

    @Test func modeLabelsCoverAllModes() {
        #expect(Set(Labels.modes.map(\.rawValue)) == Set(ConversionMode.allCases.map(\.rawValue)))
        #expect(Labels.modes.first == .auto)
        #expect(Labels.mode(.aggressiveCrop) == "Recorte sem cabeçalho/rodapé")
        #expect(Labels.mode(.passthrough) == "Passagem direta")
        #expect(Labels.mode(forcing: .crop) == .crop)
        #expect(Labels.mode(forcing: .aggressiveCrop) == .aggressiveCrop)
        #expect(Labels.strategy(for: .auto) == nil)
        // E3–E5: nome da estratégia, força a própria estratégia e volta pelo clique.
        for (m, s) in [(ConversionMode.landscapeSlices, StrategyID.landscapeSlices), (.portraitSlices, .portraitSlices),
                       (.columns, .columns)] {
            #expect(Labels.strategy(for: m) == s)
            #expect(Labels.mode(forcing: s) == m)
            #expect(Labels.mode(m) == s.displayName)
        }
        #expect(Array(Labels.modes.prefix(4)) == [.auto, .crop, .aggressiveCrop, .passthrough])
    }

    @Test func candidateClickForcesStrategyAndOrientation() throws {
        func summary(_ s: StrategyID, _ p: ViewportProfile) -> CandidateSummary {
            CandidateSummary(Candidate(profile: p, estimate: Estimate(strategy: s, orientation: p.orientation, bodyXHeightMM: 1.6,
                                                                      smallestXHeightMM: 1.6, screensPerSourcePage: 2,
                                                                      fidelityCost: s.fidelityCost)),
                             legibility: .standard)
        }
        // Fatias e colunas só com a divisão permitida (INC-22); sem ela o clique não faz nada.
        #expect(ConversionSettings().forcing(summary(.landscapeSlices, .booksPortrait.rotated)) == nil)
        #expect(ConversionSettings().forcing(summary(.columns, .booksPortrait)) == nil)
        #expect(ConversionSettings().forcing(summary(.crop, .booksPortrait))?.mode == .crop)
        let base = ConversionSettings(allowSplitting: true)
        let e3 = try #require(base.forcing(summary(.landscapeSlices, .booksPortrait.rotated)))
        #expect(e3.mode == .landscapeSlices && e3.profileID == "books.landscape.fullscreen")
        let e5 = try #require(base.forcing(summary(.columns, .booksPortrait)))
        #expect(e5.mode == .columns && e5.profileID == base.profileID)
        // Girado fora dos embutidos: só o modo muda.
        let safe = ConversionSettings(profileID: "safearea.portrait")
        #expect(try #require(safe.forcing(summary(.crop, safe.profile.rotated))).profileID == "safearea.portrait")
        #expect(Labels.candidate(summary(.columns, .booksPortrait)) == "Colunas · retrato: 9,6 pt, 2 telas")
    }

    @Test func rotationSwitchesBetweenBuiltInProfiles() {
        #expect(ConversionSettings().rotatedProfileID == "books.landscape.fullscreen")
        #expect(ConversionSettings(profileID: "fullscreen.landscape").rotatedProfileID == "fullscreen.portrait")
        #expect(ConversionSettings(profileID: "safearea.portrait").rotatedProfileID == nil)
    }

    @Test func statusAfterSuccessCountsWarnings() async throws {
        let pdf = try await CorpusFiles.shared.pdf("book6x9")
        let r = try await Converter().plan(input: pdf, options: ConversionSettings().options)
        let status = DocumentStatus.after(.success(FullPlanReport(r)))
        #expect(!status.isFailure)
        #expect(status == DocumentStatus.settled(warnings: DocumentStatus.warningCount(r)))
    }
}

// MARK: - Pré-visualização

@Suite struct RendererTests {
    @Test func outputAndSourcePagesRenderFromPlan() async throws {
        let pdf = try await CorpusFiles.shared.pdf("book6x9")
        let r = try await Converter().plan(input: pdf, options: ConversionSettings().options)
        let doc = try #require(PDFDocument(url: pdf))
        let img = try #require(PlanRenderer.renderOutputPage(0, plan: r.plan, analysis: r.analysis, document: doc, pixelsPerPoint: 1))
        // Tamanho da página de saída do plano (no M3 o auto pode escolher o perfil girado).
        let size = r.plan.pages[0].sizePt
        #expect(size == MiniPage.fullPortrait || size == MiniPage.fullLandscape)
        #expect(img.width == Int(size.width.rounded(.up)))
        #expect(img.height == Int(size.height.rounded(.up)))
        #expect(darkFraction(img) > 0.005)   // tem texto

        let src = try #require(PlanRenderer.renderSourcePage(0, plan: r.plan, analysis: r.analysis, document: doc,
                                                             highlight: 0, pixelsPerPoint: 1))
        let canvas = try #require(PlanRenderer.sourceCanvas(0, plan: r.plan, analysis: r.analysis))
        #expect(src.width == Int(canvas.width.rounded(.up)))
        // Uma janela por colocação que sai da página 0 (fatias: várias, em páginas de saída seguidas).
        let fromFirst = r.plan.pages.indices.filter { j in r.plan.pages[j].placements.contains { $0.sourcePage == 0 } }
        #expect(!fromFirst.isEmpty && fromFirst.first == 0)
        #expect(PlanRenderer.windows(0, plan: r.plan).map(\.output) == fromFirst)
    }

    private func darkFraction(_ img: CGImage) -> Double {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return 0 }
        return Double(px.count { $0 < 128 }) / Double(px.count)
    }
}
