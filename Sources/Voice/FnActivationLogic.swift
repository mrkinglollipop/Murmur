import Foundation

struct FnActivationLogic {
    static let doubleTapWindow: TimeInterval = 0.4
    static let holdThreshold: TimeInterval = 0.15

    struct State: Equatable {
        var isRecording: Bool = false
        var isToggleLocked: Bool = false
        var firstTapAnchor: Date? = nil
        var fnPhysicallyDown: Bool = false
        /// When non-nil, a holdThreshold timer should fire at this deadline if still pending.
        var holdDeadline: Date? = nil
    }

    enum Effect: Equatable {
        case startRecording
        case stopRecording
        case scheduleHoldTimer(deadline: Date)
        case cancelHoldTimer
    }

    /// Pure transition. Inject `now`. Do not read Date() inside except via `now`.
    static func handle(
        state: inout State,
        fnDown: Bool,
        useToggleLock: Bool,
        now: Date
    ) -> [Effect] {
        if let anchor = state.firstTapAnchor,
           now.timeIntervalSince(anchor) >= doubleTapWindow {
            state.firstTapAnchor = nil
        }

        let wasPhysicallyDown = state.fnPhysicallyDown
        state.fnPhysicallyDown = fnDown

        if !useToggleLock {
            var effects: [Effect] = []
            if fnDown && !state.isRecording {
                effects.append(.startRecording)
                state.isRecording = true
                state.firstTapAnchor = nil
                state.holdDeadline = nil
            } else if !fnDown && state.isRecording {
                effects.append(.stopRecording)
                state.isRecording = false
                state.firstTapAnchor = nil
                state.holdDeadline = nil
            }
            return effects
        }

        let edgeDown = fnDown && !wasPhysicallyDown
        let edgeUp = !fnDown && wasPhysicallyDown

        if edgeDown && state.isToggleLocked {
            state.isToggleLocked = false
            if state.isRecording {
                state.isRecording = false
                return [.stopRecording, .cancelHoldTimer]
            }
            state.firstTapAnchor = nil
            state.holdDeadline = nil
            return [.cancelHoldTimer]
        }

        if edgeDown, let anchor = state.firstTapAnchor, !state.isToggleLocked {
            if now.timeIntervalSince(anchor) < doubleTapWindow {
                state.isToggleLocked = true
                state.firstTapAnchor = nil
                state.holdDeadline = nil
                var effects: [Effect] = [.cancelHoldTimer]
                if !state.isRecording {
                    state.isRecording = true
                    effects.insert(.startRecording, at: 0)
                }
                return effects
            }
        }

        if edgeDown && !state.isToggleLocked && state.firstTapAnchor == nil {
            state.firstTapAnchor = now
            let deadline = now.addingTimeInterval(holdThreshold)
            state.holdDeadline = deadline
            return [.scheduleHoldTimer(deadline: deadline)]
        }

        if edgeUp {
            var effects: [Effect] = [.cancelHoldTimer]
            state.holdDeadline = nil
            if state.isRecording && !state.isToggleLocked {
                state.isRecording = false
                effects.append(.stopRecording)
            }
            return effects
        }

        return []
    }

    /// Restart does not start recording; only syncs physical-down for correct edges.
    static func reconcilePhysicalDownAfterRestart(state: inout State, fnHeld: Bool) {
        state.fnPhysicallyDown = fnHeld
    }

    enum TapReenableEffect: Equatable {
        case cancelHoldTimer
        case stopStuckPTTRecording
        case logStuckToggleLockRecording
    }

    /// Resync fn state after CGEvent tap re-enable. Does not auto-unlock toggle-locked recording.
    static func resyncAfterTapReenable(
        state: inout State,
        fnHeld: Bool
    ) -> [TapReenableEffect] {
        state.firstTapAnchor = nil
        state.holdDeadline = nil
        reconcilePhysicalDownAfterRestart(state: &state, fnHeld: fnHeld)

        var effects: [TapReenableEffect] = [.cancelHoldTimer]

        if state.isRecording && !state.isToggleLocked && !fnHeld {
            state.isRecording = false
            effects.append(.stopStuckPTTRecording)
        }

        if state.isRecording && state.isToggleLocked {
            effects.append(.logStuckToggleLockRecording)
        }

        return effects
    }

    static func handleHoldTimerFired(
        state: inout State,
        useToggleLock: Bool,
        now: Date
    ) -> [Effect] {
        state.holdDeadline = nil

        guard state.fnPhysicallyDown else {
            state.firstTapAnchor = nil
            return []
        }

        if !useToggleLock {
            state.firstTapAnchor = nil
            guard !state.isRecording else { return [] }
            state.isRecording = true
            return [.startRecording]
        }

        guard state.firstTapAnchor != nil,
              !state.isToggleLocked else {
            state.firstTapAnchor = nil
            return []
        }

        state.firstTapAnchor = nil
        guard !state.isRecording else {
            return []
        }
        state.isRecording = true
        return [.startRecording]
    }
}
