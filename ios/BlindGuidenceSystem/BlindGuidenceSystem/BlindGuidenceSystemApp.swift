import SwiftUI

@main
struct BlindGuidenceSystemApp: App {
    @State private var isSplashFinished = false
    
    var body: some Scene {
        WindowGroup {
            ZStack {
                if isSplashFinished {
                    ContentView()
                        .transition(.opacity)
                } else {
                    SplashScreenView(isFinished: $isSplashFinished)
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}
