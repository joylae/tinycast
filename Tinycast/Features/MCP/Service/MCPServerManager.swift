import Foundation
import Observation

/// Every running server's lifecycle. Whether a call may run is the coordinator's decision.
@MainActor
@Observable
final class MCPServerManager {
    private struct Preparation {
        let servers: Set<UUID>
        let continuation: CheckedContinuation<Void, Error>
    }

    private(set) var connections: [UUID: MCPServerConnection] = [:]

    @ObservationIgnored private let oauth: MCPOAuthManager?
    @ObservationIgnored private let secrets: MCPSecretStore
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var starting: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var preparations: [UUID: Preparation] = [:]

    /// Servers outlive one summon but not an afternoon; a resident helper is the memory budget.
    private static let idleTimeout: Duration = .seconds(600)

    init(secrets: MCPSecretStore = MCPSecretStore(), oauth: MCPOAuthManager? = nil) {
        self.oauth = oauth
        self.secrets = secrets
    }

    func status(of id: UUID) -> MCPServerStatus {
        connections[id]?.status ?? .stopped
    }

    var tools: [MCPTool] {
        connections.values.filter { $0.status.isReady }.flatMap(\.tools)
    }

    /// Brings the running set in line with what Settings holds, starting only what is missing.
    func reconcile(_ servers: [MCPServer]) {
        let wanted = Dictionary(servers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, connection) in connections where wanted[id] != connection.server {
            starting.removeValue(forKey: id)?.cancel()
            connection.stop()
            connections[id] = nil
        }
        for server in servers {
            guard let existing = connections[server.id] else {
                let connection = MCPServerConnection(
                    server: server, secrets: secrets.secrets(for: server.id), oauth: oauth)
                connections[server.id] = connection
                start(connection)
                continue
            }
            // Idle covers failed, so entering chat retries a server that lost its network once.
            if existing.isIdle { start(existing) }
        }
        resumePreparations()
        armIdleTimer()
    }

    func prepare(_ servers: [MCPServer]) async throws {
        try Task.checkCancellation()
        reconcile(servers)
        let pending = Set(servers.map(\.id)).intersection(starting.keys)
        guard !pending.isEmpty else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                preparations[id] = Preparation(servers: pending, continuation: continuation)
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.preparations.removeValue(forKey: id)?.continuation
                    .resume(throwing: CancellationError())
            }
        }
    }

    private func start(_ connection: MCPServerConnection) {
        let id = connection.server.id
        guard starting[id] == nil else { return }
        starting[id] = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await connection.start()
            guard self?.connections[id] === connection else { return }
            self?.starting[id] = nil
            self?.resumePreparations()
        }
    }

    private func resumePreparations() {
        for (id, preparation) in preparations where preparation.servers.isDisjoint(with: starting.keys) {
            preparations[id] = nil
            preparation.continuation.resume()
        }
    }

    func connection(slug: String) -> MCPServerConnection? {
        connections.values.first { $0.server.slug == slug }
    }

    func disconnect(_ id: UUID) {
        starting.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.stop()
        resumePreparations()
    }

    func stop() {
        for task in starting.values { task.cancel() }
        starting = [:]
        let waiting = preparations.values
        preparations = [:]
        for preparation in waiting { preparation.continuation.resume(throwing: CancellationError()) }
        idleTask?.cancel()
        idleTask = nil
        for connection in connections.values { connection.stop() }
        connections = [:]
    }

    /// Restarted on every use, so the countdown measures idleness rather than uptime.
    func markUsed() {
        armIdleTimer()
    }

    private func armIdleTimer() {
        idleTask?.cancel()
        guard !connections.isEmpty else {
            idleTask = nil
            return
        }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }
}
