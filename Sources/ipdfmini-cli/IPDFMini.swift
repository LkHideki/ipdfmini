import ArgumentParser
import Foundation
import LayoutEngine
import MiniGeometry
import MiniKit
import PDFAnalysis
import PDFWriting
import SyntheticCorpus

// CLI do núcleo. PLAN.md §12.4.

@main
struct IPDFMini: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ipdfmini",
        abstract: "Adapta PDFs para o iPad mini 7.",
        subcommands: [Analyze.self, Plan.self, Convert.self, Calibrate.self, CorpusCommand.self])
}

extension ConversionMode: ExpressibleByArgument {
    /// Nomes aceitos em `--mode` (sem distinção de maiúsculas): valor bruto, nome curto
    /// em português e em inglês e o id da estratégia.
    static let argumentNames: [(names: [String], mode: ConversionMode)] = [
        (["auto", "automatico", "automático"], .auto),
        (["crop", "recorte", "e1"], .crop),
        (["aggressive", "agressivo", "e2"], .aggressiveCrop),
        (["passthrough", "direta", "passagem", "e0"], .passthrough),
        (["landscape", "paisagem", "landscapeslices", "e3"], .landscapeSlices),
        (["portrait", "retrato", "portraitslices", "e4"], .portraitSlices),
        (["columns", "colunas", "e5"], .columns),
    ]

    public init?(argument: String) {
        let a = argument.lowercased()
        guard let m = Self.argumentNames.first(where: { $0.names.contains(a) })?.mode else { return nil }
        self = m
    }

    public static var allValueStrings: [String] { argumentNames.map { $0.names[0] } }
}
extension PageClassMode: ExpressibleByArgument {}
extension Orientation: ExpressibleByArgument {}

/// Falha já explicada ao usuário: mensagem em stderr e código de saída.
struct CLIFailure: Error, CustomStringConvertible {
    var message: String
    var code: Int32 = 2
    var description: String { message }
}

enum Output {
    static func json<T: Encodable>(_ value: T) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try e.encode(value), as: UTF8.self)
    }

    static func error(_ s: String) {
        FileHandle.standardError.write(Data(("ipdfmini: " + s + "\n").utf8))
    }

    /// Traduz erros do núcleo para mensagens em português.
    static func describe(_ error: Error) -> String {
        switch error {
        case AnalysisError.locked: "PDF protegido por senha: informe --password"
        case AnalysisError.unreadable: "não foi possível ler o PDF"
        case let e as WriteError:
            switch e {
            case .cannotOpen(let u): "não foi possível abrir \(u.path)"
            case .encryptedWithoutPassword: "PDF criptografado: informe --password"
            case .wrongPassword: "senha incorreta"
            case .unsupportedPlan(let m): "plano não suportado pelo escritor: \(m)"
            case .writeFailed(let u): "falha ao gravar \(u.path)"
            }
        case let e as ValidatorError:
            switch e {
            case .cannotOpenSource(let u): "validação: não foi possível abrir a origem \(u.path)"
            case .cannotOpenOutput(let u): "validação: não foi possível abrir a saída \(u.path)"
            }
        case let e as CLIFailure: e.message
        case let e as CustomStringConvertible: e.description
        default: "\(error)"
        }
    }
}

/// Executa o corpo traduzindo erros do núcleo; `ExitCode` passa direto.
func guarded(_ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch let e as ExitCode {
        throw e
    } catch {
        Output.error(Output.describe(error))
        throw ExitCode((error as? CLIFailure)?.code ?? 2)
    }
}

func inputURL(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: url.path) else { throw CLIFailure(message: "arquivo não encontrado: \(path)") }
    return url
}

struct ConversionArguments: ParsableArguments {
    @Option(help: ArgumentHelp("Perfil de viewport.", valueName: "id"))
    var profile: String = ViewportProfile.booksPortrait.id

    @Option(help: ArgumentHelp(
        "Estratégia: auto (motor de decisão), passthrough|direta (E0), crop|recorte (E1), aggressive|agressivo (E2, sem cabeçalho/rodapé), landscape|paisagem (E3, fatias em paisagem), portrait|retrato (E4, fatias em retrato) ou columns|colunas (E5). Aceita também E0–E5.",
        valueName: "modo"))
    var mode: ConversionMode = .auto

    @Flag(name: .customLong("remove-headers"), help: "Deixa o modo auto remover cabeçalho, rodapé e número de página (E2).")
    var removeHeaders = false

    @Option(name: .customLong("margin-mm"), help: "Respiro em cada lado, em mm.")
    var marginMM: Double = 2

    @Option(name: .customLong("class-mode"), help: "Classes de escala: all, oddEven ou bySize.")
    var classMode: PageClassMode = .oddEven

    @Option(help: "Senha do PDF de origem.")
    var password: String?

    func options() throws -> ConversionOptions {
        guard let p = ViewportProfile.named(profile) else {
            let ids = ViewportProfile.builtIn.map(\.id).joined(separator: ", ")
            throw CLIFailure(message: "perfil desconhecido: \(profile) (disponíveis: \(ids))")
        }
        guard marginMM >= 0, marginMM.isFinite else { throw CLIFailure(message: "--margin-mm precisa ser ≥ 0") }
        var recipe = Recipe()
        recipe.marginMM = marginMM
        recipe.classMode = classMode
        return ConversionOptions(profile: p, mode: mode, recipe: recipe, password: password, removeHeaderFooter: removeHeaders)
    }
}

struct Analyze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Analisa um PDF (tipo, páginas, corpo, avisos).")

    @Argument(help: "PDF de entrada.") var pdf: String
    @Option(help: "Senha do PDF.") var password: String?
    @Flag(help: "Imprime a análise completa em JSON.") var json = false

    func run() async throws {
        try await guarded {
            let doc = try await Converter().analyze(input: try inputURL(pdf), password: password)
            print(json ? try Output.json(doc) : Text.analysis(AnalysisSummary(doc)))
        }
    }
}

struct Plan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Mostra os candidatos (§8) e o plano escolhido, sem gravar.")

    @Argument(help: "PDF de entrada.") var pdf: String
    @OptionGroup var conversion: ConversionArguments
    @Flag(help: "Imprime candidatos e plano em JSON.") var json = false
    // App (§14.2): análise inteira no mesmo JSON, para replanejar sem reanalisar.
    @Flag(help: "Com --json: inclui a análise completa (FullPlanReport).") var full = false

    func run() async throws {
        try await guarded {
            let input = try inputURL(pdf)
            let options = try conversion.options()
            let r = try await Converter().plan(input: input, options: options)
            guard json else { print(Text.plan(r)); return }
            guard full else { print(try Output.json(PlanReport(r))); return }
            // O app mostra "Sumário: N itens" da origem sem abrir o PDF por conta própria.
            let outline = NavigationSummary.outlineItemCount(url: input, password: options.password)
            print(try Output.json(FullPlanReport(r, sourceOutlineItems: outline)))
        }
    }
}

struct Convert: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Converte, valida e imprime o relatório.",
        discussion: "Código de saída 1 quando algum invariante falha; 2 em erro de entrada ou escrita.")

    @Argument(help: "PDF de entrada.") var pdf: String
    @Option(name: [.short, .customLong("output")], help: "PDF de saída.") var output: String
    @OptionGroup var conversion: ConversionArguments
    @Flag(help: "Imprime o relatório em JSON.") var json = false

    func run() async throws {
        var passed = true
        try await guarded {
            let input = try inputURL(pdf)
            let out = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
            guard out.standardizedFileURL != input.standardizedFileURL else {
                throw CLIFailure(message: "a saída não pode sobrescrever a entrada")
            }
            let r = try await Converter().convert(input: input, output: out, options: try conversion.options())
            print(json ? try Output.json(r) : Text.conversion(r))
            passed = r.passed
        }
        if !passed { throw ExitCode(1) }
    }
}

struct Calibrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Gera o PDF de calibração (§3).")

    @Option(name: [.short, .customLong("output")], help: "PDF de saída.") var output: String
    @Option(help: "portrait ou landscape.") var orientation: Orientation = .portrait

    func run() async throws {
        try await guarded {
            let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
            try CalibrationPDF.write(to: url, orientation: orientation)
            print("PDF de calibração (\(orientation == .portrait ? "retrato" : "paisagem")) gravado em \(url.path)")
        }
    }
}

struct CorpusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "corpus", abstract: "Grava o corpus sintético (PDF + verdade).")

    @Argument(help: "Diretório de destino (criado se preciso).") var dir: String

    func run() async throws {
        try await guarded {
            let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
            let files = try Corpus.writeAll(to: url)
            print("\(files.count / 2) cenários gravados em \(url.path)")
        }
    }
}

// MARK: - Texto

enum Text {
    static func analysis(_ a: AnalysisSummary) -> String {
        var out: [String] = []
        out.append("Documento: \(Describe.documentKind(a.kind)) · \(a.pageCount) \(a.pageCount == 1 ? "página" : "páginas")")
        if let x = a.bodyXHeightPt, let pt = a.bodyPointSizeEquivalent {
            out.append("Corpo: altura-x \(Describe.number(x, decimals: 2)) pt · \(Describe.number(pt)) pt equivalente na origem")
        } else {
            out.append("Corpo: altura-x não medida")
        }
        let kinds = a.pageKinds.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\(Describe.pageKind($0.key)) \($0.value)" }
        out.append("Páginas: " + kinds.joined(separator: " · "))
        out.append("Tamanhos: " + a.sizeGroups.map { "\(Describe.size($0.size)) (\($0.pages))" }.joined(separator: " · "))
        if a.warnings.isEmpty {
            out.append("Avisos: nenhum")
        } else {
            out.append("Avisos:")
            out += a.warnings.map { "  - " + $0 }
        }
        return out.joined(separator: "\n")
    }

    static func candidates(_ c: [CandidateSummary], chosen: Int) -> [String] {
        var out = ["Candidatos: " + c.map(\.line).joined(separator: " · ")]
        let ch = c[chosen]
        out.append("Escolhido: \(ch.line) [\(ch.strategy.rawValue), perfil \(ch.profileID)]")
        for r in ch.risks { out.append("  risco: \(r)") }
        return out
    }

    static func planLines(_ plan: LayoutPlan) -> [String] {
        let scales = Set(plan.pages.flatMap { $0.placements.map { (Double($0.scale) * 1000).rounded() / 1000 } }).sorted()
        var out = ["Plano: \(plan.pages.count) páginas de saída de \(Describe.size(plan.profile.sizePt)); escalas "
                   + scales.map { Describe.number($0, decimals: 3) }.joined(separator: ", ")]
        out += plan.warnings.map { "  aviso: " + Describe.planWarning($0) }
        return out
    }

    static func plan(_ r: PlanResult) -> String {
        var out = [analysis(AnalysisSummary(r.analysis)), ""]
        out += candidates(r.candidates, chosen: r.chosenIndex)
        if r.mode != .auto { out.append("  (modo \(r.mode.rawValue) forçado)") }
        out += planLines(r.plan)
        return out.joined(separator: "\n")
    }

    static func conversion(_ r: ConversionReport) -> String {
        var out = ["Entrada: \(r.input)", analysis(r.analysis), ""]
        out += candidates(r.candidates, chosen: r.chosenIndex)
        if r.mode != .auto { out.append("  (modo \(r.mode.rawValue) forçado)") }
        out += planLines(r.plan)
        out.append("Saída: \(r.output) · \(r.write.outputPageCount) páginas · \(r.write.bytes) bytes")
        out += r.write.warnings.map { "  aviso: " + Describe.writeWarning($0) }
        if let n = r.navigation {
            out.append(n.sourceOutlineItems == 0 ? "Sumário: sem sumário na origem"
                       : "Sumário: \(n.preservedOutlineItems) de \(n.sourceOutlineItems) preservados")
        }
        if let v = r.validation {
            out.append("Validação:")
            for i in v.results {
                let mark = switch i.status {
                case .passed: "ok   "
                case .failed: "FALHA"
                case .notApplicable: "n/a  "
                }
                out.append("  \(mark) \(i.id) \(i.title): \(i.detail)")
            }
            out.append(v.passed ? "Resultado: aprovado" : "Resultado: REPROVADO (\(v.failures.map(\.id).joined(separator: ", ")))")
        } else {
            out.append("Validação: desligada")
        }
        return out.joined(separator: "\n")
    }
}
