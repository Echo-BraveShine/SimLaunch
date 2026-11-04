import Foundation

public enum L10n {
    public static var language: String {
        let choice = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        if choice == "system" { return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en" }
        return choice == "zh-Hans" ? "zh-Hans" : "en"
    }
    public static func text(_ key: String) -> String { text(key, language: language) }
    // SwiftPM can emit lowercase localization directory names on case-sensitive runners.
    // Read the selected table explicitly, independent of the host's preferred languages.
    private static let tables: [String: [String: String]] = {
        guard let root = Bundle.module.resourceURL else { return [:] }
        return Dictionary(uniqueKeysWithValues: ["en", "zh-Hans"].map { ($0, loadTable(language: $0, resourceDirectory: root)) })
    }()
    static func loadTable(language: String, resourceDirectory: URL) -> [String: String] {
        let name = language.replacingOccurrences(of: "_", with: "-").lowercased() + ".lproj"
        guard let directory = (try? FileManager.default.contentsOfDirectory(at: resourceDirectory, includingPropertiesForKeys: nil))?.first(where: { $0.lastPathComponent.lowercased() == name }),
              let data = try? Data(contentsOf: directory.appendingPathComponent("Localizable.strings")),
              let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return [:] }
        return table
    }
    public static func text(_ key: String, language: String) -> String {
        let selected = language.replacingOccurrences(of: "_", with: "-").lowercased()
        let canonical = selected == "zh-hans" ? "zh-Hans" : selected
        return tables[canonical]?[key] ?? key
    }
    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale(identifier: language), arguments: arguments)
    }
}
