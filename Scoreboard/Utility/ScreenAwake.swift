//
//  ScreenAwake.swift
//  Scoreboard
//
//  Created by Cam Graham on 04/11/2026.
//

import SwiftUI
import UIKit

/// Keeps the phone from auto-locking while any screen asks it to.
///
/// Locking sends the app to the background, and a pass can't run there — the GPU is off
/// limits and the reader can be interrupted. So while frames are being analysed the idle
/// timer is held off.
///
/// The idle timer is one switch for the whole app, and analysis screens stack: the review
/// cover sits on top of the first pass. Each screen holds on by its own id, and the timer
/// only comes back once nobody is holding — so one screen letting go can't undo another.
@MainActor
final class ScreenAwake {
    static let shared = ScreenAwake { UIApplication.shared.isIdleTimerDisabled = $0 }

    private var holders: Set<UUID> = []

    /// Turns auto-lock off (true) or back on (false). Injected so tests don't touch the
    /// real setting.
    private let apply: (Bool) -> Void

    init(apply: @escaping (Bool) -> Void) {
        self.apply = apply
    }

    var isHeld: Bool { !holders.isEmpty }

    /// Keep the screen awake on behalf of `id`. Holding twice counts once.
    func hold(_ id: UUID) {
        let wasHeld = isHeld
        holders.insert(id)
        if !wasHeld { apply(true) }
    }

    /// Stop holding for `id`. Auto-lock returns when the last holder lets go.
    func release(_ id: UUID) {
        guard holders.remove(id) != nil else { return }
        if !isHeld { apply(false) }
    }
}

private struct KeepsScreenAwake: ViewModifier {
    let isOn: Bool
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { update(isOn) }
            .onChange(of: isOn) { _, isOn in update(isOn) }
            // Always let go on the way out, whatever the condition says — a screen that
            // closes mid-pass must not leave the phone unable to lock.
            .onDisappear { ScreenAwake.shared.release(id) }
    }

    private func update(_ isOn: Bool) {
        if isOn {
            ScreenAwake.shared.hold(id)
        } else {
            ScreenAwake.shared.release(id)
        }
    }
}

extension View {
    /// Holds off auto-lock while `isOn` is true and the view is on screen.
    func keepsScreenAwake(_ isOn: Bool) -> some View {
        modifier(KeepsScreenAwake(isOn: isOn))
    }
}
