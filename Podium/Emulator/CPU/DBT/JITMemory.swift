import Foundation
#if canImport(Darwin)
import Darwin
import libkern.OSCacheControl
#endif

/// The memory translated code lives in: one region, allocated the first
/// time it's asked for and kept for the life of the process. On iOS it
/// comes from the attached debugger (StikDebug) — each request is a round
/// trip to it, and later ones are unreliable — so there is never a second
/// allocation: when the region fills up, everything in it is discarded
/// and translation starts over in the same memory.
///
/// Code is written at `writable` and runs at `executable`; they're the
/// same memory, at one address or two depending on how it was obtained.
final class JITMemory {
    let executable: UnsafeMutableRawPointer
    let writable: UnsafeMutableRawPointer
    let size: Int
    /// macOS keeps `MAP_JIT` memory either writable or executable, per
    /// thread, switched with `pthread_jit_write_protect_np`.
    private let switchesWriteProtection: Bool
    /// How the region was obtained (single RWX mapping vs debugger dual
    /// map), for the Developer screen.
    let mode: PodiumJITMode

    static let regionSize = 64 << 20

    private static var cached: JITMemory?
    private static let cacheLock = NSLock()

    /// The shared region, or nil when this process can't run generated
    /// code (on iOS, when no debugger has prepared memory for it).
    /// Retried on every access that finds nothing cached, so attaching the
    /// debugger after launch (then powering the machine back on, which
    /// builds a new session) picks JIT up without relaunching the app.
    static var shared: JITMemory? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached { return cached }
        let fresh = allocate()
        cached = fresh
        return fresh
    }

    /// Why `shared` is nil, in plain words for the Developer screen and
    /// the log — "no debugger attached" vs "debugger attached but its JIT
    /// setup didn't go through".
    static var unavailableReason: String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard cached == nil else { return nil }
        let message = String(cString: podium_jit_last_error())
        return message.isEmpty ? "JIT memory unavailable." : message
    }

    /// How the cached region was obtained, in plain words.
    static var modeName: String {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return switch cached?.mode {
        case .some(PodiumJITModeRWX): "single RWX mapping"
        case .some(PodiumJITModeDualMapped): "debugger dual map"
        default: "unknown mode"
        }
    }

    private init(executable: UnsafeMutableRawPointer, writable: UnsafeMutableRawPointer, size: Int, switchesWriteProtection: Bool, mode: PodiumJITMode) {
        self.executable = executable
        self.writable = writable
        self.size = size
        self.switchesWriteProtection = switchesWriteProtection
        self.mode = mode
    }

    private static func allocate() -> JITMemory? {
        #if os(macOS)
        guard let region = mmap(nil, regionSize, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0),
              region != MAP_FAILED else { return nil }
        return JITMemory(executable: region, writable: region, size: regionSize, switchesWriteProtection: true, mode: PodiumJITModeRWX)
        #elseif os(iOS)
        var writable: UnsafeMutableRawPointer?
        var mode = PodiumJITModeNone
        guard let executable = podium_jit_allocate(regionSize, &writable, &mode), let writable else { return nil }
        return JITMemory(executable: executable, writable: writable, size: regionSize, switchesWriteProtection: false, mode: mode)
        #else
        return nil
        #endif
    }

    /// Makes the region writable on this thread, for `body`, then
    /// executable again, with the instruction cache made coherent for the
    /// bytes at `offset..<offset + length`.
    func write(at offset: Int, length: Int, _ body: (UnsafeMutableRawPointer) -> Void) {
        #if os(macOS)
        if switchesWriteProtection { pthread_jit_write_protect_np(0) }
        #endif
        body(writable + offset)
        #if os(macOS)
        if switchesWriteProtection { pthread_jit_write_protect_np(1) }
        #endif
        sys_icache_invalidate(executable + offset, length)
    }
}
