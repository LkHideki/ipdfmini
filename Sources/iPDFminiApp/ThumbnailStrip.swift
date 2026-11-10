import AppCore
import SwiftUI

/// Faixa inferior: páginas de saída com selos de aviso (§13).
struct ThumbnailStrip: View {
    let item: DocumentItem
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(0..<item.pageCount, id: \.self) { j in
                        thumbnail(j)
                            .id(j)
                            .onTapGesture { item.currentPage = j }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.visible)
            .onChange(of: item.currentPage) { _, j in
                withAnimation(.snappy) { proxy.scrollTo(j, anchor: .center) }
            }
        }
        .background(.bar)
    }

    private func thumbnail(_ j: Int) -> some View {
        let height: CGFloat = 92
        let size = item.planned?.plan.pages[j].sizePt ?? CGSize(width: 2, height: 3)
        let width = height * size.width / max(size.height, 1)
        let badges = j < item.badges.count ? item.badges[j] : []
        let selected = j == item.currentPage
        return VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = item.outputImage(j, ppp: (height / size.height * displayScale * 4).rounded(.up) / 4) {
                        Image(decorative: img, scale: 1).resizable().interpolation(.medium)
                    } else {
                        Color.white
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(selected ? Color.accentColor : Color.black.opacity(0.15), lineWidth: selected ? 2.5 : 0.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                if !badges.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(badges, id: \.self) { b in
                            Image(systemName: b.symbol)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 17, height: 17)
                                .background(Circle().fill(b == .smallText ? Color.orange : (b == .emptyPage ? Color.gray : Color.purple)))
                                .help(b.title)
                        }
                    }
                    .offset(x: 6, y: -5)
                }
            }
            Text("\(j + 1)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(selected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Página de saída \(j + 1)" + (badges.isEmpty ? "" : ", " + badges.map(\.title).joined(separator: ", ")))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { item.currentPage = j }
    }
}
