import SwiftUI

//https://www.rudrank.com/exploring-swiftui-animating-mesh-gradient-with-colors-in-ios-18/
@available(iOS 18.0, *)
struct AnimatedColorsMeshGradientView: View {
    // lots of colour
//    private let colors: [Color] = [
//           // Deep space and nebula colors
//           Color(red: 0.15, green: 0.05, blue: 0.40),  // Deep cosmic blue
//           Color(red: 0.30, green: 0.10, blue: 0.60),  // Rich purple
//           Color(red: 0.50, green: 0.15, blue: 0.80),  // Bright nebula purple
//           
//           // Cosmic pinks and magentas
//           Color(red: 0.85, green: 0.20, blue: 0.70),  // Bright magenta
//           Color(red: 0.70, green: 0.15, blue: 0.55),  // Deep magenta
//           Color(red: 0.90, green: 0.30, blue: 0.80),  // Bright pink
//           
//           // Deep space accents
//           Color(red: 0.20, green: 0.05, blue: 0.45),  // Dark cosmic blue
//           Color(red: 0.10, green: 0.05, blue: 0.35),  // Very deep purple
//           Color(red: 0.05, green: 0.02, blue: 0.30)   // Almost black cosmic blue
//       ]
    
    private let colors: [Color] = [
          // Deep space and black hole tones
          Color(red: 0.08, green: 0.02, blue: 0.20),  // Almost black cosmic
          Color(red: 0.15, green: 0.05, blue: 0.35),  // Deep space purple
          Color(red: 0.25, green: 0.08, blue: 0.45),  // Subtle nebula purple
          
          // Subtle cosmic pinks and magentas
          Color(red: 0.40, green: 0.10, blue: 0.35),  // Dark magenta
          Color(red: 0.35, green: 0.08, blue: 0.30),  // Deep magenta
          Color(red: 0.45, green: 0.15, blue: 0.40),  // Muted pink
          
          // Dark space accents
          Color(red: 0.12, green: 0.03, blue: 0.25),  // Very dark cosmic blue
          Color(red: 0.05, green: 0.02, blue: 0.20),  // Near black purple
          Color(red: 0.03, green: 0.01, blue: 0.15)   // Deep space black
      ]
    

  private let points: [SIMD2<Float>] = [
    SIMD2<Float>(0.0, 0.0), SIMD2<Float>(0.5, 0.0), SIMD2<Float>(1.0, 0.0),
    SIMD2<Float>(0.0, 0.5), SIMD2<Float>(0.5, 0.5), SIMD2<Float>(1.0, 0.5),
    SIMD2<Float>(0.0, 1.0), SIMD2<Float>(0.5, 1.0), SIMD2<Float>(1.0, 1.0)
  ]
}

@available(iOS 18.0, *)
extension AnimatedColorsMeshGradientView {
    var body: some View {
    TimelineView(.animation) { timeline in
      MeshGradient(
        width: 3,
        height: 3,
        locations: .points(points),
        colors: .colors(animatedColors(for: timeline.date)),
        background: .black,
        smoothsColors: true
      )
    }
    
  }
}

@available(iOS 18.0, *)
extension AnimatedColorsMeshGradientView {
  private func animatedColors(for date: Date) -> [Color] {
    let phase = CGFloat(date.timeIntervalSince1970)

    return colors.enumerated().map { index, color in
      let hueShift = cos(phase + Double(index) * 0.3) * 0.1
      return shiftHue(of: color, by: hueShift)
    }
  }

  private func shiftHue(of color: Color, by amount: Double) -> Color {
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 0
    var alpha: CGFloat = 0

    UIColor(color).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

    hue += CGFloat(amount)
    hue = hue.truncatingRemainder(dividingBy: 1.0)

    if hue < 0 {
      hue += 1
    }

    return Color(hue: Double(hue), saturation: Double(saturation), brightness: Double(brightness), opacity: Double(alpha))
  }
}

#Preview {
    if #available(iOS 18.0, *) {
        AnimatedColorsMeshGradientView()
    } else {
        // Fallback on earlier versions
    }
}
