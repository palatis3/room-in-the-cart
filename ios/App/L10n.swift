import Foundation

func tr(_ key: String) -> String { String(localized: String.LocalizationValue(key)) }
func message(_ key: String, _ args: CVarArg...) -> String {
    String(format: tr(key), locale: Locale.current, arguments: args)
}
