//
//  NotchLessonTab.swift
//  leanring-buddy
//
//  The open notch's Lesson tab: at most one alert row, the error card while
//  the error glow is live, then either the empty day's start tiles or the
//  last lesson as a sheet of paper with Replay, the Notebook and Copy in its
//  header and the next steps as chips. TutorControlBar.swift lays these out
//  with the chat box and footer.
//
//  Paper for learning, quiet black for controls: the lesson card is paper
//  with ink-coloured text; alerts, tiles and the error card stay in the
//  notch's own dark language.
//

import AppKit
import SwiftUI

// MARK: - Alerts

/// One alert at most, most pressing first.
enum NotchAlert: Equatable {
    case permission(String)
    case key(String)
    case signIn(String)
    case update(TutorControlBarModel.UpdateBanner)
}

struct NotchAlertRow: View {
    let alert: NotchAlert
    @ObservedObject var model: TutorControlBarModel
    @State private var hasCopiedCommand = false

    /// Typed in Terminal to sign Google Cloud in again.
    static let signInCommand = "gcloud auth application-default login"

    private var isUpdate: Bool {
        if case .update = alert { return true }
        return false
    }
    private var tint: Color { isUpdate ? DS.Colors.accentText : DS.Colors.warning }

    private var glyph: String {
        switch alert {
        case .permission: return "exclamationmark.triangle"
        case .key, .signIn: return "key"
        case .update: return "sparkles"
        }
    }

    private var sentence: String {
        switch alert {
        case .permission(let text), .key(let text), .signIn(let text): return text
        case .update(let banner): return banner.text
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            if case .update(let banner) = alert, banner.isWorking {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: glyph)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 18)
            }
            Self.firstSentenceBold(sentence)
                .font(.system(size: 12.5))
                .foregroundStyle(DS.Notch.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(tint.opacity(isUpdate ? 0.28 : 0.30), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actions: some View {
        switch alert {
        case .permission:
            NotchButton(systemImage: "lock.open", title: "Allow", action: model.onAllowPermission)
        case .key:
            NotchButton(systemImage: "wrench.and.screwdriver", title: "Fix", action: model.onFixKeys)
        case .signIn:
            NotchButton(systemImage: hasCopiedCommand ? "checkmark" : "doc.on.doc",
                        title: hasCopiedCommand ? "Copied" : "Copy command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.signInCommand, forType: .string)
                hasCopiedCommand = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { hasCopiedCommand = false }
            }
            .accessibilityLabel("Copy the sign-in command")
        case .update(let banner):
            if banner.canInstall {
                HStack(spacing: 10) {
                    NotchQuietTextButton(title: "What's new", action: model.onShowReleaseNotes)
                    NotchPrimaryButton(systemImage: nil, title: "Update", action: model.onInstallUpdate)
                }
            }
        }
    }

    /// The first sentence carries the news, so it is semibold; the rest is
    /// the fix, in the same size.
    static func firstSentenceBold(_ text: String) -> Text {
        guard let end = text.range(of: ". ") else { return Text(text).fontWeight(.semibold) }
        let first = String(text[..<end.lowerBound]) + "."
        let rest = String(text[end.upperBound...])
        return Text(first).fontWeight(.semibold) + Text(" " + rest)
    }
}

// MARK: - The error card

/// The error the glow offered, as Buddy read it, at the top of the Lesson
/// tab. Explain asks about it through the ordinary answer; Not now lets it
/// go for good (the watcher never offers the same error twice).
struct NotchErrorCard: View {
    let errorOffer: NotchErrorOffer
    @ObservedObject var model: TutorControlBarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "apple.terminal")
                    .font(.system(size: 11, weight: .semibold))
                Text("In \(errorOffer.applicationName), just now")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(DS.Notch.errorCardEyebrow)

            VStack(alignment: .leading, spacing: 3) {
                Text(errorOffer.messageLine)
                    .foregroundStyle(DS.Notch.textPrimary)
                if let locationLine = errorOffer.locationLine {
                    Text(locationLine)
                        .foregroundStyle(DS.Notch.textSecondary)
                }
            }
            .font(.system(size: 12.5, design: .monospaced))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)

            HStack(spacing: 14) {
                NotchPrimaryButton(systemImage: "sparkles", title: "Explain this error", action: model.onExplainError)
                NotchQuietTextButton(title: "Not now", action: model.onDismissError)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Notch.errorGlow.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(DS.Notch.errorCardBorder.opacity(0.28), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Error on screen, in \(errorOffer.applicationName)")
    }
}

// MARK: - The empty day

/// One intro and three ways in, built from what the student has learned
/// and kept, instead of a manual. Gone after the first question; the lesson
/// card takes the space.
struct NotchHomeView: View {
    @ObservedObject var model: TutorControlBarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.greeting)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 5) {
                    Text("Hold")
                    NotchKeycap(symbol: "\u{2303}", name: "Control")
                    NotchKeycap(symbol: "\u{2325}", name: "Option")
                    Text("and ask about anything on your screen.")
                }
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(DS.Notch.textSecondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Hold Control and Option and ask about anything on your screen.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 10) {
                NotchStartTile(
                    systemImage: "rectangle.and.pencil.and.ellipsis", tint: DS.Colors.accentText,
                    title: "Learn something new",
                    detail: Text("Buddy teaches it on a full-screen board, one part at a time."),
                    footer: "Try: \u{201C}teach me tries from scratch\u{201D}",
                    accessibilityText: "Learn something new. Buddy teaches it on a full-screen board, one part at a time.",
                    action: {
                        // The cursor lands between the words, for the topic.
                        model.onPutInChatBox("teach me  from scratch", 9)
                    })
                if let fadingIdea = model.homeSuggestions.fadingIdea {
                    NotchStartTile(
                        systemImage: "person.wave.2", tint: DS.Colors.success,
                        title: "Teach it back",
                        detail: Text("Explain ") + Text(fadingIdea.name).fontWeight(.semibold).foregroundColor(.white)
                            + Text(" in your words. Buddy marks the gaps."),
                        footer: fadingIdea.learnedText,
                        accessibilityText: "Teach it back. Explain \(fadingIdea.name) in your words. \(fadingIdea.learnedText).",
                        action: { model.onPutInChatBox("let me explain \(fadingIdea.name) to you", nil) })
                } else {
                    // Nothing fading to review: a tip that needs no click,
                    // so it is not drawn as a button.
                    NotchStartTile(
                        systemImage: "exclamationmark.triangle", tint: DS.Colors.success,
                        title: "Explain an error",
                        detail: Text("Run your code. If it fails, Buddy notices the error and offers to explain it."),
                        footer: nil,
                        accessibilityText: "Explain an error. Run your code. If it fails, Buddy notices the error and offers to explain it.",
                        action: nil)
                }
                if let lastStudyDay = model.homeSuggestions.lastStudyDay {
                    NotchStartTile(
                        systemImage: "book.pages", tint: DS.Colors.warning,
                        title: lastStudyDay.title,
                        detail: Text("\(lastStudyDay.pageCount == 1 ? "1 page" : "\(lastStudyDay.pageCount) pages") in your Notebook, starting with \(lastStudyDay.firstLessonTitle)."),
                        footer: "Open Notebook",
                        accessibilityText: "\(lastStudyDay.title). \(lastStudyDay.pageCount) pages in your Notebook. Opens the Notebook.",
                        action: { model.onOpenNotebook(lastStudyDay.dayIdentifier) })
                }
            }
        }
    }

    /// "Afternoon, Sam." from the name given in setup, or the Mac account's
    /// first name before setup.
    static var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let partOfDay = hour < 12 ? "Morning" : (hour < 18 ? "Afternoon" : "Evening")
        let givenName = UserDefaults.standard.string(forKey: "studentName") ?? ""
        let firstName = givenName.isEmpty
            ? (NSFullUserName().split(separator: " ").first.map(String.init) ?? "")
            : givenName
        return firstName.isEmpty ? "\(partOfDay)." : "\(partOfDay), \(firstName)."
    }
}

/// A key drawn as a key, for shortcuts written in hints.
struct NotchKeycap: View {
    let symbol: String
    let name: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DS.Notch.textPrimary)
            .frame(minWidth: 22, minHeight: 20)
            .padding(.horizontal, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
            .accessibilityLabel(name)
    }
}

/// One way in on an empty day. The whole tile is the button.
private struct NotchStartTile: View {
    let systemImage: String
    let tint: Color
    let title: String
    let detail: Text
    let footer: String?
    let accessibilityText: String
    /// Nil for a tip that does nothing on a click.
    let action: (() -> Void)?
    @State private var isHovering = false

    private var isInteractive: Bool { action != nil }

    var body: some View {
        Group {
            if let action {
                Button(action: action) { tileContent }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
                    }
            } else {
                tileContent
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isInteractive ? .isButton : .isStaticText)
    }

    private var tileContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.15)))
                .padding(.bottom, 18)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.bottom, 4)
            detail
                .font(.system(size: 11.5))
                .foregroundStyle(DS.Notch.textSecondary)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 10)
            if let footer {
                Text(footer)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(isHovering ? 0.085 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.white.opacity(isHovering ? 0.16 : 0.07), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - The last lesson

/// The last lesson folded to one row, under the error card while it shows.
struct FoldedLessonRow: View {
    @ObservedObject var model: TutorControlBarModel
    let onAsk: (String) -> Void
    let onCopy: (TutorFollowUpButton) -> Void
    let onCopyLesson: (String) -> Void
    let onStop: () -> Void
    @State private var isUnfolded = false
    @State private var isHovering = false

    private var lessonTitle: String {
        if let lessonName = model.transcript.last(where: { $0.lessonTitle != nil })?.lessonTitle {
            return LessonTitle.displayed(lessonName)
        }
        if let lastQuestion = model.transcript.last(where: { $0.speaker == .student })?.text {
            return LessonTitle.fromQuestion(lastQuestion)
        }
        return "Your lesson"
    }

    var body: some View {
        if isUnfolded {
            LessonCard(model: model, onAsk: onAsk, onCopy: onCopy, onCopyLesson: onCopyLesson, onStop: onStop)
                .transition(.opacity)
        } else {
            Button(action: { withAnimation(NotchMotion.change) { isUnfolded = true } }) {
                HStack(spacing: 9) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(DS.Notch.textSecondary)
                    Text("Last lesson: \(lessonTitle)")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(isHovering ? 0.94 : 0.8))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.Notch.textSecondary)
                }
                .padding(.horizontal, 13)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.08 : 0.05)))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .onHover { hovering in
                withAnimation(NotchMotion.hover) { isHovering = hovering }
            }
            .accessibilityLabel("Last lesson, \(lessonTitle). Show it")
        }
    }
}

/// The last lesson as a sheet of paper: what it was called, what was said,
/// and where to go next. One surface: the answer sits on the paper itself.
struct LessonCard: View {
    @ObservedObject var model: TutorControlBarModel
    let onAsk: (String) -> Void
    let onCopy: (TutorFollowUpButton) -> Void
    let onCopyLesson: (String) -> Void
    let onStop: () -> Void
    @State private var isShowingWholeAnswer = false
    @State private var hasJustCopied = false

    /// Past this, the answer is folded to five lines with a way to open it.
    private static let foldAfterCharacters = 360
    /// Opened, a long answer scrolls inside the card instead of pushing the
    /// notch off the bottom of the screen.
    private static let openAnswerMaximumHeight: CGFloat = 300
    /// The model's own follow-ups and Buddy's quiet ones, together.
    private static let mostChips = 4

    private var lastTutorTurn: TranscriptEntry? {
        model.transcript.last(where: { $0.speaker == .tutor })
    }
    private var lastQuestion: String? {
        model.transcript.last(where: { $0.speaker == .student })?.text
    }

    /// The card's heading: the lesson's name, or the question when it has
    /// none, as a title.
    private var cardTitle: String {
        if let lessonName = lastTutorTurn?.lessonTitle { return LessonTitle.displayed(lessonName) }
        if let lastQuestion { return LessonTitle.fromQuestion(lastQuestion) }
        return "Your lesson"
    }

    /// "LAST LESSON · 14:32 · LEETCODE", or "EXPLAINING NOW".
    private var eyebrow: String {
        if model.isSpeaking { return "EXPLAINING NOW" }
        var parts = ["LAST LESSON"]
        if let time = lastTutorTurn?.time {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            parts.append(formatter.string(from: time))
        }
        if let applicationName = model.lastLessonApplicationName { parts.append(applicationName.uppercased()) }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// What Teach it back and Go deeper are about: the lesson's own name,
    /// in the middle of a sentence.
    private var topicForChips: String {
        let title = lastTutorTurn?.lessonTitle ?? lastQuestion ?? "this"
        guard let first = title.first, title.count > 1,
              title[title.index(after: title.startIndex)].isLowercase else { return title }
        return first.lowercased() + title.dropFirst()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let lastTutorTurn {
                // The lesson's own name leads. The question as speech
                // recognition heard it is often rough, so it sits
                // underneath, small, as a reminder.
                Text(cardTitle)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Paper.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let firstIdea = model.buildsOn.first {
                    BuildsOnChip(ideaNames: model.buildsOn) { model.onOpenKnowledgeMap(firstIdea) }
                }
                // Under a name, and under a question too long to be the
                // heading whole.
                if let lastQuestion, cardTitle != LessonTitle.displayed(lastQuestion) {
                    Text("You asked: \u{201C}\(lastQuestion)\u{201D}")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Paper.inkMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                answer(lastTutorTurn.text)
                    .padding(.top, 2)

                chipRow
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DS.Paper.card)
                .overlay(PaperDotGrid().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
        // A new lesson starts folded again.
        .onChange(of: lastTutorTurn?.id) { _, _ in isShowingWholeAnswer = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Last lesson, \(cardTitle)")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(eyebrow)
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(DS.Paper.eyebrow)
                .lineLimit(1)
                .contentTransition(.opacity)
            Spacer(minLength: 8)
            // Plays the last answer again, voice and drawing, with no new
            // request; while an answer is being said it stops it instead.
            if model.isSpeaking {
                PaperButton(systemImage: "stop.fill", title: "Stop", tooltip: "Stop explaining", action: onStop)
                    .accessibilityLabel("Stop")
            } else if model.canReplayLastAnswer {
                PaperButton(systemImage: "arrow.counterclockwise", title: "Replay",
                            tooltip: "Replay the lesson with its drawing", action: model.onReplayLastAnswer)
                    .accessibilityLabel("Replay lesson")
            }
            PaperIconButton(systemImage: "book.pages", tooltip: "Open in Notebook") {
                model.onOpenNotebook(nil)
            }
            .accessibilityLabel("Open in Notebook")
            PaperIconButton(systemImage: hasJustCopied ? "checkmark" : "doc.on.doc", tooltip: "Copy") {
                guard let lastTutorTurn else { return }
                let title = lastTutorTurn.lessonTitle.map { LessonTitle.displayed($0) + "\n\n" } ?? ""
                onCopyLesson(title + lastTutorTurn.text)
                hasJustCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { hasJustCopied = false }
            }
            .accessibilityLabel(hasJustCopied ? "Copied" : "Copy lesson")
        }
        .frame(minHeight: 26)
    }

    /// The model's own follow-ups first, as blue gels; then the quiet ones
    /// Buddy adds on a finished lesson. Four at most, quiet ones dropped
    /// first.
    @ViewBuilder
    private var chipRow: some View {
        let modelChips = Array(model.followUps.prefix(2))
        let isFinished = !model.isSpeaking
        let quietChips: [(title: String, systemImage: String, tooltip: String, question: String)] = isFinished ? [
            ("Teach it back", "person.wave.2", "Explain it in your words",
             "let me explain \(topicForChips) back to you"),
        ] + (model.lastAnswerOffersGoDeeper ? [
            ("Go deeper", "rectangle.and.pencil.and.ellipsis", "Continue on the full-screen board",
             "teach me \(topicForChips) from scratch"),
        ] : []) : []
        let quietRoom = max(0, Self.mostChips - modelChips.count)
        if !modelChips.isEmpty || !quietChips.isEmpty {
            HStack(spacing: 8) {
                ForEach(modelChips) { button in
                    GelChip(
                        title: model.copiedButtonID == button.id ? "Copied" : button.title,
                        systemImage: button.question != nil ? "arrow.turn.down.right" : "doc.on.doc",
                        tooltip: button.question ?? "Copy to clipboard"
                    ) {
                        if let question = button.question { onAsk(question) } else { onCopy(button) }
                    }
                    .accessibilityLabel(button.question.map { "Ask: \($0)" } ?? "Copy \(button.title)")
                }
                ForEach(Array(quietChips.prefix(quietRoom)), id: \.title) { chip in
                    QuietGelChip(title: chip.title, systemImage: chip.systemImage, tooltip: chip.tooltip) {
                        onAsk(chip.question)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func answer(_ answerText: String) -> some View {
        let isLong = answerText.count > Self.foldAfterCharacters
        VStack(alignment: .leading, spacing: 8) {
            if isLong && isShowingWholeAnswer {
                ScrollView {
                    answerTextView(answerText, lineLimit: nil)
                }
                .frame(maxHeight: Self.openAnswerMaximumHeight)
            } else {
                answerTextView(answerText, lineLimit: isLong ? 5 : nil)
            }
            if isLong {
                Button(action: {
                    withAnimation(.smooth(duration: 0.28)) { isShowingWholeAnswer.toggle() }
                }) {
                    HStack(spacing: 4) {
                        Text(isShowingWholeAnswer ? "Show less" : "Show the whole answer")
                        Image(systemName: isShowingWholeAnswer ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(DS.Paper.link)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Selectable only when not folded: selectable text on macOS draws every
    /// line whatever its line limit.
    @ViewBuilder
    private func answerTextView(_ answerText: String, lineLimit: Int?) -> some View {
        let text = Text(answerText)
            .font(.system(size: 13.5, weight: .regular))
            .lineSpacing(3)
            .foregroundStyle(DS.Paper.ink)
        if let lineLimit {
            text
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
        } else {
            text
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Faint dots, like the squared paper the drawings use.
struct PaperDotGrid: View {
    var spacing: CGFloat = 14

    var body: some View {
        Canvas { context, size in
            var dots = Path()
            var y: CGFloat = spacing / 2
            while y < size.height {
                var x: CGFloat = spacing / 2
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x, y: y, width: 1.6, height: 1.6))
                    x += spacing
                }
                y += spacing
            }
            context.fill(dots, with: .color(DS.Paper.dot))
        }
        .allowsHitTesting(false)
    }
}

/// The ideas this lesson builds on. A button: it opens the Map on the first.
private struct BuildsOnChip: View {
    let ideaNames: [String]
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 10, weight: .bold))
                Text("Builds on " + ideaNames.joined(separator: " \u{00B7} "))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(DS.Paper.buildsOnText)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(DS.Paper.buildsOnFill.opacity(isHovering ? 1 : 0.85)))
            .overlay(Capsule().fill(Color.black.opacity(isHovering ? 0.04 : 0)))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(NotchMotion.hover) { isHovering = hovering }
        }
        .nativeTooltip("Open it on your Map")
        .accessibilityLabel("Builds on \(ideaNames.joined(separator: ", ")). Open on the Map")
    }
}

/// A button on paper with its label: black 6%, 11% on hover.
private struct PaperButton: View {
    let systemImage: String
    let title: String
    let tooltip: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Color.black.opacity(isHovering ? 0.88 : 0.72))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(isHovering ? DS.Paper.controlHover : DS.Paper.control))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(NotchMotion.hover) { isHovering = hovering }
        }
        .nativeTooltip(tooltip)
    }
}

/// An icon-only button on paper, with the same fill on hover.
private struct PaperIconButton: View {
    let systemImage: String
    let tooltip: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.black.opacity(isHovering ? 0.88 : 0.6))
                .frame(width: 26, height: 26)
                .background(Circle().fill(isHovering ? DS.Paper.controlHover : Color.clear))
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(NotchMotion.hover) { isHovering = hovering }
        }
        .nativeTooltip(tooltip)
    }
}

/// A raised, glossy button for the model's own next step, the way the
/// paper cards' actions read as things to press.
private struct GelChip: View {
    let title: String
    let systemImage: String
    let tooltip: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Color(red: 0.05, green: 0.12, blue: 0.3))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(LinearGradient(
                    colors: [Color(red: 0.78, green: 0.87, blue: 1.0), Color(red: 0.53, green: 0.69, blue: 0.98)],
                    startPoint: .top, endPoint: .bottom
                ))
            )
            .overlay(Capsule().strokeBorder(Color(red: 0.2, green: 0.36, blue: 0.8).opacity(0.7), lineWidth: 1))
            .shadow(color: Color.black.opacity(isHovering ? 0.25 : 0.12), radius: isHovering ? 5 : 2, y: 1)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(NotchMotion.hover) { isHovering = hovering }
        }
        .nativeTooltip(tooltip)
    }
}

/// Buddy's own next steps after a lesson, quieter than the model's.
private struct QuietGelChip: View {
    let title: String
    let systemImage: String
    let tooltip: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    // Some glyphs draw their second layer faint by default.
                    .symbolRenderingMode(.monochrome)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(DS.Paper.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(isHovering ? 0.75 : 0.55)))
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(NotchMotion.hover) { isHovering = hovering }
        }
        .nativeTooltip(tooltip)
        .accessibilityLabel(title)
    }
}
