import CoreGraphics

/// Conversões de coordenadas, num único lugar.
///
/// Convenção do projeto — **espaço de página** (page space):
/// - coordenadas PDF (y para cima) já com `/Rotate` aplicado;
/// - a caixa efetiva (`CropBox ∩ MediaBox`, ou `TrimBox` quando aplicável)
///   mantém a origem que tem no espaço do usuário; só o tamanho gira;
/// - com rotação 0, espaço de página = espaço do usuário.
///
/// Todo retângulo da análise, do plano e da validação vive nesse espaço.
/// Só o escritor volta ao espaço do usuário (para gravar caixas).
public struct PageGeometry: Codable, Sendable, Equatable {
    /// Caixa efetiva em espaço do usuário (sem rotação).
    public var effectiveBox: CGRect
    /// `/Rotate` normalizado para 0, 90, 180 ou 270 (sentido horário).
    public var rotation: Int

    public init(effectiveBox: CGRect, rotation: Int) {
        self.effectiveBox = effectiveBox.standardized
        self.rotation = PageGeometry.normalize(rotation)
    }

    public static func normalize(_ r: Int) -> Int { ((r % 360) + 360) % 360 / 90 * 90 }

    public var isQuarterTurn: Bool { rotation == 90 || rotation == 270 }

    /// Tamanho exibido (após rotação).
    public var displaySize: CGSize {
        isQuarterTurn ? CGSize(width: effectiveBox.height, height: effectiveBox.width) : effectiveBox.size
    }

    /// Caixa efetiva em espaço de página.
    public var pageBox: CGRect { CGRect(origin: effectiveBox.origin, size: displaySize) }

    /// Espaço do usuário → espaço de página.
    public var userToPage: CGAffineTransform {
        let x0 = effectiveBox.minX, y0 = effectiveBox.minY
        let w = effectiveBox.width, h = effectiveBox.height
        // u = x - x0, v = y - y0; (u', v') na caixa girada; depois soma (x0, y0).
        let (a, b, c, d, tu, tv): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
        switch rotation {
        case 90:  (a, b, c, d, tu, tv) = (0, -1, 1, 0, 0, w)    // u' = v,     v' = w - u
        case 180: (a, b, c, d, tu, tv) = (-1, 0, 0, -1, w, h)   // u' = w - u, v' = h - v
        case 270: (a, b, c, d, tu, tv) = (0, 1, -1, 0, h, 0)    // u' = h - v, v' = u
        default:  return .identity
        }
        return CGAffineTransform(translationX: -x0, y: -y0)
            .concatenating(CGAffineTransform(a: a, b: b, c: c, d: d, tx: tu, ty: tv))
            .concatenating(CGAffineTransform(translationX: x0, y: y0))
    }

    public var pageToUser: CGAffineTransform { userToPage.inverted() }

    public func toPage(_ r: CGRect) -> CGRect { r.applying(userToPage).standardized }
    public func toUser(_ r: CGRect) -> CGRect { r.applying(pageToUser).standardized }
    public func toPage(_ p: CGPoint) -> CGPoint { p.applying(userToPage) }
    public func toUser(_ p: CGPoint) -> CGPoint { p.applying(pageToUser) }
}

/// Mapeamento entre espaço de página e pixels de um raster da caixa de página.
/// Pixels têm origem no canto superior esquerdo (y para baixo).
public struct RasterMapping: Sendable, Equatable {
    public var pageBox: CGRect
    public var pixelsPerPoint: CGFloat

    public init(pageBox: CGRect, pixelsPerPoint: CGFloat) {
        self.pageBox = pageBox
        self.pixelsPerPoint = pixelsPerPoint
    }

    public var width: Int { Int((pageBox.width * pixelsPerPoint).rounded(.up)) }
    public var height: Int { Int((pageBox.height * pixelsPerPoint).rounded(.up)) }

    /// Retângulo em pixels (inteiros, inclusivo-exclusivo) → espaço de página.
    public func pageRect(pixelX x0: Int, y y0: Int, toX x1: Int, toY y1: Int) -> CGRect {
        let s = pixelsPerPoint
        return CGRect(x: pageBox.minX + CGFloat(x0) / s,
                      y: pageBox.maxY - CGFloat(y1) / s,
                      width: CGFloat(x1 - x0) / s,
                      height: CGFloat(y1 - y0) / s)
    }

    /// Espaço de página → retângulo de pixels (arredondado para fora, recortado ao raster).
    public func pixelRect(_ r: CGRect) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        let s = pixelsPerPoint
        let x0 = Int(((r.minX - pageBox.minX) * s).rounded(.down))
        let x1 = Int(((r.maxX - pageBox.minX) * s).rounded(.up))
        let y0 = Int(((pageBox.maxY - r.maxY) * s).rounded(.down))
        let y1 = Int(((pageBox.maxY - r.minY) * s).rounded(.up))
        return (max(0, x0), max(0, y0), min(width, x1), min(height, y1))
    }

    /// Transformação para desenhar a página num `CGContext` de bitmap, a ser
    /// concatenada após o `PageGeometry.userToPage`. CGContext já é y para cima.
    public var pageToContext: CGAffineTransform {
        CGAffineTransform(translationX: -pageBox.minX, y: -pageBox.minY)
            .concatenating(CGAffineTransform(scaleX: pixelsPerPoint, y: pixelsPerPoint))
    }
}

public enum Fit {
    /// Escala que faz `content` caber em `viewport` (limitada pela dimensão que esgota antes).
    public static func scale(content: CGSize, into viewport: CGSize) -> CGFloat {
        guard content.width > 0, content.height > 0 else { return 1 }
        return min(viewport.width / content.width, viewport.height / content.height)
    }
}
