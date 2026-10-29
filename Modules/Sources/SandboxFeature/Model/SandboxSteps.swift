public import ChatDomain
import Foundation

/// Open Terminal's tools, by their OpenAPI operation ids (v0.14, docs/research/open-terminal.md §2.1).
/// The server turns each operation into a tool with that name; items carry no tool id, so the
/// name is how a Response's sandbox steps are recognised (ADR 0120).
public enum TerminalTool: String, CaseIterable, Sendable {
    case runCommand = "run_command"
    case processStatus = "get_process_status"
    case processInput = "send_process_input"
    case killProcess = "kill_process"
    case listProcesses = "list_processes"
    case writeFile = "write_file"
    case replaceFileContent = "replace_file_content"
    case readFile = "read_file"
    case listFiles = "list_files"
    case displayFile = "display_file"
    case grepSearch = "grep_search"
    case matchFiles = "match_files"
    case searchFiles = "search_files"
    case globSearch = "glob_search"
    case readUserTerminal = "read_user_terminal"
    case sendUserTerminalInput = "send_user_terminal_input"

    /// Calls that continue an earlier `run_command` (same process id).
    var continuesRun: Bool {
        self == .processStatus || self == .processInput || self == .killProcess
    }
}

/// One command the model ran in the sandbox, with everything later calls added to it: polled
/// output, input it typed, a kill (OT-02).
public struct SandboxRun: Sendable, Hashable, Identifiable {
    public enum Status: Sendable, Hashable {
        case running
        case done
        case killed
        /// The call itself failed (the server or the terminal returned an error).
        case failed(String)
    }

    /// One piece of output; `isError` for stderr.
    public struct Chunk: Sendable, Hashable {
        public var text: String
        public var isError: Bool
    }

    /// The call id of the `run_command` that started it.
    public let id: String
    public var command: String
    public var cwd: String?
    /// Open Terminal's process id, which later status, input and kill calls name.
    public var processID: String?
    public var status: Status
    public var exitCode: Int?
    public var chunks: [Chunk]
    /// The terminal dropped output (its log was cut).
    public var truncated: Bool
    /// A call for this run is still waiting for its result.
    public var isWaiting: Bool
    /// Input the model typed into the process.
    public var inputs: [String]

    /// Still running: either the process reported so, or a call is in flight.
    public var isRunning: Bool { isWaiting || status == .running }

    /// Non-zero exit, a kill, or a failed call.
    public var failed: Bool {
        switch status {
        case .failed, .killed: true
        case .done: (exitCode ?? 0) != 0
        case .running: false
        }
    }

    /// The output as one text, line endings normalised and terminal escapes removed.
    public var output: String {
        chunks.map(\.text).joined()
    }

    /// The command's first line, for the header ("Ran `ls -la`").
    public var headline: String {
        let first = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
        return first.trimmingCharacters(in: .whitespaces)
    }
}

/// A file operation in the sandbox: one quiet line in the transcript (OT-02).
public struct SandboxFileStep: Sendable, Hashable, Identifiable {
    public enum Action: Sendable, Hashable {
        case create
        case edit
        case read
        case list
        case search(String)
        case listProcesses
        case readTerminal
        case typeInTerminal
    }

    public let id: String
    public var action: Action
    public var path: String?
    public var size: Int?
    public var isRunning: Bool
    public var failed: Bool
    public var error: String?

    /// The file's (or folder's) last path component.
    public var name: String? {
        guard let path, !path.isEmpty else { return nil }
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        return (trimmed as NSString).lastPathComponent
    }

    /// "Created hello.txt" / "Creating hello.txt".
    public var title: String {
        let name = self.name ?? "a file"
        switch action {
        case .create: return isRunning ? "Creating \(name)" : (failed ? "Couldn't create \(name)" : "Created \(name)")
        case .edit: return isRunning ? "Editing \(name)" : (failed ? "Couldn't edit \(name)" : "Edited \(name)")
        case .read: return isRunning ? "Reading \(name)" : (failed ? "Couldn't read \(name)" : "Read \(name)")
        case .list:
            let folder = self.name ?? "the folder"
            return isRunning ? "Looking in \(folder)" : "Looked in \(folder)"
        case .search(let query):
            let target = query.isEmpty ? "files" : "files for “\(query)”"
            return isRunning ? "Searching \(target)" : "Searched \(target)"
        case .listProcesses: return isRunning ? "Checking running commands" : "Checked running commands"
        case .readTerminal: return isRunning ? "Reading the terminal" : "Read the terminal"
        case .typeInTerminal: return isRunning ? "Typing in the terminal" : "Typed in the terminal"
        }
    }

    public var systemImage: String {
        switch action {
        case .create: "doc.badge.plus"
        case .edit: "pencil.line"
        case .read: "doc.text"
        case .list: "folder"
        case .search: "magnifyingglass"
        case .listProcesses: "list.bullet.rectangle"
        case .readTerminal, .typeInTerminal: "terminal"
        }
    }
}

/// A file the model showed the user (`display_file`): a card on the Response (OT-03).
public struct SandboxFile: Sendable, Hashable, Identifiable {
    /// The call id.
    public let id: String
    /// The absolute path in the sandbox.
    public var path: String
    public var name: String
    public var mimeType: String?
    /// The terminal server the file lives on; `nil` falls back to the Chat's.
    public var terminalID: String?
    /// The Chat (sandbox session) it was created in; `nil` falls back to the Chat's id.
    public var sessionID: String?
    /// The model asked to show it inline (images, PDFs) rather than only as a card.
    public var inline: Bool
    public var isRunning: Bool
    /// The terminal reported that the file doesn't exist.
    public var isMissing: Bool

    public var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    public var isImage: Bool {
        mimeType?.lowercased().hasPrefix("image/") ?? ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(fileExtension)
    }

    /// A short type badge ("CSV", "XLSX").
    public var typeBadge: String {
        let ext = fileExtension
        if !ext.isEmpty, ext.count <= 5 { return ext.uppercased() }
        return mimeType?.split(separator: "/").last.map { String($0.prefix(5)).uppercased() } ?? "FILE"
    }
}

/// How one tool call of a Response renders in the sandbox's view of it.
public enum SandboxStep: Sendable, Hashable {
    case run(SandboxRun)
    /// A status, input or kill call folded into the run card of `runID`.
    case folded(runID: String)
    case file(SandboxFileStep)
    case display(SandboxFile)
}

/// Every sandbox step of one Response, keyed by call id. Built from the Response's tool steps
/// (`ToolActivity`, which already knows what's running), so the live stream and a reloaded Chat
/// render the same (OT-02).
public struct SandboxLog: Sendable, Hashable {
    public private(set) var steps: [String: SandboxStep] = [:]

    public init(_ activities: [ToolActivity]) {
        var runsByProcess: [String: String] = [:]
        for activity in activities {
            guard let tool = TerminalTool(rawValue: activity.name) else { continue }
            let arguments = Self.object(activity.arguments) ?? [:]
            let result = activity.result.flatMap(Self.object)
            if tool == .runCommand {
                var run = SandboxRun(
                    id: activity.id,
                    command: arguments["command"] as? String ?? "",
                    cwd: arguments["cwd"] as? String,
                    processID: nil,
                    status: .running,
                    exitCode: nil,
                    chunks: [],
                    truncated: false,
                    isWaiting: activity.isRunning,
                    inputs: []
                )
                Self.apply(result: result, text: activity.result, failed: activity.failed, offset: 0, tail: arguments["tail"] != nil, to: &run)
                if let processID = run.processID { runsByProcess[processID] = run.id }
                steps[activity.id] = .run(run)
            } else if tool.continuesRun {
                let processID = (arguments["process_id"] ?? arguments["id"]).map { "\($0)" }
                guard let processID, let runID = runsByProcess[processID], case .run(var run)? = steps[runID] else {
                    steps[activity.id] = .file(Self.fileStep(activity, tool: tool, arguments: arguments, result: result))
                    continue
                }
                run.isWaiting = activity.isRunning
                switch tool {
                case .processInput:
                    if let input = arguments["input"] as? String { run.inputs.append(input) }
                case .killProcess:
                    if activity.result != nil, !activity.failed { run.status = .killed }
                default:
                    let offset = Self.int(arguments["offset"]) ?? 0
                    Self.apply(result: result, text: activity.result, failed: activity.failed, offset: offset, tail: arguments["tail"] != nil, to: &run)
                }
                steps[runID] = .run(run)
                steps[activity.id] = .folded(runID: runID)
            } else if tool == .displayFile {
                steps[activity.id] = Self.display(activity, arguments: arguments, result: result)
            } else {
                steps[activity.id] = .file(Self.fileStep(activity, tool: tool, arguments: arguments, result: result))
            }
        }
    }

    public subscript(callID: String) -> SandboxStep? {
        steps[callID]
    }

    // MARK: Runs

    private static func apply(result: [String: Any]?, text: String?, failed: Bool, offset: Int, tail: Bool, to run: inout SandboxRun) {
        guard let text else { return }
        guard let result else {
            // Not JSON: the server's or the terminal's error text.
            run.status = .failed(text.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        if let detail = result["detail"] ?? result["error"], result["status"] == nil {
            run.status = .failed("\(detail)")
            return
        }
        if let id = result["id"] as? String { run.processID = id }
        if run.command.isEmpty, let command = result["command"] as? String { run.command = command }
        if let cwd = result["cwd"] as? String { run.cwd = cwd }
        switch result["status"] as? String {
        case "running": run.status = .running
        case "killed": run.status = .killed
        case "done": run.status = .done
        default: if failed { run.status = .failed(text) }
        }
        if let code = int(result["exit_code"]) { run.exitCode = code }
        if (result["truncated"] as? Bool) == true { run.truncated = true }
        let chunks = (result["output"] as? [[String: Any]] ?? []).compactMap { entry -> SandboxRun.Chunk? in
            guard let data = entry["data"] as? String else { return nil }
            return SandboxRun.Chunk(text: TerminalText.clean(data), isError: (entry["type"] as? String) == "stderr")
        }
        if tail {
            run.chunks = chunks
            run.truncated = true
        } else {
            // Status calls read from an offset (non-consuming cursors): replace from there on.
            let start = min(max(offset, 0), run.chunks.count)
            run.chunks = Array(run.chunks.prefix(start)) + chunks
        }
    }

    // MARK: Files

    private static func fileStep(_ activity: ToolActivity, tool: TerminalTool, arguments: [String: Any], result: [String: Any]?) -> SandboxFileStep {
        let action: SandboxFileStep.Action = switch tool {
        case .writeFile: .create
        case .replaceFileContent: .edit
        case .readFile: .read
        case .listFiles: .list
        case .grepSearch, .matchFiles, .searchFiles, .globSearch:
            .search((arguments["query"] ?? arguments["pattern"] ?? arguments["name"]).map { "\($0)" } ?? "")
        case .listProcesses, .processStatus, .processInput, .killProcess: .listProcesses
        case .readUserTerminal: .readTerminal
        case .sendUserTerminalInput: .typeInTerminal
        case .runCommand, .displayFile: .read
        }
        let path = (result?["path"] ?? result?["dir"] ?? arguments["path"] ?? arguments["directory"]).map { "\($0)" }
        let detail = result.flatMap { $0["detail"] ?? $0["error"] }.map { "\($0)" }
        let failed = activity.failed || detail != nil || (activity.result != nil && result == nil && tool != .readFile)
        return SandboxFileStep(
            id: activity.id,
            action: action,
            path: path,
            size: int(result?["size"]),
            isRunning: activity.isRunning,
            failed: failed,
            error: failed ? (detail ?? activity.result) : nil
        )
    }

    private static func display(_ activity: ToolActivity, arguments: [String: Any], result: [String: Any]?) -> SandboxStep {
        let path = (result?["full_path"] ?? result?["path"] ?? arguments["path"]).map { "\($0)" } ?? ""
        let missing = (result?["exists"] as? Bool) == false
        if activity.result != nil, result == nil || missing || path.isEmpty {
            return .file(SandboxFileStep(
                id: activity.id, action: .read, path: path.isEmpty ? nil : path, size: nil,
                isRunning: false, failed: true, error: missing ? "The file doesn't exist." : activity.result
            ))
        }
        let name = (result?["name"] as? String) ?? (path as NSString).lastPathComponent
        return .display(SandboxFile(
            id: activity.id,
            path: path,
            name: name.isEmpty ? "File" : name,
            mimeType: (result?["mime_type"] ?? result?["content_type"]) as? String,
            terminalID: (result?["terminal_id"] ?? result?["terminal_selector"]) as? String,
            sessionID: result?["session_id"] as? String,
            inline: (result?["displayed"] as? Bool) == true || (arguments["inline"] as? Bool) == true,
            isRunning: activity.isRunning,
            isMissing: missing
        ))
    }

    // MARK: JSON

    static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return value
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as Int: number
        case let number as Double: Int(number)
        case let text as String: Int(text)
        default: nil
        }
    }
}

/// Output of a pseudo-terminal, readable as plain text.
enum TerminalText {
    /// Drops ANSI escape sequences and carriage returns (PTY line endings are `\r\n`).
    static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n")
        result = result.replacingOccurrences(of: #"\u001B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\u001B\][^\u0007]*\u0007"#, with: "", options: .regularExpression)
        return result.replacingOccurrences(of: "\r", with: "\n")
    }

    /// The last `limit` lines of `text`, and whether lines were dropped.
    static func tail(_ text: String, lines limit: Int) -> (text: String, dropped: Int) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        guard lines.count > limit else { return (lines.joined(separator: "\n"), 0) }
        return (lines.suffix(limit).joined(separator: "\n"), lines.count - limit)
    }
}
