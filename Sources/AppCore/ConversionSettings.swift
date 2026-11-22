import CoreGraphics
import Foundation
import LayoutEngine
import MiniGeometry
import MiniKit
import PDFAnalysis

/// Ajustes do inspetor. Os mesmos valores viram `ConversionOptions` (replanejar em
/// processo) e argumentos da CLI (processo filho); os dois caminhos precisam dar o
/// mesmo plano, senão a pré-visualização mente sobre o arquivo exportado.
public struct ConversionSettings: Codable, Sendable, Equatable {
    public var profileID: String
    public var mode: ConversionMode
    public var marginMM: Double
    public var classMode: PageClassMode
    /// Fatias e colunas (E3–E5). Desligado: cada página de origem vira exatamente uma
    /// página de saída, em todo caminho do app (pré-visualização, exportação, lote).
    @DefaultsToFalse public var allowSplitting: Bool

    public init(profileID: String = ViewportProfile.booksPortrait.id, mode: ConversionMode = .auto,
                marginMM: Double = 2, classMode: PageClassMode = .oddEven, allowSplitting: Bool = false) {
        self.profileID = profileID
        self.mode = mode
        self.marginMM = marginMM
        self.classMode = classMode
        self.allowSplitting = allowSplitting
    }

    public var profile: ViewportProfile { ViewportProfile.named(profileID) ?? .booksPortrait }

    /// Modo que de fato vai para o núcleo. Na CLI, forçar fatias implica permitir a
    /// divisão; aqui o interruptor manda, e um modo de fatias sem ele volta ao automático.
    public var effectiveMode: ConversionMode { allowSplitting || !mode.splitsPages ? mode : .auto }

    /// Liga ou desliga a divisão; desligar tira um modo de fatias que tenha ficado escolhido.
    public mutating func setAllowSplitting(_ on: Bool) {
        allowSplitting = on
        if !on, mode.splitsPages { mode = .auto }
    }

    public var options: ConversionOptions {
        var recipe = Recipe()
        recipe.marginMM = marginMM
        recipe.classMode = classMode
        return ConversionOptions(profile: profile, mode: effectiveMode, recipe: recipe, allowSplitting: allowSplitting)
    }

    /// Mesmos nomes de `ConversionArguments` da CLI.
    public var cliArguments: [String] {
        ["--profile", profile.id, "--mode", effectiveMode.rawValue, "--margin-mm", String(marginMM),
         "--class-mode", classMode.rawValue] + (allowSplitting ? ["--allow-split"] : [])
    }

    /// Ajustes que reproduzem um candidato da tabela (clique): força a estratégia e, se o
    /// candidato estiver no perfil girado e ele for embutido, troca o perfil (o modo forçado
    /// prefere o perfil escolhido, então só o modo não bastaria). `nil` se não há modo ou
    /// se o candidato divide páginas sem a divisão permitida.
    public func forcing(_ c: CandidateSummary) -> ConversionSettings? {
        guard let m = Labels.mode(forcing: c.strategy), allowSplitting || !m.splitsPages else { return nil }
        var s = self
        s.mode = m
        if c.profileID != profileID, ViewportProfile.named(c.profileID) != nil { s.profileID = c.profileID }
        return s
    }

    /// Perfil girado 90° entre os embutidos (botão de rotação do modo "Mini").
    public var rotatedProfileID: String? { ViewportProfile.named(profile.rotated.id)?.id }
}

/// Replanejamento em processo a partir da análise decodificada (alvo ≤ 100 ms).
public enum Replanner {
    public struct Outcome: Sendable {
        public var result: PlanResult
        public var millis: Double
    }

    public static func replan(_ analysis: DocumentAnalysis, _ settings: ConversionSettings) throws -> Outcome {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try Converter().plan(analysis: analysis, options: settings.options)
        let d = clock.now - start
        let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        return Outcome(result: result, millis: ms)
    }
}
