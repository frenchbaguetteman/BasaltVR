import SwiftUI
import AppKit
import BasaltBottleKit
import BasaltCore
import BasaltManagerKit

extension BasaltAppModel {
    /// Detected games and profiles that are not already shown as a
    /// BSManager instance.
    var directLibraryGames: [DetectedGame] {
        let instanceExecutables = Set(bsManagerInstances.map(\.executable.standardizedFileURL))
        return games.filter { game in
            guard game.source == .bsmanager, let executable = game.hostExecutable else {
                return true
            }
            return !instanceExecutables.contains(executable.standardizedFileURL)
        }
    }

    var libraryItemCount: Int {
        steamGames.filter { !$0.isTool }.count + bsManagerInstances.count
            + directLibraryGames.count
    }
}

enum LibrarySheet: Identifiable {
    case importBottle(DiscoveredBottle)
    case chooseBottle(BSManagerInstance)
    case installBSManager(URL)
    case addGame
    case edit(LaunchProfile)
    case settings(String)

    var id: String {
        switch self {
        case .importBottle(let bottle): "import-\(bottle.id)"
        case .chooseBottle(let instance): "choose-bottle-\(instance.id)"
        case .installBSManager(let url): "install-\(url.path)"
        case .addGame: "add-game"
        case .edit(let profile): "edit-\(profile.name)"
        case .settings(let profileName): "settings-\(profileName)"
        }
    }
}

struct LibraryView: View {
    @ObservedObject var model: BasaltAppModel
    @State private var search = ""
    @State private var sheet: LibrarySheet?
    @AppStorage("BasaltVR.library.vrOnly") private var vrOnly = false
    @AppStorage("BasaltVR.library.showTools") private var showTools = false

    private let columns = [
        GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 18, alignment: .top),
    ]

    private func matches(_ values: String...) -> Bool {
        search.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(search) }
    }

    /// Playable items first, otherwise in discovery (alphabetical) order.
    private func playableFirst<T>(_ items: [T], _ isPlayable: (T) -> Bool) -> [T] {
        items.filter(isPlayable) + items.filter { !isPlayable($0) }
    }

    private var steamGames: [SteamGame] {
        playableFirst(model.steamGames.filter {
            (showTools || !$0.isTool)
                && (!vrOnly || $0.isKnownVRGame)
                && matches($0.name, $0.bottleName)
        }) { model.profile(for: $0) != nil }
    }

    private var bsManagerInstances: [BSManagerInstance] {
        playableFirst(model.bsManagerInstances.filter {
            matches($0.name, $0.directory.path, $0.bottleName ?? "")
        }) { model.profile(for: $0) != nil }
    }

    private var directGames: [DetectedGame] {
        playableFirst(model.directLibraryGames.filter {
            matches($0.title, $0.bottleName)
        }) { $0.profileName != nil }
    }

    /// Steam games matching the search that only the persisted VR filter hides.
    private var hiddenByVROnly: Int {
        guard vrOnly else { return 0 }
        return model.steamGames.filter {
            (showTools || !$0.isTool) && !$0.isKnownVRGame && matches($0.name, $0.bottleName)
        }.count
    }

    private var showsBSManagerSection: Bool {
        !bsManagerInstances.isEmpty || search.isEmpty
    }

    var body: some View {
        let steam = steamGames
        let bsManager = bsManagerInstances
        let direct = directGames
        let isEmpty = steam.isEmpty && bsManager.isEmpty && direct.isEmpty
        let hidden = hiddenByVROnly

        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if isEmpty && hidden > 0 {
                    ContentUnavailableView {
                        Label("No VR games", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text(hiddenGamesText(hidden))
                    } actions: {
                        Button("Show All Games") { vrOnly = false }
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else if isEmpty && !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else if isEmpty && model.bsManagerInstallations.isEmpty {
                    emptyLibrary
                } else {
                    if !steam.isEmpty {
                        section("Steam", count: steam.count) {
                            ForEach(steam) { game in
                                SteamGameTile(game: game, model: model) { sheet = $0 }
                            }
                        }
                    } else if hidden > 0 {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionTitle(title: "Steam") {
                                Button("Show All Games") { vrOnly = false }
                                    .controlSize(.small)
                            }
                            Text(hiddenGamesText(hidden))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if showsBSManagerSection {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionTitle(title: "BSManager", count: bsManager.isEmpty ? nil : bsManager.count) {
                                BSManagerActions(model: model, present: { sheet = $0 })
                            }
                            if bsManager.isEmpty {
                                BSManagerHint(hasLauncher: !model.bsManagerInstallations.isEmpty)
                            } else {
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                                    ForEach(bsManager) { instance in
                                        BSManagerInstanceTile(instance: instance, model: model) { sheet = $0 }
                                    }
                                }
                            }
                        }
                    }
                    if !direct.isEmpty {
                        section("Launch Profiles", count: direct.count) {
                            ForEach(direct) { game in
                                DetectedGameTile(game: game, model: model) { sheet = $0 }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Library")
        .navigationSubtitle(plural(model.libraryItemCount, "game"))
        .searchable(text: $search, placement: .toolbar, prompt: "Search games or bottles")
        .toolbar {
            ToolbarItem {
                Button { sheet = .addGame } label: {
                    Label("Add Game…", systemImage: "plus")
                }
                .help("Add a Windows game from any folder in a Basalt bottle")
            }
            ToolbarItem {
                Menu {
                    Toggle("VR Games Only", isOn: $vrOnly)
                    Toggle("Show Steam Tools", isOn: $showTools)
                } label: {
                    Label(
                        "Filter",
                        systemImage: vrOnly || showTools
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle")
                }
                .help("Filter Steam games")
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .importBottle(let bottle):
                ImportBottleSheet(bottle: bottle, model: model)
            case .chooseBottle(let instance):
                BSManagerBottleSheet(instance: instance, model: model)
            case .installBSManager(let installer):
                BSManagerInstallerSheet(installer: installer, model: model)
            case .addGame:
                AddGameSheet(model: model)
            case .edit(let profile):
                ProfileEditorSheet(profile: profile, model: model)
            case .settings(let profileName):
                PerGameSettingsSheet(profileName: profileName, model: model)
            }
        }
    }

    private func section<Content: View>(
        _ title: String, count: Int, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title, count: count)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                content()
            }
        }
    }

    private func hiddenGamesText(_ count: Int) -> String {
        count == 1
            ? "1 Steam game is hidden by the VR Games Only filter."
            : "\(count) Steam games are hidden by the VR Games Only filter."
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("No games yet", systemImage: "gamecontroller")
        } description: {
            Text("Games installed with Steam in a Basalt, Whisky, or CrossOver bottle appear here automatically, along with BSManager versions and launch profiles.")
        } actions: {
            Button("Open Bottles") { model.selection = .bottles }
                .buttonStyle(.borderedProminent)
            Button("Locate BSManager…") { locateBSManager(model) }
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }
}

@MainActor
private func locateBSManager(_ model: BasaltAppModel) {
    guard let location = FilePanels.chooseFolder(
        title: "Locate BSManager or a Beat Saber Instance",
        message: "Choose an installation parent, BSManager, BSInstances, or an individual instance folder.")
    else { return }
    Task { await model.setBSManagerLocation(location) }
}

// MARK: - BSManager

private struct BSManagerActions: View {
    @ObservedObject var model: BasaltAppModel
    let present: (LibrarySheet) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if model.bsManagerInstallations.count == 1,
               let installation = model.bsManagerInstallations.first {
                Button {
                    model.launchBSManager(installation)
                } label: {
                    Label("Open BSManager", systemImage: "arrow.up.forward.app")
                }
                .disabled(model.sessionState.isActive)
            } else if !model.bsManagerInstallations.isEmpty {
                Menu {
                    ForEach(model.bsManagerInstallations) { installation in
                        Button(installation.bottleName) {
                            model.launchBSManager(installation)
                        }
                    }
                } label: {
                    Label("Open BSManager", systemImage: "arrow.up.forward.app")
                }
                .fixedSize()
                .disabled(model.sessionState.isActive)
            }

            Menu {
                Button(model.bsManagerInstallations.isEmpty
                       ? "Install from Windows Installer…" : "Update from Windows Installer…") {
                    chooseInstaller()
                }
                .disabled(model.sessionState.isActive)
                Button("Open Official Releases") {
                    NSWorkspace.shared.open(URL(
                        string: "https://github.com/Zagrios/bs-manager/releases/latest")!)
                }
                Divider()
                Button("Locate Instances Folder…") { locateBSManager(model) }
            } label: {
                if model.bsManagerInstallations.isEmpty {
                    Label("Install BSManager", systemImage: "arrow.down.circle")
                } else {
                    Label("More", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
            }
            .menuIndicator(model.bsManagerInstallations.isEmpty ? .visible : .hidden)
            .fixedSize()
            .help("Install, update, or locate BSManager")
        }
    }

    private func chooseInstaller() {
        guard !model.bottles.isEmpty else {
            model.alertMessage = "Create a Basalt bottle before installing BSManager."
            return
        }
        guard let url = FilePanels.chooseFile(
            title: "Choose the BSManager Windows Installer",
            message: "Select BSManager-Setup-*.exe downloaded from the official BSManager release.",
            extensions: ["exe"]) else { return }
        present(.installBSManager(url))
    }
}

private struct BSManagerHint: View {
    let hasLauncher: Bool

    var body: some View {
        HStack(spacing: 14) {
            SymbolTile(symbol: "wand.and.stars", tint: .purple, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(hasLauncher ? "No Beat Saber versions yet" : "Mod Beat Saber with BSManager")
                    .font(.headline)
                Text(hasLauncher
                     ? "Versions you download in BSManager appear here after it closes. A Steam copy of Beat Saber is listed under Steam."
                     : "Install BSManager into a Basalt bottle to download and mod Beat Saber versions. They appear here automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .cardStyle()
    }
}

// MARK: - Tiles

private struct SteamGameTile: View {
    let game: SteamGame
    @ObservedObject var model: BasaltAppModel
    let present: (LibrarySheet) -> Void

    var body: some View {
        let profile = model.profile(for: game)
        GameTile(
            title: game.name,
            subtitle: "\(game.bottleName) · \(game.bottleOrigin.label)",
            footnote: footnote,
            artwork: game.artwork.map(GameArtwork.image)
                ?? .generated(symbol: "gamecontroller.fill",
                              colors: [.basaltSlate, .black], caption: nil),
            chips: chips,
            profileName: profile?.name,
            model: model
        ) {
            if game.bottleOrigin == .managed {
                Button("Create Profile") {
                    Task { await model.createSteamProfile(for: game) }
                }
                .help("Create a VR launch profile for this game")
            } else {
                Button("Copy into Basalt…") {
                    if let bottle = model.discoveredBottles.first(where: { $0.id == game.bottleID }) {
                        present(.importBottle(bottle))
                    } else {
                        model.alertMessage = "Basalt could not find the source bottle for this Steam game. Refresh the library and try again."
                    }
                }
                .help("\(game.bottleOrigin.label) bottles are read-only. Copy this one into Basalt to play in VR.")
            }
        } menu: {
            if let profile {
                ProfileMenuItems(profile: profile, present: present)
                Divider()
            }
            Button("Show Game Files in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([game.installDirectory])
            }
        }
    }

    private var chips: [ArtworkChip] {
        var chips = [ArtworkChip(text: game.bottleOrigin.label.uppercased())]
        if game.isKnownVRGame {
            chips.append(ArtworkChip(text: "VR", systemImage: "visionpro"))
        }
        return chips
    }

    private var footnote: String? {
        var parts = [String]()
        if let size = game.sizeOnDisk {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let played = game.lastPlayed {
            parts.append("Played \(played.formatted(.relative(presentation: .named)))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct BSManagerInstanceTile: View {
    let instance: BSManagerInstance
    @ObservedObject var model: BasaltAppModel
    let present: (LibrarySheet) -> Void

    var body: some View {
        let profile = model.profile(for: instance)
        GameTile(
            title: "Beat Saber \(instance.name)",
            subtitle: instance.bottleName.map { "\($0) · BSManager" } ?? "BSManager",
            footnote: instance.isModded ? "Modded with BSIPA" : "Vanilla",
            artwork: .generated(
                symbol: instance.isModded ? "wand.and.stars" : "music.note",
                colors: [Color(red: 0.86, green: 0.12, blue: 0.32),
                         Color(red: 0.12, green: 0.36, blue: 0.95)],
                caption: instance.name),
            chips: [ArtworkChip(text: "BSMANAGER")]
                + (instance.isModded ? [ArtworkChip(text: "MODDED", systemImage: "wand.and.stars")] : []),
            profileName: profile?.name,
            model: model
        ) {
            if profile == nil {
                Button("Create Profile") { createProfile() }
                    .help("Create a VR launch profile in a Basalt bottle")
            }
        } menu: {
            if let profile {
                ProfileMenuItems(profile: profile, present: present)
                Divider()
            }
            Button("Show Instance in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([instance.executable])
            }
        }
    }

    private func createProfile() {
        let bottle = instance.bottleName.flatMap { name in
            model.bottles.first { $0.name == name }
        } ?? (model.bottles.count == 1 ? model.bottles.first : nil)
        if let bottle {
            Task { await model.createBSManagerProfile(for: instance, in: bottle) }
        } else {
            present(.chooseBottle(instance))
        }
    }
}

private struct DetectedGameTile: View {
    let game: DetectedGame
    @ObservedObject var model: BasaltAppModel
    let present: (LibrarySheet) -> Void

    var body: some View {
        let profile = game.profileName.flatMap { name in
            model.profiles.first { $0.name == name }
        }
        GameTile(
            title: game.title,
            subtitle: "\(game.bottleName) · \(game.source.rawValue.capitalized)",
            footnote: game.executable,
            artwork: .generated(
                symbol: "music.note.list",
                colors: [Color.basaltLava.opacity(0.85), Color(red: 0.35, green: 0.08, blue: 0.04)],
                caption: nil),
            chips: [ArtworkChip(text: game.source.rawValue.uppercased())],
            profileName: game.profileName,
            model: model
        ) {
            if game.profileName == nil {
                Button("Create Profile") {
                    Task { await model.createProfile(for: game) }
                }
            }
        } menu: {
            if let profile {
                ProfileMenuItems(profile: profile, present: present)
            }
            if let executable = game.hostExecutable {
                if profile != nil { Divider() }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([executable])
                }
            }
        }
    }
}

private struct ProfileMenuItems: View {
    let profile: LaunchProfile
    let present: (LibrarySheet) -> Void

    var body: some View {
        Button("Edit Launch Profile…") { present(.edit(profile)) }
        Button("Stream Settings…") { present(.settings(profile.name)) }
    }
}

/// One card shape for every library source: artwork, title block, and a
/// play/setup action with a secondary menu.
private struct GameTile<SetupAction: View, MenuItems: View>: View {
    let title: String
    let subtitle: String
    var footnote: String?
    let artwork: GameArtwork
    var chips: [ArtworkChip] = []
    /// The launch profile backing this tile, when it is ready to play.
    let profileName: String?
    @ObservedObject var model: BasaltAppModel
    @ViewBuilder var setupAction: SetupAction
    @ViewBuilder var menu: MenuItems
    @State private var hovering = false

    private var isLive: Bool {
        guard let profileName else { return false }
        return model.sessionState == .streaming(profile: profileName)
    }

    private var isStarting: Bool {
        guard let profileName else { return false }
        return model.sessionState == .starting(profile: profileName)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            GameArtworkView(artwork: artwork)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 5) {
                        ForEach(Array(chips.enumerated()), id: \.offset) { $0.element }
                    }
                    .padding(9)
                }
                .overlay(alignment: .topTrailing) {
                    if isLive {
                        ArtworkChip(text: "LIVE", systemImage: "dot.radiowaves.left.and.right", tint: .green)
                            .padding(9)
                    } else if profileName != nil {
                        ArtworkChip(text: "READY", systemImage: "checkmark", tint: .green)
                            .padding(9)
                    }
                }
                .overlay {
                    if let profileName, hovering, !model.sessionState.isActive {
                        Button {
                            Task { await model.launch(profileName: profileName) }
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 52, height: 52)
                                .background(Color.basaltLava, in: Circle())
                                .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                        .help("Play \(title)")
                    }
                }

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .help(title)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(footnote ?? " ")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 8) {
                    primaryAction
                    Spacer(minLength: 0)
                    Menu { menu } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More actions")
                }
            }
            .padding(14)
        }
        .background(.background.secondary)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                hovering ? Color.basaltLava.opacity(0.55) : Color.primary.opacity(0.08),
                lineWidth: hovering ? 1.5 : 1))
        .shadow(color: .black.opacity(hovering ? 0.22 : 0), radius: 14, y: 6)
        .scaleEffect(hovering ? 1.012 : 1)
        .animation(.easeOut(duration: 0.16), value: hovering)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var primaryAction: some View {
        if let profileName {
            if isLive {
                Button(role: .destructive) { model.stop() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else if isStarting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting…").foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { await model.launch(profileName: profileName) }
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.sessionState.isActive)
            }
        } else {
            setupAction
        }
    }
}

// MARK: - Artwork

enum GameArtwork {
    case image(URL)
    case generated(symbol: String, colors: [Color], caption: String?)
}

private struct GameArtworkView: View {
    let artwork: GameArtwork

    var body: some View {
        // Steam's library header art is 460 × 215.
        Color.clear
            .aspectRatio(460.0 / 215.0, contentMode: .fit)
            .overlay {
                switch artwork {
                case .image(let url):
                    ArtworkImage(url: url).id(url)
                case .generated(let symbol, let colors, let caption):
                    GeneratedArtwork(symbol: symbol, colors: colors, caption: caption)
                }
            }
            .clipped()
    }
}

private enum ArtworkCache {
    static let images = NSCache<NSURL, NSImage>()
}

/// Loads local Steam artwork off the main thread once, then serves it from
/// memory so library re-renders never touch the disk.
private struct ArtworkImage: View {
    let url: URL
    @State private var image: NSImage?

    init(url: URL) {
        self.url = url
        _image = State(initialValue: ArtworkCache.images.object(forKey: url as NSURL))
    }

    var body: some View {
        ZStack {
            Color.basaltSlate
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .task {
            guard image == nil else { return }
            let url = url
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: url)
            }.value
            guard let data, let loaded = NSImage(data: data) else { return }
            ArtworkCache.images.setObject(loaded, forKey: url as NSURL)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}

private struct GeneratedArtwork: View {
    let symbol: String
    let colors: [Color]
    let caption: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: symbol)
                .font(.system(size: 110, weight: .bold))
                .foregroundStyle(.white.opacity(0.12))
                .rotationEffect(.degrees(-12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .offset(x: 18, y: 14)
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                if let caption {
                    Text(caption)
                        .font(.system(.title2, design: .rounded).weight(.heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .foregroundStyle(.white)
            .padding(14)
        }
    }
}
