import Foundation
import Testing
@testable import OntologyKit

@Test func acceptedGraphQueryRanksMatchesBeforeApplyingItsLimit() {
    let query = OntologyAuthorityRetriever.liveQuery(
        queryTokens: ["adam", "just", "says"],
        acceptedGraphIRI: "https://understood.app/graph/accepted",
        limit: 6
    )

    let order = query.range(of: "ORDER BY DESC(?matchScore)")
    let limit = query.range(of: "LIMIT 36")
    #expect(order != nil)
    #expect(limit != nil)
    #expect(order!.lowerBound < limit!.lowerBound)
    #expect(query.contains("IF(CONTAINS(?searchText, \"adam\"), 1, 0)"))
    #expect(query.contains("IF(CONTAINS(?searchText, \"just\"), 1, 0)"))
    #expect(query.contains("IF(CONTAINS(?searchText, \"says\"), 1, 0)"))
}

@Test func acceptedGraphTokensDropGlueWordsButKeepTheMeaningfulPhrase() {
    let tokens = OntologyAuthorityRetriever.tokens(
        "When Adam says just do it, what should you do next?"
    )

    #expect(tokens.contains("adam"))
    #expect(tokens.contains("says"))
    #expect(tokens.contains("just"))
    #expect(tokens.contains("next"))
    #expect(!tokens.contains("the"))
    #expect(!tokens.contains("and"))
    #expect(!tokens.contains("you"))
}

@Test func acceptedGraphRetrievalSearchesTheMessageNotDelegationMetadata() {
    let prompt = """
    DELEGATION CONTEXT
    PreferredApproach: zebrametadata accepted graph authority
    DoneCondition: Name the source and next action

    ---
    When Adam says just do it, what should you do next?
    """

    let tokens = OntologyAuthorityRetriever.retrievalTokens(prompt)

    #expect(tokens.contains("adam"))
    #expect(tokens.contains("says"))
    #expect(tokens.contains("just"))
    #expect(!tokens.contains("zebrametadata"))
    #expect(!tokens.contains("authority"))
    #expect(!tokens.contains("source"))
}
