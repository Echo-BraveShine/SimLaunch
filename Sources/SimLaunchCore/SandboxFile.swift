import Foundation
import Darwin

/// A private local copy. Its staging directory is removed when the last owner releases it.
public final class SandboxFile: Identifiable, Sendable {
    public let url: URL
    private let directory: URL
    public var id: URL { url }

    fileprivate init(url: URL, directory: URL) {
        self.url = url
        self.directory = directory
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    public func export(to destination: URL, replacingExisting: Bool) async throws {
        let operation = Task.detached(priority: .utility) { [self] in
            let manager = FileManager.default
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".SimLaunch-" + UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? manager.removeItem(at: staging) }
            let copy = staging.appendingPathComponent("payload")
            try Task.checkCancellation()
            try manager.copyItem(at: url, to: copy)
            try Task.checkCancellation()
            // Commit on the destination volume only after the copy has succeeded.
            let flags = replacingExisting ? UInt32(0) : UInt32(RENAME_EXCL)
            guard renamex_np(copy.path, destination.path, flags) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path])
            }
        }
        try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() })
    }
}

extension ApplicationService {
    public func downloadSandboxFile(for app: InstalledApplication, user: String?, components: [String], name: String,
                                    forPreview: Bool) async throws -> SandboxFile {
        let filePath = components + [name]
        if device.platform == .HarmonyOS { try Self.validateHDCTransferPath(filePath) }
        let (connection, user) = try await sandboxConnection(for: app, user: user, components: filePath)
        let remoteFile = Self.quoteSandboxArgument("./" + name)
        let checkFile = sandboxNavigation(components) + "file=\(remoteFile)\n"
            + "test ! -L \"$file\" && test -f \"$file\" && test -r \"$file\" || exit 1\n"
        let sizeArguments = sandboxShell(checkFile + "exec stat -c %s \"$file\"", app: app, user: user, connection: connection)
        let reportedSize = try await run(connection, sizeArguments, timeout: 10)
        try await checkHarmonySandboxMount(reportedSize, app: app, user: user, connection: connection)
        guard let expectedSize = Int64(reportedSize.trimmingCharacters(in: .whitespacesAndNewlines)), expectedSize >= 0 else {
            throw CLIError(L10n.text("Could not verify the selected sandbox file. Refresh the folder and try again."))
        }
        if forPreview, expectedSize > 32 * 1024 * 1024 {
            throw CLIError(L10n.text("Files larger than 32 MB can be exported for local viewing."))
        }

        let manager = FileManager.default
        let staging = manager.temporaryDirectory.appendingPathComponent("SimLaunch-Sandbox-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let payload = staging.appendingPathComponent("payload")
        do {
            if device.platform == .Android {
                let args = sandboxShell(checkFile + "exec cat \"$file\"", app: app, user: user, connection: connection)
                try await ProcessRunner().runToFile(connection.path, args, environment: connection.environment, timeout: 120, destination: payload)
            } else {
                let remotePath = "./data/storage/el2/base/" + filePath.joined(separator: "/")
                let args = ["-t", connection.target, "file", "recv", "-b", app.id, remotePath, payload.path]
                let output = try await run(connection, args, timeout: 120)
                guard output.contains("FileTransfer finish") else {
                    let message = String(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
                    throw CLIError(message.isEmpty ? L10n.text("The simulator did not finish transferring the file.") : message)
                }
            }
            try await verifySandboxUser(user, app: app, connection: connection)
            try Task.checkCancellation()
            let attrs = try manager.attributesOfItem(atPath: payload.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.size] as? NSNumber)?.int64Value == expectedSize else {
                throw CLIError(L10n.text("The file changed or the transfer was incomplete. Refresh the folder and try again."))
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payload.path)
            let url = staging.appendingPathComponent(name, isDirectory: false)
            if url != payload { try manager.moveItem(at: payload, to: url) }
            return SandboxFile(url: url, directory: staging)
        } catch {
            try? manager.removeItem(at: staging)
            if let cliError = error as? CLIError, cliError.timedOut {
                throw CLIError(L10n.text("The file transfer timed out. Try again."))
            }
            throw error
        }
    }

    static func validateHDCTransferPath(_ components: [String]) throws {
        let unsupportedCharacters = "\"\\\t\r\n".unicodeScalars
        // HDC reparses transfer arguments, so these names cannot be passed through unchanged.
        if components.contains(where: { $0.unicodeScalars.contains(where: unsupportedCharacters.contains) }) {
            throw CLIError(L10n.text("HDC cannot transfer files with these characters in the path."))
        }
    }
}
