import Foundation

/// The Shiki engine shared by every editor window. Its JS bundle, grammars and themes live inside the Quick Look
/// extension bundle.
enum EditorEngine {
    static var resources = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/SquintExtension.appex/Contents/Resources")
    static let highlighter = Highlighter(resources: resources)
    private static var nextDocumentId = 0

    static func makeDocumentId() -> Int {
        nextDocumentId += 1
        return nextDocumentId
    }
}

extension Notification.Name {
    /// Posted by the settings window after it saved new settings.
    static let squintSettingsChanged = Notification.Name("SquintSettingsChanged")
}
