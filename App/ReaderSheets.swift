import ReadiumShared
import SwiftUI

// MARK: - Reader Settings

struct ReaderSettingsSheet: View {
    @ObservedObject var model: ReaderModel
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Grabber()

                brightnessGroup
                fontGroup
                textSizeGroup
                themeGroup
                spacingGroup
                layoutGroup
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .background(model.theme.backgroundColor)
        .preferredColorScheme(model.theme.isDark ? .dark : .light)
        .onChange(of: model.settings) { _, new in
            store.readerSettings = new
            store.scheduleSave()
        }
    }

    private var brightnessGroup: some View {
        SettingsGroup {
            HStack(spacing: 12) {
                Text("🔅").font(.system(size: 16))
                Slider(value: Binding(
                    get: { Double(model.settings.brightness) },
                    set: { model.settings.brightness = Int($0) }
                ), in: 35...100)
                .tint(model.theme.accentColor)
                Text("🔆").font(.system(size: 16))
            }
        }
    }

    private var fontGroup: some View {
        SettingsGroup(title: "Font") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(ReaderFont.displayCases, id: \.self) { font in
                    Button {
                        model.settings.font = font
                    } label: {
                        Text(font.label)
                            .font(font.previewFont)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(model.settings.font == font ? model.theme.accentColor.opacity(0.22) : Color.gray.opacity(0.16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(model.settings.font == font ? model.theme.accentColor : Color.clear, lineWidth: 1.5)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var textSizeGroup: some View {
        SettingsGroup(title: "Text Size") {
            HStack(spacing: 14) {
                Button {
                    model.settings.fontSize = max(60, model.settings.fontSize - 10)
                } label: {
                    Text("A−")
                        .font(.system(size: 16, weight: .heavy))
                        .frame(width: 56, height: 44)
                        .background(Color.gray.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                Spacer()
                Text("\(model.settings.fontSize)%")
                    .font(.system(size: 17, weight: .heavy))
                Spacer()
                Button {
                    model.settings.fontSize = min(200, model.settings.fontSize + 10)
                } label: {
                    Text("A+")
                        .font(.system(size: 16, weight: .heavy))
                        .frame(width: 56, height: 44)
                        .background(Color.gray.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
            .foregroundStyle(model.theme.foregroundColor)
            ToggleRow(title: "Bold text", isOn: Binding(
                get: { model.settings.bold },
                set: { model.settings.bold = $0 }
            ))
        }
    }

    private var themeGroup: some View {
        SettingsGroup(title: "Theme") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(ReaderTheme.allCases, id: \.self) { t in
                    themeSwatch(t)
                }
            }
        }
    }

    private func themeSwatch(_ t: ReaderTheme) -> some View {
        let palette = ReaderThemePalette.resolve(t)
        let on = model.settings.theme == t
        return Button {
            model.settings.theme = t
        } label: {
            VStack(spacing: 4) {
                Text("Aa")
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(palette.foregroundColor)
                Text(t.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.foregroundColor.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(palette.backgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(on ? Color.blue : Color.gray.opacity(0.25), lineWidth: on ? 2 : 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private var spacingGroup: some View {
        SettingsGroup(title: "Line Spacing") {
            Picker("Line spacing", selection: Binding(
                get: { model.settings.lineHeight },
                set: { model.settings.lineHeight = $0 }
            )) {
                Text("Compact").tag(1.35)
                Text("Normal").tag(1.6)
                Text("Relaxed").tag(1.95)
            }
            .pickerStyle(.segmented)

            Text("MARGINS")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(model.theme.secondaryForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)

            Picker("Margins", selection: Binding(
                get: { model.settings.margins },
                set: { model.settings.margins = $0 }
            )) {
                Text("Narrow").tag(LayoutMargin.narrow)
                Text("Normal").tag(LayoutMargin.normal)
                Text("Wide").tag(LayoutMargin.wide)
            }
            .pickerStyle(.segmented)

            ToggleRow(title: "Justify text", isOn: Binding(
                get: { model.settings.justify },
                set: { model.settings.justify = $0 }
            ))
        }
    }

    private var layoutGroup: some View {
        SettingsGroup(title: "Page Turn") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(PageAnimation.allCases, id: \.self) { animation in
                    pageTurnButton(animation)
                }
            }

            Text("Slide uses Readium's native page advance. Fade, Rigid, and Curl use BookMark's transition layer while keeping Readium's EPUB layout.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            ToggleRow(title: "Swipe to turn pages", isOn: Binding(
                get: { model.settings.swipe },
                set: { model.settings.swipe = $0 }
            ))

            ToggleRow(title: "Keep screen awake", isOn: Binding(
                get: { model.settings.keepAwake },
                set: { model.settings.keepAwake = $0 }
            ))
        }
    }

    private var pageCountGroup: some View {
        SettingsGroup(title: "Page Count Mode") {
            VStack(spacing: 8) {
                ForEach(PageCountMode.allCases, id: \.self) { mode in
                    pageCountButton(mode)
                }
            }
            Text("Positions uses Readium's content-derived page count (~1024 chars each). Viewport Chapter uses Readium's dynamic per-chapter pagination. Paginated Book holds one viewport-derived book total until layout settings change.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private func pageCountButton(_ mode: PageCountMode) -> some View {
        let isSelected = model.settings.pageCountMode == mode
        return Button {
            model.settings.pageCountMode = mode
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? model.theme.accentColor : model.theme.foregroundColor.opacity(0.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.label)
                        .font(.system(size: 13, weight: .heavy))
                    Text(mode.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .foregroundStyle(isSelected ? model.theme.accentColor : model.theme.foregroundColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isSelected ? model.theme.accentColor.opacity(0.12) : Color.gray.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func pageTurnButton(_ animation: PageAnimation) -> some View {
        let isSelected = model.settings.pageAnim == animation
        return Button {
            model.settings.pageAnim = animation
        } label: {
            VStack(spacing: 6) {
                Image(systemName: animation.iconName)
                    .font(.system(size: 16, weight: .bold))
                Text(animation.label)
                    .font(.system(size: 12, weight: .heavy))
            }
            .foregroundStyle(isSelected ? model.theme.accentColor : model.theme.foregroundColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(isSelected ? model.theme.accentColor.opacity(0.20) : Color.gray.opacity(0.16))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? model.theme.accentColor : Color.clear, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

private extension PageCountMode {
    var label: String {
        switch self {
        case .positions: return "Positions"
        case .viewportChapter: return "Viewport Chapter"
        case .viewportBook: return "Viewport Book"
        case .paginatedBook: return "Paginated Book"
        }
    }

    var subtitle: String {
        switch self {
        case .positions: return "Page X of 1333 · stable"
        case .viewportChapter: return "Page X of Y in chapter · dynamic"
        case .viewportBook: return "Page X of Y total · Apple Books–style"
        case .paginatedBook: return "Stable Page X of Y · offset based"
        }
    }
}

private extension PageAnimation {
    var label: String {
        switch self {
        case .slide: return "Slide"
        case .fade: return "Fade"
        case .rigid: return "Rigid"
        case .curl: return "Curl"
        case .none: return "None"
        }
    }

    var iconName: String {
        switch self {
        case .slide: return "arrow.left.and.right"
        case .fade: return "circle.lefthalf.filled"
        case .rigid: return "rectangle.portrait.rotate"
        case .curl: return "text.page.badge.magnifyingglass"
        case .none: return "nosign"
        }
    }
}

private extension ReaderFont {
    static var displayCases: [ReaderFont] {
        [.original, .georgia, .palatino, .charter, .times, .sans]
    }

    var label: String {
        switch self {
        case .original: return "Original"
        case .georgia: return "Georgia"
        case .palatino: return "Palatino"
        case .charter: return "Charter"
        case .times: return "Times"
        case .sans, .system: return "Modern"
        case .serif: return "Serif"
        case .rounded: return "Rounded"
        case .mono: return "Mono"
        }
    }

    var previewFont: Font {
        switch self {
        case .georgia, .palatino, .charter, .times, .serif:
            return .system(size: 14, weight: .bold, design: .serif)
        case .mono:
            return .system(size: 14, weight: .bold, design: .monospaced)
        case .rounded:
            return .system(size: 14, weight: .bold, design: .rounded)
        default:
            return .system(size: 14, weight: .bold)
        }
    }
}

private extension ReaderTheme {
    var label: String {
        switch self {
        case .original: return "Original"
        case .quiet:    return "Quiet"
        case .paper:    return "Paper"
        case .calm:     return "Calm"
        case .focus:    return "Focus"
        case .night:    return "Night"
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(14)
        .background(Color.gray.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }
}

private struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden()
        }
        .padding(.top, 6)
    }
}

// MARK: - Reader Search

struct ReaderSearchSheet: View {
    let publication: Publication
    @ObservedObject var model: ReaderModel
    let onSelect: (String) -> Void

    @State private var query = ""
    @State private var results: [Locator] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Grabber()
            HStack {
                Text("Search")
                    .font(.system(size: 18, weight: .heavy))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(model.theme.secondaryForeground)
                TextField("Search in book", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { runSearch() }
                if !query.isEmpty {
                    Button {
                        query = ""
                        results = []
                        errorMessage = nil
                        searchTask?.cancel()
                        isSearching = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(model.theme.secondaryForeground)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color.gray.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            if isSearching {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching...")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.theme.secondaryForeground)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    if !isSearching && results.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(results.enumerated()), id: \.offset) { _, locator in
                            Button {
                                if let locatorJSON = try? locator.jsonString() {
                                    onSelect(locatorJSON)
                                }
                            } label: {
                                searchResultRow(locator)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .background(model.theme.backgroundColor)
        .preferredColorScheme(model.theme.isDark ? .dark : .light)
        .onDisappear {
            searchTask?.cancel()
            searchTask = nil
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "text.magnifyingglass" : "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Search this book" : "No results")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 42)
    }

    private func searchResultRow(_ locator: Locator) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = locator.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(title)
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(model.theme.accentColor)
                    .lineLimit(1)
            }
            snippetText(locator)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(model.theme.foregroundColor)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(Divider().padding(.leading, 16), alignment: .bottom)
        .contentShape(Rectangle())
    }

    private func snippetText(_ locator: Locator) -> Text {
        let text = locator.text.sanitized()
        var result = AttributedString(text.before ?? "")
        var highlight = AttributedString(text.highlight ?? "")
        highlight.foregroundColor = model.theme.accentColor
        highlight.font = .body.weight(.heavy)
        result.append(highlight)
        result.append(AttributedString(text.after ?? ""))
        return Text(result)
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            errorMessage = nil
            return
        }

        searchTask?.cancel()
        results = []
        errorMessage = nil
        isSearching = true

        searchTask = Task {
            switch await publication.search(query: trimmed) {
            case .success(let iterator):
                // Readium now releases the iterator's resources on deinit, so
                // we no longer call the deprecated close() explicitly.
                var collected: [Locator] = []
                while !Task.isCancelled && collected.count < 100 {
                    switch await iterator.next() {
                    case .success(let collection):
                        guard let collection else {
                            await MainActor.run { isSearching = false }
                            return
                        }
                        collected.append(contentsOf: collection.locators)
                        if collected.count > 100 {
                            collected = Array(collected.prefix(100))
                        }
                        await MainActor.run { results = collected }
                    case .failure(let error):
                        await MainActor.run {
                            errorMessage = "Search failed: \(String(describing: error))"
                            isSearching = false
                        }
                        return
                    }
                }
                await MainActor.run { isSearching = false }
            case .failure(let error):
                await MainActor.run {
                    errorMessage = "Search failed: \(String(describing: error))"
                    isSearching = false
                }
            }
        }
    }
}

// MARK: - Reader Contents (Chapters + Bookmarks)

private struct ReaderContentsChapterRow: Identifiable {
    let id: String
    let title: String
    let chapterIndex: Int
    let depth: Int
}

struct ReaderContentsSheet: View {
    @ObservedObject var model: ReaderModel
    let bookId: String
    let initialTab: ContentTab
    let onJump: (Int, Int?) -> Void
    let onLocatorJump: (String) -> Void
    var onSelectChapter: (Int) -> Void { { onJump($0, nil) } }
    @EnvironmentObject private var store: Store
    @State private var tab: ContentTab = .chapters

    enum ContentTab { case chapters, bookmarks }

    var body: some View {
        VStack(spacing: 0) {
            Grabber()
            HStack {
                Text(tab == .chapters ? "Contents" : "Bookmarks")
                    .font(.system(size: 18, weight: .heavy))
                    .frame(maxWidth: .infinity)
            }
            .padding(.bottom, 12)

            Picker("", selection: $tab) {
                Text("Chapters").tag(ContentTab.chapters)
                Text("Bookmarks").tag(ContentTab.bookmarks)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            switch tab {
            case .chapters:
                chaptersList
            case .bookmarks:
                bookmarksList
            }
        }
        .background(model.theme.backgroundColor)
        .preferredColorScheme(model.theme.isDark ? .dark : .light)
        .onAppear { tab = initialTab }
    }

    private var chaptersList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    let rows = chapterRows
                    if !rows.isEmpty {
                        ForEach(rows) { row in
                            Button {
                                onSelectChapter(row.chapterIndex)
                            } label: {
                                HStack(spacing: 10) {
                                    Text(row.title)
                                        .font(.system(size: 15, weight: chapterTitleWeight(row)))
                                        .foregroundStyle(model.theme.foregroundColor)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                    if row.chapterIndex == model.chapterIndex {
                                        Image(systemName: "book.fill")
                                            .foregroundStyle(model.theme.accentColor)
                                    }
                                }
                                .padding(.leading, 16 + CGFloat(min(row.depth, 3)) * 28)
                                .padding(.trailing, 16)
                                .padding(.vertical, 14)
                                .background(chapterRowBackground(isCurrent: row.chapterIndex == model.chapterIndex))
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(Color.primary.opacity(0.12))
                                        .frame(height: 1)
                                        .padding(.leading, 16 + CGFloat(min(row.depth, 3)) * 28)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(row.id)
                        }
                    } else {
                        Text("No chapters")
                            .padding(.vertical, 28)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onAppear { scrollToCurrentChapter(proxy) }
            .onChange(of: tab) { _, newTab in
                if newTab == .chapters {
                    scrollToCurrentChapter(proxy)
                }
            }
            .onChange(of: model.chapterIndex) { _, _ in
                if tab == .chapters {
                    scrollToCurrentChapter(proxy)
                }
            }
        }
    }

    private var chapterRows: [ReaderContentsChapterRow] {
        guard let pkg = model.package, !pkg.spine.isEmpty else { return [] }
        let tocRows = pkg.toc.enumerated().compactMap { offset, entry -> ReaderContentsChapterRow? in
            guard let chapterIndex = spineIndex(for: entry.href, in: pkg) else { return nil }
            let title = entry.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return ReaderContentsChapterRow(
                id: "toc-\(offset)-\(chapterIndex)",
                title: title,
                chapterIndex: chapterIndex,
                depth: max(0, entry.depth)
            )
        }
        if !tocRows.isEmpty { return tocRows }

        return pkg.spine.enumerated().map { idx, entry in
            ReaderContentsChapterRow(
                id: "spine-\(idx)",
                title: chapterDisplayTitle(idx: idx, fallback: entry.title),
                chapterIndex: idx,
                depth: 0
            )
        }
    }

    private func chapterRowBackground(isCurrent: Bool) -> some ShapeStyle {
        isCurrent ? AnyShapeStyle(model.theme.accentColor.opacity(0.16)) : AnyShapeStyle(Color.clear)
    }

    private func chapterTitleWeight(_ row: ReaderContentsChapterRow) -> Font.Weight {
        if row.chapterIndex == model.chapterIndex { return .heavy }
        return row.depth == 0 ? .heavy : .semibold
    }

    private func scrollToCurrentChapter(_ proxy: ScrollViewProxy) {
        guard let targetId = chapterRows.first(where: { $0.chapterIndex == model.chapterIndex })?.id else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(targetId, anchor: .center)
            }
        }
    }

    private func chapterDisplayTitle(idx: Int, fallback: String) -> String {
        if idx == model.chapterIndex, let live = model.readiumChapterTitle, !live.isEmpty {
            return live
        }
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Chapter \(idx + 1)" : trimmed
    }

    private func spineIndex(for href: String, in package: EPUBPackage) -> Int? {
        let target = normalizedHref(href)
        return package.spine.firstIndex { entry in
            let spineHref = normalizedHref(entry.href)
            return target == spineHref || target.hasPrefix("\(spineHref)#")
        }
    }

    private func normalizedHref(_ href: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        return decoded
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var bookmarksList: some View {
        ScrollView {
            VStack(spacing: 0) {
                let list = (store.bookmarks[bookId] ?? []).sorted { $0.createdAt > $1.createdAt }
                if list.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "bookmark")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("No bookmarks yet")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("Tap the bookmark icon in the reader to save the current page.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .padding(.vertical, 36)
                } else {
                    ForEach(list) { bm in
                        HStack(spacing: 12) {
                            Image(systemName: "bookmark.fill")
                                .foregroundStyle(Theme.gold)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bookmarkDisplayTitle(bm))
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(model.theme.foregroundColor)
                                    .lineLimit(1)
                                Text("Saved \(Fmt.compactDate(bm.createdAt, includeYear: true))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                deleteBookmark(bm)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .padding(4)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(Color.primary.opacity(0.12))
                                .frame(height: 1)
                                .padding(.leading, 16)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            jumpTo(bm)
                        }
                    }
                }
            }
        }
    }

    private func deleteBookmark(_ bm: Bookmark) {
        var list = store.bookmarks[bookId] ?? []
        list.removeAll { $0.id == bm.id }
        store.bookmarks[bookId] = list
        store.scheduleSave()
    }

    private func bookmarkDisplayTitle(_ bm: Bookmark) -> String {
        let parts = bm.label
            .split(separator: "·", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if parts.count == 2, parts[0] == parts[1] {
            return parts[0]
        }
        if bm.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let page = bm.page {
            return "Page \(page)"
        }
        return bm.label
    }

    private func jumpTo(_ bm: Bookmark) {
        if bm.cfi.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            onLocatorJump(bm.cfi)
            return
        }

        // cfi format we set: "ch:<chapter>:p<page>"
        let parts = bm.cfi.split(separator: ":")
        guard parts.count >= 2,
              let ch = Int(parts[1])
        else { return }
        onSelectChapter(ch)
    }
}
