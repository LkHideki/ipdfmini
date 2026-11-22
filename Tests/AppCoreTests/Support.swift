import Foundation
import Testing
@testable import AppCore

/// CLI do mesmo build (`swift test` compila o produto `ipdfmini` ao lado do .xctest).
enum Helper {
    static let binary: URL? = {
        // Imagem deste módulo (…/debug/ipdfminiPackageTests.xctest/Contents/MacOS/…): o
        // runner do Swift Testing não registra o .xctest em Bundle.allBundles.
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let name = info.dli_fname else { return nil }
        var dir = URL(fileURLWithPath: String(cString: name))
        while dir.path != "/" && dir.pathExtension != "xctest" { dir.deleteLastPathComponent() }
        let exe = dir.deletingLastPathComponent().appendingPathComponent("ipdfmini")
        return FileManager.default.isExecutableFile(atPath: exe.path) ? exe : nil
    }()

    static func client(planTimeout: TimeInterval = 120) throws -> HelperClient {
        let exe = try #require(binary, "executável ipdfmini não encontrado ao lado do bundle de testes")
        return HelperClient(executable: exe, planTimeout: planTimeout)
    }
}

enum Scratch {
    static let root: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("AppCoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    /// Executável falso (script de shell) para simular o processo filho.
    static func script(_ name: String, _ body: String) throws -> URL {
        let u = url(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        return u
    }
}

/// Corpus gravado pela própria CLI, fora deste processo: gerar PDFs com CoreText em
/// paralelo com os outros testes já travou o processo.
actor CorpusFiles {
    static let shared = CorpusFiles()
    private var task: Task<URL, Error>?

    func dir() async throws -> URL {
        if let task { return try await task.value }
        let exe = try #require(Helper.binary, "executável ipdfmini não encontrado ao lado do bundle de testes")
        let t = Task { () throws -> URL in
            let d = Scratch.url("corpus")
            let o = await HelperProcess.run(executable: exe, arguments: ["corpus", d.path], timeout: 300)
            guard o.termination == .exited(0) else {
                throw CorpusError(message: String(decoding: o.stderr, as: UTF8.self))
            }
            return d
        }
        task = t
        return try await t.value
    }

    func pdf(_ scenario: String) async throws -> URL { try await dir().appendingPathComponent("\(scenario).pdf") }
}

struct CorpusError: Error { var message: String }
