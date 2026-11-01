import SwiftUI
import AVKit
import SafariServices

enum Palette {
    static let red = Color(red: 0.91, green: 0.035, blue: 0.21)
    static let panel = Color(red: 0.065, green: 0.065, blue: 0.085)
    static let muted = Color.white.opacity(0.58)
}
struct GShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 100
        let origin = CGPoint(x: rect.midX - 50 * scale, y: rect.midY - 50 * scale)
        var path = Path()
        path.addArc(center: CGPoint(x: 50, y: 50), radius: 34, startAngle: .degrees(40), endAngle: .degrees(320), clockwise: false)
        path.move(to: CGPoint(x: 50, y: 50)); path.addLine(to: CGPoint(x: 84, y: 50)); path.addLine(to: CGPoint(x: 84, y: 72))
        return path.applying(CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: origin.x, y: origin.y)))
    }
}
struct BrandMark: View {
    var animated = false
    var intro = false
    var reduced = false
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @State private var reveal: CGFloat = 0
    @State private var pulse = false
    var body: some View {
        GeometryReader { geometry in
            GShape().trim(from: 0, to: intro && !reduced && !systemReduced ? reveal : 1)
                .stroke(LinearGradient(colors: [Color(red: 1, green: 0.28, blue: 0.4), Palette.red, Color(red: 0.55, green: 0.02, blue: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing), style: StrokeStyle(lineWidth: min(geometry.size.width, geometry.size.height) * 0.13, lineCap: .butt, lineJoin: .miter))
                .padding(geometry.size.width * 0.04)
                .scaleEffect(pulse ? 1.015 : 1)
                .opacity(pulse ? 0.88 : 1)
                .onAppear {
                    if intro { withAnimation(.easeInOut(duration: 1.65)) { reveal = 1 } }
                    if animated && !reduced && !systemReduced { withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) { pulse = true } }
                }
        }.accessibilityLabel("GUIZADO TV")
    }
}
struct IntroScreen: View {
    @EnvironmentObject private var store: AppStore
    @State private var word = false
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 26) {
                BrandMark(animated: false, intro: true, reduced: store.settings.reduceMotion).frame(width: 160, height: 160)
                Text("GUIZADO TV").font(.system(size: 20, weight: .semibold, design: .rounded)).tracking(7).opacity(word ? 1 : 0)
            }
        }.onAppear { withAnimation(.easeOut(duration: 0.45).delay(0.5)) { word = true } }
    }
}
struct ArtworkView: View {
    let media: Media
    var backdrop = false
    var logo = false
    @EnvironmentObject private var store: AppStore
    @State private var artwork: UIImage?
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.18, green: 0.045, blue: 0.09), Palette.panel], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let artwork {
                if logo { Image(uiImage: artwork).resizable().scaledToFit().padding(12).transition(.opacity) }
                else { Image(uiImage: artwork).resizable().scaledToFill().transition(.opacity) }
            } else {
                BrandMark(reduced: true).frame(width: 50, height: 50).opacity(0.45)
            }
        }.clipped().task(id: media.id + (backdrop ? ":backdrop" : ":poster")) {
            if let local = await ArtworkCache.shared.bundled(media) { artwork = local; if !backdrop { return } }
            if backdrop { do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return } }
            let address = backdrop && !media.backdrop.isEmpty ? media.backdrop : media.image
            var loaded = await ArtworkCache.shared.image(address, referer: media.source == "cinecalidad" ? CatalogService.secondary + "/" : CatalogService.primary.absoluteString + "/")
            if loaded == nil && !backdrop, let alternate = await CatalogService.shared.alternativeArtwork(media) { loaded = await ArtworkCache.shared.image(alternate) }
            guard !Task.isCancelled, let loaded else { return }
            withAnimation(store.settings.reduceMotion ? nil : .easeOut(duration: 0.18)) { artwork = loaded }
        }
    }
}
struct PosterCard: View {
    let media: Media
    var width: CGFloat = 124
    let action: () -> Void
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                ArtworkView(media: media, logo: media.kind == .live).frame(width: width, height: media.kind == .live ? width * 0.67 : width * 1.48).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 12))
                Text(media.title).font(.system(size: 12, weight: .medium)).lineLimit(2).frame(height: 32, alignment: .topLeading)
                if let saved = store.bookmark(media.id) {
                    ProgressView(value: saved.fraction).tint(Palette.red)
                    if !saved.remaining.isEmpty { Text(saved.remaining).font(.caption2).foregroundStyle(Palette.muted).lineLimit(1) }
                } else { Text(media.subtitle).font(.caption2).foregroundStyle(Palette.muted).lineLimit(1) }
            }.frame(width: width, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(PosterPressStyle(reduced: store.settings.reduceMotion))
            .contextMenu {
                Button { store.toggleFavorite(media) } label: { Label(store.isFavorite(media) ? "Quitar de mi lista" : "Guardar en mi lista", systemImage: store.isFavorite(media) ? "heart.slash" : "heart") }
                if let _ = store.bookmark(media.id) { Button("Reproducir desde el principio") { store.checkpoint(media, position: 0, duration: 0, ended: true); store.open(media) } }
            }
            .accessibilityLabel(media.title + ", " + media.subtitle)
    }
}
struct PosterPressStyle: ButtonStyle {
    var reduced: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed && !reduced ? 0.975 : 1).opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduced ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
private struct GridWidth: PreferenceKey {
    static var defaultValue: CGFloat = 320
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
struct MediaGrid: View {
    let media: [Media]
    @EnvironmentObject private var store: AppStore
    @State private var available: CGFloat = 320
    var body: some View {
        let count = max(2, Int((available + 12) / 116))
        let width = max(80, (available - CGFloat(count - 1) * 12) / CGFloat(count))
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 12), count: count), spacing: 20) {
            ForEach(media) { item in PosterCard(media: item, width: width) { store.open(item) } }
        }.frame(maxWidth: .infinity).background(GeometryReader { proxy in Color.clear.preference(key: GridWidth.self, value: proxy.size.width) })
            .onPreferenceChange(GridWidth.self) { available = $0 }
    }
}
struct NoticeView: View {
    let title: String
    let detail: String
    var symbol = "sparkles.tv"
    var body: some View {
        VStack(spacing: 13) { Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(Palette.red); Text(title).font(.headline); Text(detail).font(.subheadline).foregroundStyle(Palette.muted).multilineTextAlignment(.center) }
            .frame(maxWidth: .infinity).padding(.vertical, 52).padding(.horizontal, 22)
    }
}
struct OfficialBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration(); configuration.entersReaderIfAvailable = false
        let view = SFSafariViewController(url: url, configuration: configuration)
        view.preferredControlTintColor = UIColor(Palette.red); view.dismissButtonStyle = .close; return view
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
struct NativePlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController(); controller.player = player; controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = true; controller.canStartPictureInPictureAutomaticallyFromInline = true
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { if controller.player !== player { controller.player = player } }
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) { controller.player = nil }
}
@MainActor struct PlayerScreen: View {
    @StateObject private var session: PlayerSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    init(media: Media, store: AppStore) { _session = StateObject(wrappedValue: PlayerSession(media: media, store: store)) }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            NativePlayer(player: session.player).ignoresSafeArea()
            VStack {
                HStack { Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).padding(13).background(.black.opacity(0.65), in: Circle()) }; Spacer() }.padding()
                Spacer()
                if session.loading { ProgressView("Cargando \(session.media.title)…").tint(.white).padding(22).background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 16)) }
                if let error = session.errorMessage {
                    VStack(spacing: 16) { Text("Fuente no disponible").font(.headline); Text(error).font(.subheadline).multilineTextAlignment(.center); Button("Reintentar") { session.retry() }.buttonStyle(.borderedProminent).tint(Palette.red) }.padding(24).background(Palette.panel, in: RoundedRectangle(cornerRadius: 20)).padding()
                }
                if let next = session.next {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Siguiente episodio en \(session.countdown) s").font(.headline)
                        Text(next.title).lineLimit(2)
                        HStack { Button("Ver ahora") { session.playNext() }.buttonStyle(.borderedProminent).tint(Palette.red); Button("Cancelar") { session.cancelNext() }.buttonStyle(.bordered) }
                    }.padding(20).frame(maxWidth: 420).background(Palette.panel, in: RoundedRectangle(cornerRadius: 18)).padding()
                }
                Spacer().frame(height: 50)
            }
        }.preferredColorScheme(.dark).onAppear { session.start() }.onDisappear { session.stop() }
            .onChange(of: scenePhase) { phase in if phase != .active { session.save() } }
    }
}
