import Foundation

// MARK: - Duplicate detection model
//
// A "duplicate" is the same app or tool present on the Mac via TWO OR MORE
// installations at once. ForgedBrew finds three genuine kinds:
//
//   • appStoreVsHomebrew — the app is installed from the Mac App Store AND is
//     also managed by a Homebrew cask. (This is the OneDrive situation: vendors
//     like Microsoft ship via the App Store, so the brew copy and the MAS copy
//     coexist.)
//   • multipleCopies — the same Foo.app bundle exists at two+ locations on disk
//     (e.g. /Applications and ~/Applications), regardless of source. One of the
//     copies may be the brew-managed one and the other a stray.
//   • formulaAndCask — the same tool is installed both as a Homebrew formula AND
//     as a cask.
//
// We deliberately do NOT treat "a single manual app that merely matches a cask"
// as a duplicate — that is Adopt's job (take ownership in place, nothing
// removed). Duplicates is specifically about >1 real installation, where the
// resolution is to REMOVE one copy.
//
// All types are `nonisolated`/`Sendable` so they cross the BrewCLIService actor
// boundary back to the @MainActor UI without isolation warnings (the project
// builds with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor).

// What kind of overlap a DuplicateGroup represents. Drives the row's heading,
// icon, and the guidance we show about which copy is usually safe to remove.
nonisolated enum DuplicateKind: String, Sendable, Hashable {
    case appStoreVsHomebrew   // MAS install + a Homebrew cask for the same app
    case multipleCopies       // same .app bundle at 2+ paths on disk
    case formulaAndCask       // same tool installed as both a formula and a cask

    var title: String {
        switch self {
        case .appStoreVsHomebrew: return "App Store + Homebrew"
        case .multipleCopies:     return "Multiple copies on disk"
        case .formulaAndCask:     return "Formula + Cask"
        }
    }

    var systemImage: String {
        switch self {
        case .appStoreVsHomebrew: return "bag"
        case .multipleCopies:     return "doc.on.doc"
        case .formulaAndCask:     return "shippingbox.and.arrow.backward"
        }
    }

    // A short, neutral explanation shown under the group so the user understands
    // why it's flagged and how to think about resolving it.
    var explanation: String {
        switch self {
        case .appStoreVsHomebrew:
            return "Installed from both the App Store and Homebrew. Keep one to avoid conflicting updates — most people keep the App Store copy and remove the Homebrew cask, or vice-versa."
        case .multipleCopies:
            return "The same app exists in more than one folder. Keep the copy you actually launch and remove the extra one."
        case .formulaAndCask:
            return "This tool is installed twice via Homebrew — once as a formula and once as a cask. Keep whichever you rely on and remove the other."
        }
    }
}

// Where a single installation came from, plus how ForgedBrew can remove it.
nonisolated enum DuplicateSource: Sendable, Hashable {
    case appStore                 // has Contents/_MASReceipt/receipt
    case homebrewCask(String)     // managed by `brew --cask <token>`
    case homebrewFormula(String)  // managed by `brew <token>` (formula)
    case manualOnDisk             // a plain .app bundle, not MAS, not brew-managed

    var label: String {
        switch self {
        case .appStore:                 return "App Store"
        case .homebrewCask(let t):      return "Homebrew cask (\(t))"
        case .homebrewFormula(let t):   return "Homebrew formula (\(t))"
        case .manualOnDisk:             return "Manual install"
        }
    }

    var shortLabel: String {
        switch self {
        case .appStore:        return "App Store"
        case .homebrewCask:    return "Homebrew"
        case .homebrewFormula: return "Homebrew"
        case .manualOnDisk:    return "Manual"
        }
    }

    // The brew token backing this source, when there is one.
    var brewToken: String? {
        switch self {
        case .homebrewCask(let t), .homebrewFormula(let t): return t
        case .appStore, .manualOnDisk: return nil
        }
    }

    // How removal works for this source, used to phrase the confirmation and
    // pick the removal path:
    //   • brew cask/formula → `brew uninstall`
    //   • manual on-disk    → move the .app bundle to the Trash
    //   • App Store         → move the .app bundle to the Trash (recoverable).
    //     The Apple purchase record is unaffected, so it can be re-downloaded;
    //     we just ask for a confirmation first.
    var isRemovableFromForgedBrew: Bool {
        switch self {
        case .homebrewCask, .homebrewFormula, .manualOnDisk: return true
        // App Store copies are removable too: we move the bundle to the Trash
        // (recoverable), and the user's purchase record stays intact in their
        // Apple account, so they can always re-download. The sheet asks for a
        // quick confirmation first since it's a purchased app.
        case .appStore: return true
        }
    }

    // True when removing this source needs an extra confirmation step. App Store
    // apps are purchased, so we double-check before trashing the local copy even
    // though the purchase itself is unaffected.
    var needsRemovalConfirmation: Bool {
        switch self {
        case .appStore: return true
        case .homebrewCask, .homebrewFormula, .manualOnDisk: return false
        }
    }
}

// One concrete installation of an app/tool.
nonisolated struct DuplicateInstall: Identifiable, Sendable, Hashable {
    var id: String { (path ?? "") + "|" + source.label }
    let source: DuplicateSource
    let path: String?       // absolute path to the .app bundle, when on disk
    let version: String?    // best-effort version string
    let sizeBytes: Int64?   // on-disk size, when known (for the user's context)

    // Human size like "412 MB", or nil when unknown.
    var sizeString: String? {
        guard let sizeBytes else { return nil }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: sizeBytes)
    }
}

// An app/tool that is installed more than once. `installs` always has >= 2
// entries (that's what makes it a duplicate).
nonisolated struct DuplicateGroup: Identifiable, Sendable, Hashable {
    var id: String { kind.rawValue + "|" + key }
    let kind: DuplicateKind
    let key: String          // normalized match key (stable identity)
    let displayName: String  // human name shown to the user (e.g. "OneDrive")
    let installs: [DuplicateInstall]
}
