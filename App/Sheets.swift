import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Missing EPUB Recovery

struct RelinkEPUBSheet: View {
    let book: Book
    let onRelink: (URL) -> Void
    let onClose: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showFilePicker = false

    var body: some View {
        VStack(spacing: 0) {
            Grabber()
            VStack(spacing: 4) {
                Text("Missing EPUB File")
                    .font(.system(size: 16, weight: .heavy))
                Text(book.title)
                    .font(.system(size: 13, weight: .bold))
                    .multilineTextAlignment(.center)
                Text("Choose the EPUB file again to keep this book's progress, sessions, and bookmarks.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtle)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 14)

            ActionGroup {
                ActionRow(icon: "link", title: "Relink EPUB", action: { showFilePicker = true })
                ActionRow(icon: "xmark", title: "Close Reader", action: {
                    dismiss()
                    onClose()
                })
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .background(Theme.background)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType(filenameExtension: "epub") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            dismiss()
            onRelink(url)
        }
    }
}

// MARK: - Book Actions

struct BookActionsSheet: View {
    let book: Book
    let onContinue: () -> Void
    let onFinish: () -> Void
    let onDetails: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Grabber()
            VStack(spacing: 4) {
                Text(book.title).font(.system(size: 16, weight: .heavy)).multilineTextAlignment(.center)
                Text(book.author).font(.system(size: 12)).foregroundStyle(Theme.subtle)
            }
            .padding(.bottom, 14)

            ActionGroup {
                ActionRow(icon: "book", title: "Continue Reading", action: onContinue)
                ActionRow(
                    icon: book.finished ? "calendar.badge.clock" : "checkmark.seal",
                    title: book.finished ? "Edit Finish Date" : "Mark as Finished",
                    action: onFinish
                )
                ActionRow(icon: "info.circle", title: "Book Details", action: onDetails)
                ActionRow(icon: "trash", title: "Remove from Library", destructive: true, action: onRemove)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .background(Theme.background)
    }
}

// MARK: - Book Details

struct BookDetailsSheet: View {
    let book: Book
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    private var totalSecs: Int { store.sessionsForBook(book).reduce(0) { $0 + $1.secs } }
    private var sessionCount: Int { store.sessionsForBook(book).count }
    private var pct: Int { Int((store.progress[book.id]?.pct ?? 0) * 100) }

    private var lengthValue: String? {
        guard let total = book.totalWords, total > 0 else { return nil }
        let pages = EPUBWordCounter.standardizedPages(
            forWords: total,
            wordsPerPage: store.resolvedWordsPerPageForCurrentDevice()
        )
        return "\(pages.formatted()) pages"
    }

    /// Estimated minutes left in the book at the user's learned pace.
    /// Position derived from saved progress percentage × totalWords, since
    /// the reader isn't open here.
    private var timeRemainingValue: String? {
        guard let totalWords = book.totalWords, totalWords > 0 else { return nil }
        let pct = store.progress[book.id]?.pct ?? 0
        let currentOffset = Int(Double(totalWords) * max(0, min(1, pct)))
        guard let wpm = ReadingSpeedEstimator.wpm(forBookID: book.id, sessions: store.sessions),
              let mins = ReadingSpeedEstimator.minutesRemainingInBook(
                book: book,
                currentWordOffset: currentOffset,
                wpm: wpm
              ),
              mins > 0
        else { return nil }
        return "~\(Fmt.duration(mins * 60))"
    }

    var body: some View {
        VStack(spacing: 0) {
            Grabber()
            VStack(spacing: 4) {
                Text(book.title).font(.system(size: 16, weight: .heavy)).multilineTextAlignment(.center)
                Text(book.author).font(.system(size: 12)).foregroundStyle(Theme.subtle)
            }
            .padding(.bottom, 14)

            ActionGroup {
                if let lengthValue {
                    DetailRow(label: "Length", value: lengthValue)
                }
                if !book.finished, let timeRemainingValue {
                    DetailRow(label: "Time remaining", value: timeRemainingValue)
                }
                DetailRow(label: "Progress", value: "\(pct)%")
                DetailRow(label: "Time read", value: Fmt.duration(totalSecs))
                DetailRow(label: "Sessions", value: "\(sessionCount)")
                DetailRow(label: "Added", value: Fmt.longDate(book.added))
                if book.finished, let f = book.finishedAt {
                    DetailRow(label: "Finished", value: Fmt.dateAndTime(f))
                }
            }
            .padding(.bottom, 12)

            ActionGroup {
                Button { dismiss() } label: {
                    Text("Done")
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(Theme.text)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .background(Theme.background)
    }
}

// MARK: - Goal Editor

struct GoalEditorSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var minutes: Int = 15
    @State private var customText: String = ""
    @State private var reminderEnabled = true
    @State private var reminderTime = Date()

    private let chips = [10, 15, 20, 30, 45, 60, 90, 120]

    var body: some View {
        VStack(spacing: 0) {
            Grabber()
            VStack(spacing: 4) {
                Text("Daily Reading Goal").font(.system(size: 16, weight: .heavy))
                Text("Days you meet this goal count toward your streak.")
                    .font(.system(size: 12)).foregroundStyle(Theme.subtle)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 14)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(chips, id: \.self) { v in
                    Button {
                        minutes = v
                        customText = ""
                    } label: {
                        Text("\(v)")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(minutes == v ? Theme.accent : Theme.text)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(minutes == v ? Theme.accent.opacity(0.08) : Theme.card)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.cornerSmall)
                                    .stroke(minutes == v ? Theme.accent : Theme.border, lineWidth: 2)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 6) {
                Text("CUSTOM (MINUTES PER DAY)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.subtle)
                    .tracking(0.5)
                TextField("e.g. 25", text: $customText)
                    .keyboardType(.numberPad)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .background(Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cornerSmall)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
                    .onChange(of: customText) { _, new in
                        if let v = Int(new), v > 0 { minutes = v }
                    }
            }
            .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $reminderEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reading Reminder")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.text)
                        Text("Only sends if you still have minutes left.")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.subtle)
                    }
                }
                .tint(Theme.accent)

                if reminderEnabled {
                    DatePicker("Reminder Time", selection: $reminderTime, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.compact)
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .padding(14)
            .background(Theme.card)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerSmall)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
            .padding(.bottom, 16)

            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cornerSmall)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
                }
                .buttonStyle(.plain)
                Button {
                    store.goal.minutes = max(1, minutes)
                    store.goal.reminderEnabled = reminderEnabled
                    let comps = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
                    store.goal.reminderHour = comps.hour ?? 18
                    store.goal.reminderMinute = comps.minute ?? 0
                    store.scheduleSave()
                    Task {
                        await ReadingReminderScheduler.reschedule(for: store, requestAuthorizationIfNeeded: reminderEnabled)
                    }
                    dismiss()
                } label: {
                    Text("Save Goal")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .background(Theme.background)
        .onAppear {
            minutes = store.goal.minutes
            reminderEnabled = store.goal.reminderEnabled
            reminderTime = reminderDate(hour: store.goal.reminderHour, minute: store.goal.reminderMinute)
        }
    }

    private func reminderDate(hour: Int, minute: Int) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = min(23, max(0, hour))
        comps.minute = min(59, max(0, minute))
        return Calendar.current.date(from: comps) ?? Date()
    }
}

// MARK: - Finish Date

struct FinishDateSheet: View {
    let book: Book
    let onDone: () -> Void
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date = Date()

    var body: some View {
        VStack(spacing: 0) {
            Grabber()
            VStack(spacing: 4) {
                Text(book.finished ? "Edit Finish Date" : "Mark as Finished")
                    .font(.system(size: 16, weight: .heavy))
                Text("Set when you finished this book — backdate it if you finished it elsewhere.")
                    .font(.system(size: 12)).foregroundStyle(Theme.subtle)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 6) {
                Text("FINISHED ON")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.subtle)
                    .tracking(0.5)
                DatePicker("", selection: $date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .background(Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cornerSmall)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
            }
            .padding(.bottom, 16)

            HStack(spacing: 10) {
                if book.finished {
                    Button {
                        store.markUnfinished(id: book.id)
                        dismiss(); onDone()
                    } label: {
                        Text("Mark Unfinished")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.card)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.cornerSmall)
                                    .stroke(Theme.border, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cornerSmall)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
                }
                .buttonStyle(.plain)
                Button {
                    store.markFinished(id: book.id, on: date)
                    dismiss(); onDone()
                } label: {
                    Text("Save")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .background(Theme.background)
        .onAppear { date = book.finishedAt ?? Date() }
    }
}

// MARK: - Day Detail

struct DayDetailSheet: View {
    @State private var dayKey: String
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var selectedBookId: String = ""
    @State private var minutesText: String = ""
    @State private var pagesText: String = ""
    @State private var startTime: Date = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var hasEndTime: Bool = false
    @State private var endTime: Date = Calendar.current.date(bySettingHour: 20, minute: 30, second: 0, of: Date()) ?? Date()
    @State private var editingSession: ReadingSession?

    init(dayKey: String) {
        _dayKey = State(initialValue: dayKey)
    }

    private var dayDate: Date {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return Date() }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) ?? Date()
    }

    private func shiftDay(by delta: Int) {
        let cal = Calendar.current
        guard let newDate = cal.date(byAdding: .day, value: delta, to: dayDate) else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            dayKey = Fmt.dayKey(newDate)
        }
    }

    private var daySessions: [ReadingSession] {
        store.sessions
            .filter { Fmt.dayKey($0.start) == dayKey }
            .sorted { $0.start < $1.start }
    }

    private var dayTotal: Int { daySessions.reduce(0) { $0 + $1.secs } }

    private var isFutureDay: Bool {
        let cal = Calendar.current
        return cal.startOfDay(for: dayDate) > cal.startOfDay(for: Date())
    }

    private var goalMet: Bool {
        Fmt.minutes(dayTotal) >= max(1, store.goal.minutes)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Grabber()
                HStack(spacing: 16) {
                    Button {
                        shiftDay(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 36, height: 36)
                            .background(Theme.accent.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Previous day")

                    Text(Fmt.longDate(dayDate))
                        .font(.system(size: 16, weight: .heavy))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)

                    Button {
                        shiftDay(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 36, height: 36)
                            .background(Theme.accent.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next day")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

                HStack(spacing: 6) {
                    Text(Fmt.duration(dayTotal))
                        .foregroundStyle(Theme.accent)
                        .fontWeight(.heavy)
                    Text("read · goal \(max(1, store.goal.minutes)) min")
                        .foregroundStyle(Theme.subtle)
                    if goalMet {
                        Text("· ✅ goal met")
                            .foregroundStyle(Theme.accent)
                            .fontWeight(.bold)
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

                if daySessions.isEmpty {
                    Text("No sessions on this day yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.subtle)
                        .padding(.vertical, 18)
                } else {
                    VStack(spacing: 8) {
                        ForEach(daySessions) { s in
                            sessionRow(s)
                        }
                    }
                    .padding(.bottom, 12)
                }

                Divider().padding(.vertical, 4)

                if isFutureDay {
                    Text("You can't log a reading session for a future day.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.subtle)
                        .multilineTextAlignment(.center)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                } else {
                    Text("Add a reading session")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.subtle)
                        .tracking(0.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 10)
                        .padding(.bottom, 6)

                    Menu {
                        Button("Manual entry") { selectedBookId = "" }
                        ForEach(store.books) { b in
                            Button(b.title) { selectedBookId = b.id }
                        }
                    } label: {
                        HStack {
                            Text(selectedBookLabel)
                                .foregroundStyle(Theme.text)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .foregroundStyle(Theme.subtle)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 13)
                        .background(Theme.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cornerSmall)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
                    }
                    .padding(.bottom, 10)

                    HStack(spacing: 10) {
                        field("Minutes", text: $minutesText, keyboard: .numberPad)
                        field("Pages", text: $pagesText, keyboard: .numberPad)
                    }
                    .padding(.bottom, 10)

                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("START TIME")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.subtle)
                            DatePicker("", selection: $startTime, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("END TIME")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Theme.subtle)
                                Spacer()
                                Toggle("", isOn: $hasEndTime).labelsHidden().scaleEffect(0.7)
                            }
                            if hasEndTime {
                                DatePicker("", selection: $endTime, displayedComponents: .hourAndMinute)
                                    .labelsHidden()
                            } else {
                                Text("optional")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.subtle.opacity(0.6))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.bottom, 12)
                }

                HStack(spacing: 10) {
                    Button { dismiss() } label: {
                        Text("Close")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.card)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.cornerSmall)
                                    .stroke(Theme.border, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
                    }
                    .buttonStyle(.plain)
                    if !isFutureDay {
                        Button { addSession() } label: {
                            Text("Add Session")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
                        }
                        .buttonStyle(.plain)
                        .disabled(!sessionValid)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .onAppear {
            if let first = store.continueBook() { selectedBookId = first.id }
        }
        .sheet(item: $editingSession) { s in
            SessionEditorSheet(session: s)
                .presentationDetents([.large])
        }
    }

    private var selectedBookLabel: String {
        if selectedBookId.isEmpty { return "Manual entry" }
        return store.books.first { $0.id == selectedBookId }?.title ?? "Manual entry"
    }

    private func sessionRow(_ s: ReadingSession) -> some View {
        HStack(spacing: 12) {
            Circle().fill(s.manual ? Theme.gold : Theme.accent).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.bookTitle.isEmpty ? "Untitled" : s.bookTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(s.start, format: .dateTime.hour().minute())
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtle)
                HStack(spacing: 8) {
                    if let pages = s.pages, pages > 0 {
                        Text("\(pages) page\(pages == 1 ? "" : "s")")
                    }
                    if let wpm = s.wordsPerMinute, wpm > 0 {
                        Text("\(Int(ceil(wpm))) WPM")
                    }
                }
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(Theme.accent)
            }
            Spacer()
            Text(Fmt.duration(s.secs))
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(Theme.accent)
            Button {
                store.deleteSession(id: s.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.subtle)
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .smallCardStyle()
        .contentShape(Rectangle())
        .onTapGesture { editingSession = s }
    }

    private func field(_ label: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.subtle)
                .tracking(0.5)
            TextField("", text: text)
                .keyboardType(keyboard)
                .padding(.horizontal, 14).padding(.vertical, 13)
                .background(Theme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerSmall)
                        .stroke(Theme.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
        }
    }

    /// True when the manual-add form has a usable value to commit. Mirrors the
    /// webapp's gate (must be 1..=720 minutes, or end-time after start).
    private var sessionValid: Bool {
        let typedMins = Int(minutesText) ?? 0
        if typedMins > 0 { return typedMins <= 720 }
        if hasEndTime {
            let derived = inferredMinutesFromEnd()
            return derived > 0 && derived <= 720
        }
        return false
    }

    private func inferredMinutesFromEnd() -> Int {
        guard hasEndTime else { return 0 }
        let cal = Calendar.current
        let startSet = combine(time: startTime)
        var endSet = combine(time: endTime)
        if endSet < startSet, let next = cal.date(byAdding: .day, value: 1, to: endSet) {
            endSet = next
        }
        return max(0, Int(endSet.timeIntervalSince(startSet) / 60.0))
    }

    private func combine(time: Date) -> Date {
        let cal = Calendar.current
        let t = cal.dateComponents([.hour, .minute], from: time)
        var d = cal.dateComponents([.year, .month, .day], from: dayDate)
        d.hour = t.hour
        d.minute = t.minute
        return cal.date(from: d) ?? dayDate
    }

    private func addSession() {
        var mins = Int(minutesText) ?? 0
        if mins <= 0 && hasEndTime { mins = inferredMinutesFromEnd() }
        guard mins > 0 else { return }
        // Clamp to match webapp (1..720, "12 hour" guard against typos).
        mins = min(720, mins)

        let start = combine(time: startTime)
        let end: Date? = hasEndTime
            ? combine(time: endTime).addingTimeInterval(hasEndTime && combine(time: endTime) < start ? 86_400 : 0)
            : Calendar.current.date(byAdding: .minute, value: mins, to: start)

        let book = store.books.first { $0.id == selectedBookId }
        let session = ReadingSession(
            bookId: book?.id,
            bookTitle: book?.title ?? "Manual entry",
            start: start,
            end: end,
            secs: mins * 60,
            pages: Int(pagesText),
            manual: true
        )
        store.addSession(session)
        minutesText = ""
        pagesText = ""
        hasEndTime = false
    }
}

// MARK: - Session Editor

struct SessionEditorSheet: View {
    let session: ReadingSession
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var bookId: String = ""
    @State private var startDate: Date = Date()
    @State private var minutesText: String = ""
    @State private var pagesText: String = ""
    @State private var wordsPerMinuteText: String = ""
    @State private var progressDeltaText: String = ""
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Grabber()
                VStack(spacing: 4) {
                    Text("Edit Session").font(.system(size: 16, weight: .heavy))
                    Text("Update the reading session data.")
                        .font(.system(size: 12)).foregroundStyle(Theme.subtle)
                }
                .padding(.bottom, 14)

                VStack(alignment: .leading, spacing: 6) {
                    Text("BOOK")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.subtle)
                    Menu {
                        Button("Manual entry") { bookId = "" }
                        ForEach(store.books) { b in
                            Button(b.title) { bookId = b.id }
                        }
                    } label: {
                        HStack {
                            Text(store.books.first { $0.id == bookId }?.title ?? "Manual entry")
                                .foregroundStyle(Theme.text)
                            Spacer()
                            Image(systemName: "chevron.down").foregroundStyle(Theme.subtle)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 13)
                        .background(Theme.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cornerSmall)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
                    }
                }
                .padding(.bottom, 10)

                VStack(alignment: .leading, spacing: 6) {
                    Text("START")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.subtle)
                    DatePicker("", selection: $startDate)
                        .labelsHidden()
                }
                .padding(.bottom, 10)

                HStack(spacing: 10) {
                    field("Minutes", text: $minutesText)
                    field("Pages", text: $pagesText)
                }
                .padding(.bottom, 10)

                field("WPM", text: $wordsPerMinuteText)
                    .padding(.bottom, 10)

                VStack(alignment: .leading, spacing: 6) {
                    Text("PROGRESS CHANGE (%)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.subtle)
                    TextField("optional, e.g. 1 or 0.5", text: $progressDeltaText)
                        .keyboardType(.decimalPad)
                        .padding(.horizontal, 14).padding(.vertical, 13)
                        .background(Theme.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cornerSmall)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
                }
                .padding(.bottom, 16)

                HStack(spacing: 10) {
                    Button {
                        confirmDelete = true
                    } label: {
                        Text("Delete")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.card)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.cornerSmall)
                                    .stroke(Theme.border, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
                    }
                    .buttonStyle(.plain)
                    Button { dismiss() } label: {
                        Text("Cancel")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.card)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.cornerSmall)
                                    .stroke(Theme.border, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
                    }
                    .buttonStyle(.plain)
                    Button {
                        save()
                    } label: {
                        Text("Save")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .onAppear {
            bookId = session.bookId ?? ""
            startDate = session.start
            minutesText = "\(session.secs / 60)"
            pagesText = session.pages.map(String.init) ?? ""
            wordsPerMinuteText = session.wordsPerMinute.map { "\(Int(ceil($0)))" } ?? ""
            // Show stored delta as a percent (storage uses 0...1 fractional).
            if let d = session.progressDelta {
                progressDeltaText = String(format: "%g", d * 100)
            } else {
                progressDeltaText = ""
            }
        }
        .alert("Delete this session?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                store.deleteSession(id: session.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the session permanently. It won't affect the book.")
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.subtle)
            TextField("", text: text)
                .keyboardType(.numberPad)
                .padding(.horizontal, 14).padding(.vertical, 13)
                .background(Theme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerSmall)
                        .stroke(Theme.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
        }
    }

    private func save() {
        // Clamp minutes to webapp range (1..720).
        let mins = max(0, min(720, Int(minutesText) ?? 0))
        var s = session
        s.bookId = bookId.isEmpty ? nil : bookId
        s.bookTitle = store.books.first { $0.id == bookId }?.title ?? s.bookTitle
        s.start = startDate
        s.secs = max(0, mins * 60)
        s.end = Calendar.current.date(byAdding: .second, value: s.secs, to: startDate)
        s.pages = Int(pagesText)
        if let wpm = Double(wordsPerMinuteText), wpm > 0 {
            s.wordsPerMinute = ceil(wpm)
        } else {
            s.wordsPerMinute = nil
        }
        // Field is labeled as percent, so 0.6 means 0.6%, stored as 0.006.
        if let raw = Double(progressDeltaText.replacingOccurrences(of: ",", with: ".")), raw > 0 {
            s.progressDelta = raw / 100.0
        } else {
            s.progressDelta = nil
        }
        store.updateSession(s)
        dismiss()
    }
}

// MARK: - Shared sheet bits

struct Grabber: View {
    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.15))
            .frame(width: 38, height: 5)
            .padding(.bottom, 14)
    }
}

struct ActionGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge))
        .shadow(color: .black.opacity(0.07), radius: 12, y: 2)
    }
}

struct ActionRow: View {
    let icon: String
    let title: String
    var destructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(destructive ? Theme.danger : Theme.text)
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(Divider().padding(.leading, 50), alignment: .bottom)
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.subtle)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(Divider().padding(.leading, 16), alignment: .bottom)
    }
}
