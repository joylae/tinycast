import Foundation
import Observation

@MainActor
@Observable
final class QuickActionChatSession {
    let action: QuickAction
    let original: String
    let instructions: String
    let chat: AIChatState
    let toolSessionID = UUID()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var cachedDiff: (result: String, chunks: [TextDiffEngine.Chunk])?
    private(set) var isPreparing = false

    var model: AIModelSelection? { chat.session.model }
    var isWorking: Bool { isPreparing || chat.isStreaming }
    var primaryAction: AIChatState.PrimaryAction {
        if isWorking { return .stop }
        return chat.primaryAction(draft: "")
    }
    init(
        action: QuickAction, original: String, instructions: String,
        model: AIModelSelection?, chat: AIChatState
    ) {
        self.action = action
        self.original = original
        self.instructions = instructions
        self.chat = chat
        chat.usePreset(
            ChatPreset(
                name: action.title, iconSymbol: action.symbol, instructions: instructions,
                model: model))
    }

    func selectModel(_ selection: AIModelSelection) {
        chat.setModel(selection)
    }

    func outputBudget(using provider: any AIProvider) -> Int {
        QuickActionRunner.maxOutputTokens(
            for: action, selection: original, on: provider)
    }

    func start(_ work: @escaping @MainActor () async -> Void) {
        generation += 1
        let mine = generation
        self.work?.cancel()
        isPreparing = true
        self.work = Task { [weak self] in
            await work()
            guard let self, mine == generation else { return }
            isPreparing = false
            self.work = nil
        }
    }

    func stop() {
        generation += 1
        work?.cancel()
        work = nil
        isPreparing = false
        chat.cancel()
    }

    var diff: [TextDiffEngine.Chunk] {
        guard action.showsDiff, let result = chat.lastCompletedResult else { return [] }
        if let cachedDiff, cachedDiff.result == result { return cachedDiff.chunks }
        let chunks = TextDiffEngine.diff(original: original, modified: result)
        cachedDiff = (result, chunks)
        return chunks
    }
}
