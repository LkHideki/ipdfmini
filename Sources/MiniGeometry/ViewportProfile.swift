import CoreGraphics

public enum PageTurn: String, Codable, Sendable {
    case horizontal, verticalContinuous
}

/// Área útil real de um leitor no mini. PLAN.md §3.
///
/// Todos os tamanhos estão em pontos PDF físicos: uma página de saída com
/// `sizePt` aberta nesse leitor aparece em escala 1:1.
public struct ViewportProfile: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var sizePt: CGSize
    public var cornerRadiusPt: CGFloat
    public var viewingDistanceMM: Double
    public var pageTurn: PageTurn
    public var honorsCropBox: Bool

    public init(id: String, sizePt: CGSize, cornerRadiusPt: CGFloat = MiniDevice.cornerRadiusPt,
                viewingDistanceMM: Double = 350, pageTurn: PageTurn = .horizontal, honorsCropBox: Bool = true) {
        self.id = id
        self.sizePt = sizePt
        self.cornerRadiusPt = cornerRadiusPt
        self.viewingDistanceMM = viewingDistanceMM
        self.pageTurn = pageTurn
        self.honorsCropBox = honorsCropBox
    }

    public var orientation: Orientation { sizePt.width <= sizePt.height ? .portrait : .landscape }
    /// Razão altura/largura.
    public var aspect: CGFloat { sizePt.height / sizePt.width }

    /// Mesmo perfil girado 90°.
    public var rotated: ViewportProfile {
        var p = self
        p.sizePt = CGSize(width: sizePt.height, height: sizePt.width)
        p.id = id.replacingOccurrences(of: orientation.rawValue, with: orientation == .portrait ? "landscape" : "portrait")
        return p
    }

    public static let fullscreenPortrait = ViewportProfile(id: "fullscreen.portrait", sizePt: MiniPage.fullPortrait)
    public static let fullscreenLandscape = ViewportProfile(id: "fullscreen.landscape", sizePt: MiniPage.fullLandscape)
    /// *Hipótese*: insets de 24 pt (topo) e 20 pt (base) UIKit. Spike S4.
    public static let safeAreaPortrait = ViewportProfile(
        id: "safearea.portrait",
        sizePt: CGSize(width: MiniPage.fullPortrait.width,
                       height: MiniPage.fullPortrait.height - 44 * MiniDevice.pdfPointsPerUIKitPoint))
    /// Alvo do MVP (Books, PDF, barras ocultas). Até a calibração (S4), assume tela cheia.
    public static let booksPortrait = ViewportProfile(id: "books.portrait.fullscreen", sizePt: MiniPage.fullPortrait)
    public static let booksLandscape = ViewportProfile(id: "books.landscape.fullscreen", sizePt: MiniPage.fullLandscape)

    public static let builtIn: [ViewportProfile] = [
        .booksPortrait, .booksLandscape, .fullscreenPortrait, .fullscreenLandscape, .safeAreaPortrait,
    ]

    public static func named(_ id: String) -> ViewportProfile? { builtIn.first { $0.id == id } }

    /// Perfil a partir das leituras do PDF de calibração: quantos pontos de
    /// cada borda ficam escondidos no leitor real.
    public static func calibrated(id: String, hiddenTop: CGFloat, hiddenBottom: CGFloat,
                                  hiddenLeft: CGFloat, hiddenRight: CGFloat,
                                  orientation: Orientation = .portrait) -> ViewportProfile {
        let full = MiniPage.full(orientation)
        return ViewportProfile(id: id, sizePt: CGSize(width: full.width - hiddenLeft - hiddenRight,
                                                      height: full.height - hiddenTop - hiddenBottom))
    }
}

public extension CGRect {
    /// Quadrados de canto de lado `r` dentro do retângulo, que devem ficar sem tinta.
    func cornerSquares(radius r: CGFloat) -> [CGRect] {
        guard r > 0 else { return [] }
        return [
            CGRect(x: minX, y: minY, width: r, height: r),
            CGRect(x: maxX - r, y: minY, width: r, height: r),
            CGRect(x: minX, y: maxY - r, width: r, height: r),
            CGRect(x: maxX - r, y: maxY - r, width: r, height: r),
        ]
    }
}
