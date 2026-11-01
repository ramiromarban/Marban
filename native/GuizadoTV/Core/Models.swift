import Foundation

enum MediaKind: String, Codable, Sendable { case movie, series, episode, season, live, official }
enum LibrarySection: String, CaseIterable, Identifiable, Sendable {
    case movies, series
    var id: String { rawValue }
    var title: String { self == .movies ? "Películas" : "Series" }
}
enum CatalogFilter: String, CaseIterable, Identifiable, Sendable {
    case all, genres, premieres, recent, continuing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Todo"
        case .genres: return "Géneros"
        case .premieres: return "Estrenos \(Calendar.current.component(.year, from: Date()))"
        case .recent: return "Recién añadidas"
        case .continuing: return "Seguir viendo"
        }
    }
}

struct Media: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var kind: MediaKind
    var remoteID = ""
    var source = "principal"
    var overview = ""
    var image = ""
    var backdrop = ""
    var streamURL = ""
    var referer = ""
    var releaseYear = ""
    var genreIDs: [String] = []
    var parentID = ""
    var seriesTitle = ""
    var season = 0
    var episode = 0
    var catalogPage = 1
    var episodeTotal = 0
    var channelID = ""
    var channelGroup = ""
    var limitedSchedule = false
    var alternatives: [Media] = []
    var officialURL = ""

    var playable: Bool { kind == .movie || kind == .episode || kind == .live }
    var subtitle: String {
        switch kind {
        case .episode: return "T\(season) · E\(episode)"
        case .season: return "Abrir episodios"
        case .live: return "EN VIVO · \(LiveDirectory.category(self))"
        case .official: return "Página del proveedor"
        case .series: return releaseYear.isEmpty ? "SERIE" : "SERIE · \(releaseYear)"
        case .movie: return releaseYear.isEmpty ? "PELÍCULA" : "PELÍCULA · \(releaseYear)"
        }
    }
    var artworkKey: String { kind == .live ? "channel-\(channelID)" : id }
    var identity: String {
        let name = TextTools.clean(title).replacingOccurrences(of: #"\s*\((?:19|20)\d{2}\)\s*$"#, with: "", options: .regularExpression)
        return "\(kind.rawValue)|\(TextTools.normalized(name).filter { $0.isLetter || $0.isNumber })|\(releaseYear)"
    }

    enum CodingKeys: String, CodingKey {
        case id, title, kind, remoteID, source, overview, image, backdrop, streamURL, referer, releaseYear, genreIDs
        case parentID, seriesTitle, season, episode, catalogPage, episodeTotal, channelID, channelGroup, limitedSchedule, alternatives, officialURL
    }
    init(id: String, title: String, kind: MediaKind) { self.id = id; self.title = title; self.kind = kind }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        kind = try c.decode(MediaKind.self, forKey: .kind)
        remoteID = try c.decodeIfPresent(String.self, forKey: .remoteID) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "principal"
        overview = try c.decodeIfPresent(String.self, forKey: .overview) ?? ""
        image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
        backdrop = try c.decodeIfPresent(String.self, forKey: .backdrop) ?? image
        streamURL = try c.decodeIfPresent(String.self, forKey: .streamURL) ?? ""
        referer = try c.decodeIfPresent(String.self, forKey: .referer) ?? ""
        releaseYear = try c.decodeIfPresent(String.self, forKey: .releaseYear) ?? ""
        genreIDs = try c.decodeIfPresent([String].self, forKey: .genreIDs) ?? []
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID) ?? ""
        seriesTitle = try c.decodeIfPresent(String.self, forKey: .seriesTitle) ?? ""
        season = try c.decodeIfPresent(Int.self, forKey: .season) ?? 0
        episode = try c.decodeIfPresent(Int.self, forKey: .episode) ?? 0
        catalogPage = try c.decodeIfPresent(Int.self, forKey: .catalogPage) ?? 1
        episodeTotal = try c.decodeIfPresent(Int.self, forKey: .episodeTotal) ?? 0
        channelID = try c.decodeIfPresent(String.self, forKey: .channelID) ?? ""
        channelGroup = try c.decodeIfPresent(String.self, forKey: .channelGroup) ?? ""
        limitedSchedule = try c.decodeIfPresent(Bool.self, forKey: .limitedSchedule) ?? false
        alternatives = try c.decodeIfPresent([Media].self, forKey: .alternatives) ?? []
        officialURL = try c.decodeIfPresent(String.self, forKey: .officialURL) ?? ""
    }
}

struct MediaPage: Codable, Sendable { var items: [Media]; var page = 1; var hasNext = false; var fromCache = false }
struct Genre: Codable, Identifiable, Sendable { var id: String; var title: String; var slug: String }
struct StreamDescriptor: Sendable { var url: URL; var referer: String }
struct Bookmark: Codable, Identifiable, Sendable {
    var media: Media; var position: Double; var duration: Double; var updated: Date
    var id: String { media.id }
    var fraction: Double { duration > 0 ? min(1, position / duration) : 0 }
    var remaining: String { duration > position ? "Faltan \(Int(ceil((duration - position) / 60))) min" : "" }
}
enum Quality: String, Codable, CaseIterable, Identifiable {
    case maximum, adaptive, saver
    var id: String { rawValue }
    var title: String { self == .maximum ? "Sin límite de resolución" : self == .adaptive ? "Automática" : "Ahorro de datos" }
}
struct UserSettings: Codable {
    var reduceMotion = false
    var showIntro = true
    var autoNext = true
    var captions = false
    var quality = Quality.maximum
}
struct Profile: Codable, Identifiable {
    var id = UUID().uuidString; var name: String
    var favorites: [Media] = []; var history: [Bookmark] = []; var settings = UserSettings()
}
enum AppFailure: LocalizedError {
    case unavailable(String), invalidData, invalidURL, tooLarge
    var errorDescription: String? {
        switch self {
        case .unavailable(let text): return text
        case .invalidData: return "La fuente devolvió datos que no se pudieron leer."
        case .invalidURL: return "La dirección de esta fuente no es compatible."
        case .tooLarge: return "La respuesta de la fuente excedió el límite permitido."
        }
    }
}

enum TextTools {
    static func normalized(_ text: String) -> String { text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_MX")) }
    static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
        for (a, b) in ["&amp;": "&", "&quot;": "\"", "&#039;": "'", "&nbsp;": " "] { result = result.replacingOccurrences(of: a, with: b) }
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let valueRange = Range(match.range(at: 1), in: result), let whole = Range(match.range, in: result) else { continue }
                let raw = String(result[valueRange]); let number = raw.hasPrefix("x") ? UInt32(raw.dropFirst(), radix: 16) : UInt32(raw)
                if let number, let scalar = UnicodeScalar(number) { result.replaceSubrange(whole, with: String(scalar)) }
            }
        }
        return result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func captures(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
    }
    static func string(_ value: Any?) -> String { if let text = value as? String { return text }; if let number = value as? NSNumber { return number.stringValue }; return "" }
}
