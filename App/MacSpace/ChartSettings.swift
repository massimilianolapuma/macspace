import Foundation
import MacSpaceCore

/// Which chart shows the current folder; remembered across launches (`@AppStorage(ChartKind.storageKey)`).
enum ChartKind: String {
    case sunburst, treemap

    static let storageKey = "chartKind"
}

/// How chart fills are colored; remembered across launches (`@AppStorage(ColorMode.storageKey)`).
/// Changing it only redraws: the scan and the current folder stay as they are. A stored value
/// this build does not know (plan 2's `"neutral"`) reads as the default, `.deletable`.
enum ColorMode: String, CaseIterable, Identifiable {
    /// By safety level (spec §5.2): what can be removed lights up in orange, the rest is neutral.
    case deletable
    /// By file type (`FileCategory`).
    case category
    /// By estimated last use (`AgeBucket`).
    case lastUse

    static let storageKey = "colorMode"

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .deletable: "Eliminabili"
        case .category: "Per tipo di file"
        case .lastUse: "Per ultimo uso"
        }
    }
}

extension FileCategory {
    var title: LocalizedStringResource {
        switch self {
        case .video: "Video"
        case .photo: "Foto e immagini"
        case .music: "Musica e audio"
        case .document: "Documenti"
        case .app: "App"
        case .development: "Sviluppo"
        case .archive: "Archivi e installer"
        case .system: "Sistema"
        case .appData: "Dati delle app e cache"
        case .other: "Altro"
        }
    }
}

extension AgeBucket {
    var title: LocalizedStringResource {
        switch self {
        case .lastMonth: "Ultimo mese"
        case .lastSixMonths: "Ultimi 6 mesi"
        case .lastYear: "Ultimo anno"
        case .oneToTwoYears: "1–2 anni fa"
        case .older: "Oltre 2 anni"
        case .unknown: "Sconosciuto"
        }
    }
}
