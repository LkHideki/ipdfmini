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

    public init(profileID: String = ViewportProfile.booksPortrait.id, mode: ConversionMode = .auto,
                marginMM: Double = 2, classMode: PageClassMode = .oddEven) {
        self.profileID = profileID
        self.mode = mode
        self.marginMM = marginMM
        self.classMode = classMode
    }

    public var profile: ViewportProfile { ViewportProfile.named(profileID) ?? .booksPortrait }

    public var options: ConversionOptions {
        var recipe = Recipe()
        recipe.marginMM = marginMM
        recipe.classMode = classMode
        return ConversionOptions(profile: profile, mode: mode, recipe: recipe)
    }

    /// Mesmos nomes de `ConversionArguments` da CLI.
    public var cliArguments: [String] {
        ["--profile", profile.id, "--mode", mode.rawValue, "--margin-mm", String(marginMM),
         "--class-mode", classMode.rawValue]
    }

    /// Perfil girado 90° entre os embutidos (botão de rotação do modo "Mini").
    public var rotatedProfileID: String? { ViewportProfile.named(profile.rotated.id)?.id }
}

/// Replanejamento em processo a partir da análise decodificada (§16: alvo ≤ 100 ms).
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
