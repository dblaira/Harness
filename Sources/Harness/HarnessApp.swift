import SwiftUI
import OntologyKit
import CoreText

@main
struct HarnessApp: App {
    private let ontology = OntologyLoader.load()

    init() { Self.registerFonts() }

    var body: some Scene {
        WindowGroup("The Adam Pattern") {
            #if os(macOS)
            MacChatView(ontology: ontology)
                .frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 720)
            #else
            ChatView(ontology: ontology)
            #endif
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        #endif
    }

    /// Register bundled Playfair Display so Font.custom can find it.
    private static func registerFonts() {
        guard let url = Bundle.main.url(forResource: "PlayfairDisplay", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}
