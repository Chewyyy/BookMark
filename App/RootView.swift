import SwiftUI

enum Tab: Hashable { case library, journal, stats }

struct RootView: View {
    @EnvironmentObject private var store: Store
    @State private var tab: Tab = .library
    @State private var readingBookId: String? = nil
    @State private var missingBook: Book?
    @State private var relinkError: String?
    @State private var readerToastMessage: String?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                Group {
                    switch tab {
                    case .library: LibraryView(onOpenBook: openBook, onOpenJournal: { tab = .journal })
                    case .journal: JournalView()
                    case .stats:   StatsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                BottomNav(selected: $tab)
            }
            if let readerToastMessage {
                VStack {
                    Spacer()
                    ToastView(text: readerToastMessage)
                        .padding(.bottom, 88)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .allowsHitTesting(false)
            }
        }
        .fullScreenCover(item: Binding(
            get: { readingBookId.map { BookIDWrapper(id: $0) } },
            set: { readingBookId = $0?.id }
        )) { wrapper in
            ReaderView(bookId: wrapper.id) { elapsed in
                showReaderToast(elapsed: elapsed)
            }
                .environmentObject(store)
        }
        .sheet(item: $missingBook) { book in
            RelinkEPUBSheet(
                book: book,
                onRelink: { url in
                    relink(book: book, with: url)
                },
                onClose: {
                    missingBook = nil
                }
            )
            .presentationDetents([.medium])
        }
        .alert("Could Not Relink EPUB", isPresented: Binding(
            get: { relinkError != nil },
            set: { if !$0 { relinkError = nil } }
        )) {
            Button("OK", role: .cancel) { relinkError = nil }
        } message: {
            Text(relinkError ?? "")
        }
    }

    private func openBook(_ id: String) {
        guard let book = store.books.first(where: { $0.id == id }) else { return }
        if store.epubFileExists(for: book) {
            readingBookId = id
        } else {
            missingBook = book
        }
    }

    private func relink(book: Book, with url: URL) {
        Task {
            let result = await EPUBImporter.relinkBook(id: book.id, with: url, into: store)
            switch result {
            case .success:
                missingBook = nil
                readingBookId = book.id
            case .unreadable:
                relinkError = "Choose a readable EPUB file for \(book.title)."
            }
        }
    }

    private func showReaderToast(elapsed: Int) {
        let message = "Read for \(Fmt.duration(elapsed))"
        withAnimation(.easeOut(duration: 0.18)) {
            readerToastMessage = message
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.18)) {
                    if readerToastMessage == message {
                        readerToastMessage = nil
                    }
                }
            }
        }
    }
}

private struct BookIDWrapper: Identifiable { let id: String }

private struct BottomNav: View {
    @Binding var selected: Tab

    var body: some View {
        HStack(spacing: 0) {
            navButton(.library, label: "Library", system: "books.vertical")
            navButton(.journal, label: "Journal", system: "calendar")
            navButton(.stats,   label: "Stats",   system: "chart.bar")
        }
        .padding(.top, 6)
        .padding(.bottom, 0)
        .background(
            Theme.cardOverlay
                .background(.ultraThinMaterial)
                .overlay(Divider(), alignment: .top)
                .ignoresSafeArea(.container, edges: .bottom)
        )
    }

    private func navButton(_ t: Tab, label: String, system: String) -> some View {
        Button {
            selected = t
        } label: {
            VStack(spacing: 3) {
                Image(systemName: system)
                    .font(.system(size: 20, weight: .semibold))
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(selected == t ? Theme.accent : Theme.subtle)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
