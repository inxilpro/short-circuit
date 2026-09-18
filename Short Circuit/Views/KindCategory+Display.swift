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
    /// The app most effective members point at, used to decide which members are the odd ones out.
    var majorityApp: AppRef? {
        let apps = effectiveMembers.compactMap(\.defaultApp)
        let counts = Dictionary(apps.map { ($0.url, 1) }, uniquingKeysWith: +)
        return apps.max { counts[$0.url, default: 0] < counts[$1.url, default: 0] }
    }

    /// Settable members no file resolves to on this Mac: another type wins their extensions, so
    /// their handler never decides anything. They only change through their own menu.
    var shadowedMembers: [KindMember] {
        let effective = Set(effectiveMembers.map(\.target))
        return settableMembers.filter { !effective.contains($0.target) }
    }

    /// Extensions listed for the Kind that none of its members wins, so files with them open
    /// according to some other type. Empty while any member's governed extensions are unknown.
    var extensionsHandledElsewhere: [String] {
        let utiMembers = members.filter { if case .uti = $0.target { true } else { false } }
        guard !utiMembers.isEmpty, utiMembers.allSatisfy({ $0.governedExtensions != nil }) else { return [] }
        let governed = Set(utiMembers.flatMap { $0.governedExtensions ?? [] }.map { $0.lowercased() })
        return extensions.filter { !governed.contains($0.lowercased()) }
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

    /// "2 of 3 types" when the app can take only some effective members; nil when it takes all.
    func supportNote(for app: AppRef) -> String? {
        let effective = effectiveMembers
        let accepted = effective.filter { member($0, accepts: app) }.count
        guard effective.count > 1, accepted < effective.count else { return nil }
        return "\(accepted) of \(effective.count) types"
    }

    /// The app that can take every effective member, preferring the one most of them already
    /// use; candidate order breaks ties. Nil when no single app fits, which is never a split.
    var fixSplitApp: AppRef? {
        let unifying = unifyingCandidates
        let effective = effectiveMembers
        func users(_ app: AppRef) -> Int {
            effective.filter { $0.defaultApp?.url == app.url }.count
        }
        let most = unifying.map(users).max() ?? 0
        return unifying.first { users($0) == most }
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
