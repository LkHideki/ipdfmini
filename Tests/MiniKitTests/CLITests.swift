import ArgumentParser
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

    @Test func modeAndClassArgumentsParse() throws {
        let c = try #require(try IPDFMini.parseAsRoot(["plan", "x.pdf", "--mode", "crop", "--class-mode", "bySize"]) as? Plan)
        #expect(c.conversion.mode == .crop)
        #expect(c.conversion.classMode == .bySize)
    }
}
