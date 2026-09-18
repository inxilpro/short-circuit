import SwiftUI
import UniformTypeIdentifiers

extension KindCategory {
    var title: String {
        switch self {
        case .documents: "Documents"
        case .images: "Images"
        case .audio: "Audio"
        case .video: "Video"
        case .code: "Code"
        case .archives: "Archives"
        case .web: "Web & Links"
        case .communication: "Communication"
        case .developer: "Developer"
        case .other: "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .documents: "doc.text"
        case .images: "photo"
        case .audio: "waveform"
        case .video: "film"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .archives: "archivebox"
        case .web: "globe"
        case .communication: "bubble.left.and.bubble.right"
        case .developer: "hammer"
        case .other: "square.grid.2x2"
        }
    }
}

extension KindMember.Target {
    var displayName: String {
        switch self {
        case .uti(let identifier): identifier
        case .scheme(let scheme): "\(scheme):"
        }
    }

    /// "XHTML document (public.xhtml)" reads better than a bare identifier, but the identifier
    /// stays so two similar types can be told apart.
    var friendlyName: String {
        switch self {
        case .scheme(let scheme):
            return "\(scheme): links"
        case .uti(let identifier):
            guard let description = UTType(identifier)?.localizedDescription, !description.isEmpty else { return identifier }
            return "\(description) (\(identifier))"
        }
    }
}

extension Kind {
    /// The app most settable members point at, used to decide which members are the odd ones out.
    var majorityApp: AppRef? {
        let apps = settableMembers.compactMap(\.defaultApp)
        let counts = Dictionary(apps.map { ($0.url, 1) }, uniquingKeysWith: +)
        return apps.max { counts[$0.url, default: 0] < counts[$1.url, default: 0] }
    }

    /// Whether `member` can be set to `app`. A member already on the app counts, even if the
    /// candidate list somehow omits it.
    func member(_ member: KindMember, accepts app: AppRef) -> Bool {
        member.accepts(app) || (member.isSettable && member.defaultApp?.url == app.url)
    }

    /// Apps offered for one member: only those macOS lists for it, since any other is rejected.
    func candidates(for member: KindMember) -> [AppRef] {
        var seen = Set<URL>()
        return ([member.defaultApp].compactMap { $0 } + candidates)
            .filter { seen.insert($0.url).inserted && self.member(member, accepts: $0) }
    }

    /// "2 of 3 types" when the app can take only some settable members; nil when it takes all.
    func supportNote(for app: AppRef) -> String? {
        let settable = settableMembers
        let accepted = settable.filter { member($0, accepts: app) }.count
        guard settable.count > 1, accepted < settable.count else { return nil }
        return "\(accepted) of \(settable.count) types"
    }

    struct FixSplitChoice: Equatable {
        var app: AppRef
        /// Settable members that will keep their current app because the chosen one can't open them.
        var unreachable: [KindMember]
    }

    /// The current app that the most settable members can be moved to (ties go to the app more
    /// members already use), plus the members it can't reach.
    var fixSplitChoice: FixSplitChoice? {
        let settable = settableMembers
        var seen = Set<URL>()
        let apps = settable.compactMap(\.defaultApp).filter { seen.insert($0.url).inserted }
        func score(_ app: AppRef) -> (Int, Int) {
            (settable.filter { member($0, accepts: app) }.count, settable.filter { $0.defaultApp?.url == app.url }.count)
        }
        guard let best = apps.max(by: { score($0) < score($1) }) else { return nil }
        return FixSplitChoice(app: best, unreachable: settable.filter { !member($0, accepts: best) })
    }

    /// The UTI whose document icon represents this Kind. Finder shows the icon of the type a
    /// file's extension resolves to, so that type wins when it's one of our settable members.
    /// Unsettable members never supply the icon: `public.markdown` on the dev Mac carries Word's
    /// icon although `.md` files resolve elsewhere and open in another app.
    var iconTypeIdentifier: String? {
        let settableUTIs = settableMembers.compactMap { member -> String? in
            if case .uti(let identifier) = member.target { identifier } else { nil }
        }
        for ext in extensions {
            if let resolved = UTType(filenameExtension: ext)?.identifier, settableUTIs.contains(resolved) {
                return resolved
            }
        }
        return settableUTIs.first
    }

    var formattedExtensions: String {
        extensions.map { ".\($0)" }.joined(separator: " ")
    }
}
