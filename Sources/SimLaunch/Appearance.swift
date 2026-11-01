import SwiftUI
import SimLaunchCore

struct PlatformIcon: View {
    let platform: Platform
    var size: CGFloat = 28
    private var tint: Color {
        switch platform { case .iOS: return Color(red: 0.16, green: 0.17, blue: 0.19); case .Android: return Color(red: 0.16, green: 0.62, blue: 0.36); case .HarmonyOS: return .blue }
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25).fill(tint)
            switch platform {
            case .iOS:
                Image(systemName: "apple.logo").font(.system(size: size * 0.57)).foregroundStyle(.white)
            case .Android:
                ZStack {
                    Path { p in
                        p.addArc(center: CGPoint(x: size * 0.5, y: size * 0.65), radius: size * 0.3, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                        p.closeSubpath()
                    }.fill(.white)
                    ForEach(0..<2) { index in
                        Capsule().fill(.white).frame(width: size * 0.045, height: size * 0.22)
                            .rotationEffect(.degrees(index == 0 ? -30 : 30))
                            .offset(x: size * (index == 0 ? -0.21 : 0.21), y: -size * 0.15)
                        Circle().fill(tint).frame(width: size * 0.055, height: size * 0.055)
                            .offset(x: size * (index == 0 ? -0.13 : 0.13), y: size * 0.04)
                    }
                }
            case .HarmonyOS:
                VStack(spacing: size * 0.015) {
                    Text("H").font(.system(size: size * 0.53, weight: .semibold, design: .rounded))
                    Capsule().frame(width: size * 0.34, height: size * 0.035)
                }.foregroundStyle(.white)
            }
        }.frame(width: size, height: size).accessibilityLabel(platform.rawValue)
    }
}

/// Glass is reserved for navigation and controls; device content stays on readable surfaces.
struct AdaptiveGlass: ViewModifier {
    var radius: CGFloat = 16
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        } else if reduceTransparency || contrast == .increased {
            content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}

struct GeneralSettingsIcon: View {
    var size: CGFloat = 28
    var body: some View {
        Image(systemName: "gearshape.fill")
            .font(.system(size: size * 0.57, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(red: 0.43, green: 0.47, blue: 0.54), in: RoundedRectangle(cornerRadius: size * 0.25))
    }
}
