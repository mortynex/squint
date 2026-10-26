import SwiftUI

/// First-launch guide (also Squint › Setup Guide…): turns on the Quick Look extension, turns off other previewers
/// of the same types, offers the default-app switch and update checks.
struct SetupView: View {
    var done: () -> Void = {}
    @State private var status: QuickLookExtensions.Status?
    @State private var automaticUpdates = Updater.shared.automaticChecks

    private var outsideApplications: Bool {
        let path = DefaultApps.appBundle.path
        return !path.hasPrefix("/Applications/") && !path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: DefaultApps.appBundle.path)).resizable().frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Welcome to Squint").font(.title2.bold())
                            Text("A few things to set up so Space previews code and double-click opens it here.").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if outsideApplications {
                    Section {
                        Step(ok: false, title: "Move Squint to Applications",
                             detail: "Quick Look and updates need Squint in your Applications folder. Quit, drag Squint there from the disk image and open it from there.")
                    }
                }
                quickLook
                previewers
                DefaultAppsSection()
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: $automaticUpdates)
                        .onChange(of: automaticUpdates) { Updater.shared.automaticChecks = $0 }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text("You can open this again from the Squint menu.").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 560, height: 640)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var quickLook: some View {
        Section("Quick Look") {
            switch status?.squint {
            case nil:
                Step(ok: nil, title: "Checking the Quick Look extension…", detail: nil)
            case .on:
                Step(ok: true, title: "Quick Look preview is on", detail: "Select a code file in Finder and press Space.")
            case .off:
                Step(ok: false, title: "Quick Look preview is off", detail: "Turn it on to preview code with Space.") {
                    Button("Turn On") { change { QuickLookExtensions.enableSquint() } }
                }
            case .missing:
                Step(ok: false, title: "Quick Look preview isn't registered", detail: "Register Squint's extension with macOS.") {
                    Button("Turn On") { change { QuickLookExtensions.enableSquint() } }
                }
            case .otherCopy(let path):
                Step(ok: false, title: "Quick Look uses another copy of Squint",
                     detail: (path as NSString).abbreviatingWithTildeInPath) {
                    Button("Use This Copy") { change { QuickLookExtensions.enableSquint() } }
                }
            }
            Button("Quick Look Extension Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!)
            }
        }
    }

    @ViewBuilder private var previewers: some View {
        if let status {
            Section {
                if status.competitors.isEmpty {
                    Step(ok: true, title: "No other code previewers are on", detail: nil)
                }
                ForEach(status.competitors) { c in
                    Step(ok: false, title: c.info.name,
                         detail: "Previews \(c.sharedTypes) of the same file type\(c.sharedTypes == 1 ? "" : "s"); macOS may pick it instead of Squint.") {
                        Button("Turn Off") { change { QuickLookExtensions.setEnabled(c.info.id, false) } }
                    }
                }
            } header: {
                Text("Other Previewers")
            }
        }
    }

    private func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let s = QuickLookExtensions.status()
            DispatchQueue.main.async { status = s }
        }
    }

    private func change(_ action: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            action()
            let s = QuickLookExtensions.status()
            DispatchQueue.main.async { status = s }
        }
    }
}

/// A checklist row: a green check, an orange warning or a spinner (`ok == nil`), and an optional action.
private struct Step<Action: View>: View {
    let ok: Bool?
    let title: String
    let detail: String?
    let action: Action

    init(ok: Bool?, title: String, detail: String?, @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.ok = ok
        self.title = title
        self.detail = detail
        self.action = action()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if let ok {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(ok ? .green : .orange)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            action
        }
    }
}

/// Which app opens Squint's file types, with a button per other app (shared by Settings and the setup guide).
struct DefaultAppsSection: View {
    @State private var defaults = DefaultApps.status()
    @State private var restorable = DefaultApps.restorable

    var body: some View {
        Section {
            LabeledContent("Squint opens") {
                Text("\(defaults.squint) of \(defaults.total) file types").foregroundStyle(.secondary)
            }
            ForEach(defaults.others) { app in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                        Text("\(app.types.count) type\(app.types.count == 1 ? "" : "s"): \(app.summary)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Use Squint") { takeOver(app) }
                }
            }
            if restorable > 0 {
                Button("Restore Previous Apps (\(restorable))") { restore() }
            }
        } header: {
            Text("Default App")
        } footer: {
            Text("Squint opens every type it previews unless you chose another app for it. macOS asks you to confirm each type taken from another app.")
                .foregroundStyle(.secondary)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
    }

    private func refresh() {
        defaults = DefaultApps.status()
        restorable = DefaultApps.restorable
    }

    private func takeOver(_ app: DefaultApps.OtherApp) {
        let alert = NSAlert()
        alert.messageText = "Open \(app.types.count == 1 ? "this file type" : "these \(app.types.count) file types") with Squint instead of \(app.name)?"
        alert.informativeText = app.summary + "\n\nmacOS will ask you to confirm each one."
        alert.addButton(withTitle: "Use Squint")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DefaultApps.claim(app.types)
        for delay in [1.0, 4.0, 10.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { refresh() } }
    }

    private func restore() {
        let alert = NSAlert()
        alert.messageText = "Give \(restorable) file types back to the apps that opened them before?"
        alert.informativeText = "macOS may ask you to confirm each one."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DefaultApps.restore()
        for delay in [1.0, 4.0, 10.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { refresh() } }
    }
}
