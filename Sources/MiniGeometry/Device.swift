import CoreGraphics

/// Constantes físicas do iPad mini 7 (A17 Pro).
///
/// Tudo no app deriva daqui: a área ativa da tela expressa em pontos PDF
/// (1/72 in) é o tamanho de página que aparece em escala física 1:1.
public enum MiniDevice {
    public static let activeAreaMM = CGSize(width: 115.94, height: 176.55)   // retrato
    public static let pixels = CGSize(width: 1488, height: 2266)              // retrato
    public static let ppi: CGFloat = 326
    /// Pontos UIKit (@2x) em retrato.
    public static let uikitPoints = CGSize(width: 744, height: 1133)
    /// Pixels do painel por ponto PDF (326 / 72).
    public static let pixelsPerPDFPoint: CGFloat = ppi / 72
    /// 1 pt UIKit em pontos PDF (328,64 / 744).
    public static let pdfPointsPerUIKitPoint: CGFloat = MiniPage.fullPortrait.width / uikitPoints.width
    /// Raio dos cantos do painel em pontos PDF. *Hipótese* (≈ 21,5 pt UIKit); spike S4.
    public static let cornerRadiusPt: CGFloat = 9.5
}

public enum Orientation: String, Codable, Sendable, CaseIterable {
    case portrait, landscape
}

/// Tamanhos canônicos de página de saída.
public enum MiniPage {
    public static let fullPortrait = CGSize(width: 328.64, height: 500.47)
    public static let fullLandscape = CGSize(width: 500.47, height: 328.64)
    /// Razão altura/largura em retrato (≈ 1,5229).
    public static let aspect: CGFloat = fullPortrait.height / fullPortrait.width

    public static func full(_ o: Orientation) -> CGSize {
        o == .portrait ? fullPortrait : fullLandscape
    }
}

public enum Units {
    public static let mmPerInch: CGFloat = 25.4
    public static let ptPerInch: CGFloat = 72

    public static func mmToPt(_ mm: CGFloat) -> CGFloat { mm / mmPerInch * ptPerInch }
    public static func ptToMM(_ pt: CGFloat) -> CGFloat { pt / ptPerInch * mmPerInch }
}
