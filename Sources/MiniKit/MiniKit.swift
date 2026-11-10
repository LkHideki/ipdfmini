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
    /// Motor de decisão (§8) entre E0, E1 (E2 com a opção), E3, E4 e E5, no perfil e no perfil girado.
    case auto
    /// Força E1.
    case crop
    /// Força E0.
    case passthrough
    /// Força E2 (recorte sem cabeçalho/rodapé), mesmo com `removeHeaderFooter` desligado.
    case aggressiveCrop = "aggressive"
    /// Força E3 (fatias em paisagem; usa o perfil girado se o escolhido for retrato).
    case landscapeSlices
    /// Força E4 (fatias em retrato; usa o perfil girado se o escolhido for paisagem).
    case portraitSlices
    /// Força E5 (colunas).
    case columns

    /// Modos que forçam uma estratégia de fatias ou colunas (uma página vira várias telas).
    public var splitsPages: Bool { forcedStrategy.map(StrategyID.splitsPages) ?? false }

    var forcedStrategy: StrategyID? {
        switch self {
        case .auto: nil
        case .crop: .crop
        case .passthrough: .passthrough
        case .aggressiveCrop: .aggressiveCrop
        case .landscapeSlices: .landscapeSlices
        case .portraitSlices: .portraitSlices
        case .columns: .columns
        }
    }
}

/// Escritor que grava cada estratégia. PLAN.md §9.1.
public extension StrategyID {
    /// E3 em diante distribui uma página de origem por várias telas; E0–E2 mantêm a página inteira.
    static func splitsPages(_ s: StrategyID) -> Bool { s.fidelityCost > StrategyID.aggressiveCrop.fidelityCost }
}

public enum WriterKind: String, Codable, Sendable {
    /// `BoxWriter` (PDFKit, caixas em lugar): E0–E2.
    case box
    /// `PlacementWriter` (qpdf, colocações com clip): E3 em diante.
    case placement

    public init(strategy: StrategyID) {
        self = strategy.fidelityCost <= StrategyID.aggressiveCrop.fidelityCost ? .box : .placement
    }
}

public struct ConversionOptions: Sendable, Equatable {
    public var profile: ViewportProfile
    public var mode: ConversionMode
    /// Respiro, classes, legibilidade. `recipe.strategy` é ignorado: quem decide é `mode`.
    public var recipe: Recipe
    /// Senha de usuário do PDF de origem.
    public var password: String?
    /// Permite ao modo auto remover cabeçalho, rodapé e número de página (E2).
    /// Desligado por padrão: confundir nota de rodapé com rodapé apaga conteúdo (§18, R5).
    public var removeHeaderFooter: Bool
    /// Deixa E3, E4 e E5 entrarem na disputa (e na tabela de candidatos). Desligado por
    /// padrão: dividir a página manda parte dela para outra tela, e a regra é 1 → 1.
    public var allowSplitting: Bool
    public var writeOptions: WriteOptions
    public var validate: Bool

    public init(profile: ViewportProfile = .booksPortrait, mode: ConversionMode = .auto, recipe: Recipe = Recipe(),
                password: String? = nil, removeHeaderFooter: Bool = false, allowSplitting: Bool = false,
                writeOptions: WriteOptions = WriteOptions(), validate: Bool = true) {
        self.profile = profile
        self.mode = mode
        self.recipe = recipe
        self.password = password
        self.removeHeaderFooter = removeHeaderFooter
        self.allowSplitting = allowSplitting
        self.writeOptions = writeOptions
        self.validate = validate
    }

    /// Divisão efetiva: forçar fatias ou colunas é pedir a divisão explicitamente.
    public var splittingAllowed: Bool { allowSplitting || mode.splitsPages }
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

    /// E0 e E1 sempre; E2 só com a remoção pedida (opção ou modo forçado); E3, E4 e E5
    /// só com a divisão permitida (fora dela nem viram candidatos).
    static func strategies(_ o: ConversionOptions) -> [any AdaptationStrategy] {
        var s: [any AdaptationStrategy] = [PassthroughStrategy(), CropStrategy()]
        if o.removeHeaderFooter || o.mode == .aggressiveCrop { s.append(AggressiveCropStrategy()) }
        if o.splittingAllowed { s += [LandscapeSlicesStrategy(), PortraitSlicesStrategy(), ColumnsStrategy()] }
        return s
    }

    /// Perfil escolhido e o girado (§8: estratégia × orientação).
    static func profiles(_ o: ConversionOptions) -> [ViewportProfile] { [o.profile, o.profile.rotated] }

    /// E3 só existe em paisagem e E4 só em retrato: a estimativa na outra orientação
    /// é um marcador de inaplicável (sem corpo) e só poluiria a tabela de candidatos.
    static func applicable(_ c: Candidate) -> Bool {
        switch c.strategy {
        case .landscapeSlices: c.profile.orientation == .landscape
        case .portraitSlices: c.profile.orientation == .portrait
        default: true
        }
    }

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
        let strategies = Self.strategies(options)
        // Remoção pedida: tirar cabeçalho/rodapé não conta como perda de fidelidade,
        // E2 empata com E1 e vence quando rende corpo maior.
        let overrides: [StrategyID: Int] = options.removeHeaderFooter ? [.aggressiveCrop: StrategyID.crop.fidelityCost] : [:]
        let engine = DecisionEngine(strategies: strategies, profiles: Self.profiles(options), costOverrides: overrides)
        guard let decision = engine.decide(doc, recipe: options.recipe) else { throw ConversionError.noCandidate }
        // Filtrar preserva a ordem da regra.
        let ranked = decision.candidates.filter(Self.applicable)
        guard !ranked.isEmpty else { throw ConversionError.noCandidate }
        let chosenIndex: Int
        if let forced = options.mode.forcedStrategy {
            // Forçado: no perfil pedido quando a estratégia se aplica a ele (o usuário
            // escolheu a orientação); senão no girado (E3 com perfil retrato).
            guard let i = ranked.firstIndex(where: { $0.strategy == forced && $0.profile == options.profile })
                    ?? ranked.firstIndex(where: { $0.strategy == forced }) else {
                throw ConversionError.strategyUnavailable(forced)
            }
            chosenIndex = i
        } else {
            // A orientação faz parte do perfil escolhido (§3): só gira quando nada na
            // orientação pedida chega ao mínimo. Sem isso um livro 6×9 ia para fatias
            // em paisagem (2,6 telas por página) em vez do recorte em retrato.
            let legibility = options.recipe.legibility
            chosenIndex = ranked.firstIndex {
                $0.profile == options.profile
                    && LegibilityTier($0.estimate.bodyXHeightMM, legibility) <= .meetsMinimum
            } ?? 0
        }
        let chosen = ranked[chosenIndex]
        guard let strategy = strategies.first(where: { $0.id == chosen.strategy }) else {
            throw ConversionError.strategyUnavailable(chosen.strategy)
        }
        var recipe = options.recipe
        recipe.strategy = strategy.id
        let plan = strategy.plan(doc, chosen.profile, recipe)
        let legibility = options.recipe.legibility
        let candidates = ranked.map { CandidateSummary($0, legibility: legibility) }
        return PlanResult(analysis: doc, candidates: candidates, chosenIndex: chosenIndex, mode: options.mode, plan: plan,
                          allowSplitting: options.splittingAllowed)
    }

    public func convert(input: URL, output: URL, options: ConversionOptions) async throws -> ConversionReport {
        let planned = try await plan(input: input, options: options)
        let source = SourceDocument(url: input, password: options.password)
        let writer = WriterKind(strategy: planned.plan.recipe.strategy)
        let write = switch writer {
        case .box: try await BoxWriter().write(planned.plan, source: source, to: output, options: options.writeOptions)
        case .placement: try await PlacementWriter().write(planned.plan, source: source, to: output, options: options.writeOptions)
        }
        let validation: ValidationReport? = options.validate
            ? try await validator.validate(analysis: planned.analysis, plan: planned.plan, source: source, output: output,
                                           writer: writer, allowSplitting: options.splittingAllowed)
            : nil
        // Contagem para a interface; falhar aqui não invalida a conversão (o inv. 5 já julga).
        let navigation = try? NavigationSummary.measure(plan: planned.plan, source: source, output: output)
        return ConversionReport(input: input.path, output: output.path, analysis: AnalysisSummary(planned.analysis),
                                candidates: planned.candidates, chosenIndex: planned.chosenIndex, mode: options.mode,
                                plan: planned.plan, write: write, validation: validation, navigation: navigation,
                                allowSplitting: options.splittingAllowed)
    }
}
