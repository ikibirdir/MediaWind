import AppKit
import AVKit

/// Test hook for automated checks without Accessibility or Screen Recording permissions.
/// Inactive unless the app is launched with
///
///     open --env PHOTOVIEWER_DEBUG=1 -a /Applications/PhotoViewer.app photo.jpg
///
/// Commands arrive as distributed notifications named "com.ikibirdir.PhotoViewer.debug"
/// whose object is a string (see scripts/pvdebug.swift):
///   key <keyCode> [cmd|ctrl|shift|opt]...   key down + up, through NSApp.sendEvent like a real key
///   down <keyCode> / repeat <keyCode> / up <keyCode>
///   state <path>       writes JSON describing the window
///   snapshot <path>    renders the window's layers to a PNG
enum DebugHook {
    static let notification = Notification.Name("com.ikibirdir.PhotoViewer.debug")
    nonisolated(unsafe) private static var observer: NSObjectProtocol?

    static func installIfRequested(viewer: @escaping () -> ViewerWindowController?) {
        guard ProcessInfo.processInfo.environment["PHOTOVIEWER_DEBUG"] == "1" else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { note in
            guard let command = note.object as? String else { return }
            handle(command, viewer: viewer())
        }
    }

    private static func handle(_ command: String, viewer: ViewerWindowController?) {
        let parts = command.split(separator: " ").map(String.init)
        guard let verb = parts.first else { return }
        switch verb {
        case "key", "down", "repeat", "up":
            guard parts.count > 1, let code = UInt16(parts[1]) else { return }
            var flags: NSEvent.ModifierFlags = []
            for modifier in parts.dropFirst(2) {
                switch modifier {
                case "cmd": flags.insert(.command)
                case "ctrl": flags.insert(.control)
                case "shift": flags.insert(.shift)
                case "opt": flags.insert(.option)
                default: break
                }
            }
            let window = NSApp.keyWindow ?? viewer?.window
            if verb != "up" { postKey(code, flags: flags, up: false, isRepeat: verb == "repeat", window: window) }
            if verb == "key" || verb == "up" { postKey(code, flags: flags, up: true, isRepeat: false, window: window) }
        case "state":
            guard parts.count > 1 else { return }
            writeState(to: parts[1], viewer: viewer)
        case "snapshot":
            guard parts.count > 1, let view = NSApp.keyWindow?.contentView ?? viewer?.window?.contentView else { return }
            snapshot(view, to: parts[1])
        default:
            break
        }
    }

    private static func postKey(_ code: UInt16, flags: NSEvent.ModifierFlags, up: Bool, isRepeat: Bool, window: NSWindow?) {
        let specials: [UInt16: Int] = [123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey,
                                       125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey,
                                       115: NSHomeFunctionKey, 119: NSEndFunctionKey]
        let letters: [UInt16: String] = [3: "f", 46: "m", 49: " ", 53: "\u{1b}", 29: "0", 18: "1",
                                         24: "=", 27: "-", 13: "w", 31: "o", 8: "c", 15: "r"]
        var modifiers = flags
        let characters: String
        if let special = specials[code] {
            characters = String(Character(UnicodeScalar(UInt32(special))!))
            modifiers.formUnion([.function, .numericPad])
        } else {
            characters = letters[code] ?? ""
        }
        guard let event = NSEvent.keyEvent(with: up ? .keyUp : .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window?.windowNumber ?? 0, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: isRepeat, keyCode: code) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private static func writeState(to path: String, viewer: ViewerWindowController?) {
        var state: [String: Any] = [
            "visibleWindows": NSApp.windows.filter(\.isVisible).map(\.title),
            "keyWindow": NSApp.keyWindow?.title ?? NSNull(),
            "isActive": NSApp.isActive,
            "residentMB": residentMegabytes(),
        ]
        if let viewer, let window = viewer.window {
            let image = viewer.imageView
            state["title"] = window.title
            state["isKey"] = window.isKeyWindow
            state["fullScreen"] = window.styleMask.contains(.fullScreen)
            state["firstResponder"] = window.firstResponder.map { String(describing: type(of: $0)) } ?? NSNull()
            state["current"] = viewer.navigator.current?.name ?? NSNull()
            state["shown"] = viewer.shownItem?.name ?? NSNull()
            state["quality"] = String(describing: viewer.shownQuality)
            state["position"] = viewer.navigator.positionDescription ?? NSNull()
            state["count"] = viewer.navigator.count
            state["sort"] = viewer.navigator.sortOrder.rawValue
            state["imageVisible"] = !image.isHidden
            state["isFit"] = image.isFit
            state["magnification"] = Double(image.magnification)
            state["fitMagnification"] = Double(image.fitMagnification)
            state["imageSize"] = [Double(image.imageSize.width), Double(image.imageSize.height)]
            state["shownPixelWidth"] = image.shownPixelWidth
            state["playerVisible"] = !viewer.playerView.isHidden
            state["playerRate"] = viewer.player.map { Double($0.rate) } ?? NSNull()
            state["playerMuted"] = viewer.player.map { $0.isMuted } ?? NSNull()
            state["messageVisible"] = !viewer.messageView.isHidden
            state["messageTitle"] = viewer.messageView.isHidden ? NSNull() : viewer.messageView.title
            state["bannerVisible"] = !viewer.banner.isHidden
            state["leftArrowVisible"] = !viewer.leftArrow.isHidden
            state["rightArrowVisible"] = !viewer.rightArrow.isHidden
        }
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private static func snapshot(_ view: NSView, to path: String) {
        guard let layer = view.layer else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static func residentMegabytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
}
