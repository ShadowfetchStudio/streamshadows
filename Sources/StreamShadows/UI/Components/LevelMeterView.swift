import SwiftUI

struct LevelMeterView: View {
    let level: Float
    let isMuted: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))

                let clamped = isMuted ? 0 : CGFloat(min(max(level, 0), 1))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.green, .yellow, .orange, .red],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, geo.size.width * clamped))
                    .animation(.linear(duration: 0.06), value: clamped)
            }
        }
        .frame(height: 6)
    }
}
