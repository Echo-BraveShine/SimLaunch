import Foundation

public struct SandboxDirectory: Sendable {
    public struct Entry: Identifiable, Sendable {
        public enum Kind: Sendable { case directory, file, link, other }
        public let name: String
        public let kind: Kind
        public var id: Data { Data(name.utf8) }
    }

    public let entries: [Entry]
    public let truncated: Bool

    fileprivate init(output: String) throws {
        var records = output.split(separator: "\0", omittingEmptySubsequences: false)
        guard records.count >= 3, records.removeFirst() == "SIMLAUNCH_SANDBOX_V1",
              records.removeLast().trimmingCharacters(in: .newlines).isEmpty,
              let end = records.popLast(), end == "END" || end == "LIMIT" else {
            let diagnostic = String(output.split(separator: "\0").first?.prefix(300) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError([L10n.text("Could not read the sandbox directory."), diagnostic].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        truncated = end == "LIMIT"
        entries = try records.map { record in
            let kind: Entry.Kind
            switch record.utf8.first {
            case 68: kind = .directory // D
            case 70: kind = .file      // F
            case 76: kind = .link      // L
            case 79: kind = .other     // O
            default: throw CLIError(L10n.text("Could not read the sandbox directory."))
            }
            let name = String(decoding: record.utf8.dropFirst(), as: UTF8.self)
            guard Self.validComponent(name) else { throw CLIError(L10n.text("Could not read the sandbox directory.")) }
            return Entry(name: name, kind: kind)
        }.sorted {
            if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    fileprivate static func validComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.utf8.contains(47) && !name.utf8.contains(0)
    }
}

extension ApplicationService {
    /// Read only the selected application's data, using its own debug identity.
    public func sandboxDirectory(for app: InstalledApplication, user: String?, components: [String]) async throws -> SandboxDirectory {
        let (connection, user) = try await sandboxConnection(for: app, user: user, components: components)
        let script = sandboxNavigation(components) + Self.sandboxListingScript
        let args = sandboxShell(script, app: app, user: user, connection: connection)
        let directory: SandboxDirectory
        do {
            let output = try await run(connection, args, timeout: 12)
            try await checkHarmonySandboxMount(output, app: app, user: user, connection: connection)
            directory = try SandboxDirectory(output: output)
        } catch let error as CLIError where error.timedOut {
            throw CLIError(L10n.text("The simulator took too long to list this folder. Try refreshing."))
        }
        try await verifySandboxUser(user, app: app, connection: connection)
        try Task.checkCancellation()
        return directory
    }

    func sandboxConnection(for app: InstalledApplication, user: String?, components: [String]) async throws -> (DeviceToolConnection, String) {
        guard device.platform != .iOS, ApplicationParsers.validIdentifier(app.id), !app.id.contains(where: \.isNewline),
              components.allSatisfy(SandboxDirectory.validComponent),
              components.allSatisfy({ !$0.contains("\u{FFFD}") }),
              components.joined(separator: "/").utf8.count < 4096 else {
            throw CLIError(L10n.text("The application sandbox is unavailable."))
        }
        guard let user, let id = Int(user), id >= 0, String(id) == user else {
            throw CLIError(L10n.text("Cannot confirm the application user."))
        }
        let connection = try await metadataConnection()
        try await verifySandboxUser(user, app: app, connection: connection)
        return (connection, user)
    }

    func sandboxShell(_ script: String, app: InstalledApplication, user: String, connection: DeviceToolConnection) -> [String] {
        if device.platform == .Android {
            let command = "sh -c " + Self.quoteSandboxArgument(script)
            return ["-s", connection.target, "shell", "-T", "run-as \(app.id) --user \(user) \(command)"]
        }
        // HDC reparses shell arguments and can strip backslashes before the device shell sees them.
        let command = "echo " + Data(script.utf8).base64EncodedString() + " | base64 -d | sh"
        return ["-t", connection.target, "shell", "-b", app.id, command]
    }

    func checkHarmonySandboxMount(_ output: String, app: InstalledApplication, user: String, connection: DeviceToolConnection) async throws {
        guard device.platform == .HarmonyOS,
              let firstLine = output.split(whereSeparator: \.isNewline).first,
              firstLine.hasPrefix("[Fail]"), firstLine.contains("[E003001]") else { return }
        let args = ["-t", connection.target, "shell", "bm", "dump", "-n", app.id, "-u", user]
        let details = try? await ApplicationParsers.harmonyDetails(run(connection, args, timeout: 5), app: app)
        try Task.checkCancellation()
        switch details?.extra?["appProvisionType"] {
        case "debug":
            throw CLIError(L10n.text("Open this app in the simulator, then refresh to load its debug sandbox."))
        case "release":
            throw CLIError(L10n.text("This is a release-signed HarmonyOS app. Install a debug-signed build to browse its sandbox."))
        default:
            throw CLIError(L10n.text("Sandbox access requires a running debug-signed HarmonyOS app and HDC sandbox support."))
        }
    }

    func verifySandboxUser(_ user: String, app: InstalledApplication, connection: DeviceToolConnection) async throws {
        if device.platform == .Android {
            guard try await scope(connection) == user else {
                throw CLIError(L10n.text("The application user changed. Refresh before continuing."))
            }
        } else {
            let snapshot = try ApplicationParsers.harmonyList(await run(connection, ["-t", connection.target, "shell", "bm", "dump", "-a"]))
            guard snapshot.user == user else {
                throw CLIError(L10n.text("The application user changed. Refresh before continuing."))
            }
            guard snapshot.applications.contains(where: { $0.id == app.id }) else {
                throw CLIError(L10n.text("This application is no longer installed. Refresh the list."))
            }
        }
    }

    static func quoteSandboxArgument(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func sandboxNavigation(_ components: [String]) -> String {
        let root = device.platform == .HarmonyOS ? "cd ./data/storage/el2/base || exit 1\n" : ""
        guard !components.isEmpty else { return root }
        let relativePath = Self.quoteSandboxArgument(components.joined(separator: "/"))
        // Compare physical paths after entering the folder so a swapped symlink cannot redirect a listing.
        // The suffix preserves any trailing newlines in directory names through command substitution.
        return root + """
        root=$(pwd -P && printf x) || exit 1
        cd -P ./\(relativePath) || exit 1
        current=$(pwd -P && printf x) || exit 1
        test "${current%??}" = "${root%??}"/\(relativePath) || exit 1

        """
    }

    // NUL framing preserves filenames. A final marker distinguishes success from zero-exit remote errors.
    // Batch records because Android shells may launch an external printf for every call.
    private static let sandboxListingScript = #"""
        test -r . && test -x . || exit 1
        printf 'SIMLAUNCH_SANDBOX_V1\000' || exit 1
        count=0
        end=END
        set --
        for entry in ./.[!.]* ./..?* ./*; do
            if [ -L "$entry" ]; then kind=L
            elif [ -d "$entry" ]; then kind=D
            elif [ -f "$entry" ]; then kind=F
            elif [ -e "$entry" ]; then kind=O
            else continue
            fi
            if [ "$count" -eq 2000 ]; then
                end=LIMIT
                break
            fi
            set -- "$@" "$kind${entry#./}"
            if [ "$#" -eq 64 ]; then
                printf '%s\000' "$@" || exit 1
                set --
            fi
            count=$((count + 1))
        done
        if [ "$#" -gt 0 ]; then printf '%s\000' "$@" || exit 1; fi
        printf '%s\000' "$end"
        """#
}
