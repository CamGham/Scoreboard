//
//  SpaceJamTheme.swift
//  Scoreboard
//
//  Created by Cam Graham on 25/01/2025.
//

import Foundation
import SwiftUI

//protocol Theme {
//    var background: AnyView
//        
//    
//    func buttonTheme() -> any ButtonStyle
//    
//    func background() -> any View
//}
//
//struct SpaceJamTheme: Theme {
//    func buttonTheme() -> any ButtonStyle {
//        SpaceJamButtonStyle()
//    }
//    
//    func background() -> any View {
//        AnimatedColorsMeshGradientView()
//    }
//}

/// A button style inspired by the Space Jam movie aesthetic from the 90s
/// featuring bold colors, cartoon-like animations, and basketball-themed elements
struct SpaceJamButtonStyle: ButtonStyle {
    // Configurable properties
    var baseColor: Color = Color(red: 0.05, green: 0.05, blue: 0.15) // Deep space blue
    var glowColor: Color = .cyan
    var textColor: Color = .white
    var starOpacity: Double = 0.8 // Configurable star brightness
    
    // Animation properties
    @State private var isAnimating = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .font(.headline.bold())
            .foregroundColor(textColor)
            .background(
                ZStack {
                    // Space background with gradient
                    RoundedRectangle(cornerRadius: 15)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    baseColor,
                                    Color(red: 0.1, green: 0.1, blue: 0.3),
                                    Color(red: 0.15, green: 0.05, blue: 0.25)
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            // Star field effect
                            ZStack {
                                ForEach(0..<20) { index in
                                    Circle()
                                        .fill(.white)
                                        .frame(width: CGFloat.random(in: 1...3))
                                        .offset(
                                            x: CGFloat.random(in: -50...50),
                                            y: CGFloat.random(in: -25...25)
                                        )
                                        .opacity(starOpacity)
                                        .animation(
                                            Animation
                                                .easeInOut(duration: Double.random(in: 0.5...1.5))
                                                .repeatForever(autoreverses: true)
                                                .delay(Double.random(in: 0...1)),
                                            value: configuration.isPressed
                                        )
                                }
                                
                                // Basketball outline overlay
                                Image(systemName: "circle.grid.2x2")
                                    .foregroundColor(.white.opacity(0.1))
                                    .scaleEffect(1.5)
                            }
                        )
                    
                    // Glow effect
                    RoundedRectangle(cornerRadius: 15)
                        .stroke(glowColor, lineWidth: 2)
                        .blur(radius: configuration.isPressed ? 5 : 2)
                        .opacity(configuration.isPressed ? 0.8 : 0.4)
                    
                    // Dynamic stars effect
                    ForEach(0..<5) { index in
                        Image(systemName: "star.fill")
                            .foregroundColor(glowColor)
                            .scaleEffect(configuration.isPressed ? 0.8 : 1.0)
                            .offset(x: CGFloat(index * 20 - 40), y: configuration.isPressed ? 0 : -5)
                            .opacity(configuration.isPressed ? 0.5 : 0.3)
                    }
                }
            )
            // Button press animations
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
            // Shadow effect
            .shadow(color: glowColor.opacity(0.5), radius: configuration.isPressed ? 5 : 10, x: 0, y: configuration.isPressed ? 2 : 5)
    }
}

// Preview provider for the button style
struct SpaceJamButtonStyle_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            Button("SPACE JAM!") {}
                .buttonStyle(SpaceJamButtonStyle())
            
            Button("TUNE SQUAD") {}
                .buttonStyle(SpaceJamButtonStyle(
                    baseColor: Color(red: 0.1, green: 0.05, blue: 0.2),
                    glowColor: .purple,
                    textColor: .white,
                    starOpacity: 0.9
                ))
            
            Button("MONSTARS") {}
                .buttonStyle(SpaceJamButtonStyle(
                    baseColor: Color(red: 0.05, green: 0.1, blue: 0.2),
                    glowColor: .green,
                    textColor: .white,
                    starOpacity: 0.7
                ))
        }
        .padding()
        .previewLayout(.sizeThatFits)
    }
}

// Example usage:
/*
Button("Start Game") {
    // Your action here
}
.buttonStyle(SpaceJamButtonStyle(
    baseColor: .blue,
    glowColor: .cyan,
    textColor: .white
))
*/




