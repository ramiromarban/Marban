import Foundation
import CryptoKit

actor CatalogService {
    static let shared = CatalogService()
    static let primary = URL(string: "https://lamovie.org")!
    static let secondary = "https://www.cinecalidad.am"
    static let userAgent = "Mozilla/5.0"
    private let session: URLSession
    private var pages: [String: (Date, MediaPage)] = [:]
    private var years: [Int: String] = [:]
    private var channelCache: (Date, [Media])?
    private let cacheDirectory: URL

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 18
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = URLCache(memoryCapacity: 12 * 1024 * 1024, diskCapacity: 48 * 1024 * 1024, diskPath: "GuizadoCatalog")
        session = URLSession(configuration: configuration)
        cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("GuizadoCatalog", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    func data(_ url: URL, referer: String = "", limit: Int = 8_000_000) async throws -> Data {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw AppFailure.invalidURL }
        var request = URLRequest(url: url); request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if !referer.isEmpty { request.setValue(referer, forHTTPHeaderField: "Referer") }
        let (bytes, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw AppFailure.unavailable("La fuente no está disponible en este momento.") }
        guard bytes.count <= limit else { throw AppFailure.tooLarge }; return bytes
    }
    private func text(_ url: String, referer: String = "") async throws -> String {
        guard let url = URL(string: url) else { throw AppFailure.invalidURL }
        return String(decoding: try await data(url, referer: referer), as: UTF8.self)
    }
    private func api(_ path: String, _ parameters: [String: String]) async throws -> [String: Any] {
        var parts = URLComponents(url: Self.primary.appendingPathComponent("wp-api/v1/" + path), resolvingAgainstBaseURL: false)!
        parts.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = parts.url, let json = try JSONSerialization.jsonObject(with: await data(url, referer: Self.primary.absoluteString + "/")) as? [String: Any], let content = json["data"] as? [String: Any] else { throw AppFailure.invalidData }
        return content
    }
    func genres() async throws -> [Genre] {
        let content = try await api("listing/tax/genres", ["page": "1", "postsPerPage": "100", "orderBy": "name", "order": "asc"])
        let names = ["Sci-Fi & Fantasy": "Ciencia ficción y fantasía", "Action & Adventure": "Acción y aventura", "Kids": "Infantil"]
        return (content["items"] as? [[String: Any]] ?? []).map { raw in
            let title = TextTools.clean(TextTools.string(raw["term_name"]))
            return Genre(id: TextTools.string(raw["term_id"]), title: names[title] ?? title, slug: TextTools.string(raw["term_slug"]))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private func yearID(_ year: Int) async throws -> String? {
        if let value = years[year] { return value }
        for page in 1...12 {
            let content = try await api("listing/tax/years", ["page": "\(page)", "postsPerPage": "100", "orderBy": "name", "order": "desc"])
            let items = content["items"] as? [[String: Any]] ?? []
            for raw in items where TextTools.string(raw["term_name"]) == String(year) {
                let value = TextTools.string(raw["term_id"]); years[year] = value; return value
            }
            let pagination = content["pagination"] as? [String: Any] ?? [:]
            if page >= (pagination["last_page"] as? Int ?? page) { break }
        }
        return nil
    }
    func catalog(_ section: LibrarySection, page: Int = 1, query: String = "", filter: CatalogFilter = .all, genre: Genre? = nil) async throws -> MediaPage {
        let key = [section.rawValue, String(page), query, filter.rawValue, genre?.id ?? ""].joined(separator: "|")
        if let (date, result) = pages[key], Date().timeIntervalSince(date) < 180 { return result }
        let file = cacheDirectory.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
        async let primary: MediaPage? = try? primaryPage(section, page: page, query: query, filter: filter, genre: genre)
        async let secondary: MediaPage? = try? secondaryPage(section, page: page, query: query, filter: filter, genre: genre)
        let (first, second) = await (primary, secondary)
        try Task.checkCancellation()
        guard first != nil || second != nil else {
            if let bytes = try? Data(contentsOf: file), var saved = try? JSONDecoder().decode(MediaPage.self, from: bytes) { saved.fromCache = true; return saved }
            throw AppFailure.unavailable("No se pudo actualizar el catálogo. Comprueba la conexión e intenta de nuevo.")
        }
        var seen = Set<String>(), items: [Media] = []
        for media in (first?.items ?? []) + (second?.items ?? []) where seen.insert(media.identity).inserted { items.append(media) }
        let result = MediaPage(items: items, page: page, hasNext: (first?.hasNext ?? false) || (second?.hasNext ?? false))
        pages[key] = (Date(), result)
        if pages.count > 24, let oldest = pages.min(by: { $0.value.0 < $1.value.0 })?.key { pages.removeValue(forKey: oldest) }
        if let bytes = try? JSONEncoder().encode(result) { try? bytes.write(to: file, options: .atomic) }
        return result
    }
    private func primaryPage(_ section: LibrarySection, page: Int, query: String, filter: CatalogFilter, genre: Genre?) async throws -> MediaPage {
        var filters: [String: [Int]] = [:]
        if let genre, let id = Int(genre.id) { filters["genres"] = [id] }
        let currentYear = Calendar.current.component(.year, from: Date())
        if filter == .premieres {
            guard let raw = try await yearID(currentYear), let year = Int(raw) else { return MediaPage(items: [], page: page) }
            filters["years"] = [year]
        }
        let filterJSON = String(decoding: try JSONSerialization.data(withJSONObject: filters), as: UTF8.self)
        let type = section == .movies ? "movies" : "tvshows"
        var parameters = ["page": "\(page)", "postsPerPage": "24", "postType": type, "orderBy": "latest", "order": "desc", "filter": filterJSON]
        if !query.isEmpty { parameters["q"] = query }
        let content = try await api(query.isEmpty ? "listing/" + type : "search", parameters)
        let items = (content["posts"] as? [[String: Any]] ?? []).compactMap { primaryMedia($0) }.filter { item in
            (section == .movies ? item.kind == .movie : item.kind == .series) && (filter != .premieres || item.releaseYear == "\(currentYear)") && (genre == nil || item.genreIDs.contains(genre!.id))
        }
        return MediaPage(items: items, page: page, hasNext: hasNext(content, page))
    }
    private func hasNext(_ content: [String: Any], _ page: Int) -> Bool {
        let value = content["pagination"] as? [String: Any] ?? [:]
        return (value["last_page"] as? Int ?? page) > page || !(TextTools.string(value["next_page_url"]).isEmpty)
    }
    private func artwork(_ raw: String) -> String {
        guard !raw.isEmpty, raw != "null" else { return "" }
        if raw.hasPrefix("http") { return raw }
        return Self.primary.appendingPathComponent("wp-content/uploads").appendingPathComponent(raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).absoluteString
    }
    private func primaryMedia(_ raw: [String: Any], parent: Media? = nil, page: Int = 1, total: Int = 0) -> Media? {
        let type = TextTools.string(raw["type"])
        guard let kind = ["movies": MediaKind.movie, "tvshows": .series, "episodes": .episode][type] else { return nil }
        let id = TextTools.string(raw["_id"])
        var item = Media(id: "online-" + id, title: TextTools.clean(TextTools.string(raw["title"])), kind: kind)
        item.remoteID = id; item.overview = TextTools.clean(TextTools.string(raw["overview"]))
        let images = raw["images"] as? [String: Any] ?? [:]
        item.image = artwork(TextTools.string(images["poster"])); item.backdrop = artwork(TextTools.string(images["backdrop"]))
        if item.image.isEmpty { item.image = item.backdrop }
        if item.image.isEmpty { item.image = parent?.image ?? "" }
        if item.backdrop.isEmpty { item.backdrop = item.image }
        item.releaseYear = String(TextTools.string(raw["release_date"]).prefix(4))
        if item.releaseYear.isEmpty { item.releaseYear = TextTools.captures(#"\((\d{4})\)\s*$"#, in: item.title).first.map { $0[1] } ?? "" }
        item.genreIDs = (raw["genres"] as? [Any] ?? []).map(TextTools.string)
        if let parent {
            item.parentID = parent.remoteID; item.seriesTitle = parent.title
            item.season = Int(TextTools.string(raw["season_number"])) ?? 1
            item.episode = Int(TextTools.string(raw["episode_number"])) ?? 0
            item.catalogPage = page; item.episodeTotal = total
        }
        return item
    }
    private func attribute(_ tag: String, _ name: String) -> String {
        TextTools.captures("(?:\\s|^)" + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*["']([^"']*)["']"#, in: tag).first.map { TextTools.clean($0[1]) } ?? ""
    }
    private func inner(_ html: String, _ name: String) -> String {
        TextTools.captures(#"<[^>]+class=["'][^"']*\b"# + name + #"\b[^"']*["'][^>]*>(.*?)</"#, in: html).first.map { TextTools.clean($0[1]) } ?? ""
    }
    private func cover(_ html: String) -> String {
        guard let tag = TextTools.captures(#"<img\b[^>]*>"#, in: html).first?.first else { return "" }
        let lazy = attribute(tag, "data-src"); let src = lazy.isEmpty ? attribute(tag, "src") : lazy
        return src.hasPrefix("http") ? src : ""
    }
    private func secondaryPage(_ section: LibrarySection, page: Int, query: String, filter: CatalogFilter, genre: Genre?) async throws -> MediaPage {
        var path = section == .series ? "/ver-serie/" : "/"
        if filter == .premieres { path = "/release/\(Calendar.current.component(.year, from: Date()))/" }
        else if let genre { path = "/genero-de-la-pelicula/\(genre.slug)/" }
        var parts = URLComponents(string: Self.secondary + path)!
        if !query.isEmpty { parts = URLComponents(string: Self.secondary + "/")!; parts.queryItems = [URLQueryItem(name: "s", value: query), URLQueryItem(name: "paged", value: "\(page)")] }
        else if page > 1 { parts.path += "page/\(page)/" }
        let html = try await text(parts.url!.absoluteString, referer: Self.secondary + "/")
        var items: [Media] = [], used: Set<String> = []
        for match in TextTools.captures(#"<article\b[^>]*>.*?</article>"#, in: html) {
            let article = match[0]
            if article.prefix(240).contains("naadb") { continue }
            if let genre, !article.contains("/genero-de-la-pelicula/\(genre.slug)/") { continue }
            guard let link = TextTools.captures(#"href=["'](https://www\.cinecalidad\.am/ver-(?:pelicula|serie)/[^"']+)["']"#, in: article).first?[1], used.insert(link).inserted else { continue }
            let kind: MediaKind = link.contains("/ver-serie/") ? .series : .movie
            guard section == .series ? kind == .series : kind == .movie else { continue }
            let title = inner(article, "in_title"); if title.isEmpty { continue }
            let postID = TextTools.captures(#"id=["']post-(\d+)["']"#, in: article).first?[1] ?? link
            var item = Media(id: "cine-" + postID, title: title, kind: kind)
            item.source = "cinecalidad"; item.remoteID = link; item.image = cover(article); item.backdrop = item.image
            item.overview = inner(article, "custom_synop")
            item.releaseYear = TextTools.captures(#">\s*((?:19|20)\d{2})\s*<"#, in: article).first?[1] ?? ""
            if filter == .premieres && item.releaseYear != String(Calendar.current.component(.year, from: Date())) { continue }
            items.append(item)
        }
        return MediaPage(items: items, page: page, hasNext: html.contains("/page/\(page + 1)/") || html.contains("paged=\(page + 1)"))
    }
    func episodes(for parent: Media, season: Int? = nil, page: Int = 1) async throws -> MediaPage {
        if parent.source == "cinecalidad" { return try await secondaryEpisodes(parent, season: season, page: page) }
        let content = try await api("single/episodes/list", ["_id": parent.remoteID, "page": "\(page)", "postsPerPage": "24", "season": "\(max(1, season ?? 1))"])
        if season == nil {
            let seasons = (content["seasons"] as? [Any] ?? []).compactMap { Int(TextTools.string($0)) }.filter { $0 > 0 }.sorted()
            return MediaPage(items: seasons.map { number in
                var item = Media(id: "season-\(parent.remoteID)-\(number)", title: "Temporada \(number)", kind: .season)
                item.remoteID = parent.remoteID; item.parentID = parent.remoteID; item.seriesTitle = parent.title; item.season = number; item.image = parent.image; return item
            })
        }
        let pagination = content["pagination"] as? [String: Any] ?? [:], total = pagination["total"] as? Int ?? 0
        return MediaPage(items: (content["posts"] as? [[String: Any]] ?? []).compactMap { primaryMedia($0, parent: parent, page: page, total: total) }, page: page, hasNext: hasNext(content, page))
    }
    private func secondaryEpisodes(_ parent: Media, season: Int?, page: Int) async throws -> MediaPage {
        guard parent.remoteID.hasPrefix(Self.secondary + "/ver-serie/") else { throw AppFailure.invalidURL }
        let html = try await text(parent.remoteID, referer: Self.secondary + "/")
        var seasons: Set<Int> = [], items: [Media] = [], seen: Set<String> = []
        for raw in TextTools.captures(#"<li\b[^>]*>.*?</li>"#, in: html) {
            guard let episode = TextTools.captures(#"<a[^>]+href=["'](https://www\.cinecalidad\.am/ver-el-episodio/[^"']*-s(\d+)-e(\d+)/)["'][^>]*>(.*?)</a>"#, in: raw[0]).first, let s = Int(episode[2]), let e = Int(episode[3]), seen.insert(episode[1]).inserted else { continue }
            seasons.insert(s); guard s == season else { continue }
            var item = Media(id: "cine-episode-" + episode[1], title: TextTools.clean(episode[4]), kind: .episode)
            item.remoteID = episode[1]; item.source = "cinecalidad"; item.parentID = parent.remoteID; item.seriesTitle = parent.title
            item.season = s; item.episode = e; item.image = cover(raw[0]); if item.image.isEmpty { item.image = parent.image }
            item.backdrop = parent.image; item.catalogPage = page; items.append(item)
        }
        if season == nil { return MediaPage(items: seasons.sorted().map { number in
            var item = Media(id: "cine-season-\(parent.remoteID)-\(number)", title: "Temporada \(number)", kind: .season)
            item.remoteID = parent.remoteID; item.source = "cinecalidad"; item.season = number; item.image = parent.image; return item
        }) }
        let total = items.count, start = max(0, (page - 1) * 24)
        let selected = items.dropFirst(start).prefix(24).map { raw -> Media in var item = raw; item.episodeTotal = total; return item }
        return MediaPage(items: selected, page: page, hasNext: start + 24 < total)
    }
    func nextEpisode(after media: Media) async throws -> Media? {
        guard media.kind == .episode, !media.parentID.isEmpty, media.episode > 0 else { return nil }
        var parent = Media(id: media.parentID, title: media.seriesTitle, kind: .series)
        parent.remoteID = media.parentID; parent.source = media.source; parent.image = media.image
        for page in Set([max(1, media.catalogPage - 1), media.catalogPage, media.catalogPage + 1]) {
            let result = try await episodes(for: parent, season: media.season, page: page)
            if let exact = result.items.first(where: { $0.season == media.season && $0.episode == media.episode + 1 }) { return exact }
        }
        guard media.episodeTotal > 0, media.episode >= media.episodeTotal else { return nil }
        let seasons = try await episodes(for: parent)
        guard let next = seasons.items.map(\.season).filter({ $0 > media.season }).min() else { return nil }
        return try await episodes(for: parent, season: next).items.first(where: { $0.episode == 1 })
    }
    func resolve(_ media: Media) async throws -> StreamDescriptor {
        if media.kind == .live, let url = URL(string: media.streamURL) { return StreamDescriptor(url: url, referer: media.referer) }
        let html: String
        if media.source == "cinecalidad" {
            guard media.remoteID.hasPrefix(Self.secondary + "/ver-pelicula/") || media.remoteID.hasPrefix(Self.secondary + "/ver-el-episodio/") else { throw AppFailure.invalidURL }
            html = try await text(media.remoteID, referer: Self.secondary + "/")
        } else {
            guard !media.remoteID.isEmpty, media.remoteID.allSatisfy(\.isNumber) else { throw AppFailure.invalidURL }
            let content = try await api("player", ["postId": media.remoteID, "demo": "0"])
            html = (content["embeds"] as? [[String: Any]] ?? []).map { TextTools.string($0["url"]) }.joined(separator: "\n")
        }
        let embeds = TextTools.captures(#"https?://(?:www\.)?vimeos\.net/[^\s"'<>]+"#, in: html).map { $0[0] }
        var visited = Set<String>()
        for embed in embeds where visited.insert(embed).inserted {
            do {
                let page = try await text(embed, referer: media.source == "cinecalidad" ? media.remoteID : Self.primary.absoluteString + "/")
                let unpacked = try JavaScriptUnpacker.unpack(page).replacingOccurrences(of: "\\/", with: "/")
                if let found = TextTools.captures(#"https?://[^\s"'<>]+"#, in: unpacked).map({ $0[0] }).first(where: { $0.contains(".m3u8") }), let url = URL(string: found) { return StreamDescriptor(url: url, referer: embed) }
            } catch is CancellationError { throw CancellationError() } catch { continue }
        }
        throw AppFailure.unavailable("Este título no ofrece una fuente HLS compatible en este momento.")
    }
    func channels(refresh: Bool = false) async -> [Media] {
        if !refresh, let cache = channelCache, Date().timeIntervalSince(cache.0) < 300 { return cache.1 }
        let disk = cacheDirectory.appendingPathComponent("spanish-live.m3u")
        do {
            let bytes = try await data(LiveDirectory.source)
            let parsed = LiveDirectory.parse(String(decoding: bytes, as: UTF8.self))
            guard !parsed.isEmpty else { throw AppFailure.invalidData }
            try? bytes.write(to: disk, options: .atomic); channelCache = (Date(), parsed); return parsed
        } catch {
            if let cache = channelCache { return cache.1 }
            let bytes = (try? Data(contentsOf: disk)) ?? AssetFiles.data("spanish-live.m3u") ?? Data()
            let parsed = LiveDirectory.parse(String(decoding: bytes, as: UTF8.self)); channelCache = (Date(), parsed); return parsed
        }
    }
    func alternativeArtwork(_ media: Media) async -> String? {
        guard media.kind == .movie || media.kind == .series else { return nil }
        let section: LibrarySection = media.kind == .movie ? .movies : .series
        let title = media.title.replacingOccurrences(of: #"\s*\(\d{4}\)\s*$"#, with: "", options: .regularExpression)
        if let page = try? await secondaryPage(section, page: 1, query: title, filter: .all, genre: nil), let found = page.items.first(where: { $0.identity == media.identity && !$0.image.isEmpty && $0.image != media.image }) { return found.image }
        return nil
    }
    func alternativePlayback(_ media: Media, excluding: Set<String>) async -> Media? {
        guard media.kind == .movie else { return nil }
        let title = media.title.replacingOccurrences(of: #"\s*\(\d{4}\)\s*$"#, with: "", options: .regularExpression)
        let page: MediaPage?
        if media.source == "cinecalidad" { page = try? await primaryPage(.movies, page: 1, query: title, filter: .all, genre: nil) }
        else { page = try? await secondaryPage(.movies, page: 1, query: title, filter: .all, genre: nil) }
        guard let page else { return nil }
        return page.items.first { $0.identity == media.identity && !excluding.contains($0.id) }
    }
    func bundledMovies() -> [Media] {
        guard let bytes = AssetFiles.data("catalog-preview.json"), let items = try? JSONDecoder().decode([Media].self, from: bytes) else { return [] }; return items
    }
}

enum AssetFiles {
    static func url(_ path: String) -> URL? {
        let root = Bundle.main.resourceURL?.appendingPathComponent("MediaAssets", isDirectory: true).appendingPathComponent(path)
        if let root, FileManager.default.fileExists(atPath: root.path) { return root }; return nil
    }
    static func data(_ path: String) -> Data? { url(path).flatMap { try? Data(contentsOf: $0) } }
}
