import Foundation

/// The user's brightness choice as the companion stores it (ADR-0003 decision 1):
/// a level in `Readings.brightnessLevels` under one UserDefaults key. Pure, so
/// what a stored value turns into is tested without writing preferences.
public enum BrightnessPreference {
    public static let key = "brightness"

    /// The level for what UserDefaults returned: the default when nothing, or
    /// anything that is not a level, is stored.
    public static func level(stored: Any?) -> Int {
        guard let value = stored as? Int, Readings.brightnessLevels.contains(value) else {
            return Readings.defaultBrightness
        }
        return value
    }
}
