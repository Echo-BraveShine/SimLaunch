import Foundation

public enum L10n {
    public static var language: String {
        let choice = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        if choice == "system" { return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en" }
        return choice == "zh-Hans" ? "zh-Hans" : "en"
    }
    public static func text(_ key: String) -> String { text(key, language: language) }
    public static func text(_ key: String, language: String) -> String {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale(identifier: language), arguments: arguments)
    }
}
