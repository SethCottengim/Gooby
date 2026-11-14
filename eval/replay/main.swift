// Step 3: replay real prompts through Gooby's own classifier, in time order.
//
// Built from Gooby's production sources (IntentStore, ClaudeCLI, IntentClassifier,
// TranscriptContext, PromptInbox), so instructions, parsing, filtering and counting
// are exactly what the app does. Build + run: eval/run_replay.sh
//
// Usage: gooby-replay --setup prompt|reply|title|reply+title --run N
//                     [--model opus] [--limit K] [--eval-dir DIR]
//                     [--ids FILE] [--independent]
//   --ids FILE      only these prompt ids (one per line)
//   --independent   classify each prompt on its own against no known intents (tests the
//                   ignore/task decision without carrying state); use runs >= 100 for checks
// Output (resumable; rerun the same command to continue after a crash):
//   DIR/replay/<setup>-run<N>.jsonl         one line per prompt
//   DIR/replay/<setup>-run<N>.intents.json  the intent store as of the last line
import Foundation

struct Record: Decodable {
    let id: Int
    let session: String
    let ts: Double
    let prompt: String
    let prev_reply: String?
    let title: String?
}

struct ResultLine: Codable {
    let id: Int
    let setup: String
    let run: Int
    let skipped: Bool
    var kind: String?
    var intentID: String?
    var newIntent: Bool?
    var confidence: Double?
    var request: String?
    var slug: String?
    var error: String?
    var seconds: Double?
    var contextChars: Int?
    var promptChars: Int?
    var knownIntents: Int?
    var attempts: Int?
}

func arg(_ name: String, _ fallback: String? = nil) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return fallback
}

let setup = arg("--setup") ?? "reply"
guard ["prompt", "reply", "title", "reply+title"].contains(setup) else {
    FileHandle.standardError.write(Data("bad --setup \(setup)\n".utf8)); exit(2)
}
let run = Int(arg("--run", "1")!) ?? 1
let model = arg("--model", "opus")!
let limit = Int(arg("--limit", "0")!) ?? 0
let evalDir = URL(fileURLWithPath: arg("--eval-dir",
    NSHomeDirectory() + "/Library/Application Support/Gooby/eval")!)
let outDir = evalDir.appendingPathComponent("replay")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let outURL = outDir.appendingPathComponent("\(setup)-run\(run).jsonl")
let storeFile = IntentStoreFile(url: outDir.appendingPathComponent("\(setup)-run\(run).intents.json"))

/// The context each setup gives Claude. Same label style as production for the reply.
func context(for r: Record) -> String? {
    let title = r.title.map { "Session title (what this chat is about overall): \($0)" }
    switch setup {
    case "prompt": return nil
    case "reply": return r.prev_reply
    case "title": return title
    default:
        let parts = [title, r.prev_reply].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}

// Load prompts in time order.
let text = try String(contentsOf: evalDir.appendingPathComponent("prompts.jsonl"), encoding: .utf8)
let decoder = JSONDecoder()
var records = text.split(separator: "\n").compactMap { try? decoder.decode(Record.self, from: Data($0.utf8)) }
records.sort { ($0.ts, $0.id) < ($1.ts, $1.id) }
if let idsPath = arg("--ids") {
    let wanted = Set(((try? String(contentsOfFile: idsPath, encoding: .utf8)) ?? "")
        .split(whereSeparator: \.isNewline).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    records = records.filter { wanted.contains($0.id) }
}
let independent = CommandLine.arguments.contains("--independent")
if limit > 0 { records = Array(records.prefix(limit)) }

// Resume: skip ids already written; the store file matches the last written line.
var done = Set<Int>()
if let existing = try? String(contentsOf: outURL, encoding: .utf8) {
    for line in existing.split(separator: "\n") {
        if let r = try? decoder.decode(ResultLine.self, from: Data(line.utf8)) { done.insert(r.id) }
    }
}
var store = done.isEmpty ? IntentStore() : storeFile.load()
if !FileManager.default.fileExists(atPath: outURL.path) {
    FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
}
let out = try FileHandle(forWritingTo: outURL)
try out.seekToEnd()
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

let classifier = IntentClassifier(claude: ClaudeCLI(model: model, timeout: 300))
var classified = 0
let started = Date()

for r in records where !done.contains(r.id) {
    let ctx = context(for: r)
    var line = ResultLine(id: r.id, setup: setup, run: run, skipped: false)
    guard PromptInbox.isWorthClassifying(r.prompt, context: ctx) else {
        line = ResultLine(id: r.id, setup: setup, run: run, skipped: true)
        out.write(try encoder.encode(line) + Data("\n".utf8))
        continue
    }
    line.contextChars = ctx?.count ?? 0
    line.promptChars = r.prompt.count
    line.knownIntents = store.intents.count
    let t0 = Date()
    do {
        // Unlike production, retry failures (e.g. Bedrock throttling from parallel runs) so
        // setups are compared on the same prompts. Attempts are recorded.
        var attempt = 0
        var lastError: Error?
        var maybeResult: IntentClassification?
        while attempt < 3 && maybeResult == nil {
            attempt += 1
            do {
                maybeResult = try await classifier.classify(prompt: r.prompt, context: ctx,
                                                            against: independent ? [] : store.candidatesForMatching)
            } catch {
                lastError = error
                if attempt < 3 { try? await Task.sleep(nanoseconds: 30_000_000_000) }
            }
        }
        line.attempts = attempt
        guard let result = maybeResult else { throw lastError ?? ClaudeCLIError.timedOut }
        line.seconds = Date().timeIntervalSince(t0)
        line.request = result.request
        let example = result.request ?? r.prompt
        let date = Date(timeIntervalSince1970: r.ts / 1000)
        if independent { store = IntentStore() } // no state carried between prompts
        switch result.verdict {
        case .ignore:
            line.kind = "ignore"
        case let .match(id, confidence):
            line.kind = "match"
            line.intentID = id
            line.confidence = confidence
            line.newIntent = false
            store.recordSighting(intentID: id, prompt: example, sessionID: r.session, date: date)
            line.slug = store.intent(id: id)?.slug
        case let .new(slug, summary):
            line.kind = "new"
            line.intentID = store.addIntent(slug: slug, summary: summary, prompt: example, sessionID: r.session, date: date)
            line.newIntent = true
            line.slug = SkillSlug.sanitize(slug)
        }
    } catch {
        // Unlike production (which drops the prompt), stop the run so a network outage, sleep or
        // expired login can't fill the results with errors that resume would treat as done.
        // Nothing is written for this prompt, so rerunning the same command redoes it.
        try? out.close()
        FileHandle.standardError.write(Data(
            "[\(setup) run\(run)] stopped at prompt \(r.id) after \(3) failed attempts: \(error)\n".utf8))
        exit(3)
    }
    storeFile.save(store)
    out.write(try encoder.encode(line) + Data("\n".utf8))
    classified += 1
    if classified % 25 == 0 {
        let elapsed = Date().timeIntervalSince(started)
        print("[\(setup) run\(run)] \(classified) classified, \(store.intents.count) intents, " +
              String(format: "%.1f s/call", elapsed / Double(classified)))
    }
}
try out.close()
print("[\(setup) run\(run)] finished: \(classified) classified this pass, \(store.intents.count) intents")
