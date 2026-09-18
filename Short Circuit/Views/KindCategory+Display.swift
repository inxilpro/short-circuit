import SwiftUI

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
}

extension Kind {
    /// The app most members point at, used to decide which members are the odd ones out.
    var majorityApp: AppRef? {
        let apps = members.compactMap(\.defaultApp)
        let counts = Dictionary(apps.map { ($0.url, 1) }, uniquingKeysWith: +)
        return apps.max { counts[$0.url, default: 0] < counts[$1.url, default: 0] }
    }

    var formattedExtensions: String {
        extensions.map { ".\($0)" }.joined(separator: " ")
    }
}
