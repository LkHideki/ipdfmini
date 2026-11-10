import ArgumentParser
import MiniKit
import PDFWriting
import Foundation
import PDFKit
import SyntheticCorpus
import Testing
@testable import ipdfmini_cli

// CLI chamada pelo próprio parser do ArgumentParser, como no processo
// (`ipdfmini convert …`); `ExitCode` lançado = código de saída ≠ 0.

@Suite struct CLITests {
    func run(_ args: [String]) async throws {
        var cmd = try #require(try IPDFMini.parseAsRoot(args) as? any AsyncParsableCommand)
        try await cmd.run()
    }

    @Test func convertCorpusBookExitsZero() async throws {
        let src = try TestFiles.source(.book6x9)
        let out = TestFiles.url("cli.book6x9.pdf")
        try await run(["convert", src.path, "-o", out.path, "--mode", "crop", "--profile", "books.portrait.fullscreen"])
        let doc = try #require(PDFDocument(url: out))
        #expect(doc.pageCount == 12)
    }

    @Test func convertJSONWithCustomMarginExitsZero() async throws {
        let src = try TestFiles.source(.navigation)
        let out = TestFiles.url("cli.navigation.pdf")
        try await run(["convert", src.path, "-o", out.path, "--margin-mm", "3", "--class-mode", "all", "--json"])
        #expect(FileManager.default.fileExists(atPath: out.path))
    }

    @Test func unknownProfileExitsTwo() async throws {
        let src = try TestFiles.source(.book6x9)
        await #expect(throws: ExitCode(2)) {
            try await run(["convert", src.path, "-o", TestFiles.url("cli.bad.pdf").path, "--profile", "nada"])
        }
    }

    @Test func calibrateAndPlanRun() async throws {
        let cal = TestFiles.url("cli.calibration.pdf")
        try await run(["calibrate", "-o", cal.path, "--orientation", "landscape"])
        let page = try #require(PDFDocument(url: cal)?.page(at: 0))
        #expect(page.bounds(for: .mediaBox).width > page.bounds(for: .mediaBox).height)
        try await run(["plan", try TestFiles.source(.cropMarks).path, "--mode", "passthrough"])
        try await run(["analyze", try TestFiles.source(.scannedPage).path, "--json"])
    }

    @Test func aggressiveModeAndRemoveHeadersExitZero() async throws {
        let src = try TestFiles.source(.cropMarks)
        try await run(["convert", src.path, "-o", TestFiles.url("cli.cropMarks.e2.pdf").path, "--mode", "aggressive"])
        try await run(["convert", src.path, "-o", TestFiles.url("cli.cropMarks.auto.pdf").path, "--remove-headers"])
        let c = try #require(try IPDFMini.parseAsRoot(["plan", "x.pdf", "--mode", "aggressive", "--remove-headers"]) as? Plan)
        #expect(c.conversion.mode == .aggressiveCrop)
        #expect(c.conversion.removeHeaders)
        #expect(try c.conversion.options().removeHeaderFooter)
    }

    @Test func sliceModesAcceptPortugueseEnglishAndStrategyNames() throws {
        let cases: [(String, ConversionMode)] = [
            ("landscape", .landscapeSlices), ("paisagem", .landscapeSlices), ("E3", .landscapeSlices),
            ("landscapeSlices", .landscapeSlices), ("portrait", .portraitSlices), ("retrato", .portraitSlices),
            ("e4", .portraitSlices), ("portraitSlices", .portraitSlices), ("columns", .columns), ("Colunas", .columns),
            ("E5", .columns), ("recorte", .crop), ("agressivo", .aggressiveCrop), ("direta", .passthrough),
            ("E0", .passthrough), ("automático", .auto),
        ]
        for (arg, mode) in cases {
            let c = try #require(try IPDFMini.parseAsRoot(["plan", "x.pdf", "--mode", arg]) as? Plan)
            #expect(c.conversion.mode == mode, "\(arg)")
        }
        // Valor bruto de todo modo (o app passa `rawValue` à CLI).
        for m in ConversionMode.allCases { #expect(ConversionMode(argument: m.rawValue) == m) }
        #expect(throws: (any Error).self) { try IPDFMini.parseAsRoot(["plan", "x.pdf", "--mode", "E6"]) }
        let help = IPDFMini.helpMessage(for: Plan.self)
        for word in ["landscape", "paisagem", "portrait", "retrato", "columns", "colunas", "E3", "E4", "E5"] {
            #expect(help.contains(word), "help sem \(word)")
        }
    }

    @Test func convertWithColumnsModeExitsZero() async throws {
        let src = try TestFiles.source(.arxivTwoColumn)
        let out = TestFiles.url("cli.arxiv.e5.pdf")
        try await run(["convert", src.path, "-o", out.path, "--mode", "colunas"])
        #expect(try #require(PDFDocument(url: out)).pageCount > CorpusCache.doc(.arxivTwoColumn).truth.pages.count)
    }

    @Test func reportsStayDecodable() throws {
        // Aviso de tamanho gravado antes do campo `budget` (relatório JSON antigo).
        let old = try JSONDecoder().decode(WriteWarning.self, from: Data(#"{"sizeBudgetExceeded":{"ratio":1.2}}"#.utf8))
        #expect(old == .sizeBudgetExceeded(ratio: 1.2))
        #expect(Describe.writeWarning(old) == "arquivo 1,2× a origem")
        #expect(Describe.writeWarning(.sizeBudgetExceeded(ratio: 1.42, budget: 1.3)) == "arquivo 1,42× a origem (meta ≤ 1,3×)")
        // Modos novos no JSON da CLI e de volta.
        for m in ConversionMode.allCases {
            #expect(try JSONDecoder().decode(ConversionMode.self, from: JSONEncoder().encode(m)) == m)
        }
    }

    @Test func modeAndClassArgumentsParse() throws {
        let c = try #require(try IPDFMini.parseAsRoot(["plan", "x.pdf", "--mode", "crop", "--class-mode", "bySize"]) as? Plan)
        #expect(c.conversion.mode == .crop)
        #expect(c.conversion.classMode == .bySize)
    }
}
