import AppKit

/// Moves our existing managed panel into the active Space without recreating it.
final class DesktopSpaces {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Current = @convention(c) (Int32, CFString) -> UInt64
    private typealias Move = @convention(c) (Int32, CFArray, UInt64) -> Void

    private let library: UnsafeMutableRawPointer
    private let connection: Int32
    private let current: Current
    private let move: Move?

    init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        guard let connectionSymbol = dlsym(handle, "SLSMainConnectionID"),
              let currentSymbol = dlsym(handle, "SLSManagedDisplayGetCurrentSpace") else {
            dlclose(handle)
            return nil
        }
        library = handle
        connection = unsafeBitCast(connectionSymbol, to: Connection.self)()
        current = unsafeBitCast(currentSymbol, to: Current.self)
        move = dlsym(handle, "SLSMoveWindowsToManagedSpace").map { unsafeBitCast($0, to: Move.self) }
    }

    deinit { dlclose(library) }

    func moveWindowToActiveSpace(windowNumber: Int, on display: String?) {
        guard let display, let move, connection > 0, windowNumber > 0 else { return }
        let id = current(connection, display as CFString)
        guard id != 0 else { return }
        move(connection, [NSNumber(value: windowNumber)] as CFArray, id)
    }
}
