import Foundation
import Combine

@MainActor final class AppStore: ObservableObject {
    @Published private(set) var profiles: [Profile]
    @Published private(set) var activeID: String
    @Published var playing: Media?
    @Published var official: Media?
    @Published var browsingSeries: Media?
    private let defaults: UserDefaults
    var active: Profile { profiles.first(where: { $0.id == activeID }) ?? profiles[0] }
    var settings: UserSettings { active.settings }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let initial: [Profile]
        if let bytes = defaults.data(forKey: "guizado.ios.profiles.v1"), let records = try? JSONDecoder().decode([Profile].self, from: bytes), !records.isEmpty { initial = records }
        else { initial = [Profile(name: "Principal")] }
        profiles = initial
        activeID = defaults.string(forKey: "guizado.ios.active") ?? initial[0].id
        if !profiles.contains(where: { $0.id == activeID }) { activeID = profiles[0].id }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "guizado.ios.profiles.v1") }
        defaults.set(activeID, forKey: "guizado.ios.active")
    }
    func switchProfile(_ id: String) { guard profiles.contains(where: { $0.id == id }) else { return }; activeID = id; save() }
    func createProfile(_ name: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        guard !name.isEmpty, profiles.count < 6 else { return }
        let profile = Profile(name: name); profiles.append(profile); activeID = profile.id; save()
    }
    func update<Value>(_ key: WritableKeyPath<UserSettings, Value>, _ value: Value) {
        guard let index = profiles.firstIndex(where: { $0.id == activeID }) else { return }
        profiles[index].settings[keyPath: key] = value; save()
    }
    func isFavorite(_ item: Media) -> Bool {
        active.favorites.contains { $0.id == item.id || (item.kind == .live && $0.kind == .live && LiveDirectory.identity($0) == LiveDirectory.identity(item)) }
    }
    func toggleFavorite(_ item: Media) {
        guard let index = profiles.firstIndex(where: { $0.id == activeID }) else { return }
        if isFavorite(item) { profiles[index].favorites.removeAll { $0.id == item.id || (item.kind == .live && $0.kind == .live && LiveDirectory.identity($0) == LiveDirectory.identity(item)) } }
        else { profiles[index].favorites.insert(item, at: 0) }
        save()
    }
    func bookmark(_ id: String) -> Bookmark? { active.history.first { $0.id == id } }
    func checkpoint(_ media: Media, position: Double, duration: Double, ended: Bool = false) {
        guard media.kind == .movie || media.kind == .episode, position.isFinite, let index = profiles.firstIndex(where: { $0.id == activeID }) else { return }
        profiles[index].history.removeAll { $0.id == media.id }
        let duration = duration.isFinite ? max(0, duration) : 0
        let complete = ended || (duration > 0 && position >= max(duration - 15, duration * 0.98))
        if !complete && position >= 5 {
            profiles[index].history.insert(Bookmark(media: media, position: position, duration: duration, updated: Date()), at: 0)
        }
        profiles[index].history = Array(profiles[index].history.prefix(100)); save()
    }
    func continuing(_ section: LibrarySection) -> [Media] { active.history.filter { section == .movies ? $0.media.kind == .movie : $0.media.kind == .episode }.map(\.media) }
    func recommendations(from films: [Media]) -> [Media] {
        let preferred = Set((active.favorites + active.history.map(\.media)).flatMap(\.genreIDs))
        let unfinished = Set(active.history.map(\.id))
        return Array(films.filter { $0.kind == .movie && !unfinished.contains($0.id) }.enumerated().sorted {
            let left = Set($0.element.genreIDs).intersection(preferred).count
            let right = Set($1.element.genreIDs).intersection(preferred).count
            return left == right ? $0.offset < $1.offset : left > right
        }.map(\.element).prefix(6))
    }
    func open(_ media: Media) { if media.kind == .series { browsingSeries = media } else if media.kind == .official { official = media } else if media.playable { playing = media } }
}
