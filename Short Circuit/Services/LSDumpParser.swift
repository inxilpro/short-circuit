import Foundation

/// Line-oriented parser for `lsregister -dump`.
///
/// The format is undocumented, so the parser only relies on a few stable traits: records are separated
/// by a line of 80 dashes, a record's first `key: value` line names its kind, and nested property-list
/// output is indented. Anything unrecognised is counted and skipped rather than treated as an error.
nonisolated struct LSDumpParser {
    private enum RecordKind {
        case bundle, claim, type, handlerPref
        case skipped(String)
    }

    private static let recordKinds: [String: RecordKind] = [
        "bundle id": .bundle,
        "claim id": .claim,
        "type id": .type,
        "handlerpref id": .handlerPref,
    ]

    private static let wantedKeys: [String: Set<String>] = [
        "bundle id": ["path", "name", "displayName", "localizedNames", "identifier", "version", "displayVersion", "class"],
        "claim id": ["rank", "bundle", "flags", "roles", "bindings"],
        "type id": ["bundle", "uti", "localizedDescription", "flags", "conforms to", "tags"],
    ]

    private static let headerKeys: Set<String> = ["Seeded System Version", "CacheSequenceNum"]

    private var inHeader = true
    private var header: [String: String] = [:]
    private var recordLabel: String?
    private var recordKind: RecordKind?
    private var fields: [(key: String, value: String)] = []

    private var types: [TypeDecl] = []
    private var claims: [Claim] = []
    private var bundles: [BundleRecord] = []
    private var handlerPrefs: [HandlerPref] = []
    private var skipped: [String: Int] = [:]

    // The dump prints most claims and types twice: once under their bundle and again in a flat
    // section at the end.
    private var seenTypeUnits: Set<String> = []
    private var seenClaimUnits: Set<String> = []
    private var seenBundleUnits: Set<String> = []
    private var seenHandlerPrefUnits: Set<String> = []

    init() {}

    static func parse(_ data: Data, capturedAt: Date = .now) -> LSSnapshot {
        var parser = LSDumpParser()
        data.withUnsafeBytes { parser.consume(bytes: $0) }
        return parser.finish(capturedAt: capturedAt)
    }

    static func parse(_ text: String, capturedAt: Date = .now) -> LSSnapshot {
        parse(Data(text.utf8), capturedAt: capturedAt)
    }

    /// Feeds a chunk of complete lines. Callers streaming output must split on newlines themselves
    /// and pass each line through `consume(line:)` instead.
    mutating func consume(bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress else { return }
        let count = bytes.count
        var start = 0
        while start < count {
            let remaining = count - start
            let lineEnd: Int
            if let newline = memchr(base + start, 0x0A, remaining) {
                lineEnd = base.distance(to: UnsafeRawPointer(newline))
            } else {
                lineEnd = count
            }
            consume(line: UnsafeRawBufferPointer(start: base + start, count: lineEnd - start))
            start = lineEnd + 1
        }
    }

    mutating func consume(line: String) {
        var line = line
        line.withUTF8 { consume(line: UnsafeRawBufferPointer($0)) }
    }

    mutating func consume(line: UnsafeRawBufferPointer) {
        var length = line.count
        if length > 0, line[length - 1] == 0x0D { length -= 1 }
        guard length > 0 else { return }

        let first = line[0]
        if first == 0x20 || first == 0x09 { return }

        if length == 80, first == 0x2D, Self.isSeparator(line) {
            flushRecord()
            inHeader = false
            return
        }

        guard let colon = Self.firstIndex(of: 0x3A, in: line, upTo: length) else { return }
        let key = String(decoding: UnsafeRawBufferPointer(rebasing: line[0..<colon]), as: UTF8.self)

        if inHeader {
            if Self.headerKeys.contains(key) {
                header[key] = Self.trimmedValue(line, from: colon + 1, to: length)
            }
            return
        }

        if recordLabel == nil {
            recordLabel = key
            recordKind = Self.recordKinds[key] ?? .skipped(key)
            if case .skipped = recordKind { return }
            fields.append((key, Self.trimmedValue(line, from: colon + 1, to: length)))
            return
        }

        switch recordKind {
        case .skipped, .none:
            return
        case .handlerPref:
            fields.append((key, Self.trimmedValue(line, from: colon + 1, to: length)))
        case .bundle, .claim, .type:
            guard let label = recordLabel, Self.wantedKeys[label]?.contains(key) == true,
                  !fields.contains(where: { $0.key == key })
            else { return }
            fields.append((key, Self.trimmedValue(line, from: colon + 1, to: length)))
        }
    }

    mutating func finish(capturedAt: Date = .now) -> LSSnapshot {
        flushRecord()
        return LSSnapshot(
            capturedAt: capturedAt,
            systemVersion: header["Seeded System Version"],
            cacheSequenceNumber: header["CacheSequenceNum"].flatMap { Int($0) },
            types: types,
            claims: claims,
            bundles: bundles,
            handlerPrefs: handlerPrefs,
            skippedRecordCounts: skipped
        )
    }

    // MARK: - Record assembly

    private mutating func flushRecord() {
        defer {
            recordLabel = nil
            recordKind = nil
            fields.removeAll(keepingCapacity: true)
        }
        guard let kind = recordKind, let idValue = fields.first?.value else {
            if case .skipped(let label) = recordKind { skipped[label, default: 0] += 1 }
            return
        }
        let values = Dictionary(fields.dropFirst().map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        let (name, unitID) = Self.splitUnitReference(idValue)

        switch kind {
        case .skipped(let label):
            skipped[label, default: 0] += 1
        case .bundle:
            if let unitID, !seenBundleUnits.insert(unitID).inserted { return }
            bundles.append(BundleRecord(
                unitID: unitID,
                name: values["name"] ?? name,
                identifier: values["identifier"],
                path: values["path"].map { Self.splitUnitReference($0).name },
                displayName: values["displayName"],
                version: values["displayVersion"] ?? values["version"].map(Self.stripParenthetical),
                bundleClass: values["class"].map { Self.splitUnitReference($0).name },
                localizedName: values["localizedNames"].flatMap(Self.localizedValue)
            ))
        case .claim:
            if let unitID, !seenClaimUnits.insert(unitID).inserted { return }
            let bundle = values["bundle"].map(Self.splitUnitReference)
            var claim = Claim(
                unitID: unitID,
                name: name,
                rank: values["rank"],
                bundleUnitID: bundle?.unitID,
                bundleName: bundle?.name,
                flags: Self.words(values["flags"]),
                roles: Self.words(values["roles"]),
                utis: [], extensions: [], schemes: [], mimeTypes: []
            )
            for binding in Self.list(values["bindings"]) {
                Self.classifyBinding(binding, into: &claim)
            }
            claims.append(claim)
        case .type:
            if let unitID, !seenTypeUnits.insert(unitID).inserted { return }
            let bundle = values["bundle"].map(Self.splitUnitReference)
            var extensions: [String] = []
            var mimeTypes: [String] = []
            for tag in Self.list(values["tags"]) {
                if tag.hasPrefix("."), tag.count > 1, tag != ".*" {
                    extensions.append(String(tag.dropFirst()).lowercased())
                } else if Self.isMIMEType(tag) {
                    mimeTypes.append(tag.lowercased())
                }
            }
            types.append(TypeDecl(
                unitID: unitID,
                identifier: values["uti"] ?? name,
                bundleUnitID: bundle?.unitID,
                bundleName: bundle?.name,
                localizedDescription: values["localizedDescription"].flatMap(Self.localizedValue),
                flags: Self.words(values["flags"]),
                conformsTo: Self.list(values["conforms to"]),
                extensions: extensions,
                mimeTypes: mimeTypes
            ))
        case .handlerPref:
            if let unitID, !seenHandlerPrefUnits.insert(unitID).inserted { return }
            // Header-only records (seen for `public.pax-archive`) have no tag line; the empty class marks that.
            var pref = HandlerPref(unitID: unitID, tag: name, tagClass: "", roleHandlers: [:])
            var sawTag = false
            for (key, value) in fields.dropFirst() {
                let lowered = key.lowercased()
                if lowered == "mod date" {
                    pref.modificationDate = Self.posixDate(value)
                } else if lowered.contains("role") || ["viewer", "editor", "shell", "none", "all"].contains(lowered) {
                    pref.roleHandlers[lowered] = value
                } else if !sawTag {
                    sawTag = true
                    let (tag, typeUnit) = Self.splitUnitReference(value)
                    pref.tagClass = key
                    pref.tag = tag
                    pref.tagTypeUnitID = typeUnit
                }
            }
            handlerPrefs.append(pref)
        }
    }

    private static func classifyBinding(_ binding: String, into claim: inout Claim) {
        guard let first = binding.first else { return }
        switch first {
        case "'", "\"", "*":
            return
        case ".":
            let ext = binding.dropFirst()
            if !ext.isEmpty, ext != "*" { claim.extensions.append(ext.lowercased()) }
        default:
            if binding.hasSuffix(":") {
                claim.schemes.append(String(binding.dropLast()).lowercased())
            } else if isMIMEType(binding) {
                claim.mimeTypes.append(binding.lowercased())
            } else if !binding.contains(" ") {
                claim.utis.append(binding)
            }
        }
    }

    // MARK: - Value helpers

    private static func isSeparator(_ line: UnsafeRawBufferPointer) -> Bool {
        for index in 0..<80 where line[index] != 0x2D { return false }
        return true
    }

    private static func firstIndex(of byte: UInt8, in line: UnsafeRawBufferPointer, upTo end: Int) -> Int? {
        for index in 0..<end where line[index] == byte { return index }
        return nil
    }

    private static func trimmedValue(_ line: UnsafeRawBufferPointer, from start: Int, to end: Int) -> String {
        var lower = start
        var upper = end
        while lower < upper, line[lower] == 0x20 || line[lower] == 0x09 { lower += 1 }
        while upper > lower, line[upper - 1] == 0x20 || line[upper - 1] == 0x09 { upper -= 1 }
        return String(decoding: UnsafeRawBufferPointer(rebasing: line[lower..<upper]), as: UTF8.self)
    }

    /// Splits `Name (0x1a2b)` into its name and unit ID. Names may contain parentheses or be empty
    /// (a few claims print as just `(0x1ca8)`).
    static func splitUnitReference(_ value: String) -> (name: String, unitID: String?) {
        guard value.hasSuffix(")"), let open = value.range(of: "(0x", options: .backwards) else {
            return (value, nil)
        }
        let hex = value[value.index(after: open.lowerBound)..<value.index(before: value.endIndex)]
        guard hex.count > 2, hex.dropFirst(2).allSatisfy(\.isHexDigit) else { return (value, nil) }
        let name = value[..<open.lowerBound]
        guard name.isEmpty || name.hasSuffix(" ") else { return (value, nil) }
        return (String(name.dropLast(name.isEmpty ? 0 : 1)), String(hex))
    }

    private static func stripParenthetical(_ value: String) -> String {
        guard let open = value.range(of: " (") else { return value }
        return String(value[..<open.lowerBound])
    }

    /// Flag and role lines are space-separated words followed by a raw hex value in parentheses.
    private static func words(_ value: String?) -> [String] {
        guard let value else { return [] }
        return stripParenthetical(value).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Splits on ", " outside double quotes. A bare comma is not a separator: device-model tags such
    /// as `iPhone12,1` contain one.
    static func list(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        var items: [String] = []
        var current = ""
        var inQuotes = false
        var pendingComma = false
        for character in value {
            if pendingComma {
                pendingComma = false
                if character == " " {
                    let item = current.trimmingCharacters(in: .whitespaces)
                    if !item.isEmpty { items.append(item) }
                    current = ""
                    continue
                }
                current.append(",")
            }
            if character == "\"" { inQuotes.toggle() }
            if character == ",", !inQuotes {
                pendingComma = true
                continue
            }
            current.append(character)
        }
        if pendingComma { current.append(",") }
        let item = current.trimmingCharacters(in: .whitespaces)
        if !item.isEmpty { items.append(item) }
        return items
    }

    private static func isMIMEType(_ tag: String) -> Bool {
        guard let slash = tag.firstIndex(of: "/"), slash != tag.startIndex, tag.index(after: slash) != tag.endIndex else {
            return false
        }
        return !tag.contains(" ") && !tag.hasPrefix("\"") && !tag.hasPrefix("'") && !tag.hasPrefix("/")
    }

    /// Parses `"en" = ?, "LSDefaultLocalizedValue" = "Markdown Document"`. `?` means "same as default".
    static func localizedValue(_ value: String) -> String? {
        var pairs: [(String, String)] = []
        for item in list(value) {
            guard let equals = item.range(of: " = ") else { continue }
            let key = item[..<equals.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let raw = item[equals.upperBound...]
            guard raw.hasPrefix("\""), raw.count >= 2 else { continue }
            pairs.append((key, String(raw.dropFirst().dropLast())))
        }
        for preferred in ["LSDefaultLocalizedValue", "en", "English", "Base"] {
            if let match = pairs.first(where: { $0.0 == preferred }), !match.1.isEmpty { return match.1 }
        }
        return pairs.first?.1
    }

    private static func posixDate(_ value: String) -> Date? {
        guard let range = value.range(of: "POSIX ") else { return nil }
        let digits = value[range.upperBound...].prefix { $0.isNumber || $0 == "-" }
        return Double(digits).map { Date(timeIntervalSince1970: $0) }
    }
}
