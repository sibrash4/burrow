import SwiftUI
import BurrowCore

struct StrataLayer: Identifiable, Equatable {
    var id: String
    var title: String
    var bytes: Int64
    var index: Int
}

/// Thin vertical bar: one layer per category, sized by selected bytes, anchored at the bottom.
/// Untick a row and its layer gets thinner.
struct StrataBar: View {
    var layers: [StrataLayer]
    var total: Int64

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.quaternary)
                VStack(spacing: 1) {
                    ForEach(layers.filter { $0.bytes > 0 }) { layer in
                        Rectangle()
                            .fill(fill(layer.index))
                            .frame(height: max(2, geo.size.height * CGFloat(layer.bytes) / CGFloat(max(total, 1))))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: layers)
        }
        .frame(width: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Selected space by category")
        .accessibilityValue(spoken)
    }

    private func fill(_ index: Int) -> Color {
        let (hue, lap) = StrataHue.hue(at: index)
        return hue.color(scheme: scheme, contrast: contrast).opacity(lap == 0 ? 1 : 0.6)
    }

    private var spoken: String {
        let parts = layers.filter { $0.bytes > 0 }.map { "\($0.title) \(ByteSize.format($0.bytes))" }
        return parts.isEmpty ? "Nothing selected" : parts.joined(separator: ", ")
    }
}

/// Small swatch that names a category by colour. Kept rows get an empty outline instead.
struct StrataSwatch: View {
    var index: Int
    var filled = true

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let (hue, lap) = StrataHue.hue(at: index)
        let color = hue.color(scheme: scheme, contrast: contrast)
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(filled ? color.opacity(lap == 0 ? 1 : 0.6) : Color.secondary.opacity(0.28))
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }
}
