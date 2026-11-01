import Foundation

@main struct CoreChecks {
    @MainActor static func main() throws {
        let playlist = """
        #EXTM3U
        #EXTINF:-1 tvg-id="Prueba.mx@SD" group-title="News",Prueba (480p)
        https://example.com/sd.m3u8
        #EXTINF:-1 tvg-id="Prueba.mx@Mexico" group-title="News",Prueba (1080p)
        https://example.com/hd.m3u8
        #EXTINF:-1 tvg-id="Otro.es" group-title="XXX",Excluir
        https://example.com/adult.m3u8
        """
        let channels = LiveDirectory.parse(playlist)
        precondition(channels.count == 1, "Must collapse feeds, exclude adult")
        precondition(channels[0].streamURL.contains("hd"), "Prefer Mexico feed")
        precondition(channels[0].alternatives.count == 1)
        precondition(LiveDirectory.matches(channels[0], .mexico))
        precondition(LiveDirectory.matches(channels[0], .news))
        let packed = "eval(function(p,a,c,k,e,d){}('0://1/2.3',36,4,'https|example.com|movie|m3u8'.split('|'),0,{}))"
        let unpacked = try JavaScriptUnpacker.unpack(packed)
        precondition(unpacked == "https://example.com/movie.m3u8")
        let suite = "tv.guizado.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(defaults: defaults)
        let first = store.activeID
        var film = Media(id: "test-film", title: "Prueba", kind: .movie)
        film.releaseYear = "2026"
        store.checkpoint(film, position: 150, duration: 600)
        precondition(store.continuing(.movies).count == 1)
        precondition(store.continuing(.series).isEmpty)
        store.toggleFavorite(film)
        let restored = AppStore(defaults: defaults)
        precondition(restored.bookmark(film.id)?.position == 150)
        precondition(restored.isFavorite(film))
        restored.createProfile("Segundo")
        precondition(restored.active.favorites.isEmpty && restored.active.history.isEmpty)
        restored.switchProfile(first)
        restored.checkpoint(film, position: 599, duration: 600)
        precondition(restored.continuing(.movies).isEmpty)
        let bytes = try JSONEncoder().encode(film)
        let decoded = try JSONDecoder().decode(Media.self, from: bytes)
        precondition(decoded == film)
        print("Core checks passed: M3U grouping/categories, unpacking, resume, profiles, persistence and Codable.")
    }
}
