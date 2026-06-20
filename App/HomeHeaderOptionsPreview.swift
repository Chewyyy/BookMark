import SwiftUI

struct HomeHeaderOptionsPreview: View {
    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 18) {
                PhoneMockup(title: "Option 1", subtitle: "Compact Brand Bar") {
                    CompactBrandHeader()
                }
                PhoneMockup(title: "Option 2", subtitle: "Reading Dashboard Header") {
                    DashboardHeader()
                }
                PhoneMockup(title: "Option 3", subtitle: "Cover Shelf Header") {
                    CoverShelfHeader()
                }
            }
            .padding(24)
        }
        .background(Color(white: 0.92))
    }
}

private struct PhoneMockup<Header: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var header: Header

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 12) {
                        ContinuePreviewCard()
                        StatsPreviewStrip()
                        HStack {
                            Text("YOUR LIBRARY")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(Theme.subtle)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        PreviewBookGrid()
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 16)
                }
                PreviewBottomNav()
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

private struct CompactBrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accent)
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text("BookMark")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(Theme.text)
                Text("Library")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.subtle)
            }

            Spacer()
            PreviewGoalRing(size: 42)
            PreviewPlusButton()
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Theme.background)
        .overlay(Divider().opacity(0.35), alignment: .bottom)
    }
}

private struct DashboardHeader: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Today")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.subtle)
                    Text("18 min read")
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundStyle(Theme.text)
                    HStack(spacing: 6) {
                        Label("5 day streak", systemImage: "flame.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.gold)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Theme.gold.opacity(0.14))
                            .clipShape(Capsule())
                    }
                }

                Spacer()
                PreviewGoalRing(size: 58)
                PreviewPlusButton()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(
            Theme.background
                .overlay(Theme.accent.opacity(0.06), alignment: .bottom)
        )
        .overlay(Divider().opacity(0.25), alignment: .bottom)
    }
}

private struct CoverShelfHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("BookMark")
                        .font(.system(size: 23, weight: .heavy))
                        .foregroundStyle(Theme.text)
                    Text("Back to your shelf")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.subtle)
                }
                Spacer()
                PreviewGoalRing(size: 42)
                PreviewPlusButton()
            }

            HStack(spacing: -7) {
                PreviewMiniCover(title: "D", colors: [Theme.accent, Theme.accent2])
                PreviewMiniCover(title: "S", colors: [Color(red: 0.15, green: 0.28, blue: 0.39), Color(red: 0.35, green: 0.58, blue: 0.52)])
                PreviewMiniCover(title: "M", colors: [Color(red: 0.42, green: 0.28, blue: 0.22), Color(red: 0.73, green: 0.58, blue: 0.38)])
                PreviewMiniCover(title: "A", colors: [Color(red: 0.36, green: 0.1, blue: 0.25), Color(red: 0.72, green: 0.25, blue: 0.3)])
                Spacer()
                Text("Continue")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 13)
        .background(Theme.background)
        .overlay(Divider().opacity(0.35), alignment: .bottom)
    }
}

private struct PreviewGoalRing: View {
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
                    .font(.system(size: size > 50 ? 17 : 14, weight: .black))
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

private struct PreviewPlusButton: View {
    var body: some View {
        Image(systemName: "plus.circle.fill")
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(Theme.accent)
            .frame(width: 34, height: 34)
    }
}

private struct ContinuePreviewCard: View {
    var body: some View {
        HStack(spacing: 12) {
            PreviewMiniCover(title: "N", colors: [Theme.accent, Theme.accent2])
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

private struct StatsPreviewStrip: View {
    var body: some View {
        HStack(spacing: 8) {
            PreviewStat(value: "12", label: "Books")
            PreviewStat(value: "42h", label: "Read")
            PreviewStat(value: "5", label: "Streak")
        }
        .padding(.horizontal, 16)
    }
}

private struct PreviewStat: View {
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

private struct PreviewBookGrid: View {
    private let covers: [(String, [Color])] = [
        ("N", [Theme.accent, Theme.accent2]),
        ("R", [Color(red: 0.15, green: 0.28, blue: 0.39), Color(red: 0.28, green: 0.49, blue: 0.62)]),
        ("G", [Color(red: 0.42, green: 0.28, blue: 0.22), Color(red: 0.73, green: 0.58, blue: 0.38)]),
        ("P", [Color(red: 0.36, green: 0.1, blue: 0.25), Color(red: 0.72, green: 0.25, blue: 0.3)])
    ]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(covers.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 7) {
                    PreviewMiniCover(title: covers[index].0, colors: covers[index].1)
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

private struct PreviewMiniCover: View {
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

private struct PreviewBottomNav: View {
    var body: some View {
        HStack(spacing: 0) {
            PreviewNavItem(system: "books.vertical.fill", label: "Library", selected: true)
            PreviewNavItem(system: "calendar", label: "Journal", selected: false)
            PreviewNavItem(system: "chart.bar", label: "Stats", selected: false)
        }
        .padding(.vertical, 7)
        .background(Theme.cardOverlay.overlay(Divider(), alignment: .top))
    }
}

private struct PreviewNavItem: View {
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

#Preview("Home Header Options") {
    HomeHeaderOptionsPreview()
}
