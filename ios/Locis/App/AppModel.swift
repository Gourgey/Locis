import Foundation
import LocisKit
import Observation

/// Owns the long-lived objects of the app.
@MainActor
@Observable
final class AppModel {
    let settings: SettingsStore
    let map: ParkingMapModel
    let source: DataSourceConfiguration

    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings
        let source = AppConfiguration.dataSource()
        self.source = source
        map = ParkingMapModel(provider: AppModel.makeProvider(source), profile: settings.profile)
    }

    /// Apply settings changes: the vehicle profile re-evaluates the map in place.
    func settingsChanged() {
        map.profile = settings.profile
    }

    static func makeProvider(_ source: DataSourceConfiguration) -> ParkingDataProviding {
        switch source {
        case .demo(let directory):
            return DemoDataProvider(directory: directory)
        case .remote(let baseURL):
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            return RemoteDataProvider(baseURL: baseURL, cacheDirectory: caches.appendingPathComponent("ParkingData"))
        }
    }
}
