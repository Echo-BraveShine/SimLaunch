import Foundation

extension ApplicationService {
    public func importSandboxFile(_ source: URL, into components: [String], app: InstalledApplication, user: String?) async throws {
        let manager = FileManager.default
        guard source.isFileURL, !source.hasDirectoryPath,
              let attributes = try? manager.attributesOfItem(atPath: source.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value, size >= 0 else {
            throw CLIError(L10n.text("Choose a regular local file to import."))
        }

        let name = source.lastPathComponent
        if device.platform == .HarmonyOS { try Self.validateHDCTransferPath(components + [name]) }
        let (connection, user) = try await sandboxConnection(for: app, user: user, components: components + [name])
        let stage = ".simlaunch-import-" + UUID().uuidString
        let setup = sandboxNavigation(components)
            + "stage='./\(stage)'\npayload=\"$stage/payload\"\ntarget=\(Self.quoteSandboxArgument("./" + name))\n"
        let checkConflict = #"""
        if test -e "$target" || test -L "$target"; then echo SIMLAUNCH_IMPORT_EXISTS; exit 0; fi

        """#
        func shell(_ script: String, timeout: TimeInterval = 10) async throws -> String {
            try await run(connection, sandboxShell(setup + script, app: app, user: user, connection: connection), timeout: timeout)
        }
        func require(_ marker: String, in output: String) async throws {
            try await checkHarmonySandboxMount(output, app: app, user: user, connection: connection)
            let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if message == "SIMLAUNCH_IMPORT_EXISTS" {
                throw CLIError(L10n.text("A file or folder with this name already exists."))
            }
            if message != marker {
                let reason = L10n.text("Could not import the file into this sandbox folder.")
                throw CLIError(message.isEmpty ? reason : reason + "\n" + String(message.prefix(300)))
            }
        }

        let cleanup = sandboxShell(setup + #"if test -d "$stage" && test ! -L "$stage"; then rm -f "$payload"; rmdir "$stage"; fi"#,
                                   app: app, user: user, connection: connection)
        let result: Result<Void, Error>
        do {
            let prepared = try await shell(checkConflict + #"umask 077; mkdir "$stage" && echo SIMLAUNCH_IMPORT_READY"#)
            try await require("SIMLAUNCH_IMPORT_READY", in: prepared)
            if device.platform == .Android {
                let script = setup + #"test -d "$stage" && test ! -L "$stage" || exit 1; umask 077; set -C; cat > "$payload" && echo SIMLAUNCH_IMPORT_SENT"#
                let args = sandboxShell(script, app: app, user: user, connection: connection)
                let output = try await ProcessRunner().runFromFile(connection.path, args, environment: connection.environment,
                                                                   timeout: 120, source: source)
                try await require("SIMLAUNCH_IMPORT_SENT", in: output)
            } else {
                let remote = (["./data/storage/el2/base"] + components + [stage, "payload"]).joined(separator: "/")
                try await sendHarmonySandboxFile(source, to: remote, app: app, connection: connection)
            }

            try await verifySandboxUser(user, app: app, connection: connection)
            let verifyPayload = """
            test ! -L "$stage" && test ! -L "$payload" && test -f "$payload" || exit 1
            test "$(stat -c %s "$payload")" = "\(size)" || exit 1

            """
            let publish = device.platform == .Android ? Self.androidImportPublish : Self.harmonyImportPublish
            let output = try await shell(checkConflict + verifyPayload + publish, timeout: 120)
            try await require("SIMLAUNCH_IMPORT_COMPLETE", in: output)
            result = .success(())
        } catch let error as CLIError where error.timedOut {
            result = .failure(CLIError(L10n.text("The file transfer timed out. Try again.")))
        } catch {
            result = .failure(error)
        }

        // Cancellation should still remove the temporary file from the scoped sandbox.
        _ = try? await Task.detached { try await self.run(connection, cleanup, timeout: 5) }.value
        try result.get()
    }

    private func sendHarmonySandboxFile(_ source: URL, to remote: String, app: InstalledApplication, connection: DeviceToolConnection) async throws {
        // HDC reparses host paths. Give it a predictable filename regardless of the original path.
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("SimLaunch-Import-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        let local = directory.appendingPathComponent("payload")
        try Self.validateHDCTransferPath([local.path])
        let copy = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: source, to: local)
        }
        try await withTaskCancellationHandler(operation: { try await copy.value }, onCancel: { copy.cancel() })
        let args = ["-t", connection.target, "file", "send", "-b", app.id, local.path, remote]
        let output = try await run(connection, args, timeout: 120)
        guard output.contains("FileTransfer finish"), !output.contains("[Fail]") else {
            let reason = String(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
            throw CLIError(reason.isEmpty ? L10n.text("The simulator did not finish transferring the file.") : reason)
        }
    }

    // ln -T publishes the completed Android file without following or replacing a destination.
    private static let androidImportPublish = #"""
    if ln -T "$payload" "$target"; then
        echo SIMLAUNCH_IMPORT_COMPLETE
    elif test -e "$target" || test -L "$target"; then
        echo SIMLAUNCH_IMPORT_EXISTS
    fi
    """#

    // The Harmony debug mount rejects hard links and renames. Open a new file with noclobber.
    private static let harmonyImportPublish = #"""
    size=$(stat -c %s "$payload") || exit 1
    set -C
    {
        identity=$(stat -c '%d:%i' "$target") || exit 1
        trap 'if test "$(stat -c "%d:%i" "$target" 2>|/dev/null)" = "$identity"; then rm -f "$target"; fi' EXIT
        trap 'exit 1' HUP INT TERM
        cat "$payload" >&3 && test "$(stat -c %s "$target")" = "$size" || exit 1
        trap - EXIT
        echo SIMLAUNCH_IMPORT_COMPLETE
    } 3>"$target"
    """#
}
