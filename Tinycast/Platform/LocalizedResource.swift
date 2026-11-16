import Foundation

extension LocalizedStringResource {
    func englishSource() -> String {
        guard defaultValue != String.LocalizationValue(key) else { return key }
        var resource = self
        resource.locale = Locale(identifier: "en")
        return String(localized: resource)
    }

    /// `String(localized:)` on a resource can bypass the bundle's table cache and reparse every call.
    func resolved() -> String {
        let value = Bundle.main.localizedString(forKey: key, value: nil, table: table)
        let needsArguments = value.contains("%")
        let needsDefault = value == key && defaultValue != String.LocalizationValue(key)
        return needsArguments || needsDefault ? String(localized: self) : value
    }
}
