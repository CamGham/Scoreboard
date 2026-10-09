//
//  VideoChromeStyles.swift
//  Scoreboard
//
//  Created by Cam Graham on 27/09/2026.
//

import SwiftUI

// The button vocabulary for chrome that sits over video.
//
// Shared by the analysis overlay and the review screen, which are the same app at two
// stages of one job: somebody who has just watched a clip being analysed shouldn't have
// to learn a second set of controls to go back over it. One definition also stops the two
// drifting apart, which they had — bordered system buttons on one screen, capsules on the
// other, for controls doing the same thing.
//
// Everything here assumes a dark backdrop, either the picture itself or the gradient the
// control bars lay over it, and is sized for a thumb.

/// A labelled capsule: "Rim", "Block area", "Mark section", "Stop watching".
struct ChromeChipStyle: ButtonStyle {

    var tint: Color = .white.opacity(0.14)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tint, in: Capsule())
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// The same capsule with no room for a label — a glyph on its own.
struct ChromeIconChipStyle: ButtonStyle {

    var tint: Color = .white.opacity(0.14)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .frame(width: 34, height: 32)
            .background(tint, in: Capsule())
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// A bare transport glyph, with a hit area far larger than the symbol it draws.
struct ChromeGlyphStyle: ButtonStyle {

    var size: CGFloat = 20
    var width: CGFloat = 44
    var height: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size))
            .foregroundStyle(.white)
            // A fixed target, so a 20pt glyph is still a 44pt button.
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// An icon on a material disc, for controls that sit on the picture itself rather than on
/// a control bar and so have to read against any frame.
struct ChromeCircleStyle: ButtonStyle {

    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.bold))
            .foregroundStyle(.white)
            .padding(9)
            .background {
                if let tint {
                    Circle().fill(tint)
                } else {
                    Circle().fill(.ultraThinMaterial)
                }
            }
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension ButtonStyle where Self == ChromeChipStyle {
    static var chromeChip: Self { .init() }
    static func chromeChip(tint: Color) -> Self { .init(tint: tint) }
}

extension ButtonStyle where Self == ChromeIconChipStyle {
    static var chromeIconChip: Self { .init() }
}

extension ButtonStyle where Self == ChromeGlyphStyle {
    static var chromeGlyph: Self { .init() }

    /// The oversized one, for a primary play/pause.
    static func chromeGlyph(size: CGFloat, width: CGFloat = 54, height: CGFloat = 44) -> Self {
        .init(size: size, width: width, height: height)
    }
}

extension ButtonStyle where Self == ChromeCircleStyle {
    static var chromeCircle: Self { .init() }
    static func chromeCircle(tint: Color) -> Self { .init(tint: tint) }
}

/// The scrim a control bar draws over video, so white glyphs stay legible whatever is
/// behind them. The same gradient on both screens.
struct ChromeBarBackground: ViewModifier {

    func body(content: Content) -> some View {
        content.background {
            LinearGradient(
                colors: [.clear, .black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }
}

/// The scrim behind a top bar. Fades the other way, and lighter: what sits up there is a
/// close button and a badge rather than a row of controls.
struct ChromeTopBarBackground: ViewModifier {

    func body(content: Content) -> some View {
        content.background {
            LinearGradient(
                colors: [.black.opacity(0.55), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }
}

extension View {
    func chromeBarBackground() -> some View {
        modifier(ChromeBarBackground())
    }

    func chromeTopBarBackground() -> some View {
        modifier(ChromeTopBarBackground())
    }
}
