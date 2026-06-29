import SwiftUI
import OntologyKit

@main
struct HarnessApp: App {
    private let ontology = OntologyLoader.load()
    var body: some Scene {
        WindowGroup {
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
}
