import CoreGraphics
import Testing
import MiniGeometry
import PDFAnalysis
@testable import LayoutEngine

/// Estratégia de mentira: estimativa fixa por orientação, para exercitar a regra.
struct FakeStrategy: AdaptationStrategy {
    var id: StrategyID
    var body: [Orientation: Double?]
    var screens: [Orientation: Double] = [:]

    init(_ id: StrategyID, portrait: Double?, landscape: Double? = nil,
         screensPortrait: Double = 1, screensLandscape: Double = 1) {
        self.id = id
        body = [.portrait: portrait, .landscape: landscape]
        screens = [.portrait: screensPortrait, .landscape: screensLandscape]
    }

    func estimate(_ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe) -> Estimate {
        Estimate(strategy: id, orientation: profile.orientation, bodyXHeightMM: body[profile.orientation] ?? nil,
                 smallestXHeightMM: nil, screensPerSourcePage: screens[profile.orientation] ?? 1,
                 fidelityCost: id.fidelityCost)
    }

    func plan(_ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe) -> LayoutPlan {
        LayoutPlan(profile: profile, pages: [], recipe: recipe)
    }
}

@Suite struct DecisionEngineTests {
    let doc = Fx.bookDoc(4)
    let recipe = Recipe()   // mínimo 1,25 mm, alvo 1,60 mm
    let both: [ViewportProfile] = [.booksPortrait, .booksLandscape]

    func decide(_ s: [any AdaptationStrategy], profiles: [ViewportProfile] = [.booksPortrait]) -> Decision {
        DecisionEngine(strategies: s, profiles: profiles).decide(doc, recipe: recipe)!
    }

    @Test func lowestCostReachingTarget() {
        let d = decide([FakeStrategy(.passthrough, portrait: 1.3), FakeStrategy(.landscapeSlices, portrait: 1.9),
                        FakeStrategy(.crop, portrait: 1.65)])
        #expect(d.chosen.strategy == .crop)
        #expect(d.tier == .meetsTarget)
        #expect(d.candidates.map(\.strategy) == [.crop, .landscapeSlices, .passthrough])
    }

    @Test func lowestCostReachingMinimumWhenNoneReachesTarget() {
        let d = decide([FakeStrategy(.landscapeSlices, portrait: 1.5), FakeStrategy(.passthrough, portrait: 1.0),
                        FakeStrategy(.crop, portrait: 1.3)])
        #expect(d.chosen.strategy == .crop)
        #expect(d.tier == .meetsMinimum)
    }

    @Test func mostLegibleWithWarningWhenNoneReachesMinimum() {
        let engine = DecisionEngine(strategies: [FakeStrategy(.passthrough, portrait: 0.9),
                                                 FakeStrategy(.landscapeSlices, portrait: 1.2),
                                                 FakeStrategy(.crop, portrait: 1.1)],
                                    profiles: [.booksPortrait])
        let (d, plan) = engine.plan(doc, recipe: recipe)!
        #expect(d.chosen.strategy == .landscapeSlices)
        #expect(d.tier == .belowMinimum)
        #expect(plan.warnings == [.belowMinimumLegibility(xHeightMM: 1.2)])
        #expect(plan.recipe.strategy == .landscapeSlices)
    }

    @Test func tieBrokenByFewerScreens() {
        // Mesmo custo, ambos ≥ alvo: vence quem usa menos telas por página.
        let s = FakeStrategy(.crop, portrait: 1.7, landscape: 1.8, screensPortrait: 1.4, screensLandscape: 1)
        let d = decide([s], profiles: both)
        #expect(d.chosen.estimate.orientation == .landscape)
        // Abaixo do mínimo com legibilidade igual: também menos telas.
        let t = FakeStrategy(.portraitSlices, portrait: 1.0, landscape: 1.0, screensPortrait: 1, screensLandscape: 2.5)
        #expect(decide([t], profiles: both).chosen.estimate.orientation == .portrait)
    }

    @Test func unknownLegibilityRanksLast() {
        let d = decide([FakeStrategy(.passthrough, portrait: nil), FakeStrategy(.crop, portrait: 1.0)])
        #expect(d.chosen.strategy == .crop)
        #expect(d.candidates.last?.estimate.bodyXHeightMM == nil)
    }

    @Test func emptyEngineReturnsNil() {
        #expect(DecisionEngine(strategies: [], profiles: both).decide(doc, recipe: recipe) == nil)
    }

    /// Livro 6×9 com corpo de 11 pt: E1 em retrato passa do alvo; E0 só do mínimo.
    @Test func realStrategiesBookChoosesCrop() {
        let book = Fx.bookDoc(body: 11 * 0.47)
        let engine = DecisionEngine(profiles: both)
        let (d, plan) = engine.plan(book, recipe: recipe)!
        #expect(d.chosen.strategy == .crop)
        #expect(d.chosen.estimate.orientation == .portrait)
        #expect(d.tier == .meetsTarget)
        #expect(d.candidates.count == 4)
        #expect(plan.recipe.strategy == .crop)
        #expect(plan.pages.count == book.pages.count)
        #expect(!plan.warnings.contains { if case .belowMinimumLegibility = $0 { true } else { false } })
    }

    /// Livro 6×9 com corpo de 10 pt: nenhum atinge o alvo; E0 e E1 empatam em
    /// fidelidade (só margem vazia sai), então vence o mais legível, E1.
    @Test func realStrategiesBook10ptPrefersCropOverPassthrough() {
        let book = Fx.bookDoc(body: 10 * 0.47)
        let (d, _) = DecisionEngine(profiles: [.booksPortrait]).plan(book, recipe: recipe)!
        #expect(d.chosen.strategy == .crop)
        #expect(d.tier == .meetsMinimum)
        #expect(d.candidates.last?.strategy == .passthrough)
    }

    /// A4 com margens de 1 in a 10 pt (7,2 pt sem respiro): nada atinge o mínimo,
    /// vence E1 em retrato e o plano leva o aviso, uma vez só.
    @Test func realStrategiesA4BelowMinimum() {
        let a4 = Fx.doc((0..<4).map { Fx.page($0, size: Fx.a4, ink: CGRect(x: 72, y: 72, width: 451, height: 698)) })
        let (d, plan) = DecisionEngine(profiles: both).plan(a4, recipe: recipe)!
        #expect(d.chosen.strategy == .crop)
        #expect(d.chosen.estimate.orientation == .portrait)
        #expect(d.tier == .belowMinimum)
        let below = plan.warnings.compactMap { if case .belowMinimumLegibility(let mm) = $0 { mm } else { nil } }
        #expect(below.count == 1)
        #expect(abs(below[0] - d.chosen.estimate.bodyXHeightMM!) < 1e-12)
        #expect(below[0] < recipe.legibility.minimumMM)
    }
}

@Suite struct PassthroughStrategyTests {
    let profile = ViewportProfile.booksPortrait

    @Test func a4WholePageMatchesTable23() {
        let doc = Fx.doc((0..<2).map { Fx.page($0, size: Fx.a4, origin: CGPoint(x: 10, y: 20),
                                                ink: CGRect(x: 82, y: 92, width: 451, height: 698)) })
        let plan = PassthroughStrategy().plan(doc, profile, Recipe(strategy: .passthrough))
        for (p, page) in zip(plan.placements, doc.pages) {
            let w = p.sourceRect
            #expect(w.containsApprox(page.pageBox))
            #expect(abs((w.height / w.width) / profile.aspect - 1) < 0.001)
            #expect(abs(w.midX - page.pageBox.midX) < 1e-9 && abs(w.midY - page.pageBox.midY) < 1e-9)
            // A4 inteiro: 0,552 (corpo de 10 pt → 5,5 pt).
            #expect(abs(p.scale - 0.5523) < 0.0005)
            #expect(abs(w.width - page.pageBox.width) < 1e-9)   // limitada pela largura
        }
        let est = PassthroughStrategy().estimate(doc, profile, Recipe())
        #expect(est.fidelityCost == 0)
        #expect(abs(est.bodyXHeightMM! - Double(Units.ptToMM(4.7 * 0.55225))) < 0.002)
        #expect(plan.warnings.contains { if case .belowMinimumLegibility = $0 { true } else { false } })
    }
}
