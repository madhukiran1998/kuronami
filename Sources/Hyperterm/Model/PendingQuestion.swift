import Foundation

/// What an agent asked with AskUserQuestion, from the tool's input (`questions[]`), so the sidebar
/// card can show the real options instead of Allow / Deny.
struct PendingQuestion: Equatable {
    struct Option: Equatable {
        var label: String
        var description: String?
    }

    struct Item: Equatable {
        var question: String
        var header: String?
        var options: [Option]
        var multiSelect: Bool
    }

    /// Empty when the payload was missing or malformed: the card then only offers the terminal.
    var items: [Item]

    /// How the card should present this question.
    enum Mode: Equatable {
        /// One single-select question: its options are buttons that press keys.
        case options
        /// Several questions, or a multi-select one: the terminal drives these reliably, the card
        /// shows the text and a button to open it.
        case terminalOnly
        /// Nothing usable in the payload.
        case unavailable
    }

    var mode: Mode {
        guard let only = items.first else { return .unavailable }
        return items.count == 1 && !only.multiSelect && !only.options.isEmpty ? .options : .terminalOnly
    }

    /// Reads `tool_input` of an AskUserQuestion call. Items without question text are dropped;
    /// options without a label are dropped.
    static func parse(toolInput input: [String: Any]) -> PendingQuestion {
        let raw = input["questions"] as? [[String: Any]] ?? []
        let items: [Item] = raw.compactMap { entry in
            guard let question = (entry["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty else { return nil }
            let options: [Option] = (entry["options"] as? [[String: Any]] ?? []).compactMap { option in
                guard let label = (option["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
                let description = (option["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return Option(label: label, description: description?.isEmpty == false ? description : nil)
            }
            return Item(question: question, header: entry["header"] as? String,
                        options: options, multiSelect: entry["multiSelect"] as? Bool ?? false)
        }
        return PendingQuestion(items: items)
    }

    /// The keys that pick option `index` (0-based) of a single-select question in the CLI's list,
    /// where the cursor starts on the first option: arrow down that many times, then enter.
    static func keys(forOption index: Int) -> [String] {
        Array(repeating: "down", count: max(0, index)) + ["enter"]
    }
}
