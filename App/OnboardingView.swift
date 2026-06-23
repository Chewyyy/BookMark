import SwiftUI
import UIKit
import QuartzCore

// MARK: - First-launch onboarding
//
// Presents the app as a small "book" the reader swipes through. The very first
// page turn always plays BookMark's realistic page curl (reusing the reader's
// Metal renderer) to show off the hero feature; after that the book turns with
// whichever animation the reader is currently previewing on the settings page,
// so the tutorial itself becomes a live demo of None / Fade / Slide / Rigid / Realistic.

struct OnboardingView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    // Match the device appearance during onboarding so the tutorial has both
    // day and night presentations.
    private var palette: ReaderThemePalette.Palette {
        ReaderThemePalette.resolve(colorScheme == .dark ? .night : .paper)
    }
    private static let pageCount = 9

    @State private var page = 0

    // Reader preferences the onboarding lets the user choose. Persisted to
    // `store.readerSettings` on finish so the choices carry into the reader.
    @State private var selectedAnimation: PageAnimation = .testCurl
    @State private var demoFontSize = 100

    // Reminder step.
    @State private var reminderEnabled = true
    @State private var reminderTime = OnboardingView.defaultReminderTime()
    @State private var reminderApplied = false

    // Folder steps.
    @State private var showWatchPicker = false
    @State private var showBackupPicker = false
    @State private var showAnimationTester = false

    // Sample book.
    @State private var sampleCover: UIImage?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                palette.backgroundColor.ignoresSafeArea()

                OnboardingFlip(
                    count: Self.pageCount,
                    index: $page,
                    currentAnimation: selectedAnimation,
                    forceFirstCurl: true,
                    palette: palette,
                    size: size,
                    displayScale: displayScale
                ) { idx in
                    pageBody(idx)
                }
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            if value.translation.width < -40 { goNext() }
                            else if value.translation.width > 40 { goBack() }
                        }
                )

                controlBar
                    .frame(maxHeight: .infinity, alignment: .bottom)

                if page < Self.pageCount - 1 {
                    skipButton
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
        }
        .task { await loadSample() }
        .sheet(isPresented: $showWatchPicker) {
            FolderPicker { url in
                showWatchPicker = false
                try? store.setWatchedFolder(url)
                Task { _ = await EPUBImporter.rescanFolder(url, into: store) }
            }
        }
        .sheet(isPresented: $showBackupPicker) {
            FolderPicker { url in
                showBackupPicker = false
                try? store.setBackupFolder(url)
            }
        }
        .fullScreenCover(isPresented: $showAnimationTester) {
            OnboardingAnimationReaderDemo(
                selectedAnimation: $selectedAnimation,
                fontSize: demoFontSize,
                palette: palette
            )
        }
    }

    // MARK: Navigation

    private func goNext() {
        guard page < Self.pageCount - 1 else { finish(); return }
        if page == 5 { applyReminder() }   // request notification permission in context
        page += 1
    }

    private func goBack() {
        guard page > 0 else { return }
        page -= 1
    }

    private func finish() {
        applyReminder()
        store.readerSettings.pageAnim = selectedAnimation
        store.readerSettings.fontSize = demoFontSize
        store.scheduleSave()
        // Import the sample first, then drop the onboarding gate, so the library
        // already shows the book the moment the tutorial closes.
        Task {
            await EPUBImporter.importBundledSample(into: store)
            store.completeOnboarding()
        }
    }

    private func applyReminder() {
        guard !reminderApplied || store.goal.reminderEnabled != reminderEnabled else { reminderApplied = true; return }
        reminderApplied = true
        store.goal.reminderEnabled = reminderEnabled
        let comps = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
        store.goal.reminderHour = comps.hour ?? 20
        store.goal.reminderMinute = comps.minute ?? 0
        store.scheduleSave()
        Task { await ReadingReminderScheduler.reschedule(for: store, requestAuthorizationIfNeeded: reminderEnabled) }
    }

    // MARK: Sample book

    // Only loads the cover for the preview. The sample book is imported in
    // `finish()` so the library stays empty until onboarding is actually
    // completed — otherwise quitting mid-tutorial would trip the "returning
    // user already has a library" migration and skip onboarding next launch.
    private func loadSample() async {
        if sampleCover == nil,
           let data = NSDataAsset(name: "OnboardingBook")?.data,
           let pkg = EPUBPackage.open(data: data),
           let cover = pkg.coverData(),
           let img = UIImage(data: cover) {
            sampleCover = img
        }
    }

    private static func defaultReminderTime() -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 20
        comps.minute = 0
        return Calendar.current.date(from: comps) ?? Date()
    }

    // MARK: Controls

    private var controlBar: some View {
        HStack(spacing: 14) {
            Button(action: goBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(palette.foregroundColor)
                    .frame(width: 44, height: 44)
                    .background(palette.foregroundColor.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(page == 0 ? 0 : 1)
            .disabled(page == 0)

            HStack(spacing: 7) {
                ForEach(0..<Self.pageCount, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? palette.accentColor : palette.foregroundColor.opacity(0.18))
                        .frame(width: i == page ? 20 : 7, height: 7)
                        .animation(.easeInOut(duration: 0.25), value: page)
                }
            }
            .frame(maxWidth: .infinity)

            Button(action: goNext) {
                Group {
                    if page == Self.pageCount - 1 {
                        Text("Start Reading")
                            .font(.system(size: 15, weight: .heavy, design: .serif))
                            .padding(.horizontal, 18)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 16, weight: .heavy))
                            .frame(width: 24)
                    }
                }
                .foregroundStyle(.white)
                .frame(height: 44)
                .frame(minWidth: 44)
                .background(palette.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(Divider(), alignment: .top)
    }

    private var skipButton: some View {
        Button { finish() } label: {
            Text("Skip")
                .font(.system(size: 14, weight: .bold, design: .serif))
                .foregroundStyle(palette.secondaryForeground)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .padding(.trailing, 10)
    }

    // MARK: Pages

    @ViewBuilder
    private func pageBody(_ index: Int) -> some View {
        switch index {
        case 0: coverPage
        case 1: benefitsPage
        case 2: firstBookPage
        case 3: watchFolderPage
        case 4: backupFolderPage
        case 5: reminderPage
        case 6: statsPage
        case 7: settingsPage
        default: finishPage
        }
    }

    // 0 — Cover
    private var coverPage: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.36, blue: 0.27), Color(red: 0.10, green: 0.22, blue: 0.18)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            VStack(spacing: 0) {
                Spacer()
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.bottom, 26)
                Text("BookMark")
                    .font(.system(size: 46, weight: .heavy, design: .serif))
                    .foregroundStyle(.white)
                Text("Read more. Remember everything.")
                    .font(.system(size: 17, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 10)
                Spacer()
                HStack(spacing: 8) {
                    Text("Swipe to turn the page")
                        .font(.system(size: 14, weight: .semibold, design: .serif))
                    Image(systemName: "chevron.right")
                    Image(systemName: "chevron.right")
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding(.bottom, 120)
            }
            .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // 1 — Benefits
    private var benefitsPage: some View {
        OBPage(palette: palette, kicker: "Welcome") {
            OBHeadline("A reading habit that sticks", palette: palette)
            OBParagraph("BookMark turns reading into something you can see and feel proud of. Every session you read is tracked automatically while you stay lost in the story.", palette: palette)
            VStack(alignment: .leading, spacing: 14) {
                OBBullet(icon: "flame.fill", title: "Build daily streaks", text: "Hit a small daily goal and watch your streak grow.", palette: palette)
                OBBullet(icon: "chart.bar.fill", title: "See your stats", text: "Time read, pages, reading speed, and pace over time.", palette: palette)
                OBBullet(icon: "books.vertical.fill", title: "Your whole library", text: "Open any EPUB and pick up exactly where you left off.", palette: palette)
            }
            .padding(.top, 20)
        }
    }

    // 2 — First book
    private var firstBookPage: some View {
        OBPage(palette: palette, kicker: "Your library") {
            OBHeadline("Your first book is ready", palette: palette)
            HStack(alignment: .top, spacing: 16) {
                sampleCoverView
                VStack(alignment: .leading, spacing: 4) {
                    Text("Variatio Ipsius")
                        .font(.system(size: 17, weight: .bold, design: .serif))
                        .foregroundStyle(palette.foregroundColor)
                    Text("Andrew Jackson")
                        .font(.system(size: 13, weight: .regular, design: .serif))
                        .foregroundStyle(palette.secondaryForeground)
                    Text("Ready in your library")
                        .font(.system(size: 12, weight: .heavy, design: .serif))
                        .foregroundStyle(palette.accentColor)
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 18)

            OBParagraph("We’ve set aside a short sample so you can start the moment you finish here. To add your own books, open any .epub file in BookMark — or point it at a folder and new books import themselves.", palette: palette)
        }
    }

    private var sampleCoverView: some View {
        Group {
            if let sampleCover {
                Image(uiImage: sampleCover)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [palette.accentColor, palette.accentColor.opacity(0.6)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .frame(width: 74, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
    }

    // 3 — Watch folder
    private var watchFolderPage: some View {
        OBPage(palette: palette, kicker: "Automatic imports") {
            OBHeadline("Watch a folder for new books", palette: palette)
            OBParagraph("Pick a folder — like an iCloud Drive or Dropbox folder where you save EPUBs — and BookMark imports anything new it finds, every time you open the app. Drop a book in from your Mac and it just appears here.", palette: palette)

            folderRow(
                isSet: store.watchedFolderName != nil,
                setLabel: store.watchedFolderName.map { "Watching \u{201C}\($0)\u{201D}" } ?? "",
                chooseTitle: store.watchedFolderName == nil ? "Choose Folder\u{2026}" : "Change Folder",
                action: { showWatchPicker = true }
            )
            OBLaterHint("You can set this up anytime in Stats \u{2192} Tools.", palette: palette)
        }
    }

    // 4 — Backup folder
    private var backupFolderPage: some View {
        OBPage(palette: palette, kicker: "Keep your progress safe") {
            OBHeadline("Back up to a folder you own", palette: palette)
            OBParagraph("Your library, sessions, streaks, and bookmarks are saved automatically. Point backups at a folder outside the app — like iCloud Drive — and they survive even if BookMark is deleted or you move to a new phone.", palette: palette)

            folderRow(
                isSet: store.backupFolderName != nil,
                setLabel: store.backupFolderName.map { "Backing up to \u{201C}\($0)\u{201D}" } ?? "",
                chooseTitle: store.backupFolderName == nil ? "Choose Folder\u{2026}" : "Change Folder",
                action: { showBackupPicker = true }
            )
            OBLaterHint("Until you choose one, backups stay in On My iPhone \u{203A} BookMark.", palette: palette)
        }
    }

    private func folderRow(isSet: Bool, setLabel: String, chooseTitle: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if isSet {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accentColor)
                    Text(setLabel)
                        .font(.system(size: 13, weight: .heavy, design: .serif))
                        .foregroundStyle(palette.foregroundColor)
                        .lineLimit(1)
                }
            }
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                    Text(chooseTitle)
                }
                .font(.system(size: 15, weight: .heavy, design: .serif))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(palette.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 20)
    }

    // 5 — Reminder
    private var reminderPage: some View {
        OBPage(palette: palette, kicker: "Gentle nudges") {
            OBHeadline("A reminder, only when you need it", palette: palette)
            OBParagraph("Pick a time for a daily nudge. BookMark only sends it if you still have reading minutes left for the day — never when you\u{2019}ve already hit your goal.", palette: palette)

            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $reminderEnabled) {
                    Text("Daily reading reminder")
                        .font(.system(size: 15, weight: .heavy, design: .serif))
                        .foregroundStyle(palette.foregroundColor)
                }
                .tint(palette.accentColor)

                if reminderEnabled {
                    HStack {
                        Text("Remind me at")
                            .font(.system(size: 15, weight: .semibold, design: .serif))
                            .foregroundStyle(palette.foregroundColor)
                        Spacer()
                        DatePicker("", selection: $reminderTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                }
            }
            .padding(16)
            .background(palette.foregroundColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.top, 18)

            OBBullet(icon: "moon.stars.fill", title: "Last-chance heads up", text: "If the day is almost over and you\u{2019}re still short, BookMark sends one final nudge with just enough buffer to finish before midnight and keep your streak.", palette: palette)
                .padding(.top, 18)
        }
    }

    // 6 — Stats
    private var statsPage: some View {
        OBPage(palette: palette, kicker: "Know your reading") {
            OBHeadline("Stats that actually mean something", palette: palette)
            Text("BookMark turns your reading into a simple dashboard: time, pages, streaks, pace, and yearly goals.")
                .font(.system(size: 14.5, weight: .regular, design: .serif))
                .lineSpacing(3)
                .foregroundStyle(palette.foregroundColor.opacity(0.84))
                .fixedSize(horizontal: false, vertical: true)

            OnboardingStatsMockView()
                .padding(.top, 16)
        }
    }

    // 7 — Settings demo
    private var settingsPage: some View {
        OBPage(palette: palette, kicker: "Make it yours") {
            OBHeadline("Choose how pages turn", palette: palette)
            OBParagraph("Tap a style, then open the tester to try page turns in a reader-style view. You can change this anytime in the reader.", palette: palette)

            Button { showAnimationTester = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "book.pages")
                        .font(.system(size: 22, weight: .bold))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Open page turn tester")
                            .font(.system(size: 16, weight: .heavy, design: .serif))
                        Text("Swipe, drag, and switch animations like the reader")
                            .font(.system(size: 12.5, weight: .semibold, design: .serif))
                            .foregroundStyle(palette.secondaryForeground)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .heavy))
                }
                .foregroundStyle(palette.foregroundColor)
                .padding(16)
                .background(palette.foregroundColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 14)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(Self.animationChoices, id: \.anim) { choice in
                    animationChip(choice.anim, label: choice.label, icon: choice.icon)
                }
            }
            .padding(.top, 14)

            HStack(spacing: 14) {
                Text("Text size")
                    .font(.system(size: 15, weight: .heavy, design: .serif))
                    .foregroundStyle(palette.foregroundColor)
                Spacer()
                stepButton("textformat.size.smaller") { demoFontSize = max(70, demoFontSize - 10) }
                Text("\(demoFontSize)%")
                    .font(.system(size: 15, weight: .heavy, design: .serif))
                    .foregroundStyle(palette.foregroundColor)
                    .frame(width: 56)
                    .contentTransition(.numericText())
                stepButton("textformat.size.larger") { demoFontSize = min(170, demoFontSize + 10) }
            }
            .padding(.top, 18)
        }
    }

    private static let animationChoices: [(anim: PageAnimation, label: String, icon: String)] = [
        (.none, "None", "nosign"),
        (.fade, "Fade", "circle.lefthalf.filled"),
        (.slide, "Slide", "arrow.left.and.right"),
        (.scroll, "Scroll", "arrow.up.and.down"),
        (.curl, "Rigid", "book.pages"),
        (.testCurl, "Realistic", "rectangle.portrait.on.rectangle.portrait.angled"),
    ]

    private func animationChip(_ anim: PageAnimation, label: String, icon: String) -> some View {
        let on = selectedAnimation == anim
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { selectedAnimation = anim }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 16, weight: .bold))
                Text(label).font(.system(size: 11, weight: .heavy, design: .serif))
            }
            .foregroundStyle(on ? .white : palette.foregroundColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(on ? palette.accentColor : palette.foregroundColor.opacity(0.07),
                       in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15), action)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(palette.accentColor)
                .frame(width: 44, height: 44)
                .background(palette.accentColor.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
    }

    // 8 — Finish
    private var finishPage: some View {
        OBPage(palette: palette, kicker: "You\u{2019}re all set") {
            Spacer(minLength: 10)
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(palette.accentColor)
                OBHeadline("Happy reading", palette: palette)
                OBParagraph("Your sample book is waiting in your library. Open it, read a few pages, and watch your first streak begin. Everything you set up here can be changed later in Settings and Stats.", palette: palette)
            }
            Spacer(minLength: 10)
        }
    }
}

// MARK: - Page chrome

private struct OBPage<Content: View>: View {
    let palette: ReaderThemePalette.Palette
    var kicker: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let kicker {
                Text(kicker.uppercased())
                    .font(.system(size: 12, weight: .bold, design: .serif))
                    .tracking(2.5)
                    .foregroundStyle(palette.accentColor)
                    .padding(.bottom, 20)
            }
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 30)
        .padding(.top, 195)
        .padding(.bottom, 104)
        .background(palette.backgroundColor)
    }
}

private struct OBHeadline: View {
    let text: String
    let palette: ReaderThemePalette.Palette
    init(_ text: String, palette: ReaderThemePalette.Palette) { self.text = text; self.palette = palette }
    var body: some View {
        Text(text)
            .font(.system(size: 30, weight: .heavy, design: .serif))
            .foregroundStyle(palette.foregroundColor)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 14)
    }
}

private struct OBParagraph: View {
    let text: String
    let palette: ReaderThemePalette.Palette
    init(_ text: String, palette: ReaderThemePalette.Palette) { self.text = text; self.palette = palette }
    var body: some View {
        Text(text)
            .font(.system(size: 16.5, weight: .regular, design: .serif))
            .lineSpacing(5)
            .foregroundStyle(palette.foregroundColor.opacity(0.86))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct OBBullet: View {
    let icon: String
    let title: String
    let text: String
    let palette: ReaderThemePalette.Palette
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(palette.accentColor)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .heavy, design: .serif))
                    .foregroundStyle(palette.foregroundColor)
                Text(text)
                    .font(.system(size: 14, weight: .regular, design: .serif))
                    .foregroundStyle(palette.foregroundColor.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct OBLaterHint: View {
    let text: String
    let palette: ReaderThemePalette.Palette
    init(_ text: String, palette: ReaderThemePalette.Palette) { self.text = text; self.palette = palette }
    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .regular, design: .serif))
            .italic()
            .foregroundStyle(palette.secondaryForeground)
            .padding(.top, 14)
    }
}

private struct OnboardingStatsMockView: View {
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }
    private var cardColor: Color { isDark ? Color(red: 0.10, green: 0.11, blue: 0.13) : .white }
    private var background: Color { isDark ? Color(red: 0.055, green: 0.06, blue: 0.07) : Color(red: 0.94, green: 0.92, blue: 0.87) }
    private var accent: Color { Color(red: 0.36, green: 0.80, blue: 0.61) }
    private var blue: Color { Color(red: 0.05, green: 0.54, blue: 0.96) }
    private var cyan: Color { Color(red: 0.16, green: 0.74, blue: 0.84) }
    private var primaryText: Color { isDark ? .white : Color(red: 0.08, green: 0.09, blue: 0.10) }
    private var secondaryText: Color { primaryText.opacity(isDark ? 0.62 : 0.58) }
    private var labelText: Color { primaryText.opacity(isDark ? 0.55 : 0.50) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 2), spacing: 9) {
                statCard("TOTAL READ", "147h 11m", "all time", highlighted: true)
                statCard("FINISHED", "23", "books completed")
                statCard("THIS WEEK", "5h 11m", "last 7 days")
                statCard("TOTAL PAGES", "246", "all time")
            }

            chartCard(title: "Last 7 Days") {
                fakeBars.frame(height: 64)
            }

            chartCard(title: "Reading Pace · Last 7 Days") {
                fakePace.frame(height: 86)
            }

            VStack(spacing: 8) {
                Text("2026 Reading")
                    .font(.system(size: 21, weight: .heavy, design: .serif))
                    .foregroundStyle(primaryText)
                HStack(spacing: 7) {
                    ForEach(0..<6, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(bookColor(index))
                            .frame(height: 46)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(blue)
                                    .background(Color.white, in: Circle())
                                    .offset(x: 5, y: 5)
                            }
                    }
                }
                Text("Yearly Goal Achieved")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(blue)
                Text("10 books finished — keep the streak going!")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(secondaryText)
            }
            .padding(13)
            .background(cardColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .padding(12)
        .background(background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func statCard(_ title: String, _ value: String, _ subtitle: String, highlighted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.6)
                .foregroundStyle(highlighted ? Color.white.opacity(0.76) : labelText)
            Text(value)
                .font(.system(size: 23, weight: .heavy))
                .foregroundStyle(highlighted ? Color.white : primaryText)
                .minimumScaleFactor(0.75)
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(highlighted ? Color.white.opacity(0.82) : secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .padding(12)
        .background(highlighted ? accent : cardColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func chartCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(primaryText)
            content()
        }
        .padding(12)
        .background(cardColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var fakeBars: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(Array([0.58, 0.70, 0.92, 0.60, 0.55, 0.52, 0.08].enumerated()), id: \.offset) { item in
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(item.offset == 5 ? blue.opacity(0.55) : blue)
                        .frame(height: max(6, 58 * item.element))
                    Text(["M", "T", "W", "T", "F", "S", "S"][item.offset])
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(secondaryText)
                }
            }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(red: 0.74, green: 0.62, blue: 0.34))
                .frame(height: 2)
                .opacity(0.8)
                .offset(y: 18)
        }
    }

    private var fakePace: some View {
        GeometryReader { geo in
            let points: [CGPoint] = [
                CGPoint(x: 0.02, y: 0.52), CGPoint(x: 0.20, y: 0.55), CGPoint(x: 0.38, y: 0.52),
                CGPoint(x: 0.55, y: 0.57), CGPoint(x: 0.72, y: 0.56), CGPoint(x: 0.88, y: 0.82), CGPoint(x: 1.0, y: 0.18),
            ]
            Path { path in
                path.move(to: scaled(points[0], geo.size))
                for point in points.dropFirst() { path.addLine(to: scaled(point, geo.size)) }
            }
            .stroke(cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            Path { path in
                path.move(to: CGPoint(x: 0, y: geo.size.height))
                for point in points { path.addLine(to: scaled(point, geo.size)) }
                path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                path.closeSubpath()
            }
            .fill(cyan.opacity(0.16))
        }
    }

    private func scaled(_ point: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private func bookColor(_ index: Int) -> Color {
        [Color.red.opacity(0.7), Color.orange.opacity(0.75), Color.yellow.opacity(0.65), Color.gray, Color.green.opacity(0.7), Color.purple.opacity(0.75)][index]
    }
}

// MARK: - Animation preview card (settings page demo)

private struct AnimationPreviewCard: View {
    let animation: PageAnimation
    let fontSize: Int
    let palette: ReaderThemePalette.Palette
    @Environment(\.displayScale) private var displayScale

    @State private var side = 0
    @State private var previewCurl: PreviewCurlState?
    @State private var scrollOffset: CGFloat = 0
    @State private var isScrollAnimating = false

    private let samples = [
        "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Proin lacinia cursus congue, ac nibh nec tortor tempor posuere.",
        "Aliquam erat volutpat. Nam dolor orci, eleifend et commodo nec, sodales sit amet nibh. Cras tincidunt tempor nisl.",
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if usesDragPreview {
                    sampleSide(side, size: geo.size)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if animation == .scroll {
                    sampleSide(side, size: geo.size)
                        .offset(y: scrollOffset)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    OnboardingFlip(
                        count: samples.count,
                        index: $side,
                        currentAnimation: animation,
                        forceFirstCurl: false,
                        palette: palette,
                        size: geo.size,
                        displayScale: displayScale
                    ) { idx in
                        sampleSide(idx, size: geo.size)
                    }
                    .allowsHitTesting(previewCurl == nil)
                }

                if let previewCurl {
                    InteractiveCurlTransition(
                        current: previewCurl.from,
                        destination: previewCurl.to,
                        direction: previewCurl.direction,
                        progress: previewCurl.progress,
                        verticalPull: previewCurl.verticalPull,
                        touchY: previewCurl.touchY,
                        palette: palette
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .id(previewCurl.id)
                    .allowsHitTesting(false)
                }

                VStack {
                    Spacer()
                    Text(animation == .scroll ? "Swipe up or tap to turn" : usesDragPreview ? "Drag or tap to turn  \u{203A}" : "Tap to turn  \u{203A}")
                        .font(.system(size: 11, weight: .heavy, design: .serif))
                        .foregroundStyle(palette.secondaryForeground)
                        .padding(.bottom, 8)
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture { advanceByTap(size: geo.size) }
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .local)
                    .onChanged { value in
                        updatePreviewDrag(value, size: geo.size)
                    }
                    .onEnded { value in
                        finishPreviewDrag(value, size: geo.size)
                    }
            )
        }
        .frame(height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.foregroundColor.opacity(0.12), lineWidth: 1)
        )
        .onChange(of: animation) { _, _ in
            previewCurl = nil
            scrollOffset = 0
            isScrollAnimating = false
        }
    }

    private var usesDragPreview: Bool {
        animation == .curl || animation == .rigid || animation == .testCurl
    }

    private func advanceByTap(size: CGSize) {
        guard previewCurl == nil else { return }
        if usesDragPreview {
            startPreviewCurl(direction: 1, size: size, progress: 0.001, verticalPull: 0, touchY: 0.5)
            resolvePreviewCurl(commit: true)
        } else if animation == .scroll {
            advanceScrollPage(direction: 1, size: size)
        } else {
            side = (side + 1) % samples.count
        }
    }

    private func advanceScrollPage(direction: Int, size: CGSize) {
        guard !isScrollAnimating else { return }
        isScrollAnimating = true
        let slideOut: CGFloat = direction > 0 ? -size.height : size.height
        let slideIn: CGFloat = direction > 0 ? size.height : -size.height
        Task { @MainActor in
            withAnimation(.easeIn(duration: 0.14)) { scrollOffset = slideOut }
            try? await Task.sleep(nanoseconds: 140_000_000)
            side = wrappedIndex(side + direction)
            scrollOffset = slideIn
            withAnimation(.easeOut(duration: 0.16)) { scrollOffset = 0 }
            try? await Task.sleep(nanoseconds: 160_000_000)
            isScrollAnimating = false
        }
    }

    private func updatePreviewDrag(_ value: DragGesture.Value, size: CGSize) {
        if animation == .scroll {
            guard !isScrollAnimating else { return }
            let dy = value.translation.height
            guard abs(dy) > 6, abs(dy) > abs(value.translation.width) * 0.45 else { return }
            scrollOffset = dy
            return
        }
        guard usesDragPreview else { return }
        let dx = value.translation.width
        let dy = value.translation.height
        guard abs(dx) > 6, abs(dx) > abs(dy) * 0.45 else { return }

        let direction = dx < 0 ? 1 : -1
        let progress = min(0.98, max(0.02, abs(dx) / max(size.width * 0.74, 1)))
        let verticalPull = max(-1, min(1, dy / max(size.height * 0.32, 1)))
        let touchY = max(0, min(1, value.startLocation.y / max(size.height, 1)))

        if let previewCurl {
            guard previewCurl.direction == direction else {
                self.previewCurl = nil
                startPreviewCurl(direction: direction, size: size, progress: progress, verticalPull: verticalPull, touchY: touchY)
                return
            }
            self.previewCurl?.progress = progress
            self.previewCurl?.verticalPull = verticalPull
            self.previewCurl?.touchY = touchY
        } else {
            startPreviewCurl(direction: direction, size: size, progress: progress, verticalPull: verticalPull, touchY: touchY)
        }
    }

    private func finishPreviewDrag(_ value: DragGesture.Value, size: CGSize) {
        if animation == .scroll {
            guard !isScrollAnimating else { return }
            let dy = value.translation.height
            let predictedDy = value.predictedEndTranslation.height
            let threshold = max(40, size.height * 0.25)
            if dy < -threshold || predictedDy < -threshold {
                advanceScrollPage(direction: 1, size: size)
            } else if dy > threshold || predictedDy > threshold {
                advanceScrollPage(direction: -1, size: size)
            } else {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { scrollOffset = 0 }
            }
            return
        }
        guard usesDragPreview, let previewCurl else { return }
        let threshold = max(44, size.width * 0.24)
        let dx = value.translation.width
        let predictedDx = value.predictedEndTranslation.width
        let commit = previewCurl.direction > 0
            ? dx < -threshold || predictedDx < -threshold
            : dx > threshold || predictedDx > threshold
        resolvePreviewCurl(commit: commit)
    }

    private func startPreviewCurl(direction: Int,
                                  size: CGSize,
                                  progress: CGFloat,
                                  verticalPull: CGFloat,
                                  touchY: CGFloat) {
        let target = wrappedIndex(side + direction)
        previewCurl = PreviewCurlState(
            from: snapshot(side, size: size),
            to: snapshot(target, size: size),
            direction: direction,
            target: target,
            progress: progress,
            verticalPull: verticalPull,
            touchY: touchY
        )
    }

    private func resolvePreviewCurl(commit: Bool) {
        guard let state = previewCurl else { return }
        Task { @MainActor in
            let start = state.progress
            let end: CGFloat = commit ? 1 : 0.001
            let frames = 18
            for frame in 1...frames {
                guard previewCurl?.id == state.id else { return }
                let t = CGFloat(frame) / CGFloat(frames)
                let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                previewCurl?.progress = start + (end - start) * eased
                try? await Task.sleep(nanoseconds: 11_000_000)
            }
            guard previewCurl?.id == state.id else { return }
            if commit { side = state.target }
            previewCurl = nil
        }
    }

    private func wrappedIndex(_ value: Int) -> Int {
        (value % samples.count + samples.count) % samples.count
    }

    @MainActor
    private func snapshot(_ idx: Int, size: CGSize) -> UIImage {
        let renderer = ImageRenderer(content: sampleSide(idx, size: size))
        renderer.scale = displayScale
        renderer.isOpaque = true
        return renderer.uiImage ?? UIImage()
    }

    private func sampleSide(_ idx: Int, size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(idx == 0 ? "Chapter One" : "continued")
                .font(.system(size: 11, weight: .bold, design: .serif))
                .tracking(1.5)
                .foregroundStyle(palette.accentColor)
            Text(samples[idx])
                .font(.system(size: CGFloat(fontSize) / 100 * 15, weight: .regular, design: .serif))
                .lineSpacing(4)
                .foregroundStyle(palette.foregroundColor.opacity(0.85))
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(palette.backgroundColor)
    }
}

private struct PreviewCurlState: Identifiable {
    let id = UUID()
    let from: UIImage
    let to: UIImage
    let direction: Int
    let target: Int
    var progress: CGFloat
    var verticalPull: CGFloat
    var touchY: CGFloat
}

private struct RigidTurnState: Identifiable {
    let id = UUID()
    let from: UIImage
    let to: UIImage
    let direction: Int
    let target: Int
    var progress: CGFloat
}

// MARK: - Full-screen animation tester

private struct OnboardingAnimationReaderDemo: View {
    @Binding var selectedAnimation: PageAnimation
    let fontSize: Int
    let palette: ReaderThemePalette.Palette
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    @State private var page = 0
    @State private var previewCurl: PreviewCurlState?
    @State private var rigidTurn: RigidTurnState?
    @State private var scrollOffset: CGFloat = 0
    @State private var isScrollAnimating = false

    private let samples = [
        "The room was quiet except for the soft turn of a page. BookMark keeps the words centered and the controls out of the way, so the book feels like the main event.",
        "When you swipe, the next page should already feel ready beneath your thumb. Try each style here, then keep the one that feels natural.",
        "A good reader disappears while you read. Your choice here becomes the default page turn when the tutorial ends.",
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                demoSurface(size: geo.size)
                    .ignoresSafeArea()

                topChrome
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                bottomChrome
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .background(palette.backgroundColor.ignoresSafeArea())
            .onChange(of: selectedAnimation) { _, _ in
                previewCurl = nil
                rigidTurn = nil
                scrollOffset = 0
                isScrollAnimating = false
            }
        }
    }

    @ViewBuilder
    private func demoSurface(size: CGSize) -> some View {
        switch selectedAnimation {
        case .testCurl:
            OnboardingUIKitCurlPager(index: $page, pages: demoPages(size: size), backgroundColor: palette.uiBackgroundColor)
        case .curl, .rigid:
            ZStack {
                demoPage(page, size: size)
                if let rigidTurn {
                    RigidTurnTransition(
                        current: rigidTurn.from,
                        destination: rigidTurn.to,
                        direction: rigidTurn.direction,
                        progress: rigidTurn.progress,
                        palette: palette
                    )
                    .id(rigidTurn.id)
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { startAndResolveRigidTurn(direction: 1, size: size) }
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .local)
                    .onChanged { updateRigidDrag($0, size: size) }
                    .onEnded { finishRigidDrag($0, size: size) }
            )
        case .scroll:
            ZStack {
                demoPage(page, size: size)
                    .offset(y: scrollOffset)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { advanceScrollPage(direction: 1, size: size) }
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .local)
                    .onChanged { updateScrollDrag($0, size: size) }
                    .onEnded { finishScrollDrag($0, size: size) }
            )
        default:
            OnboardingFlip(
                count: samples.count,
                index: $page,
                currentAnimation: selectedAnimation,
                forceFirstCurl: false,
                palette: palette,
                size: size,
                displayScale: displayScale
            ) { idx in
                demoPage(idx, size: size)
            }
            .contentShape(Rectangle())
            .onTapGesture { page = wrappedIndex(page + 1) }
            .gesture(
                DragGesture(minimumDistance: 24, coordinateSpace: .local)
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        if value.translation.width < -40 { page = wrappedIndex(page + 1) }
                        else if value.translation.width > 40 { page = wrappedIndex(page - 1) }
                    }
            )
        }
    }

    private var topChrome: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Page Turn Tester")
                    .font(.system(size: 17, weight: .heavy, design: .serif))
                Text("Page \(page + 1) of \(samples.count)")
                    .font(.system(size: 12, weight: .semibold, design: .serif))
                    .foregroundStyle(palette.secondaryForeground)
            }
            Spacer()
            Button { dismiss() } label: {
                Text("Done")
                    .font(.system(size: 15, weight: .heavy, design: .serif))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(palette.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(palette.foregroundColor)
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .background(.ultraThinMaterial)
    }

    private var bottomChrome: some View {
        VStack(spacing: 12) {
            Text(selectedAnimation == .testCurl ? "Drag the page edge to curl" : selectedAnimation == .scroll ? "Swipe up or down to turn" : "Tap or swipe the page to preview")
                .font(.system(size: 12, weight: .heavy, design: .serif))
                .foregroundStyle(palette.secondaryForeground)
            HStack(spacing: 7) {
                ForEach(animationChoices, id: \.anim) { choice in
                    animationButton(choice)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .background(.ultraThinMaterial)
    }

    private var animationChoices: [(anim: PageAnimation, label: String, icon: String)] {
        [
            (.none, "None", "nosign"),
            (.fade, "Fade", "circle.lefthalf.filled"),
            (.slide, "Slide", "arrow.left.and.right"),
            (.scroll, "Scroll", "arrow.up.and.down"),
            (.curl, "Rigid", "book.pages"),
            (.testCurl, "Realistic", "rectangle.portrait.on.rectangle.portrait.angled"),
        ]
    }


    private func animationButton(_ choice: (anim: PageAnimation, label: String, icon: String)) -> some View {
        let selected = selectedAnimation == choice.anim
        return Button {
            selectedAnimation = choice.anim
        } label: {
            VStack(spacing: 4) {
                Image(systemName: choice.icon)
                    .font(.system(size: 14, weight: .bold))
                    .frame(height: 16)
                Text(choice.label)
                    .font(.system(size: 9.5, weight: .heavy, design: .serif))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(selected ? .white : palette.foregroundColor)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(selected ? palette.accentColor : palette.foregroundColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func demoPages(size: CGSize) -> [AnyView] {
        samples.indices.map { AnyView(demoPage($0, size: size)) }
    }

    private func demoPage(_ idx: Int, size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Chapter Preview")
                .font(.system(size: 13, weight: .bold, design: .serif))
                .tracking(1.8)
                .foregroundStyle(palette.accentColor)
            Text(samples[idx])
                .font(.system(size: CGFloat(fontSize) / 100 * 25, weight: .regular, design: .serif))
                .lineSpacing(8)
                .foregroundStyle(palette.foregroundColor.opacity(0.88))
            Spacer()
            Text("Page \(idx + 1)")
                .font(.system(size: 14, weight: .heavy, design: .serif))
                .foregroundStyle(palette.secondaryForeground)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 34)
        .padding(.top, 118)
        .padding(.bottom, 142)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(palette.backgroundColor)
    }

    private func startAndResolveRigidTurn(direction: Int, size: CGSize) {
        guard rigidTurn == nil else { return }
        startRigidTurn(direction: direction, size: size, progress: 0.001)
        resolveRigidTurn(commit: true)
    }

    private func updateRigidDrag(_ value: DragGesture.Value, size: CGSize) {
        let dx = value.translation.width
        let dy = value.translation.height
        guard abs(dx) > 6, abs(dx) > abs(dy) * 0.45 else { return }
        let direction = dx < 0 ? 1 : -1
        let progress = min(0.98, max(0.02, abs(dx) / max(size.width * 0.72, 1)))

        if let rigidTurn {
            guard rigidTurn.direction == direction else { return }
            self.rigidTurn?.progress = progress
        } else {
            startRigidTurn(direction: direction, size: size, progress: progress)
        }
    }

    private func finishRigidDrag(_ value: DragGesture.Value, size: CGSize) {
        guard let rigidTurn else { return }
        let threshold = max(64, size.width * 0.20)
        let dx = value.translation.width
        let predictedDx = value.predictedEndTranslation.width
        let commit = rigidTurn.direction > 0
            ? dx < -threshold || predictedDx < -threshold
            : dx > threshold || predictedDx > threshold
        resolveRigidTurn(commit: commit)
    }

    private func startRigidTurn(direction: Int, size: CGSize, progress: CGFloat) {
        let target = wrappedIndex(page + direction)
        rigidTurn = RigidTurnState(
            from: snapshot(page, size: size),
            to: snapshot(target, size: size),
            direction: direction,
            target: target,
            progress: progress
        )
    }

    private func resolveRigidTurn(commit: Bool) {
        guard let state = rigidTurn else { return }
        Task { @MainActor in
            let start = state.progress
            let end: CGFloat = commit ? 1 : 0.001
            let frames = 18
            for frame in 1...frames {
                guard rigidTurn?.id == state.id else { return }
                let t = CGFloat(frame) / CGFloat(frames)
                let eased = 1 - pow(1 - t, 2.2)
                rigidTurn?.progress = start + (end - start) * eased
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            guard rigidTurn?.id == state.id else { return }
            if commit { page = state.target }
            rigidTurn = nil
        }
    }

    private func startAndResolveCurl(direction: Int, size: CGSize) {
        guard previewCurl == nil else { return }
        startPreviewCurl(direction: direction, size: size, progress: 0.001, verticalPull: 0, touchY: 0.5)
        resolvePreviewCurl(commit: true)
    }

    private func updatePreviewDrag(_ value: DragGesture.Value, size: CGSize) {
        let dx = value.translation.width
        let dy = value.translation.height
        guard abs(dx) > 6, abs(dx) > abs(dy) * 0.45 else { return }
        let direction = dx < 0 ? 1 : -1
        let progress = min(0.98, max(0.02, abs(dx) / max(size.width * 0.72, 1)))
        let verticalPull = max(-1, min(1, dy / max(size.height * 0.28, 1)))
        let touchY = max(0, min(1, value.startLocation.y / max(size.height, 1)))

        if let previewCurl {
            guard previewCurl.direction == direction else { return }
            self.previewCurl?.progress = progress
            self.previewCurl?.verticalPull = verticalPull
            self.previewCurl?.touchY = touchY
        } else {
            startPreviewCurl(direction: direction, size: size, progress: progress, verticalPull: verticalPull, touchY: touchY)
        }
    }

    private func finishPreviewDrag(_ value: DragGesture.Value, size: CGSize) {
        guard let previewCurl else { return }
        let threshold = max(64, size.width * 0.20)
        let dx = value.translation.width
        let predictedDx = value.predictedEndTranslation.width
        let commit = previewCurl.direction > 0
            ? dx < -threshold || predictedDx < -threshold
            : dx > threshold || predictedDx > threshold
        resolvePreviewCurl(commit: commit)
    }

    private func startPreviewCurl(direction: Int,
                                  size: CGSize,
                                  progress: CGFloat,
                                  verticalPull: CGFloat,
                                  touchY: CGFloat) {
        let target = wrappedIndex(page + direction)
        previewCurl = PreviewCurlState(
            from: snapshot(page, size: size),
            to: snapshot(target, size: size),
            direction: direction,
            target: target,
            progress: progress,
            verticalPull: verticalPull,
            touchY: touchY
        )
    }

    private func resolvePreviewCurl(commit: Bool) {
        guard let state = previewCurl else { return }
        Task { @MainActor in
            let start = state.progress
            let end: CGFloat = commit ? 1 : 0.001
            let frames = 24
            for frame in 1...frames {
                guard previewCurl?.id == state.id else { return }
                let t = CGFloat(frame) / CGFloat(frames)
                let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                previewCurl?.progress = start + (end - start) * eased
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            guard previewCurl?.id == state.id else { return }
            if commit { page = state.target }
            previewCurl = nil
        }
    }

    private func advanceScrollPage(direction: Int, size: CGSize) {
        guard !isScrollAnimating else { return }
        isScrollAnimating = true
        let slideOut: CGFloat = direction > 0 ? -size.height : size.height
        let slideIn: CGFloat = direction > 0 ? size.height : -size.height
        Task { @MainActor in
            withAnimation(.easeIn(duration: 0.14)) { scrollOffset = slideOut }
            try? await Task.sleep(nanoseconds: 140_000_000)
            page = wrappedIndex(page + direction)
            scrollOffset = slideIn
            withAnimation(.easeOut(duration: 0.16)) { scrollOffset = 0 }
            try? await Task.sleep(nanoseconds: 160_000_000)
            isScrollAnimating = false
        }
    }

    private func updateScrollDrag(_ value: DragGesture.Value, size: CGSize) {
        guard !isScrollAnimating else { return }
        let dy = value.translation.height
        guard abs(dy) > 6, abs(dy) > abs(value.translation.width) * 0.45 else { return }
        scrollOffset = dy
    }

    private func finishScrollDrag(_ value: DragGesture.Value, size: CGSize) {
        guard !isScrollAnimating else { return }
        let dy = value.translation.height
        let predictedDy = value.predictedEndTranslation.height
        let threshold = max(58, size.height * 0.15)
        if dy < -threshold || predictedDy < -threshold {
            advanceScrollPage(direction: 1, size: size)
        } else if dy > threshold || predictedDy > threshold {
            advanceScrollPage(direction: -1, size: size)
        } else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { scrollOffset = 0 }
        }
    }

    private func wrappedIndex(_ value: Int) -> Int {
        (value % samples.count + samples.count) % samples.count
    }

    @MainActor
    private func snapshot(_ idx: Int, size: CGSize) -> UIImage {
        let renderer = ImageRenderer(content: demoPage(idx, size: size))
        renderer.scale = displayScale
        renderer.isOpaque = true
        return renderer.uiImage ?? UIImage()
    }
}

private struct RigidTurnTransition: UIViewRepresentable {
    let current: UIImage
    let destination: UIImage
    let direction: Int
    let progress: CGFloat
    let palette: ReaderThemePalette.Palette

    func makeUIView(context: Context) -> RigidTurnHostView {
        RigidTurnHostView(current: current, destination: destination, direction: direction, palette: palette)
    }

    func updateUIView(_ uiView: RigidTurnHostView, context: Context) {
        uiView.update(progress: progress)
    }
}

@MainActor
private final class RigidTurnHostView: UIView {
    private let current: UIImage
    private let destination: UIImage
    private let direction: Int
    private let palette: ReaderThemePalette.Palette

    private var destinationView: UIImageView?
    private var sheetLayer: CALayer?
    private var foldShadow: CAGradientLayer?
    private var foldHighlight: CAGradientLayer?
    private var underShadow: CAGradientLayer?
    private var built = false
    private var pendingProgress: CGFloat = 0

    init(current: UIImage, destination: UIImage, direction: Int, palette: ReaderThemePalette.Palette) {
        self.current = current
        self.destination = destination
        self.direction = direction >= 0 ? 1 : -1
        self.palette = palette
        super.init(frame: .zero)
        backgroundColor = palette.uiBackgroundColor
        isUserInteractionEnabled = false
        layer.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1 else { return }
        if !built {
            built = true
            buildLayers()
        } else {
            destinationView?.frame = bounds
            rebuildSheetFrame()
        }
        update(progress: pendingProgress)
    }

    func update(progress: CGFloat) {
        pendingProgress = max(0, min(1, progress))
        guard built, bounds.width > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        apply(progress: pendingProgress)
        CATransaction.commit()
    }

    private func buildLayers() {
        let under = UIImageView(image: destination)
        under.frame = bounds
        under.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        under.contentMode = .scaleToFill
        under.backgroundColor = palette.uiBackgroundColor
        addSubview(under)
        destinationView = under

        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / 1200.0
        layer.sublayerTransform = perspective

        let sheet = CALayer()
        sheet.contents = current.cgImage
        sheet.contentsGravity = .resize
        sheet.magnificationFilter = .linear
        sheet.minificationFilter = .linear
        sheet.allowsEdgeAntialiasing = true
        sheet.masksToBounds = true
        sheet.isDoubleSided = false
        sheet.isOpaque = true
        sheet.contentsScale = current.scale
        sheet.shadowColor = UIColor.black.cgColor
        sheet.shadowOpacity = 0
        sheet.shadowRadius = 18
        sheet.shadowOffset = .zero
        layer.addSublayer(sheet)
        sheetLayer = sheet

        let overlays = createOverlays()
        foldShadow = overlays.shadow
        foldHighlight = overlays.highlight
        underShadow = overlays.under
        rebuildSheetFrame()
    }

    private func rebuildSheetFrame() {
        guard let sheetLayer else { return }
        let forward = direction > 0
        sheetLayer.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        sheetLayer.anchorPoint = CGPoint(x: forward ? 0 : 1, y: 0.5)
        sheetLayer.position = CGPoint(x: forward ? 0 : bounds.width, y: bounds.midY)
        foldShadow?.frame = bounds
        foldHighlight?.frame = bounds
        underShadow?.frame = bounds
    }

    private func createOverlays() -> (shadow: CAGradientLayer, highlight: CAGradientLayer, under: CAGradientLayer) {
        let forward = direction > 0

        let shadow = CAGradientLayer()
        shadow.colors = [
            UIColor.black.withAlphaComponent(0.0).cgColor,
            UIColor.black.withAlphaComponent(palette.isDark ? 0.55 : 0.35).cgColor,
            UIColor.black.withAlphaComponent(0.0).cgColor,
        ]
        shadow.locations = [0.0, 0.5, 1.0]
        shadow.startPoint = CGPoint(x: 0, y: 0.5)
        shadow.endPoint = CGPoint(x: 1, y: 0.5)
        shadow.opacity = 0
        layer.addSublayer(shadow)

        let highlight = CAGradientLayer()
        highlight.colors = [
            UIColor.white.withAlphaComponent(0.0).cgColor,
            UIColor.white.withAlphaComponent(palette.isDark ? 0.10 : 0.28).cgColor,
            UIColor.white.withAlphaComponent(0.0).cgColor,
        ]
        highlight.locations = [0.0, 0.5, 1.0]
        highlight.startPoint = CGPoint(x: 0, y: 0.5)
        highlight.endPoint = CGPoint(x: 1, y: 0.5)
        highlight.opacity = 0
        layer.addSublayer(highlight)

        let under = CAGradientLayer()
        under.colors = [
            UIColor.black.withAlphaComponent(palette.isDark ? 0.45 : 0.30).cgColor,
            UIColor.black.withAlphaComponent(0).cgColor,
        ]
        under.locations = [0.0, 1.0]
        under.startPoint = CGPoint(x: forward ? 1.0 : 0.0, y: 0.5)
        under.endPoint = CGPoint(x: forward ? 0.0 : 1.0, y: 0.5)
        under.opacity = 0
        layer.insertSublayer(under, above: destinationView?.layer)

        return (shadow, highlight, under)
    }

    private func apply(progress rawProgress: CGFloat) {
        guard let sheet = sheetLayer,
              let foldShadow,
              let foldHighlight,
              let underShadow else { return }
        let width = bounds.width
        let height = bounds.height
        let eased = rawProgress * rawProgress * (3 - 2 * rawProgress)
        let forward = direction > 0
        let edgeSign: CGFloat = forward ? -1 : 1
        let pull: CGFloat = 0
        let cornerBias: CGFloat = -0.64
        let lift = sin(.pi * rawProgress)
        let edgeTravel = width * 0.94 * eased
        let yPull = pull * height * 0.052 * lift
        let cornerLift = pull * cornerBias * height * 0.028 * lift
        let zLift = width * 0.13 * lift
        let rotationY = edgeSign * (.pi * 0.46) * eased
        let rotationX = pull * (.pi * 0.035) * lift
        let rotationZ = -edgeSign * pull * (.pi * 0.010) * lift

        var transform = CATransform3DIdentity
        transform = CATransform3DTranslate(transform, edgeSign * edgeTravel, yPull + cornerLift, zLift)
        transform = CATransform3DRotate(transform, rotationY, 0, 1, 0)
        transform = CATransform3DRotate(transform, rotationX, 1, 0, 0)
        transform = CATransform3DRotate(transform, rotationZ, 0, 0, 1)
        sheet.transform = transform
        sheet.zPosition = 100 + lift * 60
        sheet.shadowOpacity = Float(0.14 * lift + 0.08 * eased)
        sheet.shadowRadius = 16 + 12 * lift
        sheet.shadowOffset = CGSize(width: edgeSign * -8 * lift, height: 2 + 6 * lift)

        let foldX: CGFloat = forward ? width - edgeTravel : edgeTravel
        let foldBandWidth = max(44, width * (0.085 + 0.035 * lift))
        let shadowBandWidth = max(120, width * (0.22 + 0.08 * lift))
        foldHighlight.frame = CGRect(x: foldX - foldBandWidth / 2, y: 0, width: foldBandWidth, height: height)
        foldHighlight.opacity = Float(min(1.0, 0.35 + lift * 0.65) * min(1.0, rawProgress * 1.6))

        foldShadow.frame = CGRect(x: foldX - shadowBandWidth / 2, y: 0, width: shadowBandWidth, height: height)
        foldShadow.opacity = Float((0.28 + 0.42 * lift) * min(1.0, rawProgress * 1.4))

        let underWidth = max(120, width * (0.18 + 0.18 * eased))
        let underX: CGFloat = forward ? foldX - underWidth : foldX
        underShadow.frame = CGRect(x: underX, y: 0, width: underWidth, height: height)
        underShadow.opacity = Float(min(0.75, 0.18 + eased * 0.58))
    }
}

private struct OnboardingUIKitCurlPager: UIViewControllerRepresentable {
    @Binding var index: Int
    let pages: [AnyView]
    let backgroundColor: UIColor

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [UIPageViewController.OptionsKey.spineLocation: UIPageViewController.SpineLocation.min.rawValue]
        )
        controller.view.backgroundColor = backgroundColor
        controller.view.isOpaque = true
        controller.isDoubleSided = true
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        context.coordinator.tintPageCurlBacking(in: controller.view)
        controller.setViewControllers([context.coordinator.frontController(for: index)], direction: .forward, animated: false)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        uiViewController.view.backgroundColor = backgroundColor
        context.coordinator.tintPageCurlBacking(in: uiViewController.view)
        guard let current = uiViewController.viewControllers?.first as? DemoPageController, current.role == 0 else { return }
        guard current.index != index else { return }
        let direction: UIPageViewController.NavigationDirection = index > current.index ? .forward : .reverse
        uiViewController.setViewControllers([context.coordinator.frontController(for: index)], direction: direction, animated: true)
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: OnboardingUIKitCurlPager

        init(_ parent: OnboardingUIKitCurlPager) {
            self.parent = parent
        }

        func frontController(for index: Int) -> DemoPageController {
            let clamped = clampedIndex(index)
            let controller = DemoPageController(index: clamped, role: 0, rootView: parent.pages[clamped])
            controller.view.backgroundColor = parent.backgroundColor
            controller.view.isOpaque = true
            return controller
        }

        private func backingController(for index: Int, role: Int) -> DemoPageController {
            let clamped = clampedIndex(index)
            let alpha = backingTextAlpha(for: parent.backgroundColor)
            let backing = AnyView(
                ZStack {
                    Color(uiColor: parent.backgroundColor)
                    parent.pages[clamped]
                        .scaleEffect(x: -1, y: 1)
                        .opacity(alpha)
                }
            )
            let controller = DemoPageController(index: clamped, role: role, rootView: backing)
            controller.view.backgroundColor = parent.backgroundColor
            controller.view.isOpaque = true
            return controller
        }

        private func clampedIndex(_ index: Int) -> Int {
            max(0, min(parent.pages.count - 1, index))
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let controller = viewController as? DemoPageController else { return nil }
            switch controller.role {
            case 0:
                guard controller.index > 0 else { return nil }
                return backingController(for: controller.index, role: -2)
            case -2:
                return frontController(for: controller.index - 1)
            case 1:
                return backingController(for: controller.index, role: 2)
            default:
                return nil
            }
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let controller = viewController as? DemoPageController else { return nil }
            switch controller.role {
            case 0:
                guard controller.index < parent.pages.count - 1 else { return nil }
                return backingController(for: controller.index, role: 2)
            case 2:
                return frontController(for: controller.index + 1)
            case -1:
                return backingController(for: controller.index, role: -2)
            default:
                return nil
            }
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                spineLocationFor orientation: UIInterfaceOrientation) -> UIPageViewController.SpineLocation {
            pageViewController.isDoubleSided = true
            return .min
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                willTransitionTo pendingViewControllers: [UIViewController]) {
            retintCurlBacking(in: pageViewController.view)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            tintPageCurlBacking(in: pageViewController.view)
            guard completed, let current = pageViewController.viewControllers?.first as? DemoPageController, current.role == 0 else { return }
            parent.index = current.index
        }

        func retintCurlBacking(in view: UIView) {
            tintPageCurlBacking(in: view)
            for delay in [0.016, 0.05, 0.10] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.tintPageCurlBacking(in: view)
                }
            }
        }

        func tintPageCurlBacking(in view: UIView) {
            view.backgroundColor = parent.backgroundColor
            view.isOpaque = true
            view.layer.backgroundColor = parent.backgroundColor.cgColor
            for subview in view.subviews {
                tintPageCurlBacking(in: subview)
            }
        }

        private func backingTextAlpha(for color: UIColor) -> CGFloat {
            var white: CGFloat = 0
            var alpha: CGFloat = 0
            if color.getWhite(&white, alpha: &alpha) {
                return white < 0.35 ? 0.38 : 0.24
            }

            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
                let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                return luminance < 0.35 ? 0.38 : 0.24
            }

            return 0.30
        }
    }
}

private final class DemoPageController: UIHostingController<AnyView> {
    let index: Int
    let role: Int

    init(index: Int, role: Int, rootView: AnyView) {
        self.index = index
        self.role = role
        super.init(rootView: rootView)
    }

    @MainActor @preconcurrency required dynamic init?(coder aDecoder: NSCoder) {
        nil
    }
}

// MARK: - Page flip engine (None / Fade / Slide / realistic Metal curl)

private struct CurlState: Identifiable {
    let id = UUID()
    let from: UIImage
    let to: UIImage
    let direction: Int
}

private enum FlipTransitionKind { case none, fade, slide }

private struct OnboardingFlip<Page: View>: View {
    let count: Int
    @Binding var index: Int
    let currentAnimation: PageAnimation
    let forceFirstCurl: Bool
    let palette: ReaderThemePalette.Palette
    let size: CGSize
    let displayScale: CGFloat
    @ViewBuilder var page: (Int) -> Page

    @State private var displayed = 0
    @State private var curl: CurlState?
    @State private var transitionKind: FlipTransitionKind = .none
    @State private var slideForward = true
    @State private var inFlight = false
    @State private var turns = 0

    var body: some View {
        ZStack {
            page(displayed)
                .frame(width: size.width, height: size.height)
                .id(displayed)
                .transition(pageTransition)

            if let curl {
                CurlTransition(
                    current: curl.from,
                    destination: curl.to,
                    direction: curl.direction,
                    palette: palette,
                    onFinished: { finishCurl() }
                )
                .frame(width: size.width, height: size.height)
                .id(curl.id)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .onChange(of: index) { _, newValue in
            perform(to: newValue)
        }
    }

    private var pageTransition: AnyTransition {
        switch transitionKind {
        case .none: return .identity
        case .fade: return .opacity
        case .slide:
            return slideForward
                ? .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))
                : .asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing))
        }
    }

    private func perform(to target: Int) {
        let clamped = max(0, min(count - 1, target))
        guard clamped != displayed else { return }
        // Mid-curl taps are ignored; the curl's completion snaps to `index`.
        guard curl == nil else { return }
        if inFlight {
            displayed = clamped
            return
        }

        let forward = clamped > displayed
        let isFirst = turns == 0
        let anim = (isFirst && forceFirstCurl) ? .testCurl : currentAnimation
        turns += 1

        switch anim {
        case .curl, .rigid, .testCurl:
            let from = snapshot(displayed)
            transitionKind = .none
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { displayed = clamped }
            let to = snapshot(clamped)
            curl = CurlState(from: from, to: to, direction: forward ? 1 : -1)
        case .fade:
            transitionKind = .fade
            inFlight = true
            withAnimation(.easeInOut(duration: 0.32)) { displayed = clamped }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { inFlight = false }
        case .slide:
            transitionKind = .slide
            slideForward = forward
            inFlight = true
            withAnimation(.easeInOut(duration: 0.34)) { displayed = clamped }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { inFlight = false }
        case .scroll, .none:
            transitionKind = .none
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { displayed = clamped }
        }
    }

    private func finishCurl() {
        curl = nil
        inFlight = false
        if displayed != index {
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { displayed = max(0, min(count - 1, index)) }
        }
    }

    @MainActor
    private func snapshot(_ i: Int) -> UIImage {
        let renderer = ImageRenderer(content: page(i).frame(width: size.width, height: size.height))
        renderer.scale = displayScale
        renderer.isOpaque = true
        return renderer.uiImage ?? UIImage()
    }
}

// MARK: - Metal curl bridge

private struct CurlTransition: UIViewRepresentable {
    let current: UIImage
    let destination: UIImage
    let direction: Int
    let palette: ReaderThemePalette.Palette
    let onFinished: () -> Void

    func makeUIView(context: Context) -> CurlHostView {
        CurlHostView(
            current: current,
            destination: destination,
            direction: direction,
            palette: palette,
            onFinished: onFinished
        )
    }

    func updateUIView(_ uiView: CurlHostView, context: Context) {}
}

private struct InteractiveCurlTransition: UIViewRepresentable {
    let current: UIImage
    let destination: UIImage
    let direction: Int
    let progress: CGFloat
    let verticalPull: CGFloat
    let touchY: CGFloat
    let palette: ReaderThemePalette.Palette

    func makeUIView(context: Context) -> InteractiveCurlHostView {
        InteractiveCurlHostView(
            current: current,
            destination: destination,
            direction: direction,
            palette: palette
        )
    }

    func updateUIView(_ uiView: InteractiveCurlHostView, context: Context) {
        uiView.update(progress: progress, verticalPull: verticalPull, touchY: touchY)
    }
}

@MainActor
final class InteractiveCurlHostView: UIView {
    private let current: UIImage
    private let destination: UIImage
    private let direction: Int
    private let palette: ReaderThemePalette.Palette

    private var curl: MetalPageCurlView?
    private var built = false
    private var pendingProgress: CGFloat = 0.001
    private var pendingVerticalPull: CGFloat = 0
    private var pendingTouchY: CGFloat = 0.5

    init(current: UIImage,
         destination: UIImage,
         direction: Int,
         palette: ReaderThemePalette.Palette) {
        self.current = current
        self.destination = destination
        self.direction = direction
        self.palette = palette
        super.init(frame: .zero)
        backgroundColor = palette.uiBackgroundColor
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !built, bounds.width > 1, bounds.height > 1 else { return }
        built = true
        guard let view = MetalPageCurlView(
            frame: bounds,
            currentImage: current,
            destinationImage: destination,
            direction: direction,
            palette: palette
        ) else { return }
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(view)
        curl = view
        view.update(progress: pendingProgress, verticalPull: pendingVerticalPull, touchY: pendingTouchY)
    }

    func update(progress: CGFloat, verticalPull: CGFloat, touchY: CGFloat) {
        pendingProgress = progress
        pendingVerticalPull = verticalPull
        pendingTouchY = touchY
        curl?.update(progress: progress, verticalPull: verticalPull, touchY: touchY)
    }
}

/// Hosts the reader's `MetalPageCurlView` and drives a single 0->1 curl with a
/// display link, then reports completion so the SwiftUI layer can drop the
/// overlay onto the already-swapped destination page.
@MainActor
final class CurlHostView: UIView {
    private let current: UIImage
    private let destination: UIImage
    private let direction: Int
    private let palette: ReaderThemePalette.Palette
    private let onFinished: () -> Void

    private var curl: MetalPageCurlView?
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private let duration: CFTimeInterval = 0.72
    private var built = false
    private var finished = false

    init(current: UIImage,
         destination: UIImage,
         direction: Int,
         palette: ReaderThemePalette.Palette,
         onFinished: @escaping () -> Void) {
        self.current = current
        self.destination = destination
        self.direction = direction
        self.palette = palette
        self.onFinished = onFinished
        super.init(frame: .zero)
        backgroundColor = palette.uiBackgroundColor
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !built, bounds.width > 1, bounds.height > 1 else { return }
        built = true
        guard let view = MetalPageCurlView(
            frame: bounds,
            currentImage: current,
            destinationImage: destination,
            direction: direction,
            palette: palette
        ) else {
            finish()
            return
        }
        view.frame = bounds
        addSubview(view)
        curl = view
        startTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        let elapsed = CACurrentMediaTime() - startTime
        let t = max(0, min(1, elapsed / duration))
        // easeInOutQuad
        let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        curl?.update(progress: CGFloat(max(0.001, eased)), verticalPull: 0, touchY: 0.5)
        if t >= 1 { finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        link?.invalidate()
        link = nil
        onFinished()
    }
}
