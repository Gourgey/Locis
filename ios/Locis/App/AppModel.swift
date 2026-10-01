import Foundation
import LocisKit
import Observation

/// Owns the long-lived objects of the app.
@MainActor
@Observable
final class AppModel {
    let settings: SettingsStore
    private(set) var map: ParkingMapModel
    private(set) var source: DataSourceConfiguration

    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings
        let source = AppConfiguration.dataSource(preferDemo: settings.preferDemoData)
        self.source = source
        map = ParkingMapModel(provider: AppModel.makeProvider(source), profile: settings.profile)
    }

    /// Whether this build has a live dataset to switch to.
    var hasLiveData: Bool { AppConfiguration.remoteBaseURL != nil }

    /// Apply settings changes: the profile re-evaluates in place; a change of data
    /// source rebuilds the map model.
    func settingsChanged() {
        let wanted = AppConfiguration.dataSource(preferDemo: settings.preferDemoData)
        if wanted != source {
            source = wanted
            map = ParkingMapModel(provider: AppModel.makeProvider(wanted), selection: map.selection, profile: settings.profile)
        } else {
            map.profile = settings.profile
        }
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
