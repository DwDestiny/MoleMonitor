// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Elements appended one by one; a fixed capacity.
// Output: The newest `capacity` elements, oldest first; removeAll() frees the storage.
// Pos: Fixed-capacity ring buffer for the live chart window (docs/PROJECT.md 4); Foundation only, no locking.

import Foundation

/// Keeps at most `capacity` elements. Appending to a full buffer drops the oldest element. O(1) per append.
/// A value type: the owner confines it to one queue.
struct RingSeries<T> {
    let capacity: Int
    private var storage = [T]()
    private var head = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    mutating func append(_ element: T) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    /// Oldest element first.
    var elements: [T] {
        if head == 0 { return storage }
        return Array(storage[head...]) + Array(storage[..<head])
    }

    var last: T? {
        guard !storage.isEmpty else { return nil }
        if storage.count < capacity { return storage[storage.count - 1] }
        return storage[(head + capacity - 1) % capacity]
    }

    /// Drops all elements and releases the storage.
    mutating func removeAll() {
        storage = []
        head = 0
    }
}
