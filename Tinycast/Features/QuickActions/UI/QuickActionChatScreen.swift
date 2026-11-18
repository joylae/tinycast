import SwiftUI

struct QuickActionChatScreen: PaletteScreen {
    @Environment(\.metrics) private var metrics
    let vm: PaletteState
    let session: QuickActionChatSession
    let coordinator: QuickActionCoordinator
    let openModel: () -> Void

    private var chat: AIChatState { session.chat }
    private var action: AIChatState.PrimaryAction {
        if !vm.query.isEmpty, !session.isWorking { return .send }
        return session.primaryAction
    }

    struct Row: Identifiable { let id = "quick-action-chat" }
    let rows = [Row()]

    var primaryActionTitle: String {
        switch action {
        case .send: String(localized: "Send")
        case .paste: String(localized: "Paste")
        case .stop: String(localized: "Stop")
        }
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        var items: [PopoverMenuItem] = []
        if session.isWorking {
            items.append(
                PopoverMenuItem(
                    localizedTitle: "Stop Response", systemImage: "stop.fill", shortcut: "⌘."
                ) { coordinator.stopChatResponse() })
        }
        if coordinator.canContinueInChat {
            items.append(
                PopoverMenuItem(
                    localizedTitle: "Continue in AI Chat",
                    systemImage: "bubble.left.and.bubble.right", shortcut: "⌘J"
                ) { coordinator.continueChatInWindow() })
        }
        if canRegenerate {
            items.append(
                PopoverMenuItem(
                    localizedTitle: "Regenerate Response", systemImage: "arrow.clockwise",
                    shortcut: "⌘R"
                ) { coordinator.regenerateChat() })
            items.append(
                PopoverMenuItem(
                    localizedTitle: "Regenerate with Model…", systemImage: "arrow.clockwise",
                    shortcut: "⇧⌘R", action: openModel))
        }
        if chat.lastCompletedResult != nil {
            items.append(
                PopoverMenuItem(
                    localizedTitle: "Copy Last Response", systemImage: "doc.on.doc",
                    startsSection: true, shortcut: "⌘↵"
                ) { coordinator.copyChatResult() })
        }
        items.append(
            PopoverMenuItem(
                localizedTitle: "AI Quick Action Settings", systemImage: "slider.horizontal.3",
                shortcut: "⌥⌘,"
            ) { coordinator.showSettings() })
        return PopoverMenuContent(header: session.action.title, items: items)
    }

    func activate(at selection: Int) {
        switch action {
        case .stop: coordinator.stopChatResponse()
        case .send:
            if coordinator.send(vm.query) { vm.query = "" }
        case .paste: coordinator.pasteChatResult()
        }
    }

    func secondary(at selection: Int) -> Bool {
        guard chat.lastCompletedResult != nil else { return false }
        coordinator.copyChatResult()
        return true
    }

    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        switch shortcut {
        case .continueInChat where coordinator.canContinueInChat:
            coordinator.continueChatInWindow()
        case .restart where canRegenerate: coordinator.regenerateChat()
        case .restartWithModel where canRegenerate: openModel()
        case .pin where chat.isStreaming: coordinator.stopChatResponse()
        case .settings: coordinator.showSettings()
        default: return false
        }
        return true
    }

    private var canRegenerate: Bool {
        !session.isWorking && chat.session.messages.last?.role == .assistant
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(
            VStack(spacing: 0) {
                HStack(spacing: metrics.spacing.sm) {
                    SymbolImage(name: session.action.symbol, size: metrics.size.quickActionHeaderIcon)
                    Text(session.action.title)
                    Spacer()
                }
                .font(metrics.typography.panelTitle)
                .foregroundStyle(Theme.Colors.textSecondary)
                .padding(.horizontal, metrics.spacing.xxl)
                .padding(.top, metrics.spacing.xl)
                if let notice = chat.notice {
                    Text(notice)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .padding(metrics.spacing.xxl)
                }
                if !session.diff.isEmpty {
                    QuickActionDiffView(chunks: session.diff)
                        .padding(.horizontal, metrics.spacing.xxl)
                        .padding(.vertical, metrics.spacing.md)
                }
                if chat.session.messages.isEmpty, chat.notice == nil {
                    HStack(spacing: metrics.spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("Working…").foregroundStyle(Theme.Colors.textSecondary)
                    }
                    .padding(metrics.spacing.xxl)
                }
                if !chat.session.messages.isEmpty {
                    ChatTranscriptView(
                        messages: chat.session.messages, status: chat.liveStatus, usage: chat.usage,
                        surface: .palette, collapsesUserMessages: true)
                }
            })
    }
}
