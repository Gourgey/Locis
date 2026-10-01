import Foundation
import LocisKit

/// Build-time configuration, read from Info.plist (values come from Config/Locis.xcconfig).
enum AppConfiguration {
    /// The app's name as shown to the user. Change LOCIS_DISPLAY_NAME to rename it.
    static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "Locis"
    }

    static var version: String {
        let short = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
        return "\(short) (\(build))"
    }

    /// URL of the published dataset, or nil when the build has none configured.
    static var remoteBaseURL: URL? { url(forKey: "LocisDataBaseURL", in: Bundle.main.infoDictionary ?? [:]) }

    static var privacyPolicyURL: URL? { url(forKey: "LocisPrivacyPolicyURL", in: Bundle.main.infoDictionary ?? [:]) }

    static func url(forKey key: String, in info: [String: Any]) -> URL? {
        guard let text = (info[key] as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
            let url = URL(string: text), url.scheme == "https", url.host() != nil
        else { return nil }
        return url
    }

    /// The data source for this launch: live data when configured, unless the
    /// user has chosen the demo in Settings.
    static func dataSource(preferDemo: Bool) -> DataSourceConfiguration {
        if let remoteBaseURL, !preferDemo { return .remote(baseURL: remoteBaseURL) }
        return .demo(directory: DemoData.directory)
    }

    static let dtroURL = URL(string: "https://d-tro.dft.gov.uk")!
    static let licenceURL = URL(string: "https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/")!
    static let attribution = "Contains public sector information licensed under the Open Government Licence v3.0."
    static let disclaimer =
        "Parking information is provided as guidance. Always check local signs, road markings and temporary restrictions before parking."
}
