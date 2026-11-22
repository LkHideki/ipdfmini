import Foundation
import CoreGraphics

/// Modelo de legibilidade.
///
/// A grandeza medida é a altura-x física em milímetros no vidro. "pt
/// equivalente" é só para a interface: altura-x / 0,47.
public struct Legibility: Codable, Sendable, Equatable {
    public var minimumMM: Double
    public var targetMM: Double
    public var maximumMM: Double
    public var viewingDistanceMM: Double

    public init(minimumMM: Double = 1.25, targetMM: Double = 1.60, maximumMM: Double = 1.90, viewingDistanceMM: Double = 350) {
        self.minimumMM = minimumMM
        self.targetMM = targetMM
        self.maximumMM = maximumMM
        self.viewingDistanceMM = viewingDistanceMM
    }

    public static let standard = Legibility()
    /// Perfil "letra grande" (≈ 14 pt equivalente).
    public static let largePrint = Legibility(minimumMM: 2.0, targetMM: 2.32, maximumMM: 2.8)

    /// Razão altura-x / corpo típica de fontes de texto.
    public static let xHeightRatio: Double = 0.47

    public static func xHeightMM(fromXHeightPt pt: Double) -> Double { Double(Units.ptToMM(CGFloat(pt))) }
    public static func xHeightPt(fromMM mm: Double) -> Double { Double(Units.mmToPt(CGFloat(mm))) }
    /// Corpo equivalente (pt) a partir da altura-x física (mm).
    public static func pointSizeEquivalent(xHeightMM mm: Double) -> Double { xHeightPt(fromMM: mm) / xHeightRatio }
    /// Altura-x física (mm) de um corpo nominal (pt) usando a razão típica.
    public static func xHeightMM(forPointSize pt: Double) -> Double { xHeightMM(fromXHeightPt: pt * xHeightRatio) }

    /// Ângulo visual (graus) de uma altura física à distância de leitura.
    public func visualAngleDegrees(xHeightMM mm: Double) -> Double {
        2 * atan(mm / (2 * viewingDistanceMM)) * 180 / .pi
    }

    public enum Grade: String, Codable, Sendable, Comparable {
        case unreadable, belowTarget, comfortable, tooLarge
        private var rank: Int { [.unreadable: 0, .belowTarget: 1, .comfortable: 2, .tooLarge: 3][self]! }
        public static func < (a: Grade, b: Grade) -> Bool { a.rank < b.rank }
    }

    public func grade(xHeightMM mm: Double) -> Grade {
        if mm < minimumMM { return .unreadable }
        if mm < targetMM { return .belowTarget }
        if mm <= maximumMM { return .comfortable }
        return .tooLarge
    }

    /// Altura-x final no vidro (mm) de um texto com altura-x `sourceXHeightPt`
    /// desenhado com fator `scale` numa página de saída aberta em escala 1:1.
    public static func finalXHeightMM(sourceXHeightPt: Double, scale: Double) -> Double {
        xHeightMM(fromXHeightPt: sourceXHeightPt * scale)
    }
}
