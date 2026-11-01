import Foundation
import Combine
@preconcurrency import AVFoundation

@MainActor final class PlayerSession: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var media: Media
    @Published private(set) var loading = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var next: Media?
    @Published private(set) var countdown = 8
    private let store: AppStore
    private var logical: Media
    private var bridge: HLSBridge?
    private var status: NSKeyValueObservation?
    private var ended: NSObjectProtocol?
    private var clock: Any?
    private var loadTask: Task<Void, Never>?
    private var nextTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var token = UUID()
    private var attempted: Set<String> = []
    private var readyHandled = false
    private var recovering: UUID?
    private var started = false
    private var lastSave = Date.distantPast

    init(media: Media, store: AppStore) { self.media = media; self.logical = media; self.store = store }
    func start() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = true
        clock = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        load(media)
    }
    private func tick() {
        if player.rate > 0 { started = true }
        if started && Date().timeIntervalSince(lastSave) >= 5 { save(); lastSave = Date() }
    }
    func save() {
        guard started, logical.kind != .live else { return }
        store.checkpoint(logical, position: player.currentTime().seconds, duration: player.currentItem?.duration.seconds ?? 0)
    }
    func load(_ selected: Media, newTitle: Bool = true) {
        save(); cancelNext(); loadTask?.cancel(); timeoutTask?.cancel(); status = nil
        if let ended { NotificationCenter.default.removeObserver(ended) }; ended = nil
        if let old = bridge { Task { await old.stop() } }; bridge = nil
        player.pause(); player.replaceCurrentItem(with: nil)
        if newTitle { logical = selected; attempted = [] }
        media = selected; attempted.insert(selected.id); loading = true; errorMessage = nil; started = false; readyHandled = false; recovering = nil
        let request = UUID(); token = request
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let descriptor = try await CatalogService.shared.resolve(selected)
                try Task.checkCancellation()
                guard self.token == request else { return }
                let address: URL
                if !descriptor.referer.isEmpty {
                    let adapter = HLSBridge(descriptor); self.bridge = adapter
                    address = try await adapter.start()
                } else { address = descriptor.url }
                try Task.checkCancellation(); guard self.token == request else { return }
                let asset = AVURLAsset(url: address, options: [AVURLAssetHTTPUserAgentKey: CatalogService.userAgent])
                let item = AVPlayerItem(asset: asset)
                if self.store.settings.quality == .saver { item.preferredMaximumResolution = CGSize(width: 1280, height: 720); item.preferredPeakBitRate = 2_500_000 }
                self.status = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    Task { @MainActor in
                        guard let self, self.token == request else { return }
                        switch item.status {
                        case .readyToPlay: self.ready(item, request: request)
                        case .failed: await self.failed(request: request)
                        default: break
                        }
                    }
                }
                self.ended = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor in await self?.didEnd(request: request) }
                }
                self.player.replaceCurrentItem(with: item)
                self.timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                    guard let self, self.token == request, self.loading else { return }
                    await self.failed(request: request)
                }
            } catch is CancellationError { return }
            catch { await self.failed(request: request) }
        }
    }
    private func ready(_ item: AVPlayerItem, request: UUID) {
        guard !readyHandled, token == request else { return }; readyHandled = true
        timeoutTask?.cancel()
        let position = logical.kind == .live ? 0 : store.bookmark(logical.id)?.position ?? 0
        Task { [weak self] in
            guard let self else { return }
            if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible), self.token == request {
                if self.store.settings.captions {
                    let spanish = AVMediaSelectionGroup.mediaSelectionOptions(from: group.options, with: Locale(identifier: "es")).first
                    item.select(spanish ?? group.defaultOption, in: group)
                } else { item.select(nil, in: group) }
            }
        }
        if position > 0 {
            player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in guard let self, self.token == request else { return }; self.loading = false; self.started = true; self.player.play() }
            }
        } else { loading = false; started = true; player.play() }
    }
    private func failed(request: UUID) async {
        guard token == request, errorMessage == nil, recovering != request else { return }
        recovering = request
        defer { if recovering == request { recovering = nil } }
        timeoutTask?.cancel()
        if attempted.count < 3 {
            if logical.kind == .live, let other = logical.alternatives.first(where: { !attempted.contains($0.id) }) { load(other, newTitle: false); return }
            if logical.kind == .movie, let other = await CatalogService.shared.alternativePlayback(logical, excluding: attempted), token == request { load(other, newTitle: false); return }
        }
        guard token == request else { return }
        save(); player.pause(); loading = false
        errorMessage = "No se pudo reproducir esta fuente en iPhone. Puede estar caída, restringida o usar un formato incompatible."
    }
    private func didEnd(request: UUID) async {
        guard token == request else { return }
        store.checkpoint(logical, position: player.currentTime().seconds, duration: player.currentItem?.duration.seconds ?? 0, ended: true)
        started = false
        guard store.settings.autoNext, logical.kind == .episode else { return }
        guard let following = try? await CatalogService.shared.nextEpisode(after: logical), token == request else { return }
        next = following; countdown = 8
        nextTask = Task { [weak self] in
            for seconds in stride(from: 8, through: 1, by: -1) {
                guard let self, !Task.isCancelled else { return }; self.countdown = seconds
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
            self?.playNext()
        }
    }
    func playNext() { guard let next else { return }; load(next) }
    func cancelNext() { nextTask?.cancel(); nextTask = nil; next = nil }
    func retry() { load(logical) }
    func stop() {
        save(); token = UUID(); loadTask?.cancel(); timeoutTask?.cancel(); cancelNext()
        player.pause(); player.replaceCurrentItem(with: nil)
        if let clock { player.removeTimeObserver(clock) }; clock = nil
        if let ended { NotificationCenter.default.removeObserver(ended) }; ended = nil; status = nil
        if let bridge { Task { await bridge.stop() } }; bridge = nil
    }
}
