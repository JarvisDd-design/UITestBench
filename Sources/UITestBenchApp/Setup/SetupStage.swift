import SwiftUI
import UITestBenchCore

struct SetupStage: View {
    @ObservedObject var setup: SetupModel

    var body: some View {
        GeometryReader { proxy in
            let layout = PhoneLayoutCalculator.layout(
                available: proxy.size,
                profile: .standard
            )

            VStack(spacing: PhoneLayoutCalculator.capsuleGap) {
                PhoneFrame(layout: layout) {
                    SetupScreen(model: setup)
                }
                Color.clear
                    .frame(height: PhoneLayoutCalculator.capsuleHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
