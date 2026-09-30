import SwiftUI

/// 与系统外观联动的玻璃控件；旧版 macOS 使用系统材质。
private struct GlassControlModifier: ViewModifier {
    let radius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *) {
            content.background {
                shape.fill(.ultraThinMaterial).glassEffect(.regular, in: shape)
            }
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.09)))
        }
    }
}

private struct DataPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content
            .background(.thinMaterial, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.07)))
            .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
    }
}

extension View {
    func glassControl(radius: CGFloat = 10) -> some View { modifier(GlassControlModifier(radius: radius)) }
    func dataPanel() -> some View { modifier(DataPanelModifier()) }
}

struct WindowBackdrop: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
    }
}
