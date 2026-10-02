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

    var profile: VehicleProfile { VehicleProfile(vehicleType: vehicleType, blueBadge: blueBadge) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        vehicleType = VehicleType(rawValue: defaults.string(forKey: Keys.vehicleType) ?? "") ?? .car
        blueBadge = defaults.bool(forKey: Keys.blueBadge)
    }

    private enum Keys {
        static let vehicleType = "vehicleType"
        static let blueBadge = "blueBadge"
    }
}
