import Foundation
import Testing
@testable import OntologyKit

private struct AcceptingParser: TurtleParsing {
    func parse(_ turtle: String) throws {}
}

private struct RejectingParser: TurtleParsing {
    func parse(_ turtle: String) throws {
        throw TurtleParseError("rating must be an integer between 1 and 10")
    }
}

private struct FailingPoster: AcceptedGraphPosting {
    func postAcceptedTriples(_ turtle: String) async throws { throw URLError(.cannotConnectToHost) }
    func replaceAcceptedGraph(_ turtle: String) async throws { throw URLError(.cannotConnectToHost) }
}

private func temporaryOntologyRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pattern-gate-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeStore(_ root: URL, parser: any TurtleParsing = AcceptingParser()) -> PatternEvidenceStore {
    PatternEvidenceStore(ontologyRoot: root, turtleParser: parser, acceptedGraphPoster: FailingPoster())
}

private func localGraphURL(_ root: URL) -> URL {
    root.appendingPathComponent("accepted", isDirectory: true)
        .appendingPathComponent("accepted-graph.ttl")
}

private func unreachableChecker(localGraphURL url: URL) -> PatternGateChecker {
    PatternGateChecker(
        sparqlEndpoint: URL(string: "http://127.0.0.1:9/understood/sparql")!,
        timeout: 0.5,
        localGraphURL: url
    )
}

@Test func turtleEmissionCarriesEveryRequiredProperty() {
    let turtle = PatternEvidenceStore.turtle(for: StepEvidenceRating(
        buildId: "Recipes App!",
        step: 3,
        rating: 9,
        evidenceNote: "Read the \"gap\" slide.\nAll gaps named."
    ))
    #expect(turtle.contains("<https://understood.app/rating/recipes-app-step3>"))
    #expect(turtle.contains("understood:forStep <http://nousresearch.com/adam-pattern#Step3>"))
    #expect(turtle.contains("understood:forBuild \"Recipes App!\""))
    #expect(turtle.contains("understood:rating 9"))
    #expect(turtle.contains(#"Read the \"gap\" slide.\nAll gaps named."#))
    #expect(turtle.contains("^^xsd:dateTime"))
}

@Test func recordRejectsOutOfRangeAndEmptyInput() async throws {
    let store = makeStore(try temporaryOntologyRoot())
    await #expect(throws: PatternEvidenceError.invalidRating(11)) {
        try await store.record(StepEvidenceRating(buildId: "b", step: 1, rating: 11, evidenceNote: "n"))
    }
    await #expect(throws: PatternEvidenceError.invalidStep(9)) {
        try await store.record(StepEvidenceRating(buildId: "b", step: 9, rating: 7, evidenceNote: "n"))
    }
    await #expect(throws: PatternEvidenceError.emptyEvidenceNote) {
        try await store.record(StepEvidenceRating(buildId: "b", step: 1, rating: 7, evidenceNote: "  "))
    }
}

@Test func blockedValidationWritesNothing() async throws {
    let root = try temporaryOntologyRoot()
    let store = makeStore(root, parser: RejectingParser())
    await #expect(throws: PatternEvidenceError.blocked("rating must be an integer between 1 and 10")) {
        try await store.record(StepEvidenceRating(buildId: "b", step: 1, rating: 7, evidenceNote: "note"))
    }
    #expect(!FileManager.default.fileExists(atPath: localGraphURL(root).path))
}

@Test func ratingsRoundTripAndRatedCellsNeverReopen() async throws {
    let root = try temporaryOntologyRoot()
    let store = makeStore(root)
    try await store.record(StepEvidenceRating(buildId: "recipes", step: 1, rating: 8, evidenceNote: "context slide"))
    try await store.record(StepEvidenceRating(buildId: "recipes", step: 2, rating: 7, evidenceNote: "circle map"))

    let existing = try store.existingRatings(buildId: "recipes")
    #expect(existing == [1: 8, 2: 7])

    await #expect(throws: PatternEvidenceError.stepAlreadyRated(step: 1, buildId: "recipes")) {
        try await store.record(StepEvidenceRating(buildId: "recipes", step: 1, rating: 9, evidenceNote: "again"))
    }
}

@Test func gateFailsClosedWhenNothingIsReadable() async throws {
    let root = try temporaryOntologyRoot()
    let checker = unreachableChecker(localGraphURL: localGraphURL(root))
    let state = await checker.checkGate(buildId: "recipes")
    #expect(!state.executionUnlocked)
    #expect(state.source == .unavailable)
    #expect(state.ratings.isEmpty)
}

@Test func gateOpensFromLocalFileOnlyWithFourRatingsAtThreshold() async throws {
    let root = try temporaryOntologyRoot()
    let store = makeStore(root)
    try await store.record(StepEvidenceRating(buildId: "recipes", step: 1, rating: 8, evidenceNote: "context"))
    try await store.record(StepEvidenceRating(buildId: "recipes", step: 2, rating: 7, evidenceNote: "circle"))
    try await store.record(StepEvidenceRating(buildId: "recipes", step: 3, rating: 9, evidenceNote: "gap"))

    let checker = unreachableChecker(localGraphURL: localGraphURL(root))
    let threeOfFour = await checker.checkGate(buildId: "recipes")
    #expect(!threeOfFour.executionUnlocked)
    #expect(threeOfFour.source == .localFile)
    #expect(threeOfFour.ratings == [1: 8, 2: 7, 3: 9])

    try await store.record(StepEvidenceRating(buildId: "recipes", step: 4, rating: 8, evidenceNote: "success sentences"))
    let allFour = await checker.checkGate(buildId: "recipes")
    #expect(allFour.executionUnlocked)
    #expect(allFour.source == .localFile)
}

@Test func belowThresholdRatingKeepsTheGateClosed() async throws {
    let root = try temporaryOntologyRoot()
    let store = makeStore(root)
    for (step, rating) in [1: 8, 2: 6, 3: 9, 4: 8] {
        try await store.record(StepEvidenceRating(buildId: "recipes", step: step, rating: rating, evidenceNote: "note"))
    }
    let checker = unreachableChecker(localGraphURL: localGraphURL(root))
    let state = await checker.checkGate(buildId: "recipes")
    #expect(!state.executionUnlocked)
    #expect(state.ratings[2] == 6)
}

@Test func ratingsParserSeparatesBuilds() async throws {
    let root = try temporaryOntologyRoot()
    let store = makeStore(root)
    try await store.record(StepEvidenceRating(buildId: "recipes", step: 1, rating: 8, evidenceNote: "a"))
    try await store.record(StepEvidenceRating(buildId: "news-calm", step: 1, rating: 3, evidenceNote: "b"))

    let text = try String(contentsOf: localGraphURL(root), encoding: .utf8)
    #expect(PatternGateChecker.ratings(inTurtle: text, buildId: "recipes") == [1: 8])
    #expect(PatternGateChecker.ratings(inTurtle: text, buildId: "news-calm") == [1: 3])
    #expect(PatternGateChecker.ratings(inTurtle: text, buildId: "other").isEmpty)
}
