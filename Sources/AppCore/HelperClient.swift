import Darwin
import Foundation
import MiniKit

/// Falha do processo filho, já com texto para a interface.
public enum HelperError: Error, Sendable, Equatable {
    case notFound
    case launchFailed(String)
    case timedOut(seconds: Int)
    case crashed(signal: Int32)
    /// A CLI recusou ou falhou com mensagem (código 2 = entrada/escrita).
    case failed(code: Int32, message: String)
    case undecodable(String)

    public var message: String {
        switch self {
        case .notFound: "o executável auxiliar ipdfmini não foi encontrado no app"
        case .launchFailed(let m): "não foi possível iniciar o processo auxiliar: \(m)"
        case .timedOut(let s): "o processamento passou do limite de \(s) s e foi interrompido"
        case .crashed(let sig): "o processo de análise caiu (\(Self.signalName(sig))); o PDF pode estar corrompido"
        case .failed(_, let m): m
        case .undecodable(let m): "resposta inesperada do processo auxiliar: \(m)"
        }
    }

    static func signalName(_ s: Int32) -> String {
        let names: [Int32: String] = [SIGSEGV: "SIGSEGV", SIGBUS: "SIGBUS", SIGABRT: "SIGABRT", SIGILL: "SIGILL",
                                      SIGTRAP: "SIGTRAP", SIGKILL: "SIGKILL", SIGTERM: "SIGTERM", SIGFPE: "SIGFPE"]
        return "sinal \(s)" + (names[s].map { ", \($0)" } ?? "")
    }
}

/// Cliente da CLI embutida (Contents/Helpers/ipdfmini). Isolamento do §14.2: um
/// PDF que derruba o CoreGraphics derruba só o filho, e o documento vira falha.
public struct HelperClient: Sendable {
    public var executable: URL
    public var planTimeout: TimeInterval
    public var convertTimeout: TimeInterval

    public init(executable: URL, planTimeout: TimeInterval = 180, convertTimeout: TimeInterval = 600) {
        self.executable = executable
        self.planTimeout = planTimeout
        self.convertTimeout = convertTimeout
    }

    /// Ordem: variável IPDFMINI_HELPER, bundle (Contents/Helpers), ao lado do executável (`swift run`).
    public static func locate(bundle: Bundle = .main,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates: [URL] = []
        if let env = environment["IPDFMINI_HELPER"], !env.isEmpty { candidates.append(URL(fileURLWithPath: env)) }
        candidates.append(bundle.bundleURL.appendingPathComponent("Contents/Helpers/ipdfmini"))
        if let exe = bundle.executableURL { candidates.append(exe.deletingLastPathComponent().appendingPathComponent("ipdfmini")) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Análise + candidatos + plano num JSON só (`plan --json --full`).
    public func plan(input: URL, settings: ConversionSettings) async throws(HelperError) -> FullPlanReport {
        let args = ["plan", input.path, "--json", "--full"] + settings.cliArguments
        let outcome = await HelperProcess.run(executable: executable, arguments: args, timeout: planTimeout)
        let data = try Self.check(outcome, timeout: planTimeout, acceptValidationFailure: false)
        return try Self.decode(FullPlanReport.self, data)
    }

    /// Converte e valida. Invariante reprovado (código 1) ainda devolve o relatório.
    public func convert(input: URL, output: URL, settings: ConversionSettings) async throws(HelperError) -> ConversionReport {
        let args = ["convert", input.path, "-o", output.path, "--json"] + settings.cliArguments
        let outcome = await HelperProcess.run(executable: executable, arguments: args, timeout: convertTimeout)
        let data = try Self.check(outcome, timeout: convertTimeout, acceptValidationFailure: true)
        return try Self.decode(ConversionReport.self, data)
    }

    static func check(_ o: ProcessOutcome, timeout: TimeInterval, acceptValidationFailure: Bool) throws(HelperError) -> Data {
        switch o.termination {
        case .launchFailed(let m): throw .launchFailed(m)
        case .timedOut: throw .timedOut(seconds: Int(timeout.rounded()))
        case .signaled(let s): throw .crashed(signal: s)
        case .exited(0): return o.stdout
        case .exited(1) where acceptValidationFailure && !o.stdout.isEmpty: return o.stdout
        case .exited(let code):
            throw .failed(code: code, message: errorMessage(o.stderr) ?? "o processo auxiliar terminou com código \(code)")
        }
    }

    /// Primeira linha de erro da CLI, sem o prefixo "ipdfmini: ".
    static func errorMessage(_ stderr: Data) -> String? {
        let text = String(decoding: stderr, as: UTF8.self)
        let line = text.split(whereSeparator: \.isNewline).map(String.init).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard var line else { return nil }
        if line.hasPrefix("ipdfmini: ") { line.removeFirst("ipdfmini: ".count) }
        return line
    }

    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws(HelperError) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw .undecodable(String(describing: error).prefix(300).description)
        }
    }
}
