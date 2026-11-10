import AppCore
import AppKit
import CoreGraphics
import MiniGeometry
import SwiftUI

struct PreviewView: View {
    @Environment(ViewState.self) private var view
    @Environment(\.displayScale) private var displayScale
    let item: DocumentItem
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                switch view.mode {
                case .source: sourcePreview(geo.size)
                case .mini: miniPreview(geo.size)
                }
            }
        }
        .overlay(alignment: .bottom) { controls.padding(.bottom, 14) }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true; view.pointsPerMM = Self.screenPointsPerMM() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { _ in
            view.pointsPerMM = Self.screenPointsPerMM()
        }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onTapGesture { focused = true }
    }

    private func step(_ d: Int) {
        item.currentPage = max(0, min(item.pageCount - 1, item.currentPage + d))
    }

    /// Escala quantizada: redimensionar a janela não pode re-renderizar a cada pixel.
    private func quantized(_ ppp: CGFloat) -> CGFloat { max(0.25, (ppp * 4).rounded(.up) / 4) }

    // MARK: - Origem

    @ViewBuilder private func sourcePreview(_ size: CGSize) -> some View {
        if let plan = item.planned?.plan, plan.pages.indices.contains(item.currentPage),
           let src = plan.pages[item.currentPage].placements.first?.sourcePage,
           let canvas = PlanRenderer.sourceCanvas(src, plan: plan, analysis: item.planned!.analysis) {
            let avail = CGSize(width: size.width - 48, height: size.height - 120)
            let fit = max(0.05, min(avail.width / canvas.width, avail.height / canvas.height))
            let shown = CGSize(width: canvas.width * fit, height: canvas.height * fit)
            VStack(spacing: 10) {
                if let r = item.sourceImage(forOutput: item.currentPage, ppp: quantized(fit * displayScale)) {
                    Image(decorative: r.image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: shown.width, height: shown.height)
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                        .accessibilityLabel("Página de origem \(r.source + 1) com a janela de recorte da página de saída \(item.currentPage + 1)")
                }
                legend
            }
            .padding(.bottom, 56)
        } else {
            Text("Sem página para mostrar").foregroundStyle(.secondary)
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem(Color(cgColor: PlanRenderer.windowColor), "Janela de recorte", system: "viewfinder")
            legendItem(.gray, "Margem removida", system: "line.diagonal")
            if item.planned?.plan.recipe.strategy == .aggressiveCrop {
                legendItem(Color(cgColor: PlanRenderer.removedColor), "Cabeçalho/rodapé removido", system: "line.diagonal")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ color: Color, _ text: String, system: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: system).foregroundStyle(color) }
    }

    // MARK: - Mini

    @ViewBuilder private func miniPreview(_ size: CGSize) -> some View {
        if let plan = item.planned?.plan, plan.pages.indices.contains(item.currentPage) {
            let profile = plan.profile
            let landscape = profile.orientation == .landscape
            let bodyMM = landscape ? CGSize(width: PhysicalScale.bodyMM.height, height: PhysicalScale.bodyMM.width) : PhysicalScale.bodyMM
            let avail = CGSize(width: size.width - 60, height: size.height - 110)
            let fitK = max(0.5, min(avail.width / bodyMM.width, avail.height / bodyMM.height))
            let real = view.realSize ? view.pointsPerMM : nil
            let k = real ?? fitK
            let frame = DeviceFrame(item: item, k: k, landscape: landscape, page: item.currentPage, displayScale: displayScale)
            VStack(spacing: 6) {
                if real != nil {
                    ScrollView([.horizontal, .vertical]) {
                        frame.padding(30)
                    }
                    .scrollIndicators(.visible)
                } else {
                    frame
                }
                Text(caption(real: real != nil))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 56)
        }
    }

    private func caption(real: Bool) -> String {
        if real { return "Tamanho real: tela de 115,94 × 176,55 mm desenhada em escala 1:1 neste monitor" }
        if view.realSize { return "Tamanho real indisponível: o monitor não informa as dimensões físicas" }
        return "Ajustado à janela"
    }

    // MARK: - Controles flutuantes

    private var controls: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 28, height: 24) }
                        .disabled(item.currentPage == 0)
                        .accessibilityLabel("Página anterior")
                    Text("\(item.pageCount == 0 ? 0 : item.currentPage + 1) de \(item.pageCount)")
                        .monospacedDigit()
                        .frame(minWidth: 72)
                        .accessibilityLabel("Página \(item.currentPage + 1) de \(item.pageCount)")
                    Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 28, height: 24) }
                        .disabled(item.currentPage >= item.pageCount - 1)
                        .accessibilityLabel("Próxima página")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(.regular.interactive(), in: Capsule())

                if view.mode == .mini {
                    HStack(spacing: 4) {
                        Button {
                            if let id = item.settings.rotatedProfileID { item.settings.profileID = id }
                        } label: {
                            Image(systemName: item.settings.profile.orientation == .portrait ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
                                .frame(width: 28, height: 24)
                        }
                        .disabled(item.settings.rotatedProfileID == nil)
                        .help("Girar o iPad (troca o perfil para retrato/paisagem)")
                        .accessibilityLabel("Girar para \(item.settings.profile.orientation == .portrait ? "paisagem" : "retrato")")
                        @Bindable var view = view
                        Toggle(isOn: $view.realSize) {
                            Label("Tamanho real", systemImage: "ruler")
                        }
                        .toggleStyle(.button)
                        .disabled(view.pointsPerMM == nil)
                        .help(view.pointsPerMM == nil ? "O monitor não informa o tamanho físico" : "Desenhar o iPad mini em escala 1:1 neste monitor")
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
            }
        }
    }

    /// pt/mm do monitor da janela, via `CGDisplayScreenSize` (§12.1).
    @MainActor static func screenPointsPerMM() -> CGFloat? {
        guard let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main,
              let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let mm = CGDisplayScreenSize(CGDirectDisplayID(n.uint32Value))
        return PhysicalScale.pointsPerMM(screenSizeMM: mm, screenFramePoints: screen.frame.size)
    }
}

/// Moldura do iPad mini 7 com a página de saída na tela, a `k` pontos por mm.
struct DeviceFrame: View {
    let item: DocumentItem
    let k: CGFloat
    let landscape: Bool
    let page: Int
    let displayScale: CGFloat

    var body: some View {
        let bodyMM = landscape ? CGSize(width: PhysicalScale.bodyMM.height, height: PhysicalScale.bodyMM.width) : PhysicalScale.bodyMM
        let screenMM = landscape ? CGSize(width: PhysicalScale.screenMM.height, height: PhysicalScale.screenMM.width) : PhysicalScale.screenMM
        let bodySize = PhysicalScale.size(mm: bodyMM, pointsPerMM: k)
        let screenSize = PhysicalScale.size(mm: screenMM, pointsPerMM: k)
        let ptScale = PhysicalScale.pointsPerPDFPoint(pointsPerMM: k)
        let pageSize = item.planned.map { p -> CGSize in
            let s = p.plan.pages[min(page, p.plan.pages.count - 1)].sizePt
            return CGSize(width: s.width * ptScale, height: s.height * ptScale)
        } ?? .zero
        let screenCorner = Units.ptToMM(MiniDevice.cornerRadiusPt) * k
        ZStack {
            RoundedRectangle(cornerRadius: PhysicalScale.bodyCornerMM * k, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.26), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: PhysicalScale.bodyCornerMM * k, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                )
                .frame(width: bodySize.width, height: bodySize.height)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            // Câmera frontal na borda curta (no topo em retrato, à esquerda em paisagem).
            Circle()
                .fill(Color(white: 0.32))
                .frame(width: 2.2 * k, height: 2.2 * k)
                .offset(x: landscape ? -(bodySize.width + screenSize.width) / 4 : 0,
                        y: landscape ? 0 : -(bodySize.height + screenSize.height) / 4)
            ZStack {
                Color.black
                if let img = item.outputImage(page, ppp: (ptScale * displayScale * 4).rounded(.up) / 4) {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: pageSize.width, height: pageSize.height)
                        .accessibilityLabel("Página de saída \(page + 1) de \(item.pageCount) no iPad mini")
                }
            }
            .frame(width: screenSize.width, height: screenSize.height)
            .clipShape(RoundedRectangle(cornerRadius: screenCorner, style: .continuous))
        }
        .frame(width: bodySize.width, height: bodySize.height)
        .accessibilityElement(children: .contain)
    }
}
