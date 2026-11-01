import Foundation

enum TVCategory: String, CaseIterable, Identifiable {
    case all = "Español", mexico = "México", comedy = "Comedia", news = "Noticias", marathons = "24/7"
    case sports = "Deportes", documentary = "Documentales", lifestyle = "Estilo de vida", entertainment = "Entretenimiento"
    case kids = "Infantil", music = "Música", regional = "Regionales"
    var id: String { rawValue }
}
enum LiveDirectory {
    static let source = URL(string: "https://iptv-org.github.io/iptv/languages/spa.m3u")!
    static func identity(_ media: Media) -> String { media.channelID.split(separator: "@").first.map(String.init) ?? TextTools.normalized(media.title) }
    static func isMexico(_ media: Media) -> Bool {
        let id = media.channelID.lowercased()
        return id.contains(".mx@") || id.hasSuffix(".mx") || id.contains("@mexico") || media.alternatives.contains(where: isMexico)
    }
    static func dedicated(_ media: Media) -> Bool {
        guard !media.limitedSchedule else { return false }
        let name = TextTools.normalized(media.title + " " + media.channelID)
        return name.contains("24/7") || name.contains("el chavo tv") || !TextTools.captures(#"csi[: ]|star trek|south park|kenan|clarissa|hechizadas|charmed|andromeda|curro jimenez|ana y los 7|acapulco shore|macgyver|el comisario|bob esponja|sabrina|doctor who|mr[.]? bean|empenos a lo bestia|encantador de perros"#, in: name).isEmpty
    }
    static func category(_ media: Media) -> String {
        let group = media.channelGroup.lowercased(), name = TextTools.normalized(media.title + media.channelID)
        if group.contains("lifestyle") || name.contains("homehealth") || name.contains("home & health") { return TVCategory.lifestyle.rawValue }
        if group.contains("news") { return TVCategory.news.rawValue }
        if group.contains("sports") { return TVCategory.sports.rawValue }
        if group.contains("comedy") { return TVCategory.comedy.rawValue }
        if group.contains("documentary") || group.contains("science") || !TextTools.captures(#"discovery( channel| science| theater| world)"#, in: name).isEmpty { return TVCategory.documentary.rawValue }
        if group.contains("kids") || group.contains("animation") { return TVCategory.kids.rawValue }
        if group.contains("music") { return TVCategory.music.rawValue }
        if group.contains("movies") || group.contains("series") { return TVCategory.entertainment.rawValue }
        return TVCategory.regional.rawValue
    }
    static func matches(_ media: Media, _ selected: TVCategory) -> Bool {
        switch selected {
        case .all: return true
        case .mexico: return isMexico(media)
        case .marathons: return dedicated(media)
        default: return category(media) == selected.rawValue
        }
    }
    static func preference(_ media: Media) -> Int {
        let resolution = TextTools.captures(#"(\d{3,4})p"#, in: media.title).first.flatMap { Int($0[1]) } ?? 0
        return resolution + (media.channelID.lowercased().contains("@mexico") ? 10_000 : 0) + (media.streamURL.hasPrefix("https:") ? 20 : 0)
    }
    static func parse(_ raw: String) -> [Media] {
        var rows: [Media] = [], pending: Media?
        func attribute(_ line: String, _ name: String) -> String {
            TextTools.captures(NSRegularExpression.escapedPattern(for: name) + #"="([^"]*)""#, in: line).first.map { $0[1] } ?? ""
        }
        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXTINF:") {
                let title = line.components(separatedBy: ",").last ?? "Canal"
                var item = Media(id: "", title: title.replacingOccurrences(of: #"\s*\[.*?\]"#, with: "", options: .regularExpression), kind: .live)
                item.channelID = attribute(line, "tvg-id"); item.image = attribute(line, "tvg-logo")
                item.channelGroup = attribute(line, "group-title"); item.referer = attribute(line, "http-referrer")
                item.limitedSchedule = line.contains("Not 24/7"); item.source = "iptv-org"
                pending = item
            } else if line.hasPrefix("#EXTVLCOPT:http-referrer="), pending != nil {
                pending?.referer = String(line.dropFirst("#EXTVLCOPT:http-referrer=".count))
            } else if line.hasPrefix("http://") || line.hasPrefix("https://"), var item = pending {
                item.id = line; item.streamURL = line; pending = nil
                guard !item.channelGroup.lowercased().contains("xxx"), item.channelGroup.lowercased() != "adult" else { continue }
                rows.append(item)
            }
        }
        var order: [String] = [], groups: [String: [Media]] = [:], seen: Set<String> = []
        for media in rows where seen.insert(media.streamURL).inserted {
            let key = identity(media)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(media)
        }
        return order.compactMap { id in
            guard let feeds = groups[id]?.sorted(by: { preference($0) > preference($1) }), var first = feeds.first else { return nil }
            first.alternatives = Array(feeds.dropFirst()); return first
        }
    }
    static let realities: [Media] = {
        func page(_ title: String, _ address: String, _ overview: String) -> Media {
            var item = Media(id: "official:" + address, title: title, kind: .official)
            item.officialURL = address; item.overview = overview; return item
        }
        return [
            page("La Granja VIP", "https://www.tvazteca.com/aztecauno/la-granja-vip-24-7/en-vivo/", "Acceso oficial. La emisión depende del proveedor, la temporada y la región."),
            page("La Casa de los Famosos", "https://www.lacasadelosfamososmexico.tv/", "Página oficial. La disponibilidad de una emisión 24/7 depende de la temporada.")
        ]
    }()
}
