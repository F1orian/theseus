public import ChatDomain
import ComposerFeature
public import Foundation
public import OpenWebUIKit

/// Fetches files the model created, through the Server's terminal proxy, into a temporary
/// folder of this Account (OT-03, ADR 0120). Only the Session token is ever used; the terminal's
/// own key stays on the Server. Nothing is cached across Accounts or launches.
@MainActor
public final class SandboxFiles {
    public enum Failure: Error, Equatable, Sendable {
        /// The terminal or the file is gone, or the Account lost access (403/404).
        case unavailable
        /// The Account authenticates without a Session token (API key).
        case needsSessionToken
        case other(String)

        public var message: String {
            switch self {
            case .unavailable: "File no longer available"
            case .needsSessionToken: "Sandbox files open only when you're signed in with a password or single sign-on."
            case .other(let message): message
            }
        }
    }

    public let client: OpenWebUIClient
    /// The Chat's terminal when a file names none (older results, direct calls).
    public var defaultTerminalID: String?
    private let folder: URL

    /// - Parameter accountKey: Scopes the temporary folder to one Account.
    public init(client: OpenWebUIClient, accountKey: String, defaultTerminalID: String? = nil) {
        self.client = client
        self.defaultTerminalID = defaultTerminalID
        folder = FileManager.default.temporaryDirectory
            .appending(path: "theseus-sandbox", directoryHint: .isDirectory)
            .appending(path: Self.safeComponent(accountKey), directoryHint: .isDirectory)
    }

    /// The bytes of `file`, from the sandbox session of `chatID` (the file's own session wins).
    public func data(for file: SandboxFile, chatID: String?) async throws(Failure) -> Data {
        guard let terminalID = file.terminalID ?? defaultTerminalID, let session = file.sessionID ?? chatID else {
            throw .unavailable
        }
        return try await fetch(.sandboxFile(terminalID: terminalID, chatID: session, path: file.path))
    }

    /// Downloads `file` to a temporary URL named like the file (for Quick Look, sharing, Files).
    public func download(_ file: SandboxFile, chatID: String?) async throws(Failure) -> URL {
        try write(await data(for: file, chatID: chatID), name: file.name)
    }

    /// Downloads a sandbox path the file browser shows (OT-04).
    public func download(path: String, terminalID: String, chatID: String) async throws(Failure) -> URL {
        let data = try await fetch(.sandboxFile(terminalID: terminalID, chatID: chatID, path: path))
        return try write(data, name: (path as NSString).lastPathComponent)
    }

    /// Downloads a folder (or files) as one ZIP (OT-04).
    public func downloadArchive(paths: [String], name: String, terminalID: String, chatID: String) async throws(Failure) -> URL {
        let data = try await fetch(.sandboxArchive(terminalID: terminalID, chatID: chatID, paths: paths))
        return try write(data, name: name.hasSuffix(".zip") ? name : name + ".zip")
    }

    /// Downloads a file the Server stored for the Response (`message.files`, `files` events).
    public func download(_ attachment: Attachment) async throws(Failure) -> URL {
        if let url = attachment.url, url.hasPrefix("data:"), let data = Self.decodeDataURL(url) {
            return try write(data, name: attachment.name)
        }
        guard let fileID = Self.serverFileID(attachment) else { throw .unavailable }
        return try write(await fetch(.fileContent(id: fileID)), name: attachment.name)
    }

    /// Removes this Account's downloads.
    public func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Helpers

    /// A Server file id: the Attachment's own, or the one in an `/api/v1/files/{id}/content` URL.
    nonisolated static func serverFileID(_ attachment: Attachment) -> String? {
        guard let url = attachment.url else { return attachment.id }
        let parts = url.split(separator: "/").map(String.init)
        if let index = parts.firstIndex(of: "files"), parts.indices.contains(index + 1), parts.contains("api") {
            return parts[index + 1]
        }
        return nil
    }

    nonisolated static func decodeDataURL(_ url: String) -> Data? {
        guard let comma = url.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }

    private func fetch(_ endpoint: Endpoint<Data>) async throws(Failure) -> Data {
        guard await client.sessionToken() != nil else { throw .needsSessionToken }
        do {
            return try await client.send(endpoint)
        } catch {
            switch error {
            case .forbidden, .server(status: 404, _): throw .unavailable
            default: throw .other(error.message)
            }
        }
    }

    private func write(_ data: Data, name: String) throws(Failure) -> URL {
        let directory = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let url = directory.appending(path: Self.safeComponent(name.isEmpty ? "File" : name))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            throw .other("Couldn't save the file on this device.")
        }
        return url
    }

    nonisolated private static func safeComponent(_ name: String) -> String {
        let cleaned = name.map { $0 == "/" || $0 == ":" ? "-" : $0 }
        return String(cleaned).trimmingCharacters(in: .whitespaces)
    }
}
