import Foundation
import LayoutEngine
import PDFAnalysis

/// JSON de `plan --json --full`: análise completa + candidatos + plano.
///
/// O app recebe isto do processo filho (§14.2) e replaneja em processo a cada
/// ajuste sem reanalisar (§16); por isso a análise vai inteira, não resumida.
public struct FullPlanReport: Codable, Sendable, Equatable {
    public var analysis: DocumentAnalysis
    public var candidates: [CandidateSummary]
    public var chosenIndex: Int
    public var mode: ConversionMode
    public var plan: LayoutPlan
    /// Itens do sumário da origem; `nil` em JSON de versões anteriores.
    public var sourceOutlineItems: Int? = nil

    public init(_ r: PlanResult, sourceOutlineItems: Int? = nil) {
        self.sourceOutlineItems = sourceOutlineItems
        analysis = r.analysis
        candidates = r.candidates
        chosenIndex = r.chosenIndex
        mode = r.mode
        plan = r.plan
    }

    /// Volta ao tipo da fachada (o init memberwise de `PlanResult` é interno).
    public var planResult: PlanResult {
        PlanResult(analysis: analysis, candidates: candidates, chosenIndex: chosenIndex, mode: mode, plan: plan)
    }
}
