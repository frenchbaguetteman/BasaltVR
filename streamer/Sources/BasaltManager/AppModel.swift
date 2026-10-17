import Foundation
import AppKit
import CoreGraphics
import BasaltBottleKit
import BasaltCore
import BasaltManagerKit

/// Sidebar order; also the ⌘1…⌘6 order in the View menu.
enum ManagerSection: String, CaseIterable, Identifiable {
    case play = "Play"
    case library = "Library"
    case stream = "Stream"
    case bottles = "Bottles"
    case setup = "Setup"
    case settings = "Settings"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .play: return "play.circle"
        case .library: return "gamecontroller"
        case .stream: return "dot.radiowaves.left.and.right"
        case .bottles: return "shippingbox"
        case .setup: return "checklist"
        case .settings: return "gearshape"
        }
    }
}

enum SessionState: Equatable {
    case stopped
    case starting(profile: String)
    case streaming(profile: String)
    case utility(String)
    case failed(String)

    var label: String {
        switch self {
        case .stopped: return "Not running"
        case .starting: return "Connecting…"
        case .streaming(let profile): return "Streaming \(profile)"
        case .utility(let name): return name
        case .failed(let message): return message
        }
    }

    var isActive: Bool {
        switch self {
        case .starting, .streaming, .utility: return true
        case .stopped, .failed: return false
        }
    }

    var isStreaming: Bool {
        if case .streaming = self { return true }
        return false
    }

    /// The game profile of a starting or streaming session.
    var profileName: String? {
        switch self {
        case .starting(let profile), .streaming(let profile): return profile
        case .stopped, .utility, .failed: return nil
        }
    }
}

@MainActor
final class BasaltAppModel: ObservableObject {
    @Published var selection = ManagerSection.play
    @Published private(set) var setupChecks = [SetupCheck]()
    @Published private(set) var bottles = [ManagedBottle]()
    @Published private(set) var profiles = [LaunchProfile]()
    @Published private(set) var games = [DetectedGame]()
    @Published private(set) var discoveredBottles = [DiscoveredBottle]()
    @Published private(set) var steamGames = [SteamGame]()
    @Published private(set) var bsManagerInstances = [BSManagerInstance]()
    @Published private(set) var bsManagerInstallations = [BSManagerInstallation]()
    @Published private(set) var engines = [BottleEngine]()
    @Published private(set) var audioDevices = [GameAudioDevice]()
    @Published private(set) var sessionState = SessionState.stopped
    /// The log and metric samples, observed separately from this model.
    let console = SessionConsole()
    @Published var settings: StreamLaunchSettings {
        didSet { persistSettings() }
    }
    @Published private(set) var profileSettings = [String: StreamLaunchSettings]()
    @Published private(set) var dataRoot: URL
    @Published private(set) var bsManagerLocation: URL?
    /// The profile the Stream page offers to play; follows the last launch.
    @Published var preferredProfileName: String? {
        didSet {
            UserDefaults.standard.set(preferredProfileName, forKey: Self.preferredProfileKey)
        }
    }
    @Published var isBusy = false
    @Published var alertMessage: String?
    /// Finished VR sessions, newest first, persisted in the data root.
    @Published private(set) var sessionHistory = [SessionRecord]()
    /// Presents the diagnostic report sheet from Settings or the Help menu.
    @Published var showingDiagnostics = false

    var missingRequiredSetupCount: Int {
        setupChecks.filter { $0.required && $0.status != .ready }.count
    }

    let repoRoot: URL
    private(set) var manager: BottleManager
    /// The Play screen's session (scripts/play.zsh); separate from the Stream page's.
    let play: PlayController

    /// Tiles for the Play screen.
    var playGames: [PlayGame] {
        PlayLibrary.games(profiles: profiles, steamGames: steamGames)
    }

    private var streamerProcess: Process?
    private var gameProcess: Process?
    private var steamProcess: Process?
    private var controlFile: URL?
    private var activeWineCommand: BottleLaunchCommand?
    /// Identifies the in-flight `launch`. `stop()` clears it, so a launch that
    /// is still awaiting cleanup, Steam, or the streamer abandons quietly
    /// instead of starting more processes or reporting a spurious failure.
    private var activeLaunchID: UUID?
    /// The session `launch` started; `finishSession` records it to history.
    private var openSession: SessionRecord?
    private var hasChosenInitialSection = false
    private static let streamSettingsKey = "BasaltVR.streamSettings.v1"
    private static let preferredProfileKey = "BasaltVR.preferredProfile"
    private static let profileSettingsKey = "BasaltVR.profileSettings.v1"
    private static let dataRootKey = "BasaltVR.dataRoot"
    private static let bsManagerLocationKey = "BasaltVR.bsManagerLocation"

    init() {
        var startupError: String?
        let discovered: URL
        do {
            discovered = try RepositoryLocator.find()
        } catch {
            let packagedSupport = Bundle.main.resourceURL?
                .appendingPathComponent("BasaltVR", isDirectory: true)
            let candidates = [
                packagedSupport,
                Bundle.main.executableURL,
            ].compactMap { $0 }
            if let bundled = candidates.lazy.compactMap({
                try? RepositoryLocator.find(startingAt: $0)
            }).first {
                discovered = bundled
            } else {
                discovered = URL(
                    fileURLWithPath: FileManager.default.currentDirectoryPath,
                    isDirectory: true)
                startupError = error.localizedDescription
            }
        }
        repoRoot = discovered
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.streamSettingsKey),
           let decoded = try? JSONDecoder().decode(StreamLaunchSettings.self, from: data) {
            settings = decoded
        } else {
            settings = StreamLaunchSettings()
        }
        if let data = defaults.data(forKey: Self.profileSettingsKey),
           let decoded = try? JSONDecoder().decode(
            [String: StreamLaunchSettings].self, from: data) {
            profileSettings = decoded
        }
        let storedRoot = defaults.string(forKey: Self.dataRootKey)
        let selectedRoot = storedRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? BottleManager.defaultRoot()
        dataRoot = selectedRoot
        bsManagerLocation = defaults.string(forKey: Self.bsManagerLocationKey)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        preferredProfileName = defaults.string(forKey: Self.preferredProfileKey)
        manager = BottleManager(root: selectedRoot, repoRoot: discovered)
        play = PlayController(
            tools: PlayTools.locate(
                repoRoot: discovered,
                appExecutableDirectory: Bundle.main.executableURL?.deletingLastPathComponent()),
            dataRoot: selectedRoot)
        sessionHistory = SessionHistoryStore(dataRoot: selectedRoot).load()
        alertMessage = startupError
        Task { await refresh() }
    }

    func refresh() async {
        isBusy = true
        let manager = manager
        let repoRoot = repoRoot
        typealias RefreshResult = Result<(
            [ManagedBottle], [LaunchProfile], [DetectedGame],
            [BottleEngine], [SetupCheck], [GameAudioDevice],
            [DiscoveredBottle], [SteamGame], [BSManagerInstance],
            [BSManagerInstallation]
        ), Error>
        let bsManagerLocation = bsManagerLocation
        let result: RefreshResult = await Task.detached {
            do {
                try manager.prepare()
                let bottles = try manager.listBottles()
                let profiles = try manager.listProfiles()
                let games = GameDetector().detect(bottles: bottles, profiles: profiles)
                let checks = SetupInspector(repoRoot: repoRoot, manager: manager).inspect()
                let audio = (try? GameAudioDeviceDiscovery.inputDevices()) ?? []
                let discovered = ExternalBottleDiscovery().discover(managed: bottles)
                let steam = SteamLibraryDiscovery().discover(in: discovered)
                let bsManager = BSManagerDiscovery().discover(
                    additionalLocations: bsManagerLocation.map { [$0] } ?? [],
                    bottles: bottles)
                let bsManagerApps = BSManagerInstallationDiscovery().discover(
                    in: bottles)
                return RefreshResult.success(
                    (bottles, profiles, games, manager.engines(), checks, audio,
                     discovered, steam, bsManager, bsManagerApps))
            } catch {
                return RefreshResult.failure(error)
            }
        }.value
        switch result {
        case .success(let values):
            (bottles, profiles, games, engines, setupChecks, audioDevices,
             discoveredBottles, steamGames, bsManagerInstances,
             bsManagerInstallations) = values
            print("BasaltVR library: \(discoveredBottles.count) bottle(s), "
                  + "\(steamGames.filter { !$0.isTool }.count) Steam game(s), "
                  + "\(bsManagerInstances.count) BSManager instance(s), "
                  + "\(bsManagerInstallations.count) BSManager app(s), "
                  + "\(profiles.count) launch profile(s)")
            if settings.audioDeviceName == nil,
               let blackHole = audioDevices.first(where: {
                   $0.name.localizedCaseInsensitiveContains("BlackHole")
               }) {
                settings.audioDeviceName = blackHole.name
            }
            // Open on the library once the Mac is ready; first-run users
            // land on the checks they still need to finish.
            if !hasChosenInitialSection {
                hasChosenInitialSection = true
                // Players with games stay on Play; its own checks cover their setup.
                if selection == .play, missingRequiredSetupCount > 0, profiles.isEmpty {
                    selection = .setup
                }
            }
        case .failure(let error):
            alertMessage = error.localizedDescription
        }
        isBusy = false
    }

    @discardableResult
    func createBottle(name: String, engineID: String) async -> Bool {
        let manager = manager
        return await runBottleTask {
            _ = try manager.createBottle(name: name, engineID: engineID)
        }
    }

    func prepareBottle(_ name: String) async {
        let manager = manager
        await runBottleTask {
            _ = try manager.installDXMT(in: name)
            _ = try manager.installRuntime(in: name)
            _ = try manager.verify(name)
        }
    }

    @discardableResult
    func importBottle(_ bottle: DiscoveredBottle, as name: String) async -> Bool {
        guard !bottle.isManaged else { return false }
        guard let engine = engines.first(where: { $0.supportsBasaltDXMT }) else {
            alertMessage = "The isolated Basalt Wine/DXMT engine must be built before importing a bottle."
            return false
        }
        let manager = manager
        return await runBottleTask {
            _ = try manager.importPrefix(
                name: name, engineID: engine.id, sourcePrefix: bottle.prefix)
        }
    }

    func createProfile(for game: DetectedGame) async {
        guard game.profileName == nil else { return }
        isBusy = true
        let existingNames = Set(profiles.map { $0.name.lowercased() })
        let base = sanitizedProfileName("\(game.title)-\(game.bottleName)")
        var name = base
        var suffix = 2
        while existingNames.contains(name.lowercased()) {
            name = "\(base)-\(suffix)"
            suffix += 1
        }
        do {
            try manager.saveProfile(LaunchProfile(
                name: name, bottleName: game.bottleName, source: game.source,
                executable: game.executable,
                workingDirectory: game.hostExecutable?.deletingLastPathComponent().path))
            await refresh()
        } catch {
            alertMessage = error.localizedDescription
            isBusy = false
        }
    }

    func createSteamProfile(for game: SteamGame) async {
        guard let bottle = discoveredBottles.first(where: {
            $0.id == game.bottleID && $0.managed != nil
        }), let managed = bottle.managed else {
            alertMessage = "Copy this \(game.bottleOrigin.label) bottle into Basalt before creating a VR launch profile."
            return
        }
        let name = uniqueProfileName(for: "\(game.name)-\(managed.name)")
        let prefix = URL(fileURLWithPath: managed.prefixPath, isDirectory: true)
        do {
            let beatSaber = game.installDirectory.appendingPathComponent("Beat Saber.exe")
            let canLaunchGameDirectly = game.appID == "620980"
                && FileManager.default.fileExists(atPath: beatSaber.path)
            try manager.saveProfile(LaunchProfile(
                name: name, bottleName: managed.name, source: .steam,
                executable: BottleManager.winePath(
                    for: canLaunchGameDirectly ? beatSaber : game.steamExecutable,
                    prefix: prefix),
                arguments: canLaunchGameDirectly ? [] : ["-applaunch", game.appID],
                workingDirectory: (canLaunchGameDirectly
                    ? game.installDirectory
                    : game.steamExecutable.deletingLastPathComponent()).path,
                environment: canLaunchGameDirectly
                    ? ["SteamAppId": game.appID, "SteamGameId": game.appID]
                    : [:]))
            await refresh()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func createBSManagerProfile(
        for instance: BSManagerInstance, in bottle: ManagedBottle
    ) async {
        let name = uniqueProfileName(
            for: "Beat-Saber-\(instance.name)-\(bottle.name)")
        let prefix = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        do {
            try manager.saveProfile(LaunchProfile(
                name: name, bottleName: bottle.name, source: .bsmanager,
                executable: BottleManager.winePath(
                    for: instance.executable, prefix: prefix),
                workingDirectory: instance.directory.path,
                environment: [
                    "SteamAppId": "620980",
                    "SteamGameId": "620980",
                    "SteamOverlayGameId": "620980",
                    // BSIPA uses winhttp.dll as its early bootstrap hook.
                    "WINEDLLOVERRIDES": "winhttp=n,b",
                ]))
            await refresh()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func profile(for instance: BSManagerInstance) -> LaunchProfile? {
        profiles.first { profile in
            guard profile.source == .bsmanager,
                  let bottle = bottles.first(where: {
                      $0.name == profile.bottleName
                  }) else { return false }
            let expected = BottleManager.winePath(
                for: instance.executable,
                prefix: URL(fileURLWithPath: bottle.prefixPath, isDirectory: true))
            return profile.workingDirectory == instance.directory.path
                || profile.executable.caseInsensitiveCompare(expected) == .orderedSame
        }
    }

    func setBSManagerLocation(_ location: URL?) async {
        bsManagerLocation = location?.standardizedFileURL
        if let location = bsManagerLocation {
            UserDefaults.standard.set(location.path, forKey: Self.bsManagerLocationKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.bsManagerLocationKey)
        }
        await refresh()
    }

    func profile(for game: SteamGame) -> LaunchProfile? {
        guard game.bottleOrigin == .managed else { return nil }
        return profiles.first {
            $0.bottleName == game.bottleName && $0.source == .steam
                && ($0.arguments.contains(game.appID)
                    || $0.environment["SteamAppId"] == game.appID
                    || $0.environment["SteamGameId"] == game.appID)
        }
    }

    func updateProfile(_ profile: LaunchProfile) async {
        do {
            try manager.saveProfile(profile)
            await refresh()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func installOpenComposite(profileName: String, artifact: URL, target: URL) async {
        isBusy = true
        do {
            _ = try manager.installOpenComposite(
                profileName: profileName, artifact: artifact, targetDLL: target)
        } catch {
            alertMessage = error.localizedDescription
        }
        isBusy = false
    }

    func deleteProfile(_ name: String) async {
        do {
            try manager.deleteProfile(name)
            profileSettings[name] = nil
            persistProfileSettings()
            await refresh()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func streamSettings(for profile: String) -> StreamLaunchSettings {
        profileSettings[profile] ?? settings
    }

    func saveStreamSettings(_ value: StreamLaunchSettings, for profile: String) {
        profileSettings[profile] = value
        persistProfileSettings()
    }

    func resetStreamSettings(for profile: String) {
        profileSettings[profile] = nil
        persistProfileSettings()
    }

    func changeDataRoot(to root: URL) async {
        guard !sessionState.isActive, !play.isActive else {
            alertMessage = "Stop the current session before changing the data location."
            return
        }
        let standardized = root.standardizedFileURL
        dataRoot = standardized
        UserDefaults.standard.set(standardized.path, forKey: Self.dataRootKey)
        manager = BottleManager(root: standardized, repoRoot: repoRoot)
        play.update(tools: play.tools, dataRoot: standardized)
        sessionHistory = SessionHistoryStore(dataRoot: standardized).load()
        await refresh()
    }

    func launchSteam(in bottle: DiscoveredBottle) {
        guard let managed = bottle.managed else {
            alertMessage = "External bottles are shown read-only. Open this bottle in \(bottle.origin.label), or copy it into Basalt first."
            return
        }
        let candidates = [
            bottle.prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe"),
            bottle.prefix.appendingPathComponent("drive_c/Program Files/Steam/steam.exe"),
        ]
        guard let steam = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            alertMessage = "Steam is not installed in '\(bottle.name)'."
            return
        }
        do {
            let command = try manager.applicationLaunchCommand(
                bottleName: managed.name,
                executable: BottleManager.winePath(for: steam, prefix: bottle.prefix),
                currentDirectory: steam.deletingLastPathComponent())
            try launchUtility(command, label: "Steam • \(bottle.name)")
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func runInstaller(_ installer: URL, in bottle: DiscoveredBottle) {
        guard let managed = bottle.managed else { return }
        runInstaller(installer, in: managed)
    }

    func runBSManagerInstaller(_ installer: URL, in bottle: ManagedBottle) {
        runInstaller(installer, in: bottle, label: "BSManager installer")
    }

    func launchBSManager(_ installation: BSManagerInstallation) {
        guard let bottle = bottles.first(where: {
            $0.name == installation.bottleName
        }) else {
            alertMessage = "The Basalt bottle for this BSManager installation no longer exists."
            return
        }
        do {
            // Electron needs Wine's desktop shell activation path on macOS.
            // Launching the executable directly leaves app.whenReady() pending.
            // Keeping GPU work in the main process also avoids a transparent
            // Chromium window caused by cross-process surface compositing.
            // `/wait` keeps the launcher alive while BSManager runs: a bare
            // `start` exits at once, and the utility's exit handler then
            // stops every Wine process in the bottle, BSManager included.
            let command = try manager.applicationLaunchCommand(
                bottleName: bottle.name,
                executable: "start",
                arguments: [
                    "/wait",
                    "/unix",
                    installation.executable.path,
                    "--no-sandbox",
                    "--in-process-gpu",
                    "--disable-gpu",
                ],
                currentDirectory: installation.executable.deletingLastPathComponent())
            try launchUtility(command, label: "BSManager • \(bottle.name)")
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func runInstaller(
        _ installer: URL, in bottle: ManagedBottle, label: String = "Installer"
    ) {
        let prefix = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        do {
            let command = try manager.applicationLaunchCommand(
                bottleName: bottle.name,
                executable: BottleManager.winePath(for: installer, prefix: prefix),
                currentDirectory: installer.deletingLastPathComponent())
            try launchUtility(command, label: "\(label) • \(bottle.name)")
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func installDependency(for check: SetupCheck) async {
        switch check.id {
        case "screen":
            _ = CGRequestScreenCaptureAccess()
            await refresh()
        case "audio":
            // The BlackHole cask needs the Mac password, so it runs in Terminal.
            await play.perform(.installBlackHole)
            if let message = play.fixMessage { alertMessage = message }
        case "adb":
            guard let brew = SetupInspector.findExecutable(named: "brew") else {
                alertMessage = "Homebrew is not installed. Install it from brew.sh, then try again."
                NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
                return
            }
            isBusy = true
            let arguments = ["install", "android-platform-tools"]
            let result = await Self.runUtility(brew, arguments: arguments)
            isBusy = false
            if result.status != 0 { alertMessage = result.output }
            await refresh()
        case "wine", "runtime", "dxmt":
            NSWorkspace.shared.open(repoRoot.appendingPathComponent("docs/BOTTLES.md"))
        default:
            break
        }
    }

    func launch(profileName: String) async {
        guard !sessionState.isActive else { return }
        guard !play.isActive else {
            alertMessage = "A game is running from the Play page. Stop it there first."
            return
        }
        let launchID = UUID()
        activeLaunchID = launchID
        // Stop can run at any await below; never resume a stopped launch.
        func ensureCurrent() throws {
            guard activeLaunchID == launchID else { throw CancellationError() }
        }
        do {
            let launchSettings = streamSettings(for: profileName)
            preferredProfileName = profileName
            sessionState = .starting(profile: profileName)
            selection = .stream
            console.restart(with: "Preparing \(profileName)…\n")
            openSession = SessionRecord(profileName: profileName, settings: launchSettings)

            appendLog("Stopping stale Wine processes in this bottle…\n")
            let manager = manager
            // A failure thrown after Stop is swallowed by the catch below.
            try await Task.detached {
                _ = try manager.terminateBottleProcesses(forProfile: profileName)
            }.value
            try ensureCurrent()
            appendLog("Bottle process state is clean\n")

            // Keep the bottle-side DLL in lockstep with the streamer build.
            // A stale control-protocol version otherwise connects headlessly
            // and presents as a completely black headset view. Registering
            // (only when the bottle's registry no longer names this runtime)
            // cold-starts the just-stopped prefix, so keep it off the main actor,
            // and give stop() (also reached on failure) the prefix to shut down.
            activeWineCommand = try manager.prefixCommand(forProfile: profileName)
            try await Task.detached {
                let profile = try manager.loadProfile(profileName)
                try manager.syncRuntime(in: profile.bottleName)
            }.value
            try ensureCurrent()
            appendLog("OpenXR runtime is synchronized with this build\n")

            _ = try manager.installSteamWebHelperCompatibility(
                forProfile: profileName)
            if let steamCommand = try manager.steamBootstrapCommand(
                forProfile: profileName) {
                let connectionLog = try manager.steamConnectionLogURL(
                    forProfile: profileName)
                let initialLogSize = connectionLog.flatMap(Self.fileSize(at:)) ?? 0
                let steam = Process()
                steam.executableURL = steamCommand.executable
                steam.arguments = steamCommand.arguments
                steam.currentDirectoryURL = steamCommand.currentDirectory
                var steamEnvironment = ProcessInfo.processInfo.environment
                steamCommand.environment.forEach {
                    steamEnvironment[$0.key] = $0.value
                }
                steam.environment = steamEnvironment
                attachOutput(of: steam, prefix: "steam: ")
                steam.terminationHandler = { [weak self] process in
                    Task { @MainActor in
                        guard let self, self.steamProcess === process else { return }
                        self.steamProcess = nil
                    }
                }
                try steam.run()
                steamProcess = steam
                activeWineCommand = steamCommand
                appendLog("Starting Steam prerequisite…\n")
                try await Task.sleep(nanoseconds: 1_000_000_000)
                try ensureCurrent()
                // A cold start remains attached. Only accept a Logged On line
                // written by this client; otherwise a historical line can race
                // a new updater/login startup. A warm invocation exits quickly
                // and may use the current session's latest state.
                let requiredOffset = steam.isRunning ? initialLogSize : 0
                appendLog("Waiting for Steam sign-in and game IPC…\n")
                try await waitForSteam(
                    connectionLog: connectionLog,
                    after: requiredOffset,
                    launchID: launchID)
            }

            let streamer = try locateBuiltExecutable(named: "basalt-streamer")
            let control = FileManager.default.temporaryDirectory.appendingPathComponent(
                "basalt-manager-\(UUID().uuidString).control")
            let process = Process()
            process.executableURL = streamer
            process.arguments = launchSettings.arguments + ["--runtime", control.path]
            process.currentDirectoryURL = repoRoot
            attachOutput(of: process, prefix: "")
            process.terminationHandler = { [weak self] process in
                Task { @MainActor in
                    guard let self, self.streamerProcess === process else { return }
                    // While launch() is still starting up, it notices the exit
                    // itself and reports the streamer's own diagnostic.
                    guard self.activeLaunchID == nil else { return }
                    let sessionWasActive = self.sessionState.isActive
                    let failure = "Streamer exited with status \(process.terminationStatus)"
                    self.streamerProcess = nil
                    if sessionWasActive { self.finishSession(.failed, reason: failure) }
                    self.stop()
                    if sessionWasActive {
                        self.sessionState = .failed(failure)
                    }
                }
            }
            try process.run()
            streamerProcess = process
            controlFile = control
            appendLog("Starting \(launchSettings.connection.label) streamer…\n")

            for _ in 0..<300 where !FileManager.default.fileExists(atPath: control.path) {
                if !process.isRunning { break }
                try await Task.sleep(nanoseconds: 100_000_000)
                try ensureCurrent()
            }
            // A streamer terminated by Stop is not a startup failure.
            try ensureCurrent()
            if !process.isRunning {
                // Give the readability handler one turn to append the final
                // stderr chunk emitted immediately before process exit.
                try? await Task.sleep(nanoseconds: 100_000_000)
                try ensureCurrent()
                throw BottleToolError(
                    StreamerLogFailure.message(in: console.log)
                        ?? "The streamer exited before the VR runtime became ready (status \(process.terminationStatus)).")
            }
            guard FileManager.default.fileExists(atPath: control.path) else {
                throw BottleToolError(
                    "The streamer is still waiting for the headset. Keep ALVR open and the Quest awake, then try again.")
            }

            let command = try manager.profileLaunchCommand(
                profileName, controlFile: control)
            let game = Process()
            game.executableURL = command.executable
            game.arguments = command.arguments
            game.currentDirectoryURL = command.currentDirectory
            var environment = ProcessInfo.processInfo.environment
            command.environment.forEach { environment[$0.key] = $0.value }
            game.environment = environment
            attachOutput(of: game, prefix: "game: ")
            game.terminationHandler = { [weak self] game in
                Task { @MainActor in
                    guard let self, self.gameProcess === game else { return }
                    self.appendLog("Game exited with status \(game.terminationStatus)\n")
                    self.gameProcess = nil
                    self.finishSession(.ended)
                    self.stop()
                }
            }
            try game.run()
            gameProcess = game
            activeWineCommand = command
            activeLaunchID = nil
            openSession?.streamingStartedAt = Date()
            sessionState = .streaming(profile: profileName)
            selection = .stream
        } catch {
            // Stopped (or superseded by a newer launch): stop() already
            // released everything this launch started, and calling it again
            // here could tear down a session the user has since started.
            guard activeLaunchID == launchID else { return }
            finishSession(.failed, reason: error.localizedDescription)
            stop()
            sessionState = .failed(error.localizedDescription)
            alertMessage = error.localizedDescription
        }
    }

    func stop() {
        activeLaunchID = nil
        finishSession(.stopped)
        let game = gameProcess
        let steam = steamProcess
        let streamer = streamerProcess
        let wineCommand = activeWineCommand
        gameProcess = nil
        steamProcess = nil
        streamerProcess = nil
        activeWineCommand = nil

        if let game, game.isRunning { game.terminate() }
        if let steam, steam.isRunning { steam.terminate() }
        if let wineCommand {
            do {
                try manager.terminateBottleProcesses(launchedWith: wineCommand)
                appendLog("Stopped Wine processes for this session\n")
            } catch {
                appendLog("Wine cleanup failed: \(error.localizedDescription)\n")
            }
        }
        if let streamer, streamer.isRunning { streamer.terminate() }
        if let controlFile { try? FileManager.default.removeItem(at: controlFile) }
        controlFile = nil
        if sessionState.isActive { sessionState = .stopped }
    }

    private func waitForSteam(
        connectionLog: URL?, after offset: Int, launchID: UUID
    ) async throws {
        guard let connectionLog else {
            throw BottleToolError(
                "Steam did not create its connection log. Keep Steam open, finish setup, then try again.")
        }
        for _ in 0..<240 {
            guard activeLaunchID == launchID else { throw CancellationError() }
            if let data = try? Data(contentsOf: connectionLog),
               SteamConnectionLog.state(in: data, after: offset) == .loggedOn {
                appendLog("Steam is signed in; launching the game…\n")
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw BottleToolError(
            "Steam is open but not signed in. Sign in to Steam in the visible window, then press Play again.")
    }

    private static func fileSize(at url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue
    }

    @discardableResult
    private func runBottleTask(_ operation: @escaping @Sendable () throws -> Void) async -> Bool {
        isBusy = true
        do {
            try await Task.detached(operation: operation).value
            await refresh()
            return true
        } catch {
            alertMessage = error.localizedDescription
            isBusy = false
            return false
        }
    }

    private func sanitizedProfileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let mapped = value.lowercased().unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : "-"
        }
        let collapsed = String(mapped).replacingOccurrences(
            of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        return String((collapsed.isEmpty ? "game" : collapsed).prefix(56))
    }

    private func uniqueProfileName(for value: String) -> String {
        let existingNames = Set(profiles.map { $0.name.lowercased() })
        let base = sanitizedProfileName(value)
        var name = base
        var suffix = 2
        while existingNames.contains(name.lowercased()) {
            name = "\(base)-\(suffix)"
            suffix += 1
        }
        return name
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.streamSettingsKey)
        }
    }

    private func persistProfileSettings() {
        if let data = try? JSONEncoder().encode(profileSettings) {
            UserDefaults.standard.set(data, forKey: Self.profileSettingsKey)
        }
    }

    private func locateBuiltExecutable(named name: String) throws -> URL {
        let build = repoRoot.appendingPathComponent("streamer/.build", isDirectory: true)
        let candidates = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
            build.appendingPathComponent("release/\(name)"),
            build.appendingPathComponent("debug/\(name)"),
            build.appendingPathComponent("arm64-apple-macosx/release/\(name)"),
            build.appendingPathComponent("arm64-apple-macosx/debug/\(name)"),
        ].compactMap { $0 }
        if let found = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) { return found }
        throw BottleToolError(
            "\(name) is not built. Run `swift build -c release --package-path streamer` first.")
    }

    private func attachOutput(of process: Process, prefix: String) {
        // GUI utilities must not inherit BasaltVR's terminal. Foundation starts
        // child processes in their own process group, so an Electron app that
        // probes inherited stdin can otherwise be stopped by SIGTTIN when
        // BasaltVR itself was launched from a shell.
        process.standardInput = FileHandle.nullDevice

        // Keep stdout and stderr on distinct handles. Reusing one Foundation
        // Pipe for both descriptors works for simple Wine programs, but
        // Electron reconstructs process.stderr as a Node socket and sees the
        // shared descriptor as EBADF during bootstrap.
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        for pipe in [outputPipe, errorPipe] {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                let value = String(decoding: data, as: UTF8.self)
                Task { @MainActor in self?.appendLog(prefix + value) }
            }
        }
    }

    private func launchUtility(_ command: BottleLaunchCommand, label: String) throws {
        guard !sessionState.isActive, !play.isActive else {
            throw BottleToolError("Stop the current Wine or VR session first")
        }
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = command.currentDirectory
        var environment = ProcessInfo.processInfo.environment
        // VS Code/Codex shells may export this so their own Electron helper
        // processes behave like Node. Forwarding it through Wine makes packaged
        // Windows Electron apps such as BSManager run their main script as a
        // plain Node process instead of creating an application window.
        environment.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        command.environment.forEach { environment[$0.key] = $0.value }
        process.environment = environment
        attachOutput(of: process, prefix: "wine: ")
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.gameProcess === process else { return }
                self.appendLog("\(label) exited with status \(process.terminationStatus)\n")
                self.gameProcess = nil
                self.stop()
                await self.refresh()
            }
        }
        try process.run()
        gameProcess = process
        activeWineCommand = command
        sessionState = .utility(label)
        console.restart(with: "Launching \(label)…\n", clearingSamples: false)
        selection = .stream
    }

    func clearLog() {
        guard !sessionState.isActive else { return }
        console.restart()
    }

    /// Records the open session to history. The first outcome wins: the
    /// `stop()` that follows a game exit or failure finds nothing open.
    private func finishSession(_ outcome: SessionRecord.Outcome, reason: String? = nil) {
        guard var record = openSession else { return }
        openSession = nil
        // A launch stopped before the game started is not a session.
        guard record.streamingStartedAt != nil || outcome == .failed else { return }
        record.endedAt = Date()
        record.outcome = outcome
        record.failureReason = reason
        do {
            sessionHistory = try SessionHistoryStore(dataRoot: dataRoot).append(record)
        } catch {
            appendLog("Could not save session history: \(error.localizedDescription)\n")
        }
    }

    func clearSessionHistory() {
        do {
            try SessionHistoryStore(dataRoot: dataRoot).clear()
            sessionHistory = []
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// A snapshot for bug reports. Callers render it through a
    /// `DiagnosticRedactor`; nothing here leaves the Mac by itself.
    func makeDiagnosticReport(includeLog: Bool) -> DiagnosticReport {
        DiagnosticReport(
            application: .current(repoRoot: repoRoot),
            system: .current(),
            setupChecks: setupChecks,
            engines: engines,
            bottles: discoveredBottles,
            profiles: profiles,
            defaultStreamSettings: settings,
            profileStreamSettings: profileSettings,
            currentSession: .init(
                state: sessionState.label,
                profileName: openSession?.profileName,
                metrics: openSession?.metrics),
            recentSessions: sessionHistory,
            log: includeLog ? console.log : nil)
    }

    func export(_ text: String, to url: URL) {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alertMessage = "Could not save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func appendLog(_ value: String) {
        for line in console.append(value) {
            if let metric = StreamLogMetricsParser.parse(line: line) {
                console.record(metric)
                if let target = openSession?.settings.fps {
                    openSession?.metrics.add(metric, targetFPS: target)
                }
            } else if let refusal = RuntimeConnectionRefusal.message(in: line) {
                alertMessage = refusal
            }
        }
    }

    private static func runUtility(_ executable: URL, arguments: [String]) async
        -> (status: Int32, output: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(decoding: output, as: UTF8.self))
            } catch {
                return (1, error.localizedDescription)
            }
        }.value
    }
}
