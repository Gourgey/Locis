import Foundation

/// The synthetic demonstration dataset bundled with the app.
///
/// It describes a fictional street grid drawn over open parkland and is generated
/// by the pipeline (`scripts/build-demo-data.sh`). None of it is a real parking rule.
public enum DemoData {
    public static var directory: URL {
        Bundle.module.url(forResource: "demo", withExtension: nil)!
    }

    /// Centre of the fictional "Demo Quarter".
    public static let centre = Coordinate(longitude: -0.27618, latitude: 51.43827)
}
