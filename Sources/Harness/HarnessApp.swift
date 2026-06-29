import SwiftUI
import OntologyKit

@main
struct HarnessApp: App {
    private let ontology = OntologyLoader.load()
    var body: some Scene {
        WindowGroup {
            ChatView(ontology: ontology)
        }
    }
}
