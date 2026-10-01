import SwiftUI

@main
struct LocisApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            MapScreen()
                .environment(app)
        }
    }
}
