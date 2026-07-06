import SwiftUI
import OntologyKit
import CoreText

@main
struct HarnessApp: App {
    @State private var ontology = Ontology.empty
    @State private var ontologyLoaded = false

    init() { Self.registerFonts() }

    var body: some Scene {
        WindowGroup("The Adam Pattern") {
            #if os(macOS)
            MacChatView(ontology: ontology)
                .frame(
                    minWidth: CGFloat(HarnessWorkbenchLayoutState.transcriptMinimumWidth),
                    idealWidth: CGFloat(HarnessWorkbenchLayoutState().minimumWindowWidth),
                    minHeight: 680,
                    idealHeight: 780
                )
                .task(loadOntologyIfNeeded)
            #else
            ChatView(ontology: ontology)
                .task(loadOntologyIfNeeded)
            #endif
        }
        #if os(macOS)
        .windowResizability(.contentMinSize)
        #endif
    }

    private func loadOntologyIfNeeded() async {
        guard !ontologyLoaded else { return }
        let loaded = await Task.detached(priority: .userInitiated) {
            OntologyLoader.load()
        }.value
        await MainActor.run {
            ontology = loaded
            ontologyLoaded = true
        }
    }

    /// Register bundled display fonts so Font.custom can find them.
    private static func registerFonts() {
        for resource in ["PlayfairDisplay", "BodoniModa-Regular", "Roboto-Medium"] {
            guard let url = Bundle.main.url(forResource: resource, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
