import Foundation

/// Claude's verdict on one prompt.
enum IntentVerdict: Equatable {
    /// Not a reusable task (a bare "thanks", a one-off question about specific code, ...).
    case ignore
    /// Same goal as a tracked intent.
    case match(id: String, confidence: Double)
    /// A reusable task Gooby hasn't seen yet.
    case new(slug: String, summary: String)
}

struct IntentClassification: Equatable {
    var verdict: IntentVerdict
    /// The task in full, in the user's voice. For "yes go ahead" after Claude offered
    /// to commit and push, this is "commit and push". Saved instead of the raw reply.
    var request: String?
}

/// Asks Claude whether a prompt repeats a tracked intent.
struct IntentClassifier {
    /// Matches below this confidence start a new intent instead.
    static let minimumMatchConfidence = 0.75
    /// Example prompts sent per intent (keeps each call small).
    static let examplesPerIntent = 3
    static let maxPromptLength = 1000

    let claude: ClaudeCompleting

    /// `context` is Claude's message just before the prompt, if known.
    func classify(prompt: String, context: String? = nil, against intents: [TrackedIntent]) async throws -> IntentClassification {
        let reply = try await claude.complete(Self.instructions(prompt: prompt, context: context, intents: intents))
        return Self.parse(reply, knownIDs: Set(intents.map(\.id)))
    }

    static func instructions(prompt: String, context: String? = nil, intents: [TrackedIntent]) -> String {
        struct Known: Encodable {
            let id: String
            let summary: String
            let examples: [String]
        }
        let known = intents.map {
            Known(id: $0.id, summary: $0.summary, examples: $0.sightings.suffix(examplesPerIntent).map(\.prompt))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let knownJSON = (try? encoder.encode(known)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let clipped = prompt.count > maxPromptLength ? String(prompt.prefix(maxPromptLength)) + "…" : prompt
        let contextBlock = context.map {
            """

            The assistant's message right before the request (context only; classify the developer's request):
            <<<
            \($0)
            >>>

            """
        } ?? "\n"

        return """
        You help a developer notice tasks they keep asking an AI coding assistant to do, \
        so those tasks can become reusable commands. Decide what this ONE new request is.

        Known intents (JSON): \(knownJSON)
        \(contextBlock)
        New request from the developer:
        <<<
        \(clipped)
        >>>

        Rules:
        - First work out what the developer is actually asking for. If the request is a short reply \
        ("yes", "go ahead", "do it", "sure, push it") approving something the assistant offered or asked \
        about, the request IS that offered action (e.g. assistant: "Want me to commit and push?" + \
        developer: "yes" means "commit and push").
        - A reusable task is something the assistant DOES: a repeatable series of steps that changes, \
        runs, or verifies something, which the developer would want to start again as one command \
        (e.g. commit and push; diagnose and fix a failing pipeline; post a review comment on an MR; \
        restart a deployment and confirm it is healthy; check an MR against its acceptance criteria).
        - "ignore" if that is not a reusable task: thanks, feedback on the previous answer, a reply \
        to a question that offered no action, or a question/change tied to one specific piece of code \
        that would not recur. Also "ignore" questions that only ask for an answer, not for steps: \
        explanations ("what does this tool do", "why did that fail", "what should the UI show"), \
        interpreting a message or a screenshot, opinions, and simple lookups ("give me the link to the \
        MR", "what is the URL of the epic"). Answering them is not a procedure worth automating, even \
        if the developer asks such questions often.
        - "match" if it asks for the same goal as a known intent, even with different wording \
        (e.g. "commit and push to my repo", "commit and push", "commit all changes and push" are the same). \
        Give confidence 0.0-1.0 that it is the same goal.
        - "new" otherwise: a reusable task. slug: 2-5 lowercase words joined by hyphens \
        (e.g. "commit-and-push"). summary: one short imperative sentence describing the general task, \
        without details that only fit this one request.
        - For "match" and "new", "request" is the task in full as the developer would type it \
        (e.g. "commit all changes and push"), never just "yes".

        Reply with ONLY one JSON object, no other text:
        {"kind":"ignore"}
        {"kind":"match","id":"<known id>","confidence":0.9,"request":"..."}
        {"kind":"new","slug":"...","summary":"...","request":"..."}
        """
    }

    /// Anything unparseable is treated as "ignore" so a bad reply never invents an intent.
    static func parse(_ reply: String, knownIDs: Set<String>) -> IntentClassification {
        struct Raw: Decodable {
            let kind: String
            let id: String?
            let confidence: Double?
            let slug: String?
            let summary: String?
            let request: String?
        }
        let ignore = IntentClassification(verdict: .ignore, request: nil)
        guard let data = JSONExtraction.object(in: reply),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return ignore }
        let request = raw.request?.trimmingCharacters(in: .whitespacesAndNewlines)
        let restated = (request?.isEmpty ?? true) ? nil : request
        switch raw.kind {
        case "match":
            guard let id = raw.id, knownIDs.contains(id) else { return ignore }
            let confidence = raw.confidence ?? 0
            guard confidence >= minimumMatchConfidence else {
                // Low-confidence match: not the same thing. Without a slug we can't start one.
                if let slug = raw.slug, let summary = raw.summary {
                    return IntentClassification(verdict: .new(slug: slug, summary: summary), request: restated)
                }
                return ignore
            }
            return IntentClassification(verdict: .match(id: id, confidence: confidence), request: restated)
        case "new":
            guard let slug = raw.slug, let summary = raw.summary,
                  !summary.trimmingCharacters(in: .whitespaces).isEmpty else { return ignore }
            return IntentClassification(verdict: .new(slug: slug, summary: summary), request: restated)
        default:
            return ignore
        }
    }
}
