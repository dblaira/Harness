import SwiftUI
import OntologyKit
import CoreText

@main
struct HarnessApp: App {
    @State private var ontology = Ontology.empty
    @State private var ontologyLoaded = false

    /// Owns the routines lifecycle: Hermes cron mirrored read-only, native
    /// harness-routines.json jobs fired headless on a 60s tick. Started once
    /// alongside the ontology load; injected so RoutinesView (inside the
    /// cockpit) observes it.
    @StateObject private var routineScheduler: RoutineScheduler
    #if os(macOS)
    /// WO-P: audio briefs over existing text, injected at the same seam
    /// as routineScheduler so any screen can play one the same way.
    @StateObject private var audioBriefPlayer = AudioBriefPlayer()
    #endif

    init() {
        Self.registerFonts()
        _routineScheduler = StateObject(wrappedValue: RoutineScheduler(
            runner: HarnessRoutineRunner(backendResolver: Self.resolveHeadlessBackend)
        ))
    }

    var body: some Scene {
        WindowGroup("The Adam Pattern") {
            #if os(macOS)
            MacChatView(ontology: ontology)
                .tint(Theme.savyCrimson)
                .frame(
                    minWidth: CGFloat(HarnessWorkbenchLayoutState.transcriptMinimumWidth),
                    idealWidth: CGFloat(HarnessWorkbenchLayoutState().minimumWindowWidth),
                    minHeight: 680,
                    idealHeight: 780
                )
                .environmentObject(routineScheduler)
                .environmentObject(audioBriefPlayer)
                .task(loadOntologyIfNeeded)
            #else
            ChatView(ontology: ontology)
                .environmentObject(routineScheduler)
                .task(loadOntologyIfNeeded)
            #endif
        }
        #if os(macOS)
        .windowResizability(.contentMinSize)
        #endif
    }

    private func loadOntologyIfNeeded() async {
        routineScheduler.start()
        guard !ontologyLoaded else { return }
        let loaded = await Task.detached(priority: .userInitiated) {
            OntologyLoader.load()
        }.value
        await MainActor.run {
            ontology = loaded
            ontologyLoaded = true
        }
    }

    /// Backend for headless routine runs, resolved at fire time so keys
    /// added after launch are picked up. Grok first (the Harness default),
    /// then Claude, then the ChatGPT-authenticated Codex CLI which needs no
    /// key at all.
    nonisolated private static func resolveHeadlessBackend() -> (backend: Backend, apiKey: String?) {
        let environment = ProcessInfo.processInfo.environment
        if let key = environment["XAI_API_KEY"], !key.isEmpty { return (.grok, key) }
        if let key = APIKeyStore.loadKey(for: .grok) { return (.grok, key) }
        if let key = environment["ANTHROPIC_API_KEY"], !key.isEmpty { return (.claude, key) }
        if let key = APIKeyStore.loadKey(for: .claude) { return (.claude, key) }
        return (.codex, nil)
    }

    /// Register bundled display fonts so Font.custom can find them.
    private static func registerFonts() {
        for resource in ["PlayfairDisplay", "BodoniModa-Regular", "Roboto-Medium"] {
            guard let url = Bundle.main.url(forResource: resource, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
