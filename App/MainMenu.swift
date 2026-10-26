import AppKit

/// The menu bar. Shortcuts follow VS Code's macOS defaults; actions go to the first responder (the text view, the
/// editor window controller or the app delegate).
enum MainMenu {
    private static func key(_ scalar: Int) -> String { String(Character(UnicodeScalar(scalar)!)) }
    static let up = key(NSUpArrowFunctionKey), down = key(NSDownArrowFunctionKey)

    static func build(recentDelegate: NSMenuDelegate) -> NSMenu {
        let main = NSMenu()
        @discardableResult
        func menu(_ title: String, _ fill: (NSMenu) -> Void) -> NSMenu {
            let item = NSMenuItem()
            item.title = title
            let m = NSMenu(title: title)
            fill(m)
            item.submenu = m
            main.addItem(item)
            return m
        }

        menu("Squint") { m in
            m.add("About Squint", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
            m.add("Check for Updates…", #selector(Updater.checkForUpdates(_:))).target = Updater.shared
            m.add("Setup Guide…", #selector(AppDelegate.showSetup(_:)))
            m.addItem(.separator())
            m.add("Settings…", #selector(AppDelegate.showSettings(_:)), ",")
            m.addItem(.separator())
            m.add("Hide Squint", #selector(NSApplication.hide(_:)), "h")
            m.add("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            m.add("Show All", #selector(NSApplication.unhideAllApplications(_:)))
            m.addItem(.separator())
            m.add("Quit Squint", #selector(NSApplication.terminate(_:)), "q")
        }
        menu("File") { m in
            m.add("New File", #selector(EditorWindowController.newDocument(_:)), "n")
            m.add("New Window", #selector(AppDelegate.newWindow(_:)), "n", [.command, .shift])
            m.addItem(.separator())
            m.add("Open…", #selector(AppDelegate.openDocument(_:)), "o")
            m.add("Open Folder…", #selector(AppDelegate.openFolderPanel(_:)), "o", [.command, .control])
            let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
            let recentMenu = NSMenu(title: "Open Recent")
            recentMenu.delegate = recentDelegate
            recent.submenu = recentMenu
            m.addItem(recent)
            m.addItem(.separator())
            m.add("Save", #selector(EditorWindowController.saveDocument(_:)), "s")
            m.add("Save As…", #selector(EditorWindowController.saveDocumentAs(_:)), "s", [.command, .shift])
            m.add("Revert File", #selector(EditorWindowController.revertDocumentToSaved(_:)))
            m.addItem(.separator())
            m.add("Reveal in Finder", #selector(EditorWindowController.revealInFinder(_:)))
            m.add("Copy Path of Active File", #selector(EditorWindowController.copyFilePath(_:)))
            m.addItem(.separator())
            // Like VS Code: ⌘W closes the file (back to the start page), and the window once nothing is open.
            m.add("Close File", #selector(EditorWindowController.closeFile(_:)), "w")
            m.add("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        }
        menu("Edit") { m in
            m.add("Undo", Selector(("undo:")), "z")
            m.add("Redo", Selector(("redo:")), "z", [.command, .shift])
            m.addItem(.separator())
            m.add("Cut", #selector(NSText.cut(_:)), "x")
            m.add("Copy", #selector(NSText.copy(_:)), "c")
            m.add("Paste", #selector(NSText.paste(_:)), "v")
            m.add("Select All", #selector(NSText.selectAll(_:)), "a")
            m.addItem(.separator())
            m.sub("Find") { f in
                f.add("Find…", #selector(EditorWindowController.showFind(_:)), "f")
                f.add("Replace…", #selector(EditorWindowController.showReplace(_:)), "f", [.command, .option])
                f.add("Find Next", #selector(EditorWindowController.findNextMatch(_:)), "g")
                f.add("Find Previous", #selector(EditorWindowController.findPreviousMatch(_:)), "g", [.command, .shift])
                f.add("Use Selection for Find", #selector(EditorWindowController.useSelectionForFind(_:)), "e")
                f.addItem(.separator())
                f.add("Match Case", #selector(EditorWindowController.toggleMatchCase(_:)), "c", [.command, .option])
                f.add("Match Whole Word", #selector(EditorWindowController.toggleWholeWord(_:)), "w", [.command, .option])
                f.add("Use Regular Expression", #selector(EditorWindowController.toggleRegex(_:)), "r", [.command, .option])
                f.add("Preserve Case", #selector(EditorWindowController.togglePreserveCase(_:)), "p", [.command, .option])
                f.add("Find in Selection", #selector(EditorWindowController.toggleFindInSelection(_:)), "l", [.command, .option])
            }
            m.addItem(.separator())
            m.add("Toggle Line Comment", #selector(EditorTextView.toggleLineComment(_:)), "/")
            m.add("Toggle Block Comment", #selector(EditorTextView.toggleBlockComment(_:)), "a", [.shift, .option])
            m.sub("Lines") { l in
                l.add("Indent Line", #selector(EditorTextView.indentLines(_:)), "]")
                l.add("Outdent Line", #selector(EditorTextView.outdentLines(_:)), "[")
                l.addItem(.separator())
                l.add("Move Line Up", #selector(EditorTextView.moveLinesUp(_:)), up, [.option])
                l.add("Move Line Down", #selector(EditorTextView.moveLinesDown(_:)), down, [.option])
                l.add("Copy Line Up", #selector(EditorTextView.copyLinesUp(_:)), up, [.option, .shift])
                l.add("Copy Line Down", #selector(EditorTextView.copyLinesDown(_:)), down, [.option, .shift])
                l.add("Delete Line", #selector(EditorTextView.deleteLines(_:)), "k", [.command, .shift])
                l.addItem(.separator())
                l.add("Insert Line Below", #selector(EditorTextView.insertLineBelow(_:)), "\r")
                l.add("Insert Line Above", #selector(EditorTextView.insertLineAbove(_:)), "\r", [.command, .shift])
                l.add("Join Lines", #selector(EditorTextView.joinLines(_:)), "j", [.control])
                l.addItem(.separator())
                l.add("Sort Lines Ascending", #selector(EditorTextView.sortLinesAscending(_:)))
                l.add("Sort Lines Descending", #selector(EditorTextView.sortLinesDescending(_:)))
                l.add("Trim Trailing Whitespace", #selector(EditorTextView.trimTrailingWhitespace(_:)))
            }
            m.sub("Transform") { t in
                t.add("Transform to Uppercase", #selector(EditorTextView.transformToUppercase(_:)))
                t.add("Transform to Lowercase", #selector(EditorTextView.transformToLowercase(_:)))
            }
        }
        menu("Selection") { m in
            m.add("Expand Line Selection", #selector(EditorTextView.expandLineSelection(_:)), "l")
            m.addItem(.separator())
            m.add("Add Cursor Above", #selector(EditorTextView.addCursorAbove(_:)), up, [.command, .option])
            m.add("Add Cursor Below", #selector(EditorTextView.addCursorBelow(_:)), down, [.command, .option])
            m.add("Add Cursors to Line Ends", #selector(EditorTextView.addCursorsToLineEnds(_:)), "i", [.shift, .option])
            m.add("Add Next Occurrence", #selector(EditorTextView.addSelectionToNextFindMatch(_:)), "d")
            m.add("Select All Occurrences", #selector(EditorTextView.selectAllOccurrences(_:)), "l", [.command, .shift])
        }
        menu("View") { m in
            m.add("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "b")
            m.add("Explorer", #selector(EditorWindowController.showExplorer(_:)), "e", [.command, .shift])
            m.addItem(.separator())
            m.add("Word Wrap", #selector(EditorWindowController.toggleWordWrap(_:)), "z", [.option])
            m.add("Line Numbers", #selector(EditorWindowController.toggleLineNumbers(_:)))
            m.add("Change Language Mode…", #selector(EditorWindowController.changeLanguageMode(_:)))
            m.addItem(.separator())
            m.add("Zoom In", #selector(EditorWindowController.zoomIn(_:)), "=")
            m.add("Zoom Out", #selector(EditorWindowController.zoomOut(_:)), "-")
            m.add("Reset Zoom", #selector(EditorWindowController.resetZoom(_:)), "0")
            m.addItem(.separator())
            m.add("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        }
        menu("Go") { m in
            m.add("Go to File…", #selector(EditorWindowController.goToFile(_:)), "p")
            m.add("Go to Line…", #selector(EditorWindowController.goToLine(_:)), "g", [.control])
            m.add("Go to Bracket", #selector(EditorTextView.jumpToBracket(_:)), "\\", [.command, .shift])
            m.addItem(.separator())
            m.add("Back", #selector(EditorWindowController.goBack(_:)), "-", [.control])
            m.add("Forward", #selector(EditorWindowController.goForward(_:)), "-", [.control, .shift])
            m.addItem(.separator())
            m.add("Next File in Folder", #selector(EditorWindowController.nextFileInFolder(_:)), "]", [.command, .shift])
            m.add("Previous File in Folder", #selector(EditorWindowController.previousFileInFolder(_:)), "[", [.command, .shift])
        }
        let window = menu("Window") { m in
            m.add("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            m.add("Zoom", #selector(NSWindow.performZoom(_:)))
            m.addItem(.separator())
            m.add("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        }
        NSApp.windowsMenu = window
        return main
    }
}

extension NSMenu {
    @discardableResult
    func add(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = addItem(withTitle: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }

    func sub(_ title: String, _ fill: (NSMenu) -> Void) {
        let item = addItem(withTitle: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        fill(menu)
        item.submenu = menu
    }
}
