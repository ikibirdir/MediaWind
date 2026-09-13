import AppKit
import MediaWindCore

/// Builds the menu bar in code. Every command lives here with its shortcut. Viewer commands
/// have a nil target, so they reach ViewerWindowController through the responder chain and
/// are disabled (their keys pass through) when another window is key.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenuItem(appMenu()))
        main.addItem(submenuItem(fileMenu()))
        main.addItem(submenuItem(editMenu()))
        main.addItem(submenuItem(viewMenu()))
        main.addItem(submenuItem(videoMenu()))
        let window = windowMenu()
        main.addItem(submenuItem(window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(submenuItem(help))
        NSApp.helpMenu = help
        return main
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "MediaWind")
        menu.addItem(item("About MediaWind", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""))
        menu.addItem(.separator())

        let defaults = NSMenu(title: "Default Viewer")
        defaults.addItem(item("Make MediaWind the Default for Photos…", #selector(AppDelegate.makeDefaultForPhotos(_:)), ""))
        defaults.addItem(item("Make MediaWind the Default for Videos…", #selector(AppDelegate.makeDefaultForVideos(_:)), ""))
        defaults.addItem(.separator())
        defaults.addItem(item("Restore Preview and QuickTime Player…", #selector(AppDelegate.restoreSystemDefaults(_:)), ""))
        let defaultsItem = NSMenuItem(title: "Default Viewer", action: nil, keyEquivalent: "")
        defaultsItem.submenu = defaults
        menu.addItem(defaultsItem)

        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item("Hide MediaWind", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item("Quit MediaWind", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("Open…", #selector(AppDelegate.openDocument(_:)), "o"))
        menu.addItem(.separator())
        menu.addItem(item("Open in Preview", #selector(ViewerWindowController.openInPreview(_:)), "o", [.command, .shift]))
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let openWithMenu = NSMenu(title: "Open With")
        openWithMenu.delegate = OpenWithMenuDelegate.shared
        openWith.submenu = openWithMenu
        menu.addItem(openWith)
        menu.addItem(item("Show in Finder", #selector(ViewerWindowController.showInFinder(_:)), "r", [.command, .shift]))
        menu.addItem(item("Show in Finder When Closing", #selector(ViewerWindowController.toggleShowInFinderOnClose(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Copy", #selector(ViewerWindowController.copy(_:)), "c"))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Previous", #selector(ViewerWindowController.showPrevious(_:)), key(NSLeftArrowFunctionKey), []))
        menu.addItem(item("Next", #selector(ViewerWindowController.showNext(_:)), key(NSRightArrowFunctionKey), []))
        menu.addItem(item("First", #selector(ViewerWindowController.showFirst(_:)), key(NSHomeFunctionKey), []))
        menu.addItem(item("Last", #selector(ViewerWindowController.showLast(_:)), key(NSEndFunctionKey), []))
        menu.addItem(.separator())
        menu.addItem(item("Zoom In", #selector(ViewerWindowController.zoomIn(_:)), "+"))
        menu.addItem(item("Zoom Out", #selector(ViewerWindowController.zoomOut(_:)), "-"))
        menu.addItem(item("Zoom to Fit", #selector(ViewerWindowController.zoomToFit(_:)), "0"))
        menu.addItem(item("Actual Size", #selector(ViewerWindowController.zoomToActualSize(_:)), "1"))
        menu.addItem(.separator())

        let sort = NSMenu(title: "Sort By")
        let change = #selector(ViewerWindowController.changeSortOrder(_:))
        sort.addItem(item("Follow Finder", change, "", tag: 0))
        sort.addItem(.separator())
        sort.addItem(item("Name", change, "", tag: 1))
        sort.addItem(item("Kind", change, "", tag: 2))
        sort.addItem(item("Date Created", change, "", tag: 3))
        sort.addItem(item("Date Modified", change, "", tag: 4))
        sort.addItem(item("Date Added", change, "", tag: 5))
        sort.addItem(item("Date Last Opened", change, "", tag: 6))
        sort.addItem(item("Size", change, "", tag: 7))
        sort.addItem(.separator())
        sort.addItem(item("Reverse Order", #selector(ViewerWindowController.toggleSortDirection(_:)), "", tag: 100))
        let sortItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        sortItem.submenu = sort
        menu.addItem(sortItem)
        menu.addItem(.separator())

        // F and ⌃⌘F: the second is an alternate, shown while holding ⌃⌘. A viewer-only action
        // (not NSWindow's toggleFullScreen:), so a bare F still types in other windows' text fields.
        let fullScreen = item("Enter Full Screen", #selector(ViewerWindowController.toggleViewerFullScreen(_:)), "f", [])
        let fullScreenAlt = item("Enter Full Screen", #selector(ViewerWindowController.toggleViewerFullScreen(_:)), "f", [.control, .command])
        fullScreenAlt.isAlternate = true
        menu.addItem(fullScreen)
        menu.addItem(fullScreenAlt)
        menu.addItem(item("Exit Full Screen or Close", #selector(ViewerWindowController.escapeAction(_:)), "\u{1b}", []))
        return menu
    }

    private static func videoMenu() -> NSMenu {
        let menu = NSMenu(title: "Video")
        menu.addItem(item("Play/Pause", #selector(ViewerWindowController.togglePlayPause(_:)), " ", []))
        menu.addItem(item("Mute", #selector(ViewerWindowController.toggleMute(_:)), "m", []))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("Keyboard Shortcuts", #selector(AppDelegate.showKeyboardShortcuts(_:)), "/"))
        return menu
    }

    // MARK: - Helpers

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String,
                             _ modifiers: NSEvent.ModifierFlags = [.command], tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        return item
    }

    private static func key(_ functionKey: Int) -> String {
        String(Character(UnicodeScalar(UInt32(functionKey))!))
    }
}

/// Fills File ▸ Open With with the apps that can open the current file, never MediaWind itself.
final class OpenWithMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = OpenWithMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let controller = NSApp.keyWindow?.windowController as? ViewerWindowController
        guard let url = controller?.currentURL else {
            menu.addItem(NSMenuItem(title: "No File", action: nil, keyEquivalent: ""))
            return
        }
        let apps = OtherApps.candidates(for: url)
        if apps.isEmpty {
            menu.addItem(NSMenuItem(title: "No Other Apps", action: nil, keyEquivalent: ""))
        }
        for app in apps {
            let item = NSMenuItem(title: app.name, action: #selector(ViewerWindowController.openWithApp(_:)), keyEquivalent: "")
            item.representedObject = app.url
            item.image = app.icon
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Other…", action: #selector(ViewerWindowController.openWithOtherApp(_:)), keyEquivalent: ""))
    }
}
