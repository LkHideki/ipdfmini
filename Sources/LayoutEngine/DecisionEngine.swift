import CoreGraphics
import MiniGeometry
import PDFAnalysis

// Motor de decisão. PLAN.md §8.

/// Um candidato = estratégia × perfil (orientação), com a estimativa barata.
public struct Candidate: Sendable, Equatable {
    public var profile: ViewportProfile
    public var estimate: Estimate
    public var strategy: StrategyID { estimate.strategy }

    public init(profile: ViewportProfile, estimate: Estimate) {
        self.profile = profile
        self.estimate = estimate
    }
}

/// Faixa de legibilidade do corpo, na ordem de preferência da regra.
public enum LegibilityTier: Int, Sendable, Comparable {
    case meetsTarget, meetsMinimum, belowMinimum

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Sem altura-x conhecida conta como abaixo do mínimo.
    public init(_ bodyXHeightMM: Double?, _ legibility: Legibility) {
        guard let mm = bodyXHeightMM else { self = .belowMinimum; return }
        if mm >= legibility.targetMM { self = .meetsTarget }
        else if mm >= legibility.minimumMM { self = .meetsMinimum }
        else { self = .belowMinimum }
    }
}

public struct Decision: Sendable, Equatable {
    /// Ordenados pela regra; o primeiro é o escolhido.
    public var candidates: [Candidate]
    public var tier: LegibilityTier
    public var chosen: Candidate { candidates[0] }
}

public struct DecisionEngine: Sendable {
    public var strategies: [any AdaptationStrategy]
    public var profiles: [ViewportProfile]

    public init(strategies: [any AdaptationStrategy] = [PassthroughStrategy(), CropStrategy()],
                profiles: [ViewportProfile] = [.booksPortrait]) {
        self.strategies = strategies
        self.profiles = profiles
    }

    /// `nil` se não houver estratégia ou perfil.
    public func decide(_ doc: DocumentAnalysis, recipe: Recipe) -> Decision? {
        var all: [Candidate] = []
        for s in strategies {
            for p in profiles {
                var r = recipe
                r.strategy = s.id
                all.append(Candidate(profile: p, estimate: s.estimate(doc, p, r)))
            }
        }
        let ranked = Self.rank(all, legibility: recipe.legibility)
        guard let first = ranked.first else { return nil }
        return Decision(candidates: ranked, tier: LegibilityTier(first.estimate.bodyXHeightMM, recipe.legibility))
    }

    /// Decide e gera o plano só do escolhido.
    public func plan(_ doc: DocumentAnalysis, recipe: Recipe) -> (decision: Decision, plan: LayoutPlan)? {
        guard let d = decide(doc, recipe: recipe),
              let s = strategies.first(where: { $0.id == d.chosen.strategy }) else { return nil }
        var r = recipe
        r.strategy = s.id
        var plan = s.plan(doc, d.chosen.profile, r)
        // Estratégias de fora podem não emitir o aviso; garante sem duplicar.
        if d.tier == .belowMinimum, let mm = d.chosen.estimate.bodyXHeightMM,
           !plan.warnings.contains(where: { if case .belowMinimumLegibility = $0 { true } else { false } }) {
            plan.warnings.append(.belowMinimumLegibility(xHeightMM: mm))
        }
        return (d, plan)
    }

    /// Custo usado na regra. E0 e E1 só diferem por margem vazia (o recorte nunca
    /// corta tinta), então empatam; sem isso um livro 6×9 a 10 pt ficaria no E0 a
    /// 7,6 pt equivalentes, com o E1 a 9,4 pt disponível.
    static func rankCost(_ e: Estimate) -> Int { max(e.fidelityCost, StrategyID.crop.fidelityCost) }

    /// Regra §8: menor custo de fidelidade com corpo ≥ alvo; senão menor custo com
    /// corpo ≥ mínimo; senão maior legibilidade. Empate: menos telas por página.
    public static func rank(_ candidates: [Candidate], legibility: Legibility) -> [Candidate] {
        let keyed = candidates.enumerated().map { (i, c) in
            (i: i, c: c, tier: LegibilityTier(c.estimate.bodyXHeightMM, legibility))
        }
        return keyed.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            let ea = a.c.estimate, eb = b.c.estimate
            let bodyA = ea.bodyXHeightMM ?? -.infinity, bodyB = eb.bodyXHeightMM ?? -.infinity
            if a.tier == .belowMinimum {
                if bodyA != bodyB { return bodyA > bodyB }
                if ea.screensPerSourcePage != eb.screensPerSourcePage { return ea.screensPerSourcePage < eb.screensPerSourcePage }
                if rankCost(ea) != rankCost(eb) { return rankCost(ea) < rankCost(eb) }
            } else {
                if rankCost(ea) != rankCost(eb) { return rankCost(ea) < rankCost(eb) }
                if ea.screensPerSourcePage != eb.screensPerSourcePage { return ea.screensPerSourcePage < eb.screensPerSourcePage }
                if bodyA != bodyB { return bodyA > bodyB }
            }
            return a.i < b.i
        }.map(\.c)
    }
}
