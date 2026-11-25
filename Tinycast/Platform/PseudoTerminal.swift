import Darwin
import Foundation

/// libc block-buffers a pipe, so a pty is what makes output live and correctly ordered.
final class PseudoTerminal: @unchecked Sendable {
    /// Everything the command writes to any of its three descriptors arrives here.
    let parentEnd: Int32
    let processID: pid_t
    private let exitSource: any DispatchSourceProcess

    private init(parentEnd: Int32, processID: pid_t, exitSource: any DispatchSourceProcess) {
        self.parentEnd = parentEnd
        self.processID = processID
        self.exitSource = exitSource
    }

    static func spawn(
        executable: String, arguments: [String], environment: [String: String],
        workingDirectory: String, queue: DispatchQueue
    ) -> PseudoTerminal? {
        let flags = O_RDWR | O_NOCTTY | O_CLOEXEC
        let parentEnd = posix_openpt(flags)
        guard parentEnd >= 0 else { return nil }
        guard let childEnd = openChildEnd(for: parentEnd, flags: flags) else {
            Darwin.close(parentEnd)
            return nil
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        // The whole point: the child leads its session, so `kill(-pid)` reaches it all.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addchdir(&actions, workingDirectory)
        for descriptor in Int32(0)...Int32(2) {
            posix_spawn_file_actions_adddup2(&actions, childEnd, descriptor)
        }

        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }

        var processID: pid_t = 0
        let argv = CStringArray([executable] + arguments)
        let envp = CStringArray(environment.map { "\($0.key)=\($0.value)" })
        let status = posix_spawn(
            &processID, executable, &actions, &attributes, argv.pointers, envp.pointers)
        guard status == 0, processID > 0 else {
            Darwin.close(childEnd)
            Darwin.close(parentEnd)
            return nil
        }
        // Stands in for `/dev/null` stdin: a prompting command reads EOF and moves on.
        var endOfTransmission: UInt8 = 0x04
        _ = write(parentEnd, &endOfTransmission, 1)

        let exitSource = DispatchSource.makeProcessSource(identifier: processID, eventMask: .exit, queue: queue)
        exitSource.setCancelHandler { Darwin.close(childEnd) }
        exitSource.setEventHandler { [weak exitSource] in
            while tcdrain(childEnd) == -1 && errno == EINTR {}
            exitSource?.cancel()
        }
        exitSource.activate()
        return PseudoTerminal(parentEnd: parentEnd, processID: processID, exitSource: exitSource)
    }

    /// Signals the session rather than the process — the negative pid is what reaches the children.
    func signalSession(_ signal: Int32) {
        guard processID > 0 else { return }
        kill(-processID, signal)
    }

    /// Blocks until the command exits. A signalled death reports the signal, the way a shell does.
    func wait() -> Int32 {
        var status: Int32 = 0
        while waitpid(processID, &status, 0) < 0 && errno == EINTR {}
        if status & 0x7F != 0 { return 128 + (status & 0x7F) }
        return (status >> 8) & 0xFF
    }

    func close() {
        exitSource.cancel()
        Darwin.close(parentEnd)
    }

    private static func openChildEnd(for parentEnd: Int32, flags: Int32) -> Int32? {
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard grantpt(parentEnd) == 0, unlockpt(parentEnd) == 0,
            ptsname_r(parentEnd, &path, path.count) == 0
        else { return nil }
        let childEnd = open(path, flags)
        guard childEnd >= 0 else { return nil }
        if configure(childEnd) { return childEnd }
        Darwin.close(childEnd)
        return nil
    }

    private static func configure(_ childEnd: Int32) -> Bool {
        var settings = termios()
        guard tcgetattr(childEnd, &settings) == 0 else { return false }
        cfmakeraw(&settings)
        settings.c_lflag = tcflag_t(ICANON | ISIG)
        settings.c_oflag = tcflag_t(OPOST | ONLCR)
        return tcsetattr(childEnd, TCSANOW, &settings) == 0
    }
}

/// The argv/envp arrays must outlive `posix_spawn`, so this is a real allocation.
private final class CStringArray {
    let pointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ values: [String]) {
        count = values.count
        pointers = .allocate(capacity: count + 1)
        for (index, value) in values.enumerated() { pointers[index] = strdup(value) }
        pointers[count] = nil
    }

    deinit {
        for index in 0..<count { free(pointers[index]) }
        pointers.deallocate()
    }
}
