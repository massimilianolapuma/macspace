import Foundation
import MacSpaceCore

extension SafetyLevel {
    /// The level in words, as the tooltip, the list, the legend and VoiceOver say it.
    var title: LocalizedStringResource {
        switch self {
        case .safe: "Sicuro da eliminare"
        case .caution: "Da controllare"
        case .normal: "Normale"
        case .protected: "Protetto"
        }
    }

    /// The level for VoiceOver labels: nothing for `.normal`, the level most of the disk is at.
    var spokenTitle: String? {
        self == .normal ? nil : String(localized: title)
    }
}

extension SafetyVerdict {
    /// Why the item has its level, in one Italian sentence; nil for an ordinary item. An empty
    /// owner counts as unknown.
    var sentence: String? {
        let owner = owner.flatMap { $0.isEmpty ? nil : $0 }
        return switch reason {
        case .unusualPath: String(localized: "Percorso insolito: per sicurezza non si può spostare")
        case .scanRoot: String(localized: "È la cartella analizzata")
        case .essentialFolder: String(localized: "Cartella essenziale del Mac o dell'utente")
        case .insidePackage: String(localized: "Fa parte di un pacchetto: si può spostare solo il pacchetto intero")
        case .systemLocation: String(localized: "File di sistema protetto da macOS")
        case .trash: String(localized: "È il Cestino: svuotalo dal Finder")
        case .appleData: String(localized: "Dati di sistema di Apple: rimuoverli rompe le app")
        case .photosLibrary:
            String(localized: "Libreria di Foto: libera spazio da Foto › Impostazioni › «Ottimizza spazio»")
        case .runningApp: String(localized: "App in esecuzione")
        case .runningAppData:
            owner.map { String(localized: "Dati di \($0), che è in esecuzione") }
                ?? String(localized: "Dati di un'app in esecuzione")
        case .notWritable: String(localized: "Non hai i permessi per spostarlo")
        case .cloudOnly: String(localized: "Solo nel cloud: non occupa spazio su questo Mac")
        case .cloudSynced:
            owner.map {
                String(localized: "Sincronizzato con \($0): verrà eliminato anche da \($0) e dagli altri dispositivi.")
            } ?? String(localized: "Sincronizzato nel cloud: verrà eliminato anche dagli altri dispositivi.")
        case .developerCache:
            owner.map { String(localized: "Cache per sviluppatori (\($0)): si rigenera da sola") }
                ?? String(localized: "Cache per sviluppatori: si rigenera da sola")
        case .analysisPending: String(localized: "Analisi delle app in corso…")
        case .appleCache: String(localized: "Cache di sistema: si rigenera, ma alcuni servizi la usano di continuo")
        case .cacheOfRunningApp:
            owner.map { String(localized: "Cache di \($0), che è in esecuzione: chiudila prima") }
                ?? String(localized: "Cache di un'app in esecuzione: chiudila prima")
        case .cacheOfApp:
            owner.map { String(localized: "Cache di \($0), app non in esecuzione: si rigenera da sola") }
                ?? String(localized: "Cache: si rigenera da sola")
        case .leftover: String(localized: "Avanzo di un'app non più installata")
        case .recentLeftover:
            String(localized: "Sembra un avanzo, ma è stato usato di recente: forse appartiene a un'app non trovata")
        case .vendorLeftover:
            owner.map { String(localized: "Sembra un avanzo, ma \($0) dello stesso sviluppatore è installata: controlla prima") }
                ?? String(localized: "Sembra un avanzo, ma un'app dello stesso sviluppatore è installata: controlla prima")
        case .leftoverLaunchAgent:
            String(localized: "Avvio automatico di un programma non trovato: controlla prima di rimuoverlo")
        case .appData:
            owner.map { String(localized: "Dati di \($0): rimuoverli azzera documenti o impostazioni") }
                ?? String(localized: "Dati di un'app installata")
        case .installer:
            owner.map { String(localized: "File d'installazione: \($0) è già installata") }
                ?? String(localized: "File d'installazione")
        case .notUsedForLong: String(localized: "Non usato da oltre 2 anni (stima)")
        case .ordinary: nil
        }
    }

    /// The owning app, for the tooltip's "App: <owner>" line: only for a running app's own bundle,
    /// whose sentence ("App in esecuzione") does not name it. Every other sentence with an owner
    /// already names it (apps, cloud providers, developer caches); nil when unknown.
    var appName: String? {
        guard reason == .runningApp, let owner, !owner.isEmpty else { return nil }
        return owner
    }
}

extension TrashSkip {
    /// Why an item was not moved to the Trash, in words, as the result sheet lists it.
    var text: String {
        switch self {
        case .missing: String(localized: "Non esiste più")
        case .changed: String(localized: "È cambiato dopo l'analisi")
        case let .protected(reason):
            String(localized: "Ora è protetto. \(SafetyVerdict(level: .protected, reason: reason).sentence ?? String(localized: SafetyLevel.protected.title))")
        case .verdictChanged: String(localized: "La sua valutazione è cambiata: controllalo di nuovo")
        case .appsAnalysisInProgress: String(localized: "Analisi delle app in corso: riprova tra poco")
        case .openNow: String(localized: "Aperto ora in un'app")
        case .insidePackage: String(localized: "Fa parte di un pacchetto")
        case .refused: String(localized: "Rifiutato per sicurezza")
        case .cannotCheckOpenFiles: String(localized: "Impossibile verificare i file aperti")
        case .containsUnverified: String(localized: "Contiene elementi che MacSpace non ha potuto verificare")
        case .scanInProgress: String(localized: "Analisi in corso: riprova al termine")
        case let .failed(message): String(localized: "Errore: \(message)")
        }
    }
}
