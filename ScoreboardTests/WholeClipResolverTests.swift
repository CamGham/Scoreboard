//
//  WholeClipResolverTests.swift
//  ScoreboardTests
//
//  Created by Cam Graham on 18/10/2026.
//

import Testing
import Foundation
@testable import Scoreboard

/// The sampler with its default settings.
private let standardSampler = AppearanceSampler()

private typealias Colour = (luma: UInt8, cb: UInt8, cr: UInt8)

private let black: Colour = (30, 128, 128)
private let navy: Colour = (45, 150, 120)
private let grey: Colour = (120, 128, 128)
private let brick: Colour = (90, 110, 170)
private let leaves: Colour = (110, 100, 90)

private func solid(_ colour: Colour) -> [Float] {
    var histogram = [Float](repeating: 0, count: AppearanceSampler.binCount)
    histogram[standardSampler.bin(luma: colour.luma, cb: colour.cb, cr: colour.cr)] = 1
    return histogram
}

/// What a tracklet looked like over `frames`: `shorts` says who it is, `head` stands in
/// for whatever was behind them.
private func look(
    shorts: Colour,
    head: Colour = black,
    at x: CGFloat,
    frames: ClosedRange<Int>
) -> AppearanceSeparation.Look {
    var look = AppearanceSeparation.Look()
    let sample = AppearanceSample(
        bands: [solid(head), solid(black), solid(shorts), solid(black), solid(black)],
        height: 0.25,
        footY: 0.375,
        aspect: 0.32,
        centreX: x
    )
    for frame in frames {
        look.add(sample, heightRatio: nil, frame: frame, time: Double(frame) / 30)
    }
    return look
}

private func tracklet(_ track: Int, as player: Int, _ look: AppearanceSeparation.Look) -> WholeClipResolver.Tracklet {
    WholeClipResolver.Tracklet(
        trackID: track,
        firstFrame: look.firstFrame ?? 0,
        lastFrame: look.lastFrame ?? 0,
        player: player,
        look: look
    )
}

/// Only the shorts tell the players apart.
private func byShorts(_ a: AppearanceSeparation.Look, _ b: AppearanceSeparation.Look) -> Double? {
    AppearanceSeparation.hellinger(a.meanBand(.shorts), b.meanBand(.shorts))
}

/// Player 0 in navy shorts at x 0.3 and player 1 in black at x 0.7, side by side in each
/// of `count` stretches. `wrong` stretches are labelled the other way round.
private func stretches(_ count: Int, wrong: Set<Int> = [], blurred: Set<Int> = []) -> [WholeClipResolver.Tracklet] {
    (0..<count).flatMap { index -> [WholeClipResolver.Tracklet] in
        let frames = (index * 100)...(index * 100 + 50)
        let flip = wrong.contains(index)
        let zeroShorts = blurred.contains(index) ? grey : navy
        let oneShorts = blurred.contains(index) ? grey : black
        return [
            tracklet(index * 2 + 1, as: flip ? 1 : 0, look(shorts: zeroShorts, at: 0.3, frames: frames)),
            tracklet(index * 2 + 2, as: flip ? 0 : 1, look(shorts: oneShorts, at: 0.7, frames: frames)),
        ]
    }
}

@Test("Tracklets on screen together are linked into one interval")
func overlappingTrackletsFormIntervals() {
    let tracklets = [
        tracklet(1, as: 0, look(shorts: navy, at: 0.3, frames: 0...50)),
        tracklet(2, as: 1, look(shorts: black, at: 0.7, frames: 40...90)),
        tracklet(3, as: 0, look(shorts: navy, at: 0.3, frames: 85...120)),
        tracklet(4, as: 1, look(shorts: black, at: 0.7, frames: 200...250)),
    ]

    #expect(WholeClipResolver.intervals(tracklets) == [[0, 1, 2], [3]])
}

@Test("A stretch labelled the wrong way round is flipped")
func wrongStretchIsFlipped() {
    let tracklets = stretches(5, wrong: [2])

    let result = WholeClipResolver.resolve(tracklets, distance: byShorts)

    #expect(result.players == [0, 1, 0, 1, 0, 1, 0, 1, 0, 1])
    #expect(result.moves.count == 1)
    #expect(result.moves.first?.tracklets == [4, 5])
    #expect((result.moves.first?.ratio ?? 1) < 0.85)
}

@Test("A stretch that fits both players equally stays as labelled")
func weakEvidenceDoesNotFlip() {
    let tracklets = stretches(5, wrong: [2], blurred: [2])

    let result = WholeClipResolver.resolve(tracklets, distance: byShorts)

    #expect(result.players[4] == 1)
    #expect(result.players[5] == 0)
    #expect(result.moves.isEmpty)
}

@Test("A lone stretch with the wrong label — the other player hidden — is moved")
func loneStretchIsMoved() {
    var tracklets = stretches(4)
    tracklets.append(tracklet(99, as: 1, look(shorts: navy, at: 0.4, frames: 500...540)))

    let result = WholeClipResolver.resolve(tracklets, distance: byShorts)

    #expect(result.players.last == 0)
    #expect(result.moves.map(\.tracklets) == [[8]])
}

@Test("Looks are compared with ones taken at the same spot, so a change of backdrop isn't read as a change of player")
func backdropDoesNotMislead() {
    // What's behind someone counts double here — as when the backdrop fills the box.
    func byLook(_ a: AppearanceSeparation.Look, _ b: AppearanceSeparation.Look) -> Double? {
        2 * AppearanceSeparation.hellinger(a.meanBand(.head), b.meanBand(.head))
            + AppearanceSeparation.hellinger(a.meanBand(.shorts), b.meanBand(.shorts))
    }

    var tracklets: [WholeClipResolver.Tracklet] = []
    // Four stretches with player 0 on the brick side, then three with them on the trees side.
    for index in 0..<4 {
        let frames = (index * 100)...(index * 100 + 50)
        tracklets.append(tracklet(index * 2 + 1, as: 0, look(shorts: navy, head: brick, at: 0.2, frames: frames)))
        tracklets.append(tracklet(index * 2 + 2, as: 1, look(shorts: black, head: leaves, at: 0.8, frames: frames)))
    }
    for index in 4..<7 {
        let frames = (index * 100)...(index * 100 + 50)
        tracklets.append(tracklet(index * 2 + 1, as: 0, look(shorts: navy, head: leaves, at: 0.75, frames: frames)))
        tracklets.append(tracklet(index * 2 + 2, as: 1, look(shorts: black, head: brick, at: 0.25, frames: frames)))
    }

    let result = WholeClipResolver.resolve(tracklets, distance: byLook)

    #expect(result.players == tracklets.map(\.player))
    #expect(result.moves.isEmpty)
}

@Test("Players on screen together but labelled the same are left alone")
func conflictingStretchIsLeftAlone() {
    var tracklets = stretches(4)
    tracklets.append(tracklet(98, as: 1, look(shorts: navy, at: 0.3, frames: 500...540)))
    tracklets.append(tracklet(99, as: 1, look(shorts: black, at: 0.7, frames: 500...540)))

    let result = WholeClipResolver.resolve(tracklets, distance: byShorts)

    #expect(result.players.suffix(2) == [1, 1])
    #expect(result.moves.isEmpty)
}

@Test("With more than two players, nothing is moved")
func moreThanTwoPlayersAreLeftAlone() {
    var tracklets = stretches(3, wrong: [1])
    tracklets.append(tracklet(99, as: 2, look(shorts: grey, at: 0.5, frames: 400...440)))

    let result = WholeClipResolver.resolve(tracklets, distance: byShorts)

    #expect(result.players == tracklets.map(\.player))
    #expect(result.moves.isEmpty)
}

@Test("The first stretch is never flipped: it defines who P1 and P2 are")
func firstStretchIsTheAnchor() {
    // Two stretches only, disagreeing — the second, seen less clearly, is the wrong one.
    let tracklets = [
        tracklet(1, as: 0, look(shorts: navy, at: 0.3, frames: 0...50)),
        tracklet(2, as: 1, look(shorts: black, at: 0.7, frames: 0...50)),
        tracklet(1, as: 0, look(shorts: black, at: 0.7, frames: 100...150)),
        tracklet(2, as: 1, look(shorts: navy, at: 0.3, frames: 100...150)),
    ]

    let result = WholeClipResolver.resolve(tracklets, distance: byShorts)

    #expect(result.players == [0, 1, 1, 0])
    #expect(result.moves.map(\.tracklets) == [[2, 3]])
}
