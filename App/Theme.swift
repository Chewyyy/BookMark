import SwiftUI

enum Theme {
    static let background       = Color("bm.bg",     fallbackLight: hex(0xF6F3ED), fallbackDark: hex(0x101216))
    static let card             = Color("bm.card",   fallbackLight: .white,         fallbackDark: hex(0x1A1D22))
    static let cardOverlay      = Color("bm.cardov", fallbackLight: Color.white.opacity(0.96), fallbackDark: hex(0x121418).opacity(0.92))
    static let accent           = Color("bm.accent", fallbackLight: hex(0x2D6A4F), fallbackDark: hex(0x5FCB9E))
    static let accent2          = Color("bm.acc2",   fallbackLight: hex(0x52B788), fallbackDark: hex(0x73D9AF))
    static let text             = Color("bm.text",   fallbackLight: hex(0x1A1A1A), fallbackDark: hex(0xF2F4F7))
    static let subtle           = Color("bm.sub",    fallbackLight: hex(0x6B7280), fallbackDark: hex(0xA3AAB5))
    static let border           = Color("bm.border", fallbackLight: hex(0xE4DFD4), fallbackDark: hex(0x2B3038))
    static let gold             = Color("bm.gold",   fallbackLight: hex(0xC9962E), fallbackDark: hex(0xF3C15F))
    static let imsg             = Color("bm.imsg",   fallbackLight: hex(0x007AFF), fallbackDark: hex(0x0A84FF))
    static let danger           = Color("bm.dng",    fallbackLight: hex(0xC0392B), fallbackDark: hex(0xFF6B61))

    static let cornerLarge: CGFloat = 14
    static let cornerSmall: CGFloat = 10

    static let cardShadow = Shadow(color: .black.opacity(0.07), radius: 12, y: 2)
    static let cardShadowLg = Shadow(color: .black.opacity(0.13), radius: 28, y: 8)

    struct Shadow {
        var color: Color
        var radius: CGFloat
        var y: CGFloat
    }
}

private extension Color {
    init(_ name: String, fallbackLight: Color, fallbackDark: Color) {
        if let ui = UIColor(named: name) {
            self = Color(uiColor: ui)
        } else {
            self = Color(UIColor { tc in
                tc.userInterfaceStyle == .dark ? UIColor(fallbackDark) : UIColor(fallbackLight)
            })
        }
    }
}

private func hex(_ v: UInt32) -> Color {
    let r = Double((v >> 16) & 0xFF) / 255.0
    let g = Double((v >> 8) & 0xFF) / 255.0
    let b = Double(v & 0xFF) / 255.0
    return Color(red: r, green: g, blue: b)
}

extension View {
    func cardStyle(_ shadow: Theme.Shadow = Theme.cardShadow) -> some View {
        self
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
            .shadow(color: shadow.color, radius: shadow.radius, x: 0, y: shadow.y)
    }
    func smallCardStyle(_ shadow: Theme.Shadow = Theme.cardShadow) -> some View {
        self
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
            .shadow(color: shadow.color, radius: shadow.radius, x: 0, y: shadow.y)
    }
    /// Centers content and caps its width so layouts stay readable on iPad's
    /// regular-width canvas instead of stretching edge-to-edge. No effect on
    /// iPhone (compact width); the caller still controls horizontal padding.
    func readableContentWidth(_ maxWidth: CGFloat = 720) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}

/// Layout breakpoints used to switch between phone and iPad-style layouts.
/// Driven by `horizontalSizeClass`, not raw screen width, so the right layout
/// also kicks in for Slide Over / Split View windows on iPad.
enum Layout {
    /// Library grid columns by horizontal size class. Phones (compact) get 2;
    /// iPad regular width gets 4.
    static func libraryGridColumns(for sizeClass: UserInterfaceSizeClass?) -> [GridItem] {
        let count = sizeClass == .regular ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 14), count: count)
    }

    /// Stats grid columns. Phones get 2 cards/row; iPad regular gets 4 so the
    /// 8-card grid lands as 2 rows of 4 instead of one tall column.
    static func statsGridColumns(for sizeClass: UserInterfaceSizeClass?) -> [GridItem] {
        let count = sizeClass == .regular ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }
}

enum CoverGradient {
    static let palette: [(Color, Color)] = [
        (hex(0x2D6A4F), hex(0x52B788)),
        (hex(0x264653), hex(0x2A9D8F)),
        (hex(0x6D4C3D), hex(0xA98467)),
        (hex(0x3D405B), hex(0x81B29A)),
        (hex(0x5F0F40), hex(0x9A031E)),
        (hex(0x1D3557), hex(0x457B9D)),
    ]
    static func gradient(for seed: String) -> LinearGradient {
        let idx = Int(seed.unicodeScalars.first?.value ?? 0) % palette.count
        let (a, b) = palette[idx]
        return LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct CardSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(Theme.subtle)
            }
            content
        }
    }
}
