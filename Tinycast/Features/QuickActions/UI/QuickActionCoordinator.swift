import AppKit
import Observation

/// The single funnel for every Quick Action, however it was started.
@MainActor
@Observable
final class QuickActionCoordinator {
    private struct NoteSelection {
        let editor: NoteTextView
        let document: NoteEditorInput
        let range: NSRange
        let text: String
    }

    private enum Target {
        case external(NSRunningApplication?)
        case note(NoteSelection)

        var externalApp: NSRunningApplication? {
            guard case .external(let app) = self else { return nil }
            return app
        }
    }

    private let settings: AppSettings
    private let store: QuickActionSettingsStore
    private let customActions: CustomQuickActionStore
    private let injector: TextInjector
    private let appIndex: AppIndex
    private let hotKeys: HotKeyManager
    private let favorites: FavoritesStore
    private let visibility: VisibilityStore
    private let ranking: LauncherRankingStore
    private let aliases: AliasStore
    private let paletteCoordinator: PaletteCoordinator
    private let panels = QuickActionPanelController()
    private(set) var chatSession: QuickActionChatSession?
    private var chatTarget: Target?
    private unowned let core: AppCore
    private var palette: PaletteState { core.palette }
    var canContinueInChat: Bool { settings.aiEnabled }

    private static let launcherCommands = Set(BuiltInQuickAction.allCases.map(CommandID.init))

    /// One at a time: two runs race for one selection, and the second overwrites the first's work.
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Cancellation is cooperative, so a cancelled run must not hide the pill a newer run showed.
    @ObservationIgnored private var progressOwner: Int?

    init(
        settings: AppSettings, store: QuickActionSettingsStore,
        customActions: CustomQuickActionStore, injector: TextInjector,
        appIndex: AppIndex, hotKeys: HotKeyManager, favorites: FavoritesStore,
        visibility: VisibilityStore, ranking: LauncherRankingStore, aliases: AliasStore,
        paletteCoordinator: PaletteCoordinator, core: AppCore
    ) {
        self.settings = settings
        self.store = store
        self.customActions = customActions
        self.injector = injector
        self.appIndex = appIndex
        self.hotKeys = hotKeys
        self.favorites = favorites
        self.visibility = visibility
        self.ranking = ranking
        self.aliases = aliases
        self.paletteCoordinator = paletteCoordinator
        self.core = core
    }

    /// Launcher rows come and go with the switch; the Carbon bindings stay registered.
    func applyEnabled() {
        appIndex.setCommandsVisible(Self.launcherCommands, settings.quickActionsEnabled)
        applyCustomQuickActionsPresence()
        guard settings.quickActionsEnabled else {
            cancel()
            discardChat()
            core.applyInstalledAILifecycle()
            return
        }
        core.applyInstalledAILifecycle()
        store.resolveModel(
            appleIntelligenceAvailable: core.aiSettings.isAppleIntelligenceAvailable(),
            fallback: core.aiSettings.defaultModel)
        loadLanguages()
    }

    /// Enabling is consent: reading a selection and typing over it both need Accessibility.
    func setEnabled(_ enabled: Bool) {
        guard enabled != settings.quickActionsEnabled else { return }
        guard enabled else {
            settings.quickActionsEnabled = false
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        Task {
            guard
                await core.confirm(
                    title: String(localized: "Enable AI Quick Actions?"),
                    message: String(
                        localized: """
                            Tinycast needs the Accessibility permission to read the text you have \
                            selected in other apps and replace it. Nothing is read until you press \
                            a shortcut.
                            """),
                    symbol: "wand.and.sparkles", confirmTitle: String(localized: "Continue"),
                    tone: .neutral,
                    confirmRole: .standard)
            else { return }
            settings.quickActionsEnabled = true
            // The one prompt for this feature, raised from the gesture that asked for it.
            Permissions.ensureAccessibility()
        }
    }

    func applyCustomQuickActionsPresence() {
        appIndex.setCustomQuickActions(
            settings.quickActionsEnabled ? customActions.actions : [])
    }

    // MARK: - The reader's own actions

    /// The route is stored only once the record is on disk, so a refused save leaves neither behind.
    func addCustomQuickAction(
        _ draft: CustomQuickAction, model: AIModelSelection?
    ) throws(CustomQuickActionError) {
        let action = try customActions.add(draft)
        store.setModelOverride(model, for: .custom(action))
    }

    func updateCustomQuickAction(
        _ draft: CustomQuickAction, model: AIModelSelection?
    ) throws(CustomQuickActionError) {
        try customActions.update(draft)
        store.setModelOverride(model, for: .custom(draft))
    }

    func setPreviewsResult(_ previews: Bool, id: UUID) {
        do {
            try customActions.setPreviewsResult(previews, id: id)
        } catch {
            report(error)
        }
    }

    func deleteCustomQuickAction(id: UUID) async {
        guard let action = customActions.action(id: id) else { return }
        guard
            await core.confirm(
                title: String(localized: "Delete “\(action.name)”?"),
                message: String(localized: "Its instructions, shortcut and learned ranking go with it."),
                symbol: action.symbol, confirmTitle: String(localized: "Delete"))
        else { return }
        // Unwound only once the row is gone, so a kept record never loses its shortcut.
        do {
            guard let removed = try customActions.remove(id: id) else { return }
            removeCustomQuickActionReferences(removed)
        } catch {
            report(error)
        }
    }

    private func report(_ error: CustomQuickActionError) {
        Task {
            await core.showNotice(
                title: String(localized: "Couldn’t Save the Change"), message: error.localizedDescription,
                symbol: CustomQuickAction.sfSymbol, tone: .danger)
        }
    }

    private func removeCustomQuickActionReferences(_ action: CustomQuickAction) {
        let hotKeyAction = HotKeyAction.quickAction(id: action.id)
        if hotKeys.recordingAction == hotKeyAction { hotKeys.recordingAction = nil }
        hotKeys.setBinding(nil, for: hotKeyAction)
        store.setModelOverride(nil, for: .custom(action))
        favorites.remove(keys: [action.entryID])
        visibility.removeItemKeys([action.entryID])
        aliases.removeKeys([action.entryID])
        ranking.reset(itemKey: action.entryID)
    }

    func run(id: UUID) {
        guard let action = customActions.action(id: id) else { return }
        run(.custom(action))
    }

    func run(_ action: QuickAction) {
        guard settings.quickActionsEnabled else { return }
        if chatSession != nil { discardChat() }
        guard running == nil else { return }
        let source =
            paletteCoordinator.isVisible
            ? InjectionTarget.behindPalette(
                ownWindow: paletteCoordinator.previousOwnWindow, app: paletteCoordinator.targetApp)
            : InjectionTarget.current()
        let target: Target
        if let editor = source?.ownEditor as? NoteTextView {
            target = .note(
                NoteSelection(
                    editor: editor, document: core.notesCoordinator.editorInput,
                    range: editor.selectedRange(), text: editor.injectableSelection))
        } else {
            target = .external(paletteCoordinator.targetApp)
        }
        if paletteCoordinator.isVisible {
            paletteCoordinator.hidePalette(restoreFocus: source?.ownEditor is NoteTextView)
        }
        start { [weak self] in await self?.begin(action, target: target) }
    }

    func cancel() {
        generation += 1
        running?.cancel()
        running = nil
        hideProgress(ownedBy: progressOwner)
        panels.dismiss()
    }

    /// The generation stops a superseded task from clearing the newer handle as it finishes.
    private func start(_ work: @escaping @MainActor () async -> Void) {
        generation += 1
        let mine = generation
        running?.cancel()
        running = Task { [weak self] in
            await work()
            guard let self, mine == self.generation else { return }
            self.running = nil
        }
    }

    private func begin(_ action: QuickAction, target: Target) async {
        let selection: String
        do {
            switch target {
            case .external(let app):
                selection = try await QuickActionRunner.selection(in: app, using: injector)
            case .note(let note):
                selection = try QuickActionRunner.accepted(note.text)
            }
        } catch let failure as QuickActionFailure {
            reportRefusal(failure)
            return
        } catch {
            core.showMessage(error.localizedDescription, tone: .danger)
            return
        }
        let state = QuickActionPanelState(
            action: action, original: selection, targetLanguage: targetLanguage)
        let previews = store.settings.previewsResult(action)
        if previews, !action.usesTranslationFramework {
            beginChat(state, target: target)
            return
        }
        if previews { present(state, target: target) }
        await perform(state, target: target, previewing: previews)
    }

    private func beginChat(_ state: QuickActionPanelState, target: Target) {
        let chat = core.aiChats.makeEphemeralState()
        let selection = store.model(for: state.action) ?? core.aiSettings.defaultModel
        let session = QuickActionChatSession(
            action: state.action, original: state.original,
            instructions: QuickActionPrompt.instructions(
                for: state.action, override: store.settings.instructionOverride(for: state.action)),
            model: selection, chat: chat)
        chat.onReplyFinished = { [weak self] chat in
            guard let self, chatSession?.chat === chat, !paletteCoordinator.isVisible else { return }
            core.showMessage(String(localized: "Quick AI response ready"))
        }
        chatSession = session
        chatTarget = target
        palette.prepare(mode: .ai)
        core.palette.query = ""
        if let app = target.externalApp { core.palette.pasteTarget = PasteTarget(app: app) }
        paletteCoordinator.showPalette(mode: .ai)
        session.start { await self.generateInitial(session) }
    }

    private func generateInitial(_ session: QuickActionChatSession) async {
        do {
            let provider = try await core.quickActionProvider(
                for: session.action, in: session.toolSessionID, model: session.model)
            guard chatSession === session, !Task.isCancelled else { return }
            let sent = session.chat.send(
                session.original, using: provider, model: session.model,
                instructions: session.instructions,
                contextBudget: session.model?.isOnDevice == true
                    ? AppleIntelligence.contextBudget : ChatSession.defaultTextBudget,
                requestText: QuickActionPrompt.message(
                    for: session.action, selection: session.original),
                maxOutputTokens: session.outputBudget(using: provider))
            if !sent { session.chat.report(String(localized: "The action is already running.")) }
        } catch {
            guard chatSession === session, !Task.isCancelled else { return }
            session.chat.report(error.localizedDescription)
        }
    }

    @discardableResult
    func send(_ input: String) -> Bool {
        guard let session = chatSession, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !session.isWorking
        else { return false }
        session.start { await self.send(input, in: session) }
        return true
    }

    private func send(_ input: String, in session: QuickActionChatSession) async {
        do {
            let provider = try await core.quickActionProvider(
                for: session.action, in: session.toolSessionID, model: session.model)
            guard chatSession === session, !Task.isCancelled else { return }
            session.chat.send(
                input, using: provider, model: session.model,
                instructions: session.instructions,
                contextBudget: session.model?.isOnDevice == true
                    ? AppleIntelligence.contextBudget : ChatSession.defaultTextBudget,
                maxOutputTokens: session.outputBudget(using: provider))
        } catch {
            guard chatSession === session, !Task.isCancelled else { return }
            session.chat.report(error.localizedDescription)
        }
    }

    func stopChatResponse() { chatSession?.stop() }

    func regenerateChat() {
        guard let session = chatSession else { return }
        session.start { await self.regenerate(session) }
    }

    private func regenerate(_ session: QuickActionChatSession) async {
        do {
            let provider = try await core.quickActionProvider(
                for: session.action, in: session.toolSessionID, model: session.model)
            guard chatSession === session, !Task.isCancelled else { return }
            session.chat.regenerate(
                using: provider, model: session.model,
                instructions: session.instructions,
                contextBudget: session.model?.isOnDevice == true
                    ? AppleIntelligence.contextBudget : ChatSession.defaultTextBudget,
                maxOutputTokens: session.outputBudget(using: provider))
        } catch {
            guard chatSession === session, !Task.isCancelled else { return }
            session.chat.report(error.localizedDescription)
        }
    }

    func continueChatInWindow() {
        guard settings.aiEnabled, let session = chatSession,
            !session.chat.session.messages.isEmpty
        else { return }
        let draft = core.palette.query
        core.palette.query = ""
        core.mcpCoordinator.endSession(session.toolSessionID)
        chatSession = nil
        chatTarget = nil
        paletteCoordinator.hidePalette(restoreFocus: false)
        core.aiChats.continueInWindow(session.chat, draft: draft)
        core.aiChatCoordinator.showWindow()
    }

    func copyChatResult() {
        guard let session = chatSession, let text = session.chat.lastCompletedResult else { return }
        Paster.copyPlainText(text)
    }

    func showSettings() {
        paletteCoordinator.hidePalette(restoreFocus: false)
        core.settingsCoordinator.showSettings(tab: .quickActions)
    }

    func pasteChatResult() {
        guard let session = chatSession, let target = chatTarget,
            let text = session.chat.lastCompletedResult
        else { return }
        deliver(text, to: target, action: session.action)
    }

    func quickAIResultDelivered() {
        core.quickAICoordinator.quickAIDidDeliver()
    }

    func deliverQuickAI(_ text: String, target: InjectionTarget) {
        injector.deliver(
            InjectedText(text), target: target, expectedKeyword: nil, keywordLength: 0,
            automaticGeneration: nil, activateTarget: false,
            onDelivered: { [weak self] in self?.quickAIResultDelivered() },
            onFailed: { [weak self] in
                Paster.copyPlainText(text)
                self?.core.showMessage(
                    String(localized: "Couldn't paste the answer — copied instead"), tone: .danger)
            })
    }

    func discardChat() {
        guard let session = chatSession else { return }
        session.stop()
        core.mcpCoordinator.endSession(session.toolSessionID)
        chatSession = nil
        chatTarget = nil
    }

    func paletteDidPopToRoot() {
        discardChat()
    }

    /// A missing permission cannot be fixed from a pill that fades, so it earns a dialog instead.
    private func reportRefusal(_ failure: QuickActionFailure) {
        guard failure.opensAccessibilitySettings else {
            core.showMessage(failure.localizedDescription, tone: .danger)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        Task {
            guard
                await core.reportFailure(
                    title: String(localized: "AI Quick Actions can't read your selection"),
                    message: String(
                        localized: """
                            Tinycast needs the Accessibility permission to read the text you have \
                            selected and replace it. If Tinycast is already listed, switch it off \
                            and on again — a rebuilt app keeps a stale entry.
                            """),
                    symbol: "wand.and.sparkles", recovery: String(localized: "Open System Settings"))
            else { return }
            Permissions.openAccessibilitySettings()
        }
    }

    private func perform(
        _ state: QuickActionPanelState, target: Target, previewing: Bool
    ) async {
        do {
            let text = try await produce(state, previewing: previewing)
            guard !Task.isCancelled else { return }
            state.finish(text)
            if previewing { return }
            deliver(text, to: target, action: state.action)
        } catch let error where error is CancellationError || Task.isCancelled {
            return
        } catch let error as TextTranslator.Failure where error.needsDownload {
            // A HUD cannot say where the download lives, so this has to become a panel.
            if !previewing { present(state, target: target) }
            state.requireLanguageDownload()
        } catch {
            report(error, state: state, previewing: previewing)
        }
    }

    /// Without a panel there is nothing on screen saying the model is working, so the pill says it.
    private func produce(
        _ state: QuickActionPanelState, previewing: Bool
    ) async throws -> String {
        guard !previewing else { return try await generate(state, streaming: true) }
        let mine = generation
        progressOwner = mine
        core.showProgress(state.action.progressTitle, onCancel: { [weak self] in self?.cancel() })
        defer { hideProgress(ownedBy: mine) }
        return try await generate(state, streaming: false)
    }

    private func hideProgress(ownedBy owner: Int?) {
        guard let owner, progressOwner == owner else { return }
        progressOwner = nil
        core.hideProgress()
    }

    private func generate(
        _ state: QuickActionPanelState, streaming: Bool
    ) async throws -> String {
        if state.action.usesTranslationFramework {
            return try await TextTranslator.translate(state.original, to: state.targetLanguage)
        }
        let session = UUID()
        defer { core.mcpCoordinator.endSession(session) }
        let provider = try await core.quickActionProvider(for: state.action, in: session)
        return try await QuickActionRunner.run(
            state.action, selection: state.original, using: provider,
            instructionOverride: store.settings.instructionOverride(for: state.action),
            onOutput: { text in
                guard streaming else { return }
                state.updateOutput(text)
            })
    }

    /// A replacement that never lands would otherwise lose the reply, so the clipboard keeps it.
    private func deliver(_ text: String, to target: Target, action: QuickAction) {
        let onDelivered: @MainActor @Sendable () -> Void = { [weak self] in
            if self?.chatSession != nil {
                self?.paletteCoordinator.hidePalette(restoreFocus: false)
                self?.discardChat()
            }
            self?.core.showMessage(String(localized: "\(action.title) applied"))
        }
        let onFailed: @MainActor @Sendable () -> Void = { [weak self] in
            Paster.copyPlainText(text)
            self?.core.showMessage(
                String(localized: "\(action.title) couldn't replace the selection — copied instead"),
                tone: .danger)
        }
        switch target {
        case .external(let app):
            injector.replaceSelection(
                with: text, in: app, activateTarget: chatSession == nil,
                isValid: { [weak self] in
                    guard let expected = self?.chatSession?.original, let app,
                        let current = AccessibilityText.selection(in: app)
                    else { return self?.chatSession == nil }
                    return current == expected
                },
                onDelivered: onDelivered, onFailed: onFailed)
        case .note(let note):
            guard core.notesCoordinator.editorInput == note.document,
                note.editor.window?.isVisible == true,
                note.editor.replaceUnchangedSelection(
                    with: text, source: note.document.source, range: note.range)
            else { onFailed(); return }
            onDelivered()
        }
    }

    /// A failure the reader cannot see is a hotkey that silently did nothing.
    private func report(_ error: Error, state: QuickActionPanelState, previewing: Bool) {
        guard previewing else {
            core.showMessage(error.localizedDescription, tone: .danger)
            return
        }
        state.fail(error.localizedDescription)
    }

    private func present(_ state: QuickActionPanelState, target: Target) {
        panels.present(
            state,
            metrics: settings.interfaceSize.metrics,
            languages: offeredLanguages,
            onRetranslate: { [weak self] language in
                state.targetLanguage = language
                self?.rerun(state, target: target)
            },
            onReplace: { [weak self] text in
                self?.deliver(text, to: target, action: state.action)
            })
    }

    private func rerun(_ state: QuickActionPanelState, target: Target) {
        state.restart()
        start { [weak self] in await self?.perform(state, target: target, previewing: true) }
    }

    private var targetLanguage: Locale.Language {
        let stored = store.settings.targetLanguage
        guard !stored.isEmpty else { return Locale.current.language }
        return Locale.Language(identifier: stored)
    }

    /// Observed, not ignored: it arrives after the pane has painted, and the picker has to notice.
    private(set) var offeredLanguages: [Locale.Language] = []
    @ObservationIgnored private var languageLoad: Task<Void, Never>?

    func loadLanguages() {
        guard offeredLanguages.isEmpty, languageLoad == nil else { return }
        languageLoad = Task { [weak self] in
            let languages = await TextTranslator.supportedLanguages()
            self?.offeredLanguages = languages
        }
    }
}

extension TextTranslator.Failure {
    var needsDownload: Bool {
        if case .notInstalled = self { return true }
        return false
    }
}
