import Foundation

/// The strip's editing operations. Each one leaves the strip consistent: focus on a real column,
/// stack weights matching their windows, and the view offset aimed at the focused column.
extension Strip {
    public enum InsertPosition: Equatable {
        case rightOfFocused
        case end
        /// 0-based index; clamped to the strip.
        case index(Int)
    }

    // MARK: - Adding and removing

    public mutating func insert(_ id: WindowID, width: ColumnWidth, at position: InsertPosition, focus: Bool) {
        guard !contains(id) else { return }
        let col = Column(windows: [id], width: width)
        var at: Int
        switch position {
        case .rightOfFocused:
            at = columns.isEmpty ? 0 : (columns.indices.contains(focused) ? focused + 1 : columns.count)
        case .end:
            at = columns.count
        case .index(let i):
            at = min(max(i, 0), columns.count)
        }
        columns.insert(col, at: at)
        if focus {
            focused = at
            focusedPin = nil
        } else if focused >= at {
            focused += 1
        } else if focused < 0 {
            focused = at
        }
    }

    /// Removes a window wherever it is. Returns true if it was on this strip.
    @discardableResult
    public mutating func remove(_ id: WindowID) -> Bool {
        guard let loc = locate(id) else { return false }
        switch loc {
        case .pinned(let side, let row):
            pinned[side]!.windows.remove(at: row)
            pinned[side]!.normalizeWeightsAfterRemoval(row)
            if pinned[side]!.windows.isEmpty {
                pinned[side] = nil
                if focusedPin == side { focusedPin = nil }
            }
        case .strip(let c, let row):
            columns[c].windows.remove(at: row)
            columns[c].normalizeWeightsAfterRemoval(row)
            if columns[c].windows.isEmpty {
                columns.remove(at: c)
                if columns.isEmpty {
                    focused = -1
                } else if c < focused || (c == focused && c > 0) {
                    // Focus slides to the neighbour on the left, the side new windows come from.
                    focused -= 1
                }
                focused = min(focused, columns.count - 1)
            } else if columns[c].active >= row && columns[c].active > 0 {
                columns[c].active -= 1
            }
            columns.indices.forEach { columns[$0].clampActive() }
        }
        if focusedPin != nil && pinned[focusedPin!] == nil { focusedPin = nil }
        if columns.isEmpty && focusedPin == nil {
            focusedPin = PinSide.allCases.first { pinned[$0] != nil }
        }
        return true
    }

    /// Makes a window the focused one, if it's on this strip.
    @discardableResult
    public mutating func focusWindow(_ id: WindowID) -> Bool {
        guard let loc = locate(id) else { return false }
        switch loc {
        case .strip(let c, let r):
            focused = c
            columns[c].active = r
            focusedPin = nil
        case .pinned(let side, let r):
            pinned[side]!.active = r
            focusedPin = side
        }
        return true
    }

    // MARK: - Focus

    public mutating func focusLeft() -> Bool {
        if let side = focusedPin {
            if side == .right, !columns.isEmpty {
                focusedPin = nil
                if !columns.indices.contains(focused) { focused = columns.count - 1 }
                return true
            }
            if side == .right, pinned[.left] != nil { focusedPin = .left; return true }
            return false
        }
        if focused > 0 { focused -= 1; return true }
        if pinned[.left] != nil { focusedPin = .left; return true }
        return false
    }

    public mutating func focusRight() -> Bool {
        if let side = focusedPin {
            if side == .left, !columns.isEmpty {
                focusedPin = nil
                if !columns.indices.contains(focused) { focused = 0 }
                return true
            }
            if side == .left, pinned[.right] != nil { focusedPin = .right; return true }
            return false
        }
        if focused < columns.count - 1 { focused += 1; return true }
        if pinned[.right] != nil { focusedPin = .right; return true }
        return false
    }

    public mutating func focusVertical(_ delta: Int) -> Bool {
        if let side = focusedPin {
            guard var col = pinned[side] else { return false }
            let next = col.active + delta
            guard col.windows.indices.contains(next) else { return false }
            col.active = next
            pinned[side] = col
            return true
        }
        guard columns.indices.contains(focused) else { return false }
        let next = columns[focused].active + delta
        guard columns[focused].windows.indices.contains(next) else { return false }
        columns[focused].active = next
        return true
    }

    public mutating func focusColumn(_ i: Int) -> Bool {
        guard !columns.isEmpty else { return false }
        let target = min(max(i, 0), columns.count - 1)
        let changed = target != focused || focusedPin != nil
        focused = target
        focusedPin = nil
        return changed
    }

    // MARK: - Moving

    public mutating func moveColumn(by delta: Int) -> Bool {
        guard focusedPin == nil, columns.indices.contains(focused) else { return false }
        return moveColumn(to: focused + delta)
    }

    public mutating func moveColumn(to target: Int) -> Bool {
        guard focusedPin == nil, columns.indices.contains(focused) else { return false }
        let t = min(max(target, 0), columns.count - 1)
        guard t != focused else { return false }
        let col = columns.remove(at: focused)
        columns.insert(col, at: t)
        focused = t
        return true
    }

    /// Moves the focused window up or down inside its stack.
    public mutating func moveInStack(by delta: Int) -> Bool {
        guard focusedPin == nil, columns.indices.contains(focused) else { return false }
        var col = columns[focused]
        let r = col.active, t = r + delta
        guard col.windows.indices.contains(t) else { return false }
        col.windows.swapAt(r, t)
        col.normalizeWeights()
        col.weights.swapAt(r, t)
        col.active = t
        columns[focused] = col
        return true
    }

    /// Moves a column (by index) to a new index without changing which window is focused.
    public mutating func reorderColumn(from: Int, to: Int) -> Bool {
        guard columns.indices.contains(from) else { return false }
        let t = min(max(to, 0), columns.count - 1)
        guard t != from else { return false }
        let focusedID = columns.indices.contains(focused) ? columns[focused].activeWindow : nil
        let col = columns.remove(at: from)
        columns.insert(col, at: t)
        if let f = focusedID, case .strip(let c, _)? = locate(f) { focused = c }
        return true
    }

    // MARK: - Widths and heights

    private mutating func withFocusedColumn(_ body: (inout Column) -> Bool) -> Bool {
        if let side = focusedPin, var col = pinned[side] {
            let r = body(&col)
            pinned[side] = col
            return r
        }
        guard columns.indices.contains(focused) else { return false }
        return body(&columns[focused])
    }

    public static func currentProportion(of col: Column, viewportWidth: Double, gap: Double) -> Double {
        switch col.width {
        case .proportion(let p): return p
        case .fixed(let w): return (w + gap) / (viewportWidth + gap)
        }
    }

    public mutating func cycleWidth(presets: [Double], forward: Bool, viewportWidth: Double, gap: Double) -> Bool {
        let presets = presets.sorted()
        guard !presets.isEmpty else { return false }
        return withFocusedColumn { col in
            let cur = Strip.currentProportion(of: col, viewportWidth: viewportWidth, gap: gap)
            let wasFull = col.isFullWidth
            col.widthBeforeFull = nil
            let eps = 0.01
            let next: Double
            if wasFull {
                next = forward ? presets[0] : presets[presets.count - 1]
            } else if forward {
                next = presets.first { $0 > cur + eps } ?? presets[0]
            } else {
                next = presets.last { $0 < cur - eps } ?? presets[presets.count - 1]
            }
            col.width = .proportion(next)
            return true
        }
    }

    public mutating func toggleFullWidth() -> Bool {
        withFocusedColumn { col in
            if let before = col.widthBeforeFull {
                col.width = before
                col.widthBeforeFull = nil
            } else {
                col.widthBeforeFull = col.width
                col.width = .proportion(1)
            }
            return true
        }
    }

    public mutating func resizeWidth(by step: Double, viewportWidth: Double, gap: Double) -> Bool {
        withFocusedColumn { col in
            let cur = col.isFullWidth ? 1 : Strip.currentProportion(of: col, viewportWidth: viewportWidth, gap: gap)
            col.widthBeforeFull = nil
            let next = min(1, max(0.1, cur + step))
            guard abs(next - cur) > 0.0001 else { return false }
            col.width = .proportion(next)
            return true
        }
    }

    public mutating func setWidth(_ width: ColumnWidth) -> Bool {
        withFocusedColumn { col in
            col.widthBeforeFull = nil
            col.width = width
            return true
        }
    }

    public mutating func resizeHeight(by step: Double) -> Bool {
        withFocusedColumn { col in
            guard col.windows.count > 1, !col.tabbed else { return false }
            col.normalizeWeights()
            let total = col.weights.reduce(0, +)
            let share = col.weights[col.active] / total
            let target = min(0.9, max(0.1, share + step))
            guard abs(target - share) > 0.0001 else { return false }
            // Give the active row its new share and scale the others to fill the rest.
            let othersTotal = total - col.weights[col.active]
            let n = Double(col.windows.count)
            for i in col.weights.indices where i != col.active {
                let w = othersTotal > 0 ? col.weights[i] / othersTotal : 1 / (n - 1)
                col.weights[i] = w * (1 - target) * n
            }
            col.weights[col.active] = target * n
            return true
        }
    }

    public mutating func equalizeHeights() -> Bool {
        withFocusedColumn { col in
            guard col.windows.count > 1 else { return false }
            col.weights = Array(repeating: 1, count: col.windows.count)
            return true
        }
    }

    // MARK: - Stacks and tabs

    /// Moves the focused window into the neighbouring column's stack.
    public mutating func stackInto(_ side: PinSide) -> Bool {
        guard focusedPin == nil, columns.indices.contains(focused) else { return false }
        let target = side == .left ? focused - 1 : focused + 1
        guard columns.indices.contains(target) else { return false }
        guard let id = columns[focused].activeWindow else { return false }
        let src = focused
        columns[src].windows.remove(at: columns[src].active)
        columns[src].normalizeWeightsAfterRemoval(columns[src].active)
        columns[src].clampActive()
        columns[target].windows.append(id)
        columns[target].weights.append(1)
        columns[target].normalizeWeights()
        columns[target].active = columns[target].windows.count - 1
        if columns[src].windows.isEmpty {
            columns.remove(at: src)
            focused = target > src ? target - 1 : target
        } else {
            focused = target
        }
        return true
    }

    /// Takes the focused window out of its stack into a column of its own.
    public mutating func popOut(_ side: PinSide) -> Bool {
        guard focusedPin == nil, columns.indices.contains(focused) else { return false }
        var col = columns[focused]
        guard col.windows.count > 1, let id = col.activeWindow else { return false }
        let row = col.active
        col.windows.remove(at: row)
        col.normalizeWeightsAfterRemoval(row)
        col.clampActive()
        if col.windows.count < 2 { col.tabbed = false }
        columns[focused] = col
        let new = Column(windows: [id], width: col.widthBeforeFull ?? col.width)
        let at = side == .right ? focused + 1 : focused
        columns.insert(new, at: at)
        focused = at
        return true
    }

    public mutating func toggleTabbed() -> Bool {
        withFocusedColumn { col in
            col.tabbed.toggle()
            return true
        }
    }

    // MARK: - Pinning

    /// Pins the focused column to one edge, or unpins it if it's already pinned there.
    public mutating func togglePin(_ side: PinSide) -> Bool {
        if let fp = focusedPin {
            guard let col = pinned[fp] else { return false }
            pinned[fp] = nil
            focusedPin = nil
            if fp == side {
                // Unpin: back onto the strip at that end.
                let at = side == .left ? 0 : columns.count
                columns.insert(col, at: at)
                focused = at
            } else {
                // Move the pin to the other edge.
                if let other = pinned[side] {
                    columns.insert(other, at: side == .left ? 0 : columns.count)
                    if side == .left { focused += 1 }
                }
                pinned[side] = col
                focusedPin = side
            }
            return true
        }
        guard columns.indices.contains(focused) else { return false }
        let col = columns.remove(at: focused)
        if let old = pinned[side] {
            // Whatever was pinned there goes back onto the strip where this column was.
            columns.insert(old, at: min(focused, columns.count))
        }
        pinned[side] = col
        focusedPin = side
        focused = min(focused, columns.count - 1)
        if columns.isEmpty { focused = -1 }
        return true
    }

    // MARK: - Housekeeping

    /// Repairs anything out of range, e.g. after loading a saved session.
    public mutating func sanitize() {
        columns.removeAll { $0.windows.isEmpty }
        for i in columns.indices {
            columns[i].normalizeWeights()
            columns[i].clampActive()
        }
        for side in PinSide.allCases {
            if pinned[side]?.windows.isEmpty == true { pinned[side] = nil }
            pinned[side]?.normalizeWeights()
            pinned[side]?.clampActive()
        }
        if columns.isEmpty { focused = -1 } else { focused = min(max(focused, 0), columns.count - 1) }
        if let fp = focusedPin, pinned[fp] == nil { focusedPin = nil }
        if !viewOffset.isFinite { viewOffset = 0 }
    }
}

extension Column {
    mutating func normalizeWeightsAfterRemoval(_ row: Int) {
        if weights.indices.contains(row) && weights.count == windows.count + 1 {
            weights.remove(at: row)
        }
        normalizeWeights()
    }
}
