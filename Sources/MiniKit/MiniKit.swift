import CoreGraphics
import Foundation
import LayoutEngine
import MiniGeometry
import PDFAnalysis
import PDFWriting

// Fachada do núcleo: analisar → decidir/planejar → escrever → validar. PLAN.md §4.
// Sem AppKit: o núcleo precisa compilar no iPadOS (§12.6).

/// Como escolher a estratégia.
public enum ConversionMode: String, Codable, Sendable, CaseIterable {
    /// Motor de decisão (§8) entre E0 e E1.
    case auto
    /// Força E1.
    case crop
    /// Força E0.
    case passthrough

    var forcedStrategy: StrategyID? {
        switch self {
        case .auto: nil
        case .crop: .crop
        case .passthrough: .passthrough
        }
    }
}

public struct ConversionOptions: Sendable, Equatable {
    public var profile: ViewportProfile
    public var mode: ConversionMode
    /// Respiro, classes, legibilidade. `recipe.strategy` é ignorado: quem decide é `mode`.
    public var recipe: Recipe
    /// Senha de usuário do PDF de origem.
    public var password: String?
    public var writeOptions: WriteOptions
    public var validate: Bool

    public init(profile: ViewportProfile = .booksPortrait, mode: ConversionMode = .auto, recipe: Recipe = Recipe(),
                password: String? = nil, writeOptions: WriteOptions = WriteOptions(), validate: Bool = true) {
        self.profile = profile
        self.mode = mode
        self.recipe = recipe
        self.password = password
        self.writeOptions = writeOptions
        self.validate = validate
    }
}

public enum ConversionError: Error, Equatable, Sendable, CustomStringConvertible {
    case noCandidate
    case strategyUnavailable(StrategyID)

    public var description: String {
        switch self {
        case .noCandidate: "nenhum candidato de estratégia para este documento"
        case .strategyUnavailable(let s): "estratégia \(s.rawValue) indisponível"
        }
    }
}

/// Ponto de entrada do núcleo para a CLI e o app.
public struct Converter: Sendable {
    public var analyzerOptions: DocumentAnalyzer.Options
    public var validator: Validator

    public init(analyzerOptions: DocumentAnalyzer.Options = .init(), validator: Validator = Validator()) {
        self.analyzerOptions = analyzerOptions
        self.validator = validator
    }

    /// Estratégias do M1 (E0 e E1).
    static let strategies: [any AdaptationStrategy] = [PassthroughStrategy(), CropStrategy()]

    public func analyze(input: URL, password: String? = nil) async throws -> DocumentAnalysis {
        var o = analyzerOptions
        o.password = password
        return try await DocumentAnalyzer(options: o).analyze(url: input)
    }

    public func plan(input: URL, options: ConversionOptions) async throws -> PlanResult {
        let doc = try await analyze(input: input, password: options.password)
        return try plan(analysis: doc, options: options)
    }

    /// Replaneja sem reanalisar (pré-visualização, §16).
    public func plan(analysis doc: DocumentAnalysis, options: ConversionOptions) throws -> PlanResult {
        // A tabela de candidatos sai sempre completa; o modo só fixa o escolhido.
        let engine = DecisionEngine(strategies: Self.strategies, profiles: [options.profile])
        guard let decision = engine.decide(doc, recipe: options.recipe) else { throw ConversionError.noCandidate }
        let chosenIndex: Int
        if let forced = options.mode.forcedStrategy {
            guard let i = decision.candidates.firstIndex(where: { $0.strategy == forced }) else {
                throw ConversionError.strategyUnavailable(forced)
            }
            chosenIndex = i
        } else {
            chosenIndex = 0
        }
        let chosen = decision.candidates[chosenIndex]
        guard let strategy = Self.strategies.first(where: { $0.id == chosen.strategy }) else {
            throw ConversionError.strategyUnavailable(chosen.strategy)
        }
        var recipe = options.recipe
        recipe.strategy = strategy.id
        let plan = strategy.plan(doc, chosen.profile, recipe)
        let legibility = options.recipe.legibility
        let candidates = decision.candidates.map { CandidateSummary($0, legibility: legibility) }
        return PlanResult(analysis: doc, candidates: candidates, chosenIndex: chosenIndex, mode: options.mode, plan: plan)
    }

    public func convert(input: URL, output: URL, options: ConversionOptions) async throws -> ConversionReport {
        let planned = try await plan(input: input, options: options)
        let source = SourceDocument(url: input, password: options.password)
        let write = try await BoxWriter().write(planned.plan, source: source, to: output, options: options.writeOptions)
        let validation: ValidationReport? = options.validate
            ? try await validator.validate(analysis: planned.analysis, plan: planned.plan, source: source, output: output)
            : nil
        return ConversionReport(input: input.path, output: output.path, analysis: AnalysisSummary(planned.analysis),
                                candidates: planned.candidates, chosenIndex: planned.chosenIndex, mode: options.mode,
                                plan: planned.plan, write: write, validation: validation)
    }
}
