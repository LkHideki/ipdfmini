import CoreGraphics
import MiniGeometry

/// Pré-visualização em tamanho real: pontos de tela por milímetro do monitor.
public enum PhysicalScale {
    /// Corpo e tela do iPad mini 7 em retrato (mm).
    public static let bodyMM = CGSize(width: 134.8, height: 195.4)
    public static let screenMM = MiniDevice.activeAreaMM
    /// Raio dos cantos do corpo. *Hipótese* visual (não há cota publicada); só desenha a moldura.
    public static let bodyCornerMM: CGFloat = 10.5

    /// Pontos por mm a partir de `CGDisplayScreenSize` (mm) e do quadro da tela em pontos.
    ///
    /// `nil` quando o monitor não informa um tamanho crível: projetor e alguns
    /// adaptadores devolvem zero ou um valor genérico, e desenhar "tamanho real"
    /// com isso seria mentir. Exige as duas direções coerentes (≤ 5%) e densidade
    /// entre 1 e 20 pt/mm (25–500 ppp lógicos).
    public static func pointsPerMM(screenSizeMM mm: CGSize, screenFramePoints pts: CGSize) -> CGFloat? {
        guard mm.width >= 50, mm.height >= 30, pts.width > 0, pts.height > 0 else { return nil }
        let h = pts.width / mm.width, v = pts.height / mm.height
        guard abs(h / v - 1) <= 0.05 else { return nil }
        let k = (h + v) / 2
        return (1...20).contains(k) ? k : nil
    }

    /// Tamanho em pontos de tela de um objeto com `mm` milímetros.
    public static func size(mm: CGSize, pointsPerMM k: CGFloat) -> CGSize {
        CGSize(width: mm.width * k, height: mm.height * k)
    }

    /// Escala (pontos de tela por ponto PDF) que desenha uma página de saída em 1:1 físico.
    public static func pointsPerPDFPoint(pointsPerMM k: CGFloat) -> CGFloat { k * Units.mmPerInch / Units.ptPerInch }
}
