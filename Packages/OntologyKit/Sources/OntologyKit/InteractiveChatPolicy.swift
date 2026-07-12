import Foundation

/// Interactive chat has a different contract from background delegation:
/// produce something useful inside the visible response ceiling, and only
/// enter the agentic tool loop when the prompt or route actually calls for it.
public enum InteractiveChatExecutionMode: Sendable, Equatable {
    case singleShot
    case agentic
}

public enum InteractiveChatPolicy {
    /// Adam's measured click-to-visible acceptance ceiling.
    public static let visibleResponseCeilingSeconds: TimeInterval = 15

    /// Fires before the public ceiling so the main actor can publish the
    /// fallback without depending on the provider task to cooperate.
    public static let watchdogBudgetSeconds: TimeInterval = 12

    /// Interactive agentic turns are bounded separately from background work.
    /// The elapsed-time watchdog remains the hard guarantee.
    public static let agenticMaxToolIterations = 2

    /// Product-operation questions whose answer is deterministic should never
    /// spend provider tokens or depend on backend authorization. New beliefs
    /// enter through candidate review; no chat model may write accepted
    /// authority directly.
    public static func productHelpAnswer(for prompt: String) -> String? {
        let normalized = normalizedPrompt(prompt)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .?!"))
        guard normalized == "how do i add a new belief" else { return nil }

        return """
        # ☀️ Add it through Candidates, not directly to accepted authority 💥 (Executive Conclusion)

        In Chat, type: `Use the memory tool to propose this belief: [your exact words].`

        # Nothing is accepted until you review it (Consequence)

        New belief
        └── Harness stages a candidate
            ├── Yes → accepted as usually true
            ├── Sometimes → accepted as sometimes true
            └── No → not adopted

        # Open Analysis → Candidates (Recommendation)

        Review the new card and choose Yes, Sometimes, or No.

        # This preserves the authority boundary (Supporting Evidence on Request)

        The memory tool writes only to the review queue. Yes or Sometimes validates the candidate and appends it to the accepted graph.

        Rule: none
        Adam Pattern Step: 1
        """
    }

    /// True only when the user asks Harness to answer from reviewed graph
    /// authority. Requests that mix in supporting memory, candidates, or notes
    /// must stay on the broader evidence path so lower-trust material is never
    /// silently presented as accepted truth.
    public static func requestsAcceptedAuthorityOnly(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        guard !requestsLowerTrustEvidence(normalized) else { return false }
        guard !requestsExplicitToolOrAction(prompt) else { return false }

        let promptWords = words(in: normalized)
        let strongAuthoritySubjectWords: Set<String> = [
            "authority", "belief", "beliefs", "connection", "connections",
            "fact", "facts", "graph", "ontology", "truth",
        ]
        let authorityStatusWords: Set<String> = ["accepted", "approved", "confirmed"]
        guard !promptWords.isDisjoint(with: authorityStatusWords) else { return false }
        if !promptWords.isDisjoint(with: strongAuthoritySubjectWords) {
            return true
        }

        // "Information" appears in Adam's failed authority question, but also
        // in ordinary approval workflows. Keep it only when the prompt is not
        // about an operational approval domain.
        guard promptWords.contains("information") else { return false }
        let operationalApprovalWords: Set<String> = [
            "access", "booking", "branch", "command", "commit", "github",
            "issue", "merge", "permission", "pr", "reservation", "tool", "tools",
        ]
        return promptWords.isDisjoint(with: operationalApprovalWords)
    }

    public static func mode(
        prompt: String,
        routePlan: HarnessExecutionRoutePlan
    ) -> InteractiveChatExecutionMode {
        // Accepted-only lookup is itself the complete execution plan. The
        // route planner may describe that lookup as a graph action, but it
        // must not turn a local reviewed-shelf answer back into an agent loop.
        // Explicit tool wording is already excluded by the classifier.
        if requestsAcceptedAuthorityOnly(prompt) {
            return .singleShot
        }

        if requestsExplicitToolOrAction(prompt) {
            return .agentic
        }

        if routePlan.steps.contains(where: { $0.action != .searchMemory }) {
            return .agentic
        }

        return .singleShot
    }

    public static func tools(
        prompt: String,
        routePlan: HarnessExecutionRoutePlan
    ) -> [ToolSpec] {
        switch mode(prompt: prompt, routePlan: routePlan) {
        case .singleShot:
            return []
        case .agentic:
            return HarnessToolCatalog.v1
        }
    }

    public static func maxToolIterations(
        prompt: String,
        routePlan: HarnessExecutionRoutePlan
    ) -> Int {
        switch mode(prompt: prompt, routePlan: routePlan) {
        case .singleShot:
            return 0
        case .agentic:
            return agenticMaxToolIterations
        }
    }

    /// Builds the watchdog result from already-retrieved evidence. The caller
    /// supplies trust-separated arrays; this method preserves those boundaries,
    /// places accepted authority first, and removes duplicates from every lower
    /// trust section so tool output can never be displayed as accepted truth.
    public static func deadlineFallback(
        backendName: String,
        acceptedEvidence: [String],
        supportingEvidence: [String],
        toolEvidence: [String]
    ) -> String {
        var seen: Set<String> = []
        let accepted = distinctEvidence(acceptedEvidence, seen: &seen)
        let supporting = distinctEvidence(supportingEvidence, seen: &seen)
        let tools = distinctEvidence(toolEvidence, seen: &seen)
        let displayBackend = normalizedEvidence(backendName).isEmpty
            ? "The selected backend"
            : normalizedEvidence(backendName)

        return """
        # ☀️ Harness stopped waiting for \(displayBackend) and kept the evidence visible 💥 (Executive Conclusion)

        - The provider did not finish inside the \(Int(visibleResponseCeilingSeconds))-second visible response ceiling.
        - Harness preserved the evidence already selected for the visible response instead of leaving the answer area empty.

        # The app stayed responsive without collapsing the trust boundary (Consequence)

        - Accepted graph authority remains separate from supporting memory.
        - Tool evidence remains explicitly unreviewed.

        # Use the retrieved evidence now while Harness records the provider failure (Recommendation)

        Treat accepted graph authority as confirmed. Use supporting memory and tool evidence only as leads until Adam reviews them.

        # The retrieved evidence remains in its original trust layers (Supporting Evidence on Request)

        Harness stopped waiting for \(displayBackend) after \(Int(watchdogBudgetSeconds)) seconds to protect the \(Int(visibleResponseCeilingSeconds))-second visible response ceiling.

        Accepted graph authority:
        \(bullets(accepted))

        Supporting memory (not accepted authority):
        \(bullets(supporting))

        Tool evidence (unreviewed):
        \(bullets(tools))

        Rule: none
        Adam Pattern Step: 1
        """
    }

    /// Accepted-only questions do not need a provider synthesis. Returning the
    /// reviewed graph evidence directly is faster and prevents conversation
    /// history from reintroducing supporting memory or candidate material.
    public static func acceptedAuthorityAnswer(acceptedEvidence: [String]) -> String {
        var seen: Set<String> = []
        let accepted = distinctEvidence(acceptedEvidence, seen: &seen, limit: 5)
        guard !accepted.isEmpty else {
            return """
            # ☀️ Harness found no accepted authority matching this question 💥 (Executive Conclusion)

            - The reviewed graph did not contain a direct match.
            - Harness did not substitute lower-trust material for an accepted answer.

            # The question remains open instead of being answered with unreviewed material (Consequence)

            - Supporting memory, candidates, and tool evidence were excluded.

            # Refine the question or review a candidate before treating anything new as true (Recommendation)

            Ask the question with a narrower subject, or add the missing belief through candidate review.

            # The authority boundary was preserved (Supporting Evidence on Request)

            No supporting memory, candidates, or tool evidence were used.

            Rule: none
            Adam Pattern Step: 1
            """
        }

        let takeaways = accepted.prefix(2).map(evidenceTakeaway)

        return """
        # ☀️ Your accepted graph already gives you a direction 💥 (Executive Conclusion)

        \(bullets(Array(takeaways)))

        # You can decide from reviewed beliefs without mixing in lower-trust material (Consequence)

        - Only accepted graph authority shaped this answer.
        - Supporting memory, candidates, and tool evidence were excluded.

        # Use the strongest matching belief as the next decision filter (Recommendation)

        Start with the first accepted belief below, then use the remaining accepted beliefs to test whether the choice stays aligned.

        # The accepted graph evidence is preserved here (Supporting Evidence on Request)

        \(bullets(accepted))

        No supporting memory, candidates, or tool evidence were used.

        Rule: none
        Adam Pattern Step: 1
        """
    }

    /// The prompt contains Adam's skill verbatim, but a provider can still
    /// ignore it. This is the runtime gate: compliant answers pass through
    /// byte-for-byte; noncompliant answers are placed into the required four
    /// chapters without discarding any of the provider's original content.
    public static func enforceArticulateLeadershipFormat(_ response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return """
            # ☀️ Harness did not receive a usable answer 💥 (Executive Conclusion)

            - No substantive response text was returned.

            # There is nothing reliable to act on yet (Consequence)

            - Harness will not present an empty provider response as success.

            # Run the request again after checking provider authorization (Recommendation)

            Keep the original request intact and retry only after the backend is ready.

            # No provider content was available (Supporting Evidence on Request)

            Rule: none
            Adam Pattern Step: 1
            """
        }
        guard !followsArticulateLeadershipFormat(trimmed) else { return trimmed }
        if trimmed.hasPrefix("Backend failed:") || trimmed.hasPrefix("Harness could not complete this request:") {
            return failureAnswer(trimmed)
        }

        let supportingEvidence = demotingTopLevelHeadings(in: trimmed)
        return """
        # ☀️ Harness returned an answer and preserved its complete wording 💥 (Executive Conclusion)

        - The provider returned substantive text.
        - The original answer is preserved in Supporting Evidence without being promoted into accepted authority.

        # The response is readable without changing its trust level (Consequence)

        - Harness did not invent a conclusion from unreviewed provider wording.
        - The complete original response remains available below.

        # Read the original response before acting on it (Recommendation)

        Use the provider's full wording below as the answer. Treat any supporting memory or tool output according to the trust labels it carries.

        # The complete original answer is preserved below (Supporting Evidence on Request)

        \(supportingEvidence)
        """
    }

    public static func failureAnswer(_ detail: String) -> String {
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleDetail = demotingTopLevelHeadings(in: trimmedDetail)
        return """
        # ☀️ Harness could not complete this response 💥 (Executive Conclusion)

        - The request ended without a usable provider answer.
        - The exact failure is visible below instead of disappearing.

        # The failure is explicit and the request remains recoverable (Consequence)

        - Harness did not present an empty area as success.
        - Authorization failures remain identifiable by the answer interface.

        # Fix the named provider problem, then send the same request again (Recommendation)

        Use the exact failure below to repair authorization or availability; keep the original request unchanged when retrying.

        # The exact terminal failure is preserved here (Supporting Evidence on Request)

        \(visibleDetail.isEmpty ? "No failure detail was returned." : visibleDetail)

        Harness status: backend failure
        """
    }

    public static func cancelledAnswer() -> String {
        """
        # ☀️ The request was cancelled and Harness stopped working on it 💥 (Executive Conclusion)

        - Cancellation completed.
        - Harness will not keep showing a fake working state.

        # No answer was produced from the cancelled run (Consequence)

        - Pending provider and tool work was stopped.

        # Close this window or send the request again when you want it resumed (Recommendation)

        The original request remains visible above so it can be reused without reconstructing it.

        # Cancellation is the complete terminal record for this run (Supporting Evidence on Request)

        Cancelled in Harness before completion.
        """
    }

    public static func followsArticulateLeadershipFormat(_ response: String) -> Bool {
        let chapterLabels = [
            "(Executive Conclusion)",
            "(Consequence)",
            "(Recommendation)",
            "(Supporting Evidence on Request)",
        ]
        let renderedChapterOrder: [String] = response.components(separatedBy: .newlines).compactMap { line in
            let heading = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard heading.hasPrefix("# ") else { return nil }
            return chapterLabels.first { heading.contains($0) }
        }
        return renderedChapterOrder == chapterLabels
    }

    /// Provider text can contain its own level-one headings. Once that text is
    /// nested inside Supporting Evidence, demote those headings so they cannot
    /// masquerade as additional response chapters.
    private static func demotingTopLevelHeadings(in response: String) -> String {
        response.components(separatedBy: .newlines).map { line in
            let indentation = line.prefix { $0 == " " || $0 == "\t" }
            let content = line.dropFirst(indentation.count)
            guard content.hasPrefix("# ") else { return line }
            return "\(indentation)## \(content.dropFirst(2))"
        }.joined(separator: "\n")
    }

    private static func words(in prompt: String) -> Set<String> {
        Set(prompt.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private static func requestsExplicitToolOrAction(_ prompt: String) -> Bool {
        requestsCatalogTool(prompt) || requestsNarrowAction(prompt)
    }

    /// Derive names from the catalog so adding a tool cannot silently make the
    /// classifier stale. Underscored names are explicit identifiers; natural
    /// forms ("session search") require tool-use language.
    private static func requestsCatalogTool(_ prompt: String) -> Bool {
        let normalized = normalizedPrompt(prompt)
        let naturalized = normalizedPrompt(
            prompt.replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
        )

        for tool in HarnessToolCatalog.v1 {
            let identifier = tool.name.lowercased()
            let naturalName = identifier.replacingOccurrences(of: "_", with: " ")

            if identifier.contains("_"), normalized.contains(identifier) {
                return true
            }
            if normalized.contains("`\(identifier)`") || naturalized.contains("`\(naturalName)`") {
                return true
            }

            let requestPhrases = [
                "use \(naturalName)", "use the \(naturalName)",
                "using \(naturalName)", "using the \(naturalName)",
                "call \(naturalName)", "call the \(naturalName)",
                "invoke \(naturalName)", "invoke the \(naturalName)",
                "via \(naturalName)", "via the \(naturalName)",
            ]
            if requestPhrases.contains(where: naturalized.contains) {
                return true
            }
        }
        return false
    }

    /// "Run" and "write" are ordinary conversational words. They only imply
    /// tool execution when phrased as a request and paired with an executable
    /// or durable-output target.
    private static func requestsNarrowAction(_ prompt: String) -> Bool {
        let normalized = normalizedPrompt(prompt)
        let promptWords = words(in: normalized)

        let runTargets: Set<String> = [
            "app", "application", "binary", "build", "command", "commands",
            "executable", "program", "script", "scripts", "suite", "test",
            "tests", "workflow", "xcodebuild",
        ]
        if actionIsRequested("run", in: normalized),
           !promptWords.isDisjoint(with: runTargets) {
            return true
        }

        let writeTargets: Set<String> = [
            "code", "disk", "file", "files", "folder", "path", "source",
        ]
        return actionIsRequested("write", in: normalized)
            && !promptWords.isDisjoint(with: writeTargets)
    }

    private static func actionIsRequested(_ action: String, in normalizedPrompt: String) -> Bool {
        let prefixes = [
            "\(action) ", "please \(action) ", "can you \(action) ",
            "can you please \(action) ", "could you \(action) ",
            "would you \(action) ", "will you \(action) ",
            "i want you to \(action) ", "i need you to \(action) ",
            "go ahead and \(action) ",
        ]
        return prefixes.contains(where: normalizedPrompt.hasPrefix)
    }

    private static func normalizedPrompt(_ prompt: String) -> String {
        prompt.lowercased().split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    private static func requestsLowerTrustEvidence(_ normalizedPrompt: String) -> Bool {
        let lowerTrustTerms = [
            "supporting memory", "candidates", "candidate", "my notes", "notes", "note",
        ]
        return lowerTrustTerms.contains { requestedTerm($0, appearsIn: normalizedPrompt) }
    }

    private static func requestedTerm(_ term: String, appearsIn prompt: String) -> Bool {
        var searchRange = prompt.startIndex..<prompt.endIndex
        while let match = prompt.range(of: term, range: searchRange) {
            if !termIsExcluded(at: match.lowerBound, in: prompt) {
                return true
            }
            searchRange = match.upperBound..<prompt.endIndex
        }
        return false
    }

    /// Negation can govern a coordinated list ("without candidates or notes"),
    /// so inspect the current clause rather than only the word immediately
    /// before the evidence term. A later inclusion marker wins, as in
    /// "without candidates, include notes."
    private static func termIsExcluded(at termStart: String.Index, in prompt: String) -> Bool {
        let prefix = prompt[..<termStart]
        let separators: Set<Character> = [".", ",", ";", ":", "\n"]
        let clauseStart = prefix.lastIndex(where: { separators.contains($0) })
            .map { prompt.index(after: $0) } ?? prompt.startIndex
        let clause = String(prompt[clauseStart..<termStart])
        let exclusionMarkers = [
            "without ", "exclude ", "excluding ", "do not include ",
            "don't include ", "no ", "not ",
        ]
        let inclusionMarkers = [
            "include ", "including ", "compare ", "with ", "alongside ",
            "plus ", "also ",
        ]
        guard let exclusionEnd = lastMarkerEnd(exclusionMarkers, in: clause) else {
            return false
        }
        guard let inclusionEnd = lastMarkerEnd(inclusionMarkers, in: clause) else {
            return true
        }
        return exclusionEnd >= inclusionEnd
    }

    private static func lastMarkerEnd(_ markers: [String], in text: String) -> String.Index? {
        markers.compactMap { marker in
            text.range(of: marker, options: .backwards)?.upperBound
        }.max()
    }

    private static func distinctEvidence(
        _ values: [String],
        seen: inout Set<String>,
        limit: Int = 3
    ) -> [String] {
        guard limit > 0 else { return [] }
        var result: [String] = []
        for value in values {
            let normalized = normalizedEvidence(value)
            guard !normalized.isEmpty else { continue }
            let key = normalized.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard seen.insert(key).inserted else { continue }
            if result.count < limit {
                result.append(bounded(normalized))
            }
        }
        return result
    }

    private static func normalizedEvidence(_ value: String) -> String {
        value
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func evidenceTakeaway(_ evidence: String) -> String {
        let normalized = normalizedEvidence(evidence)
        let withoutSource = normalized.components(separatedBy: " — ").first ?? normalized
        return bounded(withoutSource, maxCharacters: 170)
    }

    private static func bounded(_ value: String, maxCharacters: Int = 280) -> String {
        guard value.count > maxCharacters else { return value }
        return String(value.prefix(maxCharacters - 1)) + "…"
    }

    private static func bullets(_ evidence: [String]) -> String {
        guard !evidence.isEmpty else { return "- None retrieved before the ceiling." }
        return evidence.map { "- \($0)" }.joined(separator: "\n")
    }
}
