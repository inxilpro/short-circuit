import Foundation
import os

/// The curated layer over the heuristic Kinds: names, categories, which UTIs are one format, which
/// schemes belong with them, and which Kinds are common. Read from the bundled `Catalog.json`.
nonisolated struct Catalog: Codable, Sendable {
    static let supportedVersion = 1

    nonisolated struct Entry: Codable, Sendable, Hashable {
        var id: String
        var name: String
        /// Nil when the file names a category this build doesn't know; the heuristic category is used.
        var category: KindCategory?
        /// Lower sorts earlier. Nil means not common.
        var common: Int?
        var utis: [String]
        var extensions: [String]
        var schemes: [String]
        var keywords: [String]

        init(
            id: String, name: String, category: KindCategory? = nil, common: Int? = nil, utis: [String] = [],
            extensions: [String] = [], schemes: [String] = [], keywords: [String] = []
        ) {
            self.id = id
            self.name = name
            self.category = category
            self.common = common
            self.utis = utis
            self.extensions = extensions.map(Self.normalizedExtension)
            self.schemes = schemes.map(Self.normalizedScheme)
            self.keywords = keywords
        }

        /// Authors write extensions with or without the dot; the rest of the app stores them without.
        static func normalizedExtension(_ ext: String) -> String {
            (ext.hasPrefix(".") ? String(ext.dropFirst()) : ext).lowercased()
        }

        static func normalizedScheme(_ scheme: String) -> String {
            (scheme.hasSuffix(":") ? String(scheme.dropLast()) : scheme).lowercased()
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, category, common, utis, extensions, schemes, keywords
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            category = (try? container.decodeIfPresent(String.self, forKey: .category)).flatMap { $0.flatMap(KindCategory.init(rawValue:)) }
            common = try? container.decodeIfPresent(Int.self, forKey: .common)
            utis = (try? container.decodeIfPresent([String].self, forKey: .utis)) ?? []
            extensions = ((try? container.decodeIfPresent([String].self, forKey: .extensions)) ?? []).map(Self.normalizedExtension)
            schemes = ((try? container.decodeIfPresent([String].self, forKey: .schemes)) ?? []).map(Self.normalizedScheme)
            keywords = (try? container.decodeIfPresent([String].self, forKey: .keywords)) ?? []
        }
    }

    enum LoadError: Error, Equatable {
        case unsupportedVersion(Int)
    }

    var version: Int
    var kinds: [Entry]

    init(version: Int = Catalog.supportedVersion, kinds: [Entry]) {
        self.version = version
        self.kinds = kinds
    }

    private enum CodingKeys: String, CodingKey {
        case version, kinds
    }

    /// One malformed entry is skipped rather than losing the whole catalog.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        kinds = try container.decode([Lossy<Entry>].self, forKey: .kinds).compactMap(\.value)
    }

    static func decode(_ data: Data) throws -> Catalog {
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard catalog.version == supportedVersion else { throw LoadError.unsupportedVersion(catalog.version) }
        return catalog
    }

    private static let logger = Logger(subsystem: "com.cmorrell.Short-Circuit", category: "Catalog")

    /// Never fatal: a missing or broken catalog logs and leaves the heuristic Kinds alone.
    static func load(from url: URL?) -> Catalog? {
        guard let url else {
            logger.error("Catalog.json is not in the app bundle; using heuristic Kinds only")
            return nil
        }
        do {
            return try decode(Data(contentsOf: url))
        } catch {
            logger.error("Ignoring \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static let bundled: Catalog? = load(from: Bundle.main.url(forResource: "Catalog", withExtension: "json"))
}

nonisolated private struct Lossy<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
