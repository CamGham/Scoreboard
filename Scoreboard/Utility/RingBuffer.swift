//
//  RingBuffer.swift
//  Scoreboard
//
//  Created by Cam Graham on 13/01/2026.
//

import Foundation

struct RingBuffer<T> {
    private var buffer: [T?]
    private var head = 0
    private var count = 0

    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = Array(repeating: nil, count: capacity)
    }

    mutating func append(_ element: T) {
        buffer[head] = element
        head = (head + 1) % capacity
        count = min(count + 1, capacity)
    }

    var elements: [T] {
        guard count > 0 else { return [] }

        let start = (head - count + capacity) % capacity
        return (0..<count).compactMap {
            buffer[(start + $0) % capacity]
        }
    }

    var isFull: Bool {
        count == capacity
    }
    

    func suffix(_ n: Int) -> ArraySlice<T> {
        elements.suffix(n)
    }
}
