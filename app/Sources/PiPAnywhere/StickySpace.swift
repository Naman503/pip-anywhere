import AppKit

/// Private SkyLight (window server) calls, loaded at runtime so a missing symbol just
/// disables the feature that needs it. They only ever act on our own connection and
/// windows; no SIP changes are involved.
@MainActor
enum SkyLight {
    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    static func symbol<T>(_ name: String, as _: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private typealias MainConnection = @convention(c) () -> Int32
    static let connection: Int32? = symbol("SLSMainConnectionID", as: MainConnection.self)?()

    private typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    /// The panel never activates the app, and the window server ignores cursor changes
    /// from background apps; this lets the resize handles show resize cursors anyway.
    static func allowCursorChangesInBackground() {
        guard let cid = connection,
              let set = symbol("SLSSetConnectionProperty", as: SetConnectionProperty.self) else {
            log("background cursor: SkyLight symbol missing")
            return
        }
        let status = set(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        if status != 0 { log("background cursor: SLSSetConnectionProperty returned \(status)") }
    }
}

/// Keeps our window perfectly still while the user swipes between desktops.
///
/// A window that joins all Spaces still slides out with the old Space and back in
/// with the new one. Instead, we create our own window-server space, show it above
/// the user's Spaces, and move the window into it, so Space switches don't move it.
/// This is how SketchyBar's `sticky` mode works.
@MainActor
enum StickySpace {
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsToSpace = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32
    private typealias ActiveSpace = @convention(c) (Int32) -> UInt64

    private struct API {
        let connection: Int32
        let addWindows: AddWindowsToSpace
        let activeSpace: ActiveSpace
        let space: UInt64
    }

    private static var api: API? = load()

    static var isAvailable: Bool { api != nil }

    private static func load() -> API? {
        guard let connection = SkyLight.connection,
              let spaceCreate = SkyLight.symbol("SLSSpaceCreate", as: SpaceCreate.self),
              let setLevel = SkyLight.symbol("SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevel.self),
              let showSpaces = SkyLight.symbol("SLSShowSpaces", as: ShowSpaces.self),
              let addWindows = SkyLight.symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", as: AddWindowsToSpace.self),
              let activeSpace = SkyLight.symbol("SLSGetActiveSpace", as: ActiveSpace.self)
        else {
            log("sticky space: SkyLight symbols missing; windows will slide with Spaces")
            return nil
        }
        let space = spaceCreate(connection, 1, 0)
        guard space != 0 else {
            log("sticky space: could not create a space")
            return nil
        }
        _ = setLevel(connection, space, Int32(UserDefaults.standard.integer(forKey: "stickySpaceLevel")))
        _ = showSpaces(connection, [NSNumber(value: space)] as CFArray)
        log("sticky space \(space) ready")
        return API(connection: connection, addWindows: addWindows, activeSpace: activeSpace, space: space)
    }

    /// Moves the window into the sticky space. Call after every order-front.
    static func attach(_ window: NSWindow) {
        guard let api, window.windowNumber > 0 else { return }
        let windows = [NSNumber(value: Int32(window.windowNumber))] as CFArray
        _ = api.addWindows(api.connection, api.space, windows, 0x7)
    }

    /// Puts the window back into the normal Space system.
    static func detach(_ window: NSWindow) {
        guard let api, window.windowNumber > 0 else { return }
        let windows = [NSNumber(value: Int32(window.windowNumber))] as CFArray
        _ = api.addWindows(api.connection, api.activeSpace(api.connection), windows, 0x7)
        // Let AppKit re-apply "all Spaces + over full screen".
        let behavior = window.collectionBehavior
        window.collectionBehavior = []
        window.collectionBehavior = behavior
    }
}
