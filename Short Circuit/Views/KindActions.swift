import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Long candidate lists are alphabetical, so the apps members already use are pulled to the top
/// where they can be found without scanning twenty names.
struct AppChoices {
    var current: [AppRef]
    var others: [AppRef]
    var labels: AppLabels

    var all: [AppRef] { current + others }

    init(kind: Kind) {
        var seen = Set<URL>()
        current = kind.members.compactMap(\.defaultApp).filter { seen.insert($0.url).inserted }
        others = kind.candidates.filter { seen.insert($0.url).inserted }
        labels = kind.labelContext
    }
}

enum Pasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

nonisolated extension Kind {
    /// Every identifier in the Kind, in member order: UTIs bare, schemes with their colon.
    var identifierList: [String] {
        members.map { member in
            switch member.target {
            case .uti(let identifier): identifier
            case .scheme(let scheme): "\(scheme):"
            case .fileExtension(let ext): ".\(ext)"
            }
        }
    }

    /// "Markdown (net.daringfireball.markdown, public.markdown)": the name a person reads plus the
    /// identifiers a developer came for, in the same shape the app uses for single types.
    var pasteboardText: String {
        "\(name) (\(identifierList.joined(separator: ", ")))"
    }
}

/// What a copied or dragged type carries besides its text: enough to rebuild the row elsewhere.
nonisolated struct KindExport: Codable, Sendable {
    var name: String
    var identifiers: [String]
    var extensions: [String]
    var mimeTypes: [String]
    var defaultApps: [String: String]

    init(_ kind: Kind) {
        name = kind.name
        identifiers = kind.identifierList
        extensions = kind.extensions
        mimeTypes = kind.mimeTypes
        var apps: [String: String] = [:]
        for (identifier, member) in zip(kind.identifierList, kind.members) {
            if let app = member.defaultApp { apps[identifier] = app.bundleID ?? app.url.path(percentEncoded: false) }
        }
        defaultApps = apps
    }
}

nonisolated extension Kind: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.pasteboardText)
        DataRepresentation(exportedContentType: .json) { kind in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(KindExport(kind))
        }
    }
}

extension Kind {
    /// For AppKit-era copy paths (`onCopyCommand`): the same text and JSON as `Transferable`.
    var itemProvider: NSItemProvider {
        let provider = NSItemProvider(object: pasteboardText as NSString)
        let export = KindExport(self)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.json.identifier, visibility: .all) { completion in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            completion(try? encoder.encode(export), nil)
            return nil
        }
        return provider
    }
}

/// "Open With" for a whole type: the same choices as the inspector's pop-up, for menus.
struct OpenWithMenu: View {
    let kind: Kind
    let store: KindStore

    var body: some View {
        let choices = AppChoices(kind: kind)
        Menu("Open With") {
            ForEach(choices.current) { item($0, choices: choices) }
            if !choices.current.isEmpty, !choices.others.isEmpty {
                Divider()
            }
            ForEach(choices.others) { item($0, choices: choices) }
            Divider()
            Button("Other…") { store.requestOtherApp(for: .kind(kind.id)) }
        }
        .disabled(!store.canWrite || kind.effectiveMembers.isEmpty)
    }

    private func item(_ app: AppRef, choices: AppChoices) -> some View {
        Button {
            Task { await store.setDefault(app, for: kind) }
        } label: {
            Label {
                if let note = kind.supportNote(for: app) {
                    Text("\(choices.labels.label(for: app)) — \(note)")
                } else {
                    Text(choices.labels.label(for: app))
                }
            } icon: {
                AppIconView(app: app, size: 16)
            }
        }
        .disabled(kind.defaultApp.map { AppIdentity.same($0.url, app.url) } ?? false)
    }
}

/// The actions for one type, shared by the Type menu and every context menu that shows a type,
/// so a right-click and the menu bar always offer the same things.
struct KindActions: View {
    let kind: Kind
    let store: KindStore
    var showsInBrowser = false

    var body: some View {
        OpenWithMenu(kind: kind, store: store)
        if kind.isSplit, let app = kind.fixSplitApp {
            Button("Fix Split — Use \(kind.labelContext.label(for: app)) for All") {
                Task { await store.fixSplit(kind) }
            }
            .disabled(!store.canWrite)
        }
        if showsInBrowser {
            Button("Show Type") { store.showKind(kind.id) }
        }
        Divider()
        CopyKindButtons(kind: kind)
        if let app = kind.defaultApp {
            Divider()
            RevealAppButton(app: app)
        }
    }
}

struct CopyKindButtons: View {
    let kind: Kind

    var body: some View {
        Button("Copy") { Pasteboard.copy(kind.pasteboardText) }
        Button(kind.identifierList.count == 1 ? "Copy Identifier" : "Copy Identifiers") {
            Pasteboard.copy(kind.identifierList.joined(separator: "\n"))
        }
        if !kind.extensions.isEmpty {
            Button(kind.extensions.count == 1 ? "Copy Extension" : "Copy Extensions") {
                Pasteboard.copy(kind.extensions.map { ".\($0)" }.joined(separator: " "))
            }
        }
    }
}

struct RevealAppButton: View {
    let app: AppRef

    var body: some View {
        Button("Show \(app.name) in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([app.url])
        }
    }
}

extension View {
    /// Accepts an app dragged from Finder or the Dock and hands it on; anything else is refused
    /// so the drag springs back. Whether the app can take the type is the store's call, which
    /// explains a refusal instead of failing silently.
    func appDropTarget(isEnabled: Bool, perform: @escaping (AppRef) -> Void) -> some View {
        modifier(AppDropTarget(isEnabled: isEnabled, perform: perform))
    }
}

private struct AppDropTarget: ViewModifier {
    let isEnabled: Bool
    let perform: (AppRef) -> Void
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                guard isEnabled, let url = urls.first(where: Self.isApplication) else { return false }
                perform(HandlerService.appRef(for: url))
                return true
            } isTargeted: { targeted in
                isTargeted = targeted && isEnabled
            }
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(-4)
                    .opacity(isTargeted ? 1 : 0)
            }
    }

    static func isApplication(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .application) == true
    }
}
