import Foundation

/// Stand-in data built from apps that ship with every Mac, so previews and the app render
/// without touching Launch Services.
nonisolated struct SampleKindProvider: KindProviding {
    var delay: Duration = .zero
    var failure: String?

    func loadKinds(forceRefresh: Bool) async throws -> [Kind] {
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        if let failure {
            throw SampleError(message: failure)
        }
        return Self.kinds
    }

    struct SampleError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
}

nonisolated extension AppRef {
    static let preview = system("Preview", "com.apple.Preview")
    static let textEdit = system("TextEdit", "com.apple.TextEdit")
    static let safari = AppRef(url: URL(filePath: "/Applications/Safari.app"), bundleID: "com.apple.Safari", name: "Safari")
    static let mail = system("Mail", "com.apple.mail")
    static let music = system("Music", "com.apple.Music")
    static let photos = system("Photos", "com.apple.Photos")
    static let quickTime = system("QuickTime Player", "com.apple.QuickTimePlayerX")
    static let notes = system("Notes", "com.apple.Notes")
    static let messages = system("Messages", "com.apple.MobileSMS")
    static let faceTime = system("FaceTime", "com.apple.FaceTime")
    static let calendar = system("Calendar", "com.apple.iCal")
    static let contacts = system("Contacts", "com.apple.AddressBook")
    static let maps = system("Maps", "com.apple.Maps")
    static let books = system("Books", "com.apple.iBooksX")
    static let terminal = AppRef(url: URL(filePath: "/System/Applications/Utilities/Terminal.app"), bundleID: "com.apple.Terminal", name: "Terminal")
    static let scriptEditor = AppRef(url: URL(filePath: "/System/Applications/Utilities/Script Editor.app"), bundleID: "com.apple.ScriptEditor2", name: "Script Editor")
    static let archiveUtility = AppRef(url: URL(filePath: "/System/Library/CoreServices/Applications/Archive Utility.app"), bundleID: "com.apple.archiveutility", name: "Archive Utility")

    private static func system(_ name: String, _ bundleID: String) -> AppRef {
        AppRef(url: URL(filePath: "/System/Applications/\(name).app"), bundleID: bundleID, name: name)
    }
}

nonisolated extension SampleKindProvider {
    static let kinds: [Kind] = uncatalogued.map { kind in
        guard let entry = sampleCatalog[kind.id] else { return kind }
        var kind = kind
        kind.catalogID = kind.id
        kind.commonRank = entry.rank
        kind.keywords = entry.keywords
        return kind
    }

    /// A small stand-in for Catalog.json: ranks for the Common list and extra search words.
    /// AppleScript and Gzip are catalogued but not common, like much of the real catalog.
    private static let sampleCatalog: [Kind.ID: (rank: Int?, keywords: [String])] = [
        "web-page": (1, ["browser", "website", "link", "url"]),
        "pdf": (2, ["acrobat", "document"]),
        "jpeg": (3, ["photo", "picture", "jpg"]),
        "png": (4, ["screenshot", "image"]),
        "plain-text": (5, ["txt", "notes"]),
        "markdown": (6, ["readme"]),
        "email": (7, ["mail", "message"]),
        "zip": (8, ["compressed", "archive"]),
        "mp3": (9, ["music", "song"]),
        "mpeg4-video": (10, ["movie", "film"]),
        "heic": (11, ["photo", "iphone"]),
        "calendar-event": (12, ["invite", "meeting"]),
        "applescript": (nil, ["automation"]),
        "gzip": (nil, ["compressed", "tarball"]),
    ]

    private static let uncatalogued: [Kind] = [
        Kind(
            id: "markdown", name: "Markdown", category: .documents,
            members: [
                KindMember(target: .uti("net.daringfireball.markdown"), defaultApp: .textEdit),
                // Mirrors the dev Mac, where public.markdown is declared without conformance to
                // public.item and macOS refuses to give it a handler.
                KindMember(target: .uti("public.markdown"), defaultApp: .safari, isSettable: false),
            ],
            extensions: ["md", "markdown", "mdown", "mkd"], mimeTypes: ["text/markdown", "text/x-markdown"],
            candidates: [.textEdit, .safari, .notes]
        ),
        Kind(
            id: "pdf", name: "PDF document", category: .documents,
            members: [KindMember(target: .uti("com.adobe.pdf"), defaultApp: .preview)],
            extensions: ["pdf"], mimeTypes: ["application/pdf"],
            candidates: [.preview, .safari, .books]
        ),
        Kind(
            id: "plain-text", name: "Plain text", category: .documents,
            members: [KindMember(target: .uti("public.plain-text"), defaultApp: .textEdit)],
            extensions: ["txt", "text"], mimeTypes: ["text/plain"],
            candidates: [.textEdit, .scriptEditor, .safari]
        ),
        Kind(
            id: "rtf", name: "Rich text", category: .documents,
            members: [
                KindMember(target: .uti("public.rtf"), defaultApp: .textEdit),
                KindMember(target: .uti("com.apple.rtfd"), defaultApp: .textEdit),
            ],
            extensions: ["rtf", "rtfd"], mimeTypes: ["text/rtf", "application/rtf"],
            candidates: [.textEdit, .notes]
        ),
        Kind(
            id: "epub", name: "EPUB book", category: .documents,
            members: [KindMember(target: .uti("org.idpf.epub-container"), defaultApp: .books)],
            extensions: ["epub"], mimeTypes: ["application/epub+zip"],
            candidates: [.books]
        ),
        Kind(
            id: "jpeg", name: "JPEG image", category: .images,
            members: [KindMember(target: .uti("public.jpeg"), defaultApp: .preview)],
            extensions: ["jpg", "jpeg", "jpe"], mimeTypes: ["image/jpeg"],
            candidates: [.preview, .photos, .safari]
        ),
        Kind(
            id: "png", name: "PNG image", category: .images,
            members: [KindMember(target: .uti("public.png"), defaultApp: .preview)],
            extensions: ["png"], mimeTypes: ["image/png"],
            candidates: [.preview, .photos, .safari]
        ),
        Kind(
            id: "heic", name: "HEIC image", category: .images,
            members: [
                KindMember(target: .uti("public.heic"), defaultApp: .preview),
                KindMember(target: .uti("public.heif"), defaultApp: .photos),
            ],
            extensions: ["heic", "heif"], mimeTypes: ["image/heic", "image/heif"],
            candidates: [.preview, .photos]
        ),
        Kind(
            id: "mp3", name: "MP3 audio", category: .audio,
            members: [KindMember(target: .uti("public.mp3"), defaultApp: .music)],
            extensions: ["mp3"], mimeTypes: ["audio/mpeg"],
            candidates: [.music, .quickTime]
        ),
        Kind(
            id: "mpeg4-audio", name: "MPEG-4 audio", category: .audio,
            members: [
                KindMember(target: .uti("public.mpeg-4-audio"), defaultApp: .music),
                KindMember(target: .uti("com.apple.m4a-audio"), defaultApp: .quickTime),
            ],
            extensions: ["m4a", "m4b"], mimeTypes: ["audio/mp4", "audio/x-m4a"],
            candidates: [.music, .quickTime, .books]
        ),
        Kind(
            id: "quicktime-movie", name: "QuickTime movie", category: .video,
            members: [KindMember(target: .uti("com.apple.quicktime-movie"), defaultApp: .quickTime)],
            extensions: ["mov", "qt"], mimeTypes: ["video/quicktime"],
            candidates: [.quickTime, .photos]
        ),
        Kind(
            id: "mpeg4-video", name: "MPEG-4 video", category: .video,
            members: [KindMember(target: .uti("public.mpeg-4"), defaultApp: .quickTime)],
            extensions: ["mp4", "mpg4"], mimeTypes: ["video/mp4"],
            candidates: [.quickTime, .music, .photos]
        ),
        Kind(
            id: "shell-script", name: "Shell script", category: .code,
            members: [KindMember(target: .uti("public.shell-script"), defaultApp: .terminal)],
            extensions: ["sh", "command", "zsh"], mimeTypes: ["application/x-sh"],
            candidates: [.terminal, .textEdit]
        ),
        Kind(
            id: "applescript", name: "AppleScript", category: .code,
            members: [
                KindMember(target: .uti("com.apple.applescript.text"), defaultApp: .scriptEditor),
                KindMember(target: .uti("com.apple.applescript.script"), defaultApp: .scriptEditor),
            ],
            extensions: ["applescript", "scpt"], mimeTypes: [],
            candidates: [.scriptEditor, .textEdit]
        ),
        Kind(
            id: "zip", name: "ZIP archive", category: .archives,
            members: [KindMember(target: .uti("public.zip-archive"), defaultApp: .archiveUtility)],
            extensions: ["zip"], mimeTypes: ["application/zip"],
            candidates: [.archiveUtility]
        ),
        Kind(
            id: "gzip", name: "Gzip archive", category: .archives,
            members: [KindMember(target: .uti("org.gnu.gnu-zip-archive"), defaultApp: .archiveUtility)],
            extensions: ["gz", "tgz"], mimeTypes: ["application/gzip"],
            candidates: [.archiveUtility, .terminal]
        ),
        Kind(
            id: "web-page", name: "Web page", category: .web,
            members: [
                KindMember(target: .scheme("http"), defaultApp: .safari),
                KindMember(target: .scheme("https"), defaultApp: .safari),
                KindMember(target: .uti("public.html"), defaultApp: .safari),
                // Mirrors the dev Mac: XHTML isn't part of the default browser, so it can drift.
                KindMember(target: .uti("public.xhtml"), defaultApp: .textEdit),
            ],
            extensions: ["html", "htm", "xhtml"], mimeTypes: ["text/html", "application/xhtml+xml"],
            candidates: [.safari, .textEdit]
        ),
        Kind(
            id: "web-archive", name: "Web archive", category: .web,
            members: [KindMember(target: .uti("com.apple.webarchive"), defaultApp: .safari)],
            extensions: ["webarchive"], mimeTypes: ["application/x-webarchive"],
            candidates: [.safari, .textEdit]
        ),
        Kind(
            id: "maps-link", name: "Map link", category: .web,
            members: [KindMember(target: .scheme("maps"), defaultApp: .maps)],
            extensions: [], mimeTypes: [],
            candidates: [.maps]
        ),
        Kind(
            id: "email", name: "Email", category: .communication,
            members: [
                KindMember(target: .scheme("mailto"), defaultApp: .mail),
                KindMember(target: .uti("com.apple.mail.email"), defaultApp: .mail),
                KindMember(target: .uti("public.email-message"), defaultApp: .mail),
            ],
            extensions: ["eml", "emlx"], mimeTypes: ["message/rfc822"],
            candidates: [.mail, .textEdit]
        ),
        Kind(
            id: "phone-call", name: "Phone call", category: .communication,
            members: [
                KindMember(target: .scheme("tel"), defaultApp: .faceTime),
                KindMember(target: .scheme("facetime"), defaultApp: .faceTime),
                KindMember(target: .scheme("sms"), defaultApp: .messages),
            ],
            extensions: [], mimeTypes: [],
            candidates: [.faceTime, .messages]
        ),
        Kind(
            id: "calendar-event", name: "Calendar event", category: .communication,
            members: [
                KindMember(target: .uti("com.apple.ical.ics"), defaultApp: .calendar),
                KindMember(target: .scheme("webcal"), defaultApp: .calendar),
            ],
            extensions: ["ics"], mimeTypes: ["text/calendar"],
            candidates: [.calendar, .mail]
        ),
        Kind(
            id: "vcard", name: "Contact card", category: .communication,
            members: [KindMember(target: .uti("public.vcard"), defaultApp: .contacts)],
            extensions: ["vcf", "vcard"], mimeTypes: ["text/vcard", "text/x-vcard"],
            candidates: [.contacts, .mail]
        ),
    ]
}
