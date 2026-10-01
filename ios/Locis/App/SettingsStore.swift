import Foundation
import LocisKit
import Observation

/// User settings, kept on the device only.
@MainActor
@Observable
final class SettingsStore {
    private let defaults: UserDefaults

    var vehicleType: VehicleType {
        didSet { defaults.set(vehicleType.rawValue, forKey: Keys.vehicleType) }
    }
    var blueBadge: Bool {
        didSet { defaults.set(blueBadge, forKey: Keys.blueBadge) }
    }
    /// Use the synthetic demo data even when a live dataset is configured.
    var preferDemoData: Bool {
        didSet { defaults.set(preferDemoData, forKey: Keys.preferDemo) }
    }

    var profile: VehicleProfile { VehicleProfile(vehicleType: vehicleType, blueBadge: blueBadge) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        vehicleType = VehicleType(rawValue: defaults.string(forKey: Keys.vehicleType) ?? "") ?? .car
        blueBadge = defaults.bool(forKey: Keys.blueBadge)
        preferDemoData = defaults.bool(forKey: Keys.preferDemo)
    }

    private enum Keys {
        static let vehicleType = "vehicleType"
        static let blueBadge = "blueBadge"
        static let preferDemo = "preferDemoData"
    }
}
