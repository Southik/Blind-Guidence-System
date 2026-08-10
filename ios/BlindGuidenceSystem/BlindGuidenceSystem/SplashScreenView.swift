import SwiftUI

struct SplashScreenView: View {
    @Binding var isFinished: Bool
    
    @State private var scale: CGFloat = 1.0
    @State private var opacity: Double = 1.0
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .ignoresSafeArea()
                
                Image("milo") // 👈 Replace with your image name from Assets.xcassets
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .scaleEffect(scale)
                    .opacity(opacity)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            // 1. Stay still on screen for 3.0 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 0) {
                // 2. Perform 0.8-second zoom-in and fade-out
                withAnimation(.easeInOut(duration: 0.8)) {
                    scale = 12.0  // Zooms image far past screen edges
                    opacity = 0.0 // Fades out to seamless transition
                }
            }
            
            // 3. Transition to main ContentView after animation ends (3.0s + 0.8s = 3.8s)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.8) {
                withAnimation {
                    isFinished = true
                }
            }
        }
    }
}
