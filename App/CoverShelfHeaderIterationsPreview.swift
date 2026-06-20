import SwiftUI

struct CoverShelfHeaderIterationsPreview: View {
    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 18) {
                CoverShelfPhoneMockup(title: "A", subtitle: "Soft Shelf Strip") {
                    SoftShelfHeaderIteration()
                }
                CoverShelfPhoneMockup(title: "B1", subtitle: "Clean Floating Stack") {
                    CleanFloatingCoversHeaderIteration()
                }
                CoverShelfPhoneMockup(title: "B2", subtitle: "Corner Watermark") {
                    CornerWatermarkHeaderIteration()
                }
                CoverShelfPhoneMockup(title: "B3", subtitle: "Thin Cover Rail") {
                    ThinCoverRailHeaderIteration()
                }
                CoverShelfPhoneMockup(title: "C", subtitle: "Current Book Focus") {
                    CurrentBookHeaderIteration()
                }
                CoverShelfPhoneMockup(title: "D", subtitle: "Compact Stack") {
                    CompactStackHeaderIteration()
                }
            }
            .padding(24)
        }
        .background(Color(white: 0.92))
    }
}

private struct CoverShelfPhoneMockup<Header: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var header: Header

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Iteration \(title)")
                    .font(.system(size: 14, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 12) {
                        ShelfContinuePreviewCard()
                        ShelfStatsPreviewStrip()
                        HStack {
                            Text("YOUR LIBRARY")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(Theme.subtle)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        ShelfPreviewBookGrid()
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 16)
                }
                ShelfPreviewBottomNav()
            }
            .frame(width: 270, height: 560)
            .background(Theme.background)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(Color.black.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.16), radius: 24, y: 12)
        }
    }
}

private struct SoftShelfHeaderIteration: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ShelfHeaderTopline(subtitle: "Back to your shelf")

            HStack(spacing: -7) {
                ShelfMiniCover(title: "N", colors: ShelfPalette.green)
                ShelfMiniCover(title: "R", colors: ShelfPalette.blue)
                ShelfMiniCover(title: "G", colors: ShelfPalette.brown)
                ShelfMiniCover(title: "P", colors: ShelfPalette.rose)
                Spacer()
                Text("Continue")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 13)
        .background(Theme.background)
        .overlay(Divider().opacity(0.35), alignment: .bottom)
    }
}

private struct CleanFloatingCoversHeaderIteration: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Theme.background

            ZStack {
                ShelfMiniCover(title: "R", colors: ShelfPalette.blue)
                    .frame(width: 34, height: 48)
                    .rotationEffect(.degrees(6))
                    .offset(x: 13, y: 3)
                    .opacity(0.24)
                ShelfMiniCover(title: "N", colors: ShelfPalette.green)
                    .frame(width: 38, height: 54)
                    .rotationEffect(.degrees(-5))
                    .opacity(0.34)
            }
            .offset(x: -74, y: -15)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("BookMark")
                            .font(.system(size: 24, weight: .heavy))
                            .foregroundStyle(Theme.text)
                        Text("Pick up where you left off")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.subtle)
                    }
                    Spacer()
                    ShelfGoalRing(size: 42)
                    ShelfPlusButton()
                }
                HStack(spacing: 6) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text("4 active reads")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .frame(height: 90)
        .overlay(Divider().opacity(0.35), alignment: .bottom)
    }
}

private struct CornerWatermarkHeaderIteration: View {
    var body: some View {
        ZStack(alignment: .trailing) {
            Theme.background

            HStack(spacing: -10) {
                ShelfMiniCover(title: "N", colors: ShelfPalette.green)
                    .frame(width: 36, height: 51)
                    .rotationEffect(.degrees(-4))
                ShelfMiniCover(title: "G", colors: ShelfPalette.brown)
                    .frame(width: 32, height: 45)
                    .rotationEffect(.degrees(7))
            }
            .opacity(0.18)
            .offset(x: -18, y: 6)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("BookMark")
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundStyle(Theme.text)
                    Text("4 books in progress")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.subtle)
                }
                Spacer()
                ShelfGoalRing(size: 42)
                ShelfPlusButton()
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .frame(height: 78)
        .overlay(Divider().opacity(0.35), alignment: .bottom)
    }
}

private struct ThinCoverRailHeaderIteration: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("BookMark")
                        .font(.system(size: 23, weight: .heavy))
                        .foregroundStyle(Theme.text)
                    Text("Your reading shelf")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.subtle)
                }
                Spacer()
                ShelfGoalRing(size: 42)
                ShelfPlusButton()
            }

            HStack(spacing: 6) {
                ShelfRailCover(colors: ShelfPalette.green)
                ShelfRailCover(colors: ShelfPalette.blue)
                ShelfRailCover(colors: ShelfPalette.brown)
                ShelfRailCover(colors: ShelfPalette.rose)
                Spacer()
            }
            .frame(height: 9)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Theme.background)
        .overlay(Divider().opacity(0.35), alignment: .bottom)
    }
}

private struct CurrentBookHeaderIteration: View {
    var body: some View {
        HStack(spacing: 12) {
            ShelfMiniCover(title: "N", colors: ShelfPalette.green)
                .frame(width: 50, height: 70)

            VStack(alignment: .leading, spacing: 4) {
                Text("BookMark")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(Theme.text)
                Text("Reading now")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(Theme.subtle)
                Text("Northern Lights")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)
            ShelfGoalRing(size: 42)
            ShelfPlusButton()
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 13)
        .background(Theme.background)
        .overlay(Divider().opacity(0.35), alignment: .bottom)
    }
}

private struct CompactStackHeaderIteration: View {
    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                ShelfMiniCover(title: "G", colors: ShelfPalette.brown)
                    .frame(width: 30, height: 43)
                    .offset(x: 13, y: 4)
                    .opacity(0.78)
                ShelfMiniCover(title: "R", colors: ShelfPalette.blue)
                    .frame(width: 32, height: 46)
                    .offset(x: 5, y: 1)
                    .opacity(0.9)
                ShelfMiniCover(title: "N", colors: ShelfPalette.green)
                    .frame(width: 34, height: 49)
                    .offset(x: -5, y: -2)
            }
            .frame(width: 52, height: 54)

            VStack(alignment: .leading, spacing: 2) {
                Text("BookMark")
                    .font(.system(size: 23, weight: .heavy))
                    .foregroundStyle(Theme.text)
                Text("12 books on your shelf")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.subtle)
            }

            Spacer()
            ShelfGoalRing(size: 42)
            ShelfPlusButton()
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Theme.background)
        .overlay(Divider().opacity(0.35), alignment: .bottom)
    }
}

private struct ShelfHeaderTopline: View {
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("BookMark")
                    .font(.system(size: 23, weight: .heavy))
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.subtle)
            }
            Spacer()
            ShelfGoalRing(size: 42)
            ShelfPlusButton()
        }
    }
}

private enum ShelfPalette {
    static let green = [Theme.accent, Theme.accent2]
    static let blue = [Color(red: 0.15, green: 0.28, blue: 0.39), Color(red: 0.28, green: 0.49, blue: 0.62)]
    static let brown = [Color(red: 0.42, green: 0.28, blue: 0.22), Color(red: 0.73, green: 0.58, blue: 0.38)]
    static let rose = [Color(red: 0.36, green: 0.1, blue: 0.25), Color(red: 0.72, green: 0.25, blue: 0.3)]
}

private struct ShelfGoalRing: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(Color.gray.opacity(0.22), lineWidth: 4)
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(Theme.imsg, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -1) {
                Text("18")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Theme.imsg)
                Text("25")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(Theme.subtle)
            }
        }
        .frame(width: size, height: size)
        .background(Theme.card.clipShape(Circle()))
        .shadow(color: .black.opacity(0.07), radius: 8, y: 2)
    }
}

private struct ShelfPlusButton: View {
    var body: some View {
        Image(systemName: "plus.circle.fill")
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(Theme.accent)
            .frame(width: 34, height: 34)
    }
}

private struct ShelfContinuePreviewCard: View {
    var body: some View {
        HStack(spacing: 12) {
            ShelfMiniCover(title: "N", colors: ShelfPalette.green)
                .frame(width: 46, height: 64)
            VStack(alignment: .leading, spacing: 5) {
                Text("Continue Reading")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(Theme.subtle)
                Text("Northern Lights")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Theme.text)
                ProgressView(value: 0.42)
                    .tint(Theme.accent)
            }
            Spacer()
        }
        .padding(12)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.07), radius: 10, y: 2)
        .padding(.horizontal, 16)
    }
}

private struct ShelfStatsPreviewStrip: View {
    var body: some View {
        HStack(spacing: 8) {
            ShelfStat(value: "12", label: "Books")
            ShelfStat(value: "42h", label: "Read")
            ShelfStat(value: "5", label: "Streak")
        }
        .padding(.horizontal, 16)
    }
}

private struct ShelfStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(Theme.text)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.subtle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }
}

private struct ShelfPreviewBookGrid: View {
    private let covers: [(String, [Color])] = [
        ("N", ShelfPalette.green),
        ("R", ShelfPalette.blue),
        ("G", ShelfPalette.brown),
        ("P", ShelfPalette.rose)
    ]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(covers.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 7) {
                    ShelfMiniCover(title: covers[index].0, colors: covers[index].1)
                        .frame(height: 112)
                    Text(["Northern Lights", "Reading Notes", "Green Room", "Paper Towns"][index])
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                        .foregroundStyle(Theme.text)
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

private struct ShelfMiniCover: View {
    let title: String
    let colors: [Color]

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(title)
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(.white.opacity(0.9))
                .padding(8)
        }
        .aspectRatio(0.72, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
    }
}

private struct ShelfRailCover: View {
    let colors: [Color]

    var body: some View {
        Capsule(style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
            .frame(width: 34, height: 7)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.65), lineWidth: 0.5)
            )
    }
}

private struct ShelfPreviewBottomNav: View {
    var body: some View {
        HStack(spacing: 0) {
            ShelfNavItem(system: "books.vertical.fill", label: "Library", selected: true)
            ShelfNavItem(system: "calendar", label: "Journal", selected: false)
            ShelfNavItem(system: "chart.bar", label: "Stats", selected: false)
        }
        .padding(.vertical, 7)
        .background(Theme.cardOverlay.overlay(Divider(), alignment: .top))
    }
}

private struct ShelfNavItem: View {
    let system: String
    let label: String
    let selected: Bool

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .semibold))
            Text(label.uppercased())
                .font(.system(size: 8, weight: .bold))
                .tracking(0.4)
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(selected ? Theme.accent : Theme.subtle)
    }
}

#Preview("Cover Shelf Header Iterations") {
    CoverShelfHeaderIterationsPreview()
}
