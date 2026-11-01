import SwiftUI

@main @MainActor struct GuizadoTVApp: App {
    @StateObject private var store = AppStore()
    var body: some Scene { WindowGroup { RootScreen().environmentObject(store).preferredColorScheme(.dark).tint(Palette.red) } }
}
struct RootScreen: View {
    @EnvironmentObject private var store: AppStore
    @State private var intro = true
    var body: some View {
        ZStack {
            TabView {
                NavigationStack { HomeScreen() }.tabItem { Label("Inicio", systemImage: "house") }
                NavigationStack { LibraryScreen(section: .movies) }.tabItem { Label("Películas", systemImage: "film") }
                NavigationStack { LibraryScreen(section: .series) }.tabItem { Label("Series", systemImage: "tv") }
                NavigationStack { TVScreen() }.tabItem { Label("TV", systemImage: "antenna.radiowaves.left.and.right") }
                NavigationStack { AccountScreen() }.tabItem { Label("Mi espacio", systemImage: "person.crop.circle") }
            }
            if intro && store.settings.showIntro { IntroScreen().transition(.opacity).zIndex(2) }
        }.task {
            if store.settings.showIntro { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            withAnimation(store.settings.reduceMotion ? nil : .easeOut(duration: 0.25)) { intro = false }
        }.fullScreenCover(item: $store.playing) { PlayerScreen(media: $0, store: store) }
            .sheet(item: $store.browsingSeries) { media in NavigationStack { SeriesScreen(parent: media) } }
            .sheet(item: $store.official) { media in if let url = URL(string: media.officialURL) { OfficialBrowser(url: url).ignoresSafeArea() } }
    }
}
struct HomeScreen: View {
    @EnvironmentObject private var store: AppStore
    @State private var movies: [Media] = []
    @State private var message = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack { BrandMark(animated: true, reduced: store.settings.reduceMotion).frame(width: 48, height: 48); Text("GUIZADO TV").font(.title2.bold()); Spacer() }
                if !movies.isEmpty {
                    Text("Para ti").font(.title3.bold())
                    ScrollView(.horizontal, showsIndicators: false) { LazyHStack(alignment: .top, spacing: 14) { ForEach(store.recommendations(from: movies)) { media in PosterCard(media: media, width: 134) { store.open(media) } } } }
                }
                HStack { Text("Todas las películas").font(.title3.bold()); Spacer(); NavigationLink("Ver todo") { LibraryScreen(section: .movies) }.font(.subheadline) }
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(Palette.muted) }
                MediaGrid(media: movies)
            }.padding(16)
        }.background(Color.black).navigationTitle("Inicio").navigationBarTitleDisplayMode(.inline)
            .task { movies = await CatalogService.shared.bundledMovies(); await refresh() }
            .refreshable { await refresh() }
    }
    private func refresh() async {
        do { movies = try await CatalogService.shared.catalog(.movies).items; message = "" }
        catch { message = "Mostrando el catálogo guardado. Desliza para reintentar." }
    }
}
struct LibraryScreen: View {
    let section: LibrarySection
    @EnvironmentObject private var store: AppStore
    @State private var filter = CatalogFilter.all
    @State private var genres: [Genre] = []
    @State private var genreID = ""
    @State private var query = ""
    @State private var items: [Media] = []
    @State private var page = 1
    @State private var hasNext = false
    @State private var loading = false
    @State private var message = ""
    private var requestKey: String { section.rawValue + filter.rawValue + genreID + query }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Picker("Mostrar", selection: $filter) { ForEach(CatalogFilter.allCases) { Text($0.title).tag($0) } }.pickerStyle(.menu)
                    Spacer()
                    if filter == .genres { Picker("Género", selection: $genreID) { Text("Todos los géneros").tag(""); ForEach(genres) { Text($0.title).tag($0.id) } }.pickerStyle(.menu) }
                }
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(Palette.muted) }
                if filter == .continuing {
                    if store.continuing(section).isEmpty { NoticeView(title: "Todavía no hay progreso", detail: "Tus películas o episodios empezados aparecerán aquí.") }
                    MediaGrid(media: store.continuing(section))
                } else {
                    MediaGrid(media: items)
                    if loading { ProgressView().frame(maxWidth: .infinity) }
                    if !loading && items.isEmpty { NoticeView(title: "Sin resultados", detail: "Prueba otra búsqueda o actualiza el catálogo.") }
                    if hasNext && !loading { Button("Cargar más") { Task { await fetch(reset: false) } }.buttonStyle(.bordered).frame(maxWidth: .infinity) }
                }
            }.padding(16)
        }.background(Color.black).navigationTitle(section.title).navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: section == .movies ? "Buscar película" : "Buscar serie")
            .task(id: requestKey) {
                do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
                await fetch(reset: true)
            }.task { genres = (try? await CatalogService.shared.genres()) ?? [] }
            .refreshable { await fetch(reset: true) }
    }
    private func fetch(reset: Bool) async {
        guard filter != .continuing else { return }
        let key = requestKey; loading = true
        if reset { page = 1; items = [] }
        defer { if key == requestKey { loading = false } }
        do {
            let response = try await CatalogService.shared.catalog(section, page: reset ? 1 : page + 1, query: query, filter: filter, genre: genres.first { $0.id == genreID })
            guard !Task.isCancelled, key == requestKey else { return }
            let existing = Set(items.map(\.id))
            items = reset ? response.items : items + response.items.filter { !existing.contains($0.id) }
            page = response.page; hasNext = response.hasNext; message = response.fromCache ? "Catálogo guardado; se actualizará cuando la fuente responda." : ""
        } catch is CancellationError { } catch { if key == requestKey { message = "No se pudo actualizar. Desliza para reintentar." } }
    }
}
struct SeriesScreen: View {
    let parent: Media
    @EnvironmentObject private var store: AppStore
    @State private var items: [Media] = []
    @State private var season: Int?
    @State private var page = 1
    @State private var more = false
    @State private var loading = false
    @State private var error = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ArtworkView(media: parent, backdrop: true).frame(height: 190).clipShape(RoundedRectangle(cornerRadius: 16))
                if !parent.overview.isEmpty { Text(parent.overview).font(.subheadline).foregroundStyle(Palette.muted) }
                Button(store.isFavorite(parent) ? "Quitar de mi lista" : "Guardar serie") { store.toggleFavorite(parent) }.buttonStyle(.bordered)
                if season != nil { Button("Todas las temporadas") { season = nil; Task { await load(reset: true) } } }
                ForEach(items) { item in
                    Button {
                        if item.kind == .season { season = item.season; Task { await load(reset: true) } }
                        else { store.browsingSeries = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { store.open(item) } }
                    } label: {
                        HStack(spacing: 14) {
                            ArtworkView(media: item).frame(width: 88, height: 58).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 5) { Text(item.title).font(.subheadline).lineLimit(2); Text(item.subtitle).font(.caption).foregroundStyle(Palette.muted) }
                            Spacer(); Image(systemName: item.kind == .season ? "chevron.right" : "play.fill").foregroundStyle(Palette.red)
                        }.padding(10).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                }
                if loading { ProgressView().frame(maxWidth: .infinity) }
                if !error.isEmpty { Text(error).font(.footnote) }
                if more && !loading { Button("Más episodios") { Task { await load(reset: false) } } }
            }.padding(16)
        }.background(Color.black).navigationTitle(parent.title).navigationBarTitleDisplayMode(.inline).task { await load(reset: true) }
    }
    private func load(reset: Bool) async {
        loading = true; defer { loading = false }
        do { let result = try await CatalogService.shared.episodes(for: parent, season: season, page: reset ? 1 : page + 1); items = reset ? result.items : items + result.items; page = result.page; more = result.hasNext; error = "" }
        catch { self.error = "No se pudieron cargar los episodios. Vuelve a abrir la serie para reintentar." }
    }
}
struct TVScreen: View {
    @EnvironmentObject private var store: AppStore
    @State private var channels: [Media] = []
    @State private var category = TVCategory.mexico
    @State private var query = ""
    @State private var loading = true
    var filtered: [Media] { channels.filter { LiveDirectory.matches($0, category) && (query.isEmpty || TextTools.normalized($0.title).contains(TextTools.normalized(query))) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Picker("Sección", selection: $category) { ForEach(TVCategory.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu); Spacer(); Text("\(filtered.count) canales").font(.caption).foregroundStyle(Palette.muted) }
                if category == .all || category == .entertainment {
                    DisclosureGroup("Realities · sitios oficiales") { ForEach(LiveDirectory.realities) { media in Button(media.title) { store.open(media) }.padding(.vertical, 8) }; Text("La emisión depende del país, la temporada y el proveedor.").font(.caption).foregroundStyle(Palette.muted) }
                }
                if loading { ProgressView().frame(maxWidth: .infinity) }
                MediaGrid(media: filtered)
                if !loading && filtered.isEmpty { NoticeView(title: "No hay señales en esta sección", detail: "Prueba otra categoría. La disponibilidad de los canales puede cambiar.") }
            }.padding(16)
        }.background(Color.black).navigationTitle("TV en vivo").navigationBarTitleDisplayMode(.inline).searchable(text: $query, prompt: "Buscar canal")
            .task { channels = await CatalogService.shared.channels(); loading = false }
            .refreshable { channels = await CatalogService.shared.channels(refresh: true) }
    }
}
struct AccountScreen: View {
    @EnvironmentObject private var store: AppStore
    @State private var kind = MediaKind.movie
    @State private var profileName = ""
    var body: some View {
        List {
            Section("Mi lista") {
                Picker("Contenido", selection: $kind) { Text("Películas").tag(MediaKind.movie); Text("Series").tag(MediaKind.series); Text("TV").tag(MediaKind.live) }.pickerStyle(.segmented)
                ForEach(store.active.favorites.filter { $0.kind == kind }) { media in Button { store.open(media) } label: { HStack { ArtworkView(media: media, logo: kind == .live).frame(width: 44, height: 58).clipShape(RoundedRectangle(cornerRadius: 6)); Text(media.title); Spacer(); Image(systemName: "chevron.right") } }.swipeActions { Button("Quitar", role: .destructive) { store.toggleFavorite(media) } } }
                if store.active.favorites.filter({ $0.kind == kind }).isEmpty { Text("Mantén pulsada una carátula para guardarla.").font(.footnote).foregroundStyle(Palette.muted) }
            }
            Section("Perfil local") {
                Picker("Perfil", selection: Binding(get: { store.activeID }, set: { store.switchProfile($0) })) { ForEach(store.profiles) { Text($0.name).tag($0.id) } }
                if store.profiles.count < 6 { HStack { TextField("Nombre de nuevo perfil", text: $profileName); Button("Crear") { store.createProfile(profileName); profileName = "" }.disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty) } }
            }
            Section("Reproducción") {
                Picker("Calidad", selection: Binding(get: { store.settings.quality }, set: { store.update(\.quality, $0) })) { ForEach(Quality.allCases) { Text($0.title).tag($0) } }
                Toggle("Subtítulos preferidos", isOn: Binding(get: { store.settings.captions }, set: { store.update(\.captions, $0) }))
                Toggle("Siguiente episodio automático", isOn: Binding(get: { store.settings.autoNext }, set: { store.update(\.autoNext, $0) }))
                Text("La resolución y los subtítulos dependen de la fuente y del iPhone. El reproductor ajusta la calidad a la conexión.").font(.caption).foregroundStyle(Palette.muted)
            }
            Section("Apariencia") {
                Toggle("Animación de entrada", isOn: Binding(get: { store.settings.showIntro }, set: { store.update(\.showIntro, $0) }))
                Toggle("Reducir movimiento", isOn: Binding(get: { store.settings.reduceMotion }, set: { store.update(\.reduceMotion, $0) }))
            }
            Section("Acerca de") {
                Text("GUIZADO TV · iOS 1.0").font(.headline)
                Text("El catálogo se consulta por internet. Las señales externas pueden cambiar o dejar de estar disponibles. Los perfiles, favoritos y el progreso se guardan en este iPhone.").font(.footnote)
                Text("Actualizar el catálogo no actualiza la app: las nuevas versiones deberán instalarse mediante el método de distribución que se configure.").font(.footnote).foregroundStyle(Palette.muted)
            }
        }.scrollContentBackground(.hidden).background(Color.black).navigationTitle("Mi espacio").navigationBarTitleDisplayMode(.inline)
    }
}
