import Foundation

/// Archive zero means the source did not supply a date. Export/recovery are
/// independent events; neither substitutes for an unknown original save date.
enum RecordsDatePresentation {
    static func localSavedAt(_ milliseconds: Int64, locale: Locale = recordsInterfaceLocale) -> String {
        text(milliseconds, unknown: ("Local save date not supplied", "Fecha del guardado local no indicada"),
             label: ("Saved on this device: ", "Guardado en este dispositivo: "), locale: locale)
    }
    static func householdFetchedAt(_ milliseconds: Int64, locale: Locale = recordsInterfaceLocale) -> String {
        text(milliseconds, unknown: ("Household fetch date not supplied", "Fecha de consulta del hogar no indicada"),
             label: ("Last read from household: ", "Última consulta al hogar: "), locale: locale)
    }
    static func encryptedBackupSavedAt(_ milliseconds: Int64, currentRevision: Bool, locale: Locale = recordsInterfaceLocale) -> String {
        let label = currentRevision
            ? ("Encrypted backup of selected data from this version: ", "Respaldo cifrado de los datos seleccionados de esta versión: ")
            : ("Encrypted backup of selected data from an earlier version: ", "Respaldo cifrado de los datos seleccionados de una versión anterior: ")
        return text(milliseconds, unknown: ("Encrypted backup date not supplied", "Fecha del respaldo cifrado no indicada"),
                    label: label, locale: locale)
    }
    static func sourceSavedAt(_ milliseconds: Int64, locale: Locale = recordsInterfaceLocale) -> String {
        text(milliseconds, unknown: ("Source saved date not supplied", "Fecha de guardado de origen no indicada"),
             label: ("Source saved at: ", "Guardado de origen: "), locale: locale)
    }
    static func exportedAt(_ milliseconds: Int64, locale: Locale = recordsInterfaceLocale) -> String {
        text(milliseconds, unknown: ("Export date not supplied", "Fecha de exportación no indicada"),
             label: ("File exported at: ", "Archivo exportado: "), locale: locale)
    }
    static func recoveredAt(_ milliseconds: Int64, locale: Locale = recordsInterfaceLocale) -> String {
        text(milliseconds, unknown: ("Recovery date not supplied", "Fecha de recuperación no indicada"),
             label: ("Copy recovered at: ", "Copia recuperada: "), locale: locale)
    }
    private static func text(_ milliseconds: Int64, unknown: (String, String), label: (String, String), locale: Locale) -> String {
        let spanish = locale.language.languageCode?.identifier == "es"
        guard milliseconds != 0 else { return spanish ? unknown.1 : unknown.0 }
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        return (spanish ? label.1 : label.0) + date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }
}
