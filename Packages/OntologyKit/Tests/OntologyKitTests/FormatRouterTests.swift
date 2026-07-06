import Testing
@testable import OntologyKit

@Test func comparisonQueryRoutesToMatrix() {
    let route = FormatRouter.route(query: "Compare Firecrawl versus NotebookLM for research")
    #expect(route.primary == .matrix)
    #expect(route.intent == .crossReference)
}

@Test func flowQueryRoutesToTree() {
    let route = FormatRouter.route(query: "How does the run pipeline connect to the ledger?")
    #expect(route.primary == .tree)
}

@Test func whyQueryRoutesToEditorial() {
    let route = FormatRouter.route(query: "Why is the review queue worth it strategically?")
    #expect(route.primary == .editorial)
}

@Test func trendQueryRoutesToGraphic() {
    let route = FormatRouter.route(query: "Trend of Firecrawl spend over time")
    #expect(route.primary == .graphic)
}

@Test func lookupQueryRoutesToTable() {
    let route = FormatRouter.route(query: "List the delegations from this week")
    #expect(route.primary == .table)
}

@Test func waterfallOfProseFailsVolumeDiscipline() {
    let waterfall = String(repeating: "This is a long explanatory sentence that keeps going without structure. ", count: 20)
    let result = FormatRouter.volumeDiscipline(answer: waterfall)
    #expect(!result.passed)
}

@Test func shortAnswerPassesVolumeDiscipline() {
    let result = FormatRouter.volumeDiscipline(answer: "Done. Pushed as f78396f.")
    #expect(result.passed)
}

@Test func longStructuredAnswerPassesVolumeDiscipline() {
    var structured = "| ID | Title | Fit |\n| --- | --- | --- |\n"
    for i in 0..<30 { structured += "| D-\(i) | Delegation number \(i) with a reasonably descriptive title | 0.8 |\n" }
    let result = FormatRouter.volumeDiscipline(answer: structured)
    #expect(result.passed)
}

@Test func tableRouteWithProseAnswerFailsFormatFit() {
    let route = FormatRouter.route(query: "List the delegations from this week")
    let fit = FormatRouter.formatFit(answer: "There are several delegations and they are all interesting in various ways.", route: route)
    #expect(!fit.passed)
}

@Test func tableRouteWithTableAnswerPassesFormatFit() {
    let route = FormatRouter.route(query: "List the delegations from this week")
    let fit = FormatRouter.formatFit(answer: "| ID | Title |\n| --- | --- |\n| 2 | Fitbit |", route: route)
    #expect(fit.passed)
}
