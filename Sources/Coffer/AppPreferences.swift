import Foundation

/* App-level preferences. Same UserDefaults caveat as the rest of the suite:
   `swift run` and the bundled app use different defaults domains. */
enum AppPreferences {
    static let changed = Notification.Name("Coffer.PreferencesChanged")

    private static let historyLimitKey = "pref.historyLimit"
    private static let hideMenuBarIconKey = "pref.hideMenuBarIcon"

    static var isMenuBarIconHidden: Bool {
        get { UserDefaults.standard.bool(forKey: hideMenuBarIconKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: hideMenuBarIconKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /* The whole history lives in memory, and image entries keep their full
       PNG data, so the cap is bounded on both sides: below 10 the manager
       stops being a history, and past 1,000 a screenshot-heavy day quietly
       eats RAM. */
    static let historyLimitRange = 10...1000
    static let defaultHistoryLimit = 200

    static var historyLimit: Int {
        get {
            guard let stored = UserDefaults.standard.object(forKey: historyLimitKey) as? Int
            else { return defaultHistoryLimit }
            return clampedHistoryLimit(stored)
        }
        set {
            UserDefaults.standard.set(clampedHistoryLimit(newValue), forKey: historyLimitKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Clamps a proposed limit into `historyLimitRange` — out-of-range
    /// text-field input and hand-edited defaults both land here.
    static func clampedHistoryLimit(_ value: Int) -> Int {
        min(max(value, historyLimitRange.lowerBound), historyLimitRange.upperBound)
    }
}
