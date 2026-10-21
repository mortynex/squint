import SwiftUI

private struct ThemeInfo: Decodable, Identifiable {
    let id: String
    let name: String
    let type: String
}

private enum PreviewAppearance: String, CaseIterable, Identifiable {
    case system = "Auto", light = "Light", dark = "Dark"
    var id: String { rawValue }
}

private final class SettingsModel: ObservableObject {
    @Published var settings = Settings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            NotificationCenter.default.post(name: .squintSettingsChanged, object: nil)
        }
    }
    @Published var defaults = DefaultApps.status()
    @Published var restorable = DefaultApps.restorable

    func refreshDefaults() {
        defaults = DefaultApps.status()
        restorable = DefaultApps.restorable
    }
    let themes: [ThemeInfo]
    let fonts: [String]

    init() {
        let url = AppDelegate.engineResources.appendingPathComponent("themes.json")
        themes = (try? JSONDecoder().decode([ThemeInfo].self, from: Data(contentsOf: url))) ?? []
        let manager = NSFontManager.shared
        fonts = manager.availableFontFamilies.filter { family in
            manager.font(withFamily: family, traits: [], weight: 5, size: 12)?.isFixedPitch ?? false
        }
    }
}

struct SettingsView: View {
    @StateObject private var model = SettingsModel()
    @State private var appearance = PreviewAppearance.system
    @Environment(\.colorScheme) private var systemScheme

    private var previewDark: Bool {
        switch appearance {
        case .system: return systemScheme == .dark
        case .light: return false
        case .dark: return true
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            form.frame(width: 340)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text("Preview").font(.headline)
                    Spacer()
                    Picker("", selection: $appearance) {
                        ForEach(PreviewAppearance.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                }
                .padding(12)
                CodePreview(settings: model.settings, dark: previewDark)
            }
        }
        .frame(minWidth: 860, minHeight: 540)
    }

    private var form: some View {
        Form {
            Section("Theme") {
                Picker("Light", selection: $model.settings.lightTheme) {
                    ForEach(model.themes.filter { $0.type == "light" }) { Text($0.name).tag($0.id) }
                }
                Picker("Dark", selection: $model.settings.darkTheme) {
                    ForEach(model.themes.filter { $0.type == "dark" }) { Text($0.name).tag($0.id) }
                }
            }
            Section("Font") {
                Picker("Family", selection: $model.settings.fontFamily) {
                    Text("System Mono").tag("")
                    ForEach(model.fonts, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Size: \(model.settings.fontSize) pt", value: $model.settings.fontSize, in: 9...28)
            }
            Section("Editor") {
                Toggle("Glass window", isOn: $model.settings.glassWindow)
                Toggle("Line numbers", isOn: $model.settings.lineNumbers)
                Toggle("Wrap long lines", isOn: $model.settings.wrapLines)
                Toggle("Highlight current line", isOn: $model.settings.highlightCurrentLine)
                Toggle("Indent guides", isOn: $model.settings.indentGuides)
                Toggle("Auto-close brackets and quotes", isOn: $model.settings.autoClosingBrackets)
                Picker("Tab size", selection: $model.settings.tabSize) {
                    ForEach([2, 3, 4, 8], id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("Indent using spaces", isOn: $model.settings.insertSpaces)
                Toggle("Detect indentation from file", isOn: $model.settings.detectIndentation)
            }
            Section {
                LabeledContent("Squint opens") {
                    Text("\(model.defaults.squint) of \(model.defaults.total) file types").foregroundStyle(.secondary)
                }
                ForEach(model.defaults.others) { app in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                            Text("\(app.types.count) type\(app.types.count == 1 ? "" : "s"): \(app.summary)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Use Squint") { takeOver(app) }
                    }
                }
                if model.restorable > 0 {
                    Button("Restore Previous Apps (\(model.restorable))") { restore() }
                }
            } header: {
                Text("Default App")
            } footer: {
                Text("Squint opens every type it previews unless you chose another app for it. macOS asks you to confirm each type taken from another app.")
                    .foregroundStyle(.secondary)
            }
            Section("Quick Look") {
                Toggle("Transparent background", isOn: $model.settings.transparentBackground)
                Button("Quick Look Extension Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!)
                }
                Button("Refresh Quick Look") {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
                    p.arguments = ["-r", "cache"]
                    try? p.run()
                }
                Text("Quick Look changes apply the next time you press Space on a file.").foregroundStyle(.secondary).font(.footnote)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshDefaults() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.refreshDefaults() }
    }

    private func takeOver(_ app: DefaultApps.OtherApp) {
        let alert = NSAlert()
        alert.messageText = "Open \(app.types.count == 1 ? "this file type" : "these \(app.types.count) file types") with Squint instead of \(app.name)?"
        alert.informativeText = app.summary + "\n\nmacOS will ask you to confirm each one."
        alert.addButton(withTitle: "Use Squint")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DefaultApps.claim(app.types)
        for delay in [1.0, 4.0, 10.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { model.refreshDefaults() } }
    }

    private func restore() {
        let alert = NSAlert()
        alert.messageText = "Give \(model.restorable) file types back to the apps that opened them before?"
        alert.informativeText = "macOS may ask you to confirm each one."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DefaultApps.restore()
        for delay in [1.0, 4.0, 10.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { model.refreshDefaults() } }
    }
}

/// Live preview of the current settings, rendered by the same code the Quick Look extension uses.
private struct CodePreview: NSViewRepresentable {
    let settings: Settings
    let dark: Bool

    private static let sample = """
    import { useState } from "react";

    interface User { id: number; name: string; email?: string }

    /** Fetch a user from the API. */
    export async function getUser(id: number): Promise<User | null> {
      const res = await fetch(`/api/users/${id}`, { headers: { Accept: "application/json" } });
      if (!res.ok) return null;
      return (await res.json()) as User;
    }

    export function Counter() {
      const [count, setCount] = useState(0);
      return <button onClick={() => setCount(count + 1)}>Clicked {count} times</button>;
    }
    """

    final class Coordinator { lazy var highlighter = Highlighter(resources: AppDelegate.engineResources) }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let options = settings.options(dark: dark)
        let result = context.coordinator.highlighter.highlight(code: Self.sample, name: "example.tsx", options: options)
        let root = PreviewRootView(frame: container.bounds, text: Self.sample, result: result, options: options, mode: .embedded)
        root.autoresizingMask = [.width, .height]
        container.addSubview(root)
    }
}
