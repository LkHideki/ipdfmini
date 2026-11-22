import Testing
import CoreGraphics
@testable import MiniGeometry

@Test func canonicalPageMatchesActiveArea() {
    #expect(abs(Units.mmToPt(MiniDevice.activeAreaMM.width) - MiniPage.fullPortrait.width) < 0.02)
    #expect(abs(Units.mmToPt(MiniDevice.activeAreaMM.height) - MiniPage.fullPortrait.height) < 0.02)
    #expect(abs(MiniPage.aspect - 1.5229) < 0.0005)
    #expect(abs(MiniDevice.pixelsPerPDFPoint - 4.528) < 0.001)
    #expect(abs(MiniDevice.pdfPointsPerUIKitPoint - 0.4417) < 0.0005)
}

@Test func legibilityTableFromPlan() {
    // 7,5 pt ≈ 1,24 mm ≈ 0,20° a 35 cm; 10 pt ≈ 1,66 mm.
    #expect(abs(Legibility.xHeightMM(forPointSize: 7.5) - 1.24) < 0.01)
    #expect(abs(Legibility.xHeightMM(forPointSize: 10) - 1.66) < 0.01)
    #expect(abs(Legibility.standard.visualAngleDegrees(xHeightMM: 1.24) - 0.20) < 0.01)
    #expect(abs(Legibility.pointSizeEquivalent(xHeightMM: 1.66) - 10) < 0.05)
    #expect(Legibility.standard.grade(xHeightMM: 0.91) == .unreadable)
    #expect(Legibility.standard.grade(xHeightMM: 1.30) == .belowTarget)
    #expect(Legibility.standard.grade(xHeightMM: 1.66) == .comfortable)
    #expect(Legibility.standard.grade(xHeightMM: 2.0) == .tooLarge)
}

@Test func fitScaleReferenceTable() {
    // Tabela de referência: escala e corpo por formato de página.
    let v = MiniPage.fullPortrait
    #expect(abs(Fit.scale(content: CGSize(width: 595, height: 842), into: v) - 0.552) < 0.001)
    #expect(abs(Fit.scale(content: CGSize(width: 324, height: 518), into: v) - 0.966) < 0.001)
    // paisagem fatiada (E3): limitada só pela largura
    #expect(abs(MiniPage.fullLandscape.width / 451 - 1.110) < 0.001)
}

@Test(arguments: [0, 90, 180, 270, -90, 450])
func rotationRoundTripAndBoxMapping(rotation: Int) {
    let box = CGRect(x: 30, y: 50, width: 400, height: 600)
    let g = PageGeometry(effectiveBox: box, rotation: rotation)
    #expect(g.toPage(box).equalTo(g.pageBox))
    let p = CGPoint(x: 77.5, y: 321.25)
    let back = g.toUser(g.toPage(p))
    #expect(abs(back.x - p.x) < 1e-9 && abs(back.y - p.y) < 1e-9)
}

@Test func rotation90MovesTopLeftToTopRight() {
    let g = PageGeometry(effectiveBox: CGRect(x: 0, y: 0, width: 100, height: 200), rotation: 90)
    #expect(g.displaySize == CGSize(width: 200, height: 100))
    // canto superior esquerdo do usuário (0, 200) → canto superior direito exibido (200, 100)
    let p = g.toPage(CGPoint(x: 0, y: 200))
    #expect(abs(p.x - 200) < 1e-9 && abs(p.y - 100) < 1e-9)
    let g270 = PageGeometry(effectiveBox: CGRect(x: 0, y: 0, width: 100, height: 200), rotation: 270)
    let q = g270.toPage(CGPoint(x: 0, y: 200))
    #expect(abs(q.x) < 1e-9 && abs(q.y) < 1e-9)
}

@Test func rasterMappingRoundTrip() {
    let m = RasterMapping(pageBox: CGRect(x: 10, y: 20, width: 100, height: 200), pixelsPerPoint: 2)
    #expect(m.width == 200 && m.height == 400)
    let r = m.pageRect(pixelX: 20, y: 40, toX: 60, toY: 100)
    #expect(r == CGRect(x: 20, y: 170, width: 20, height: 30))
    let px = m.pixelRect(r)
    #expect(px.x0 == 20 && px.y0 == 40 && px.x1 == 60 && px.y1 == 100)
}

@Test func calibratedProfile() {
    let p = ViewportProfile.calibrated(id: "x", hiddenTop: 10, hiddenBottom: 8, hiddenLeft: 0, hiddenRight: 0)
    #expect(abs(p.sizePt.height - (MiniPage.fullPortrait.height - 18)) < 1e-9)
    #expect(ViewportProfile.booksPortrait.rotated.sizePt == MiniPage.fullLandscape)
    #expect(CGRect(x: 0, y: 0, width: 100, height: 100).cornerSquares(radius: 10).count == 4)
}
