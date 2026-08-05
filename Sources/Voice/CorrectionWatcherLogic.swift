import Foundation

/// Pure watch lifecycle for post-injection correction learning (testable without AX/CG).
enum CorrectionWatcherLogic {

    static let idleSettle: TimeInterval = 1.75
    static let watchTimeout: TimeInterval = 60

    enum EndReason: Equatable {
        case idleSettle
        case appSwitch
        case timeout
        case nextRecording
        case cancelled
    }

    struct State: Equatable {
        var isActive: Bool = false
        var watchStartedAt: Date?
        var lastKeyDownAt: Date?
        var keyDownCount: Int = 0
        var deliveredText: String = ""
        var injectedUTF16Location: Int = 0
        var injectedUTF16Length: Int = 0
        var snapshotValue: String = ""
        var frontmostPID: pid_t = 0
    }

    enum Effect: Equatable {
        case scheduleIdleSettle(deadline: Date)
        case cancelIdleSettle
        case scheduleTimeout(deadline: Date)
        case cancelTimeout
        case tearDown
        case attemptLearn(EndReason)
    }

    static func begin(
        state: inout State,
        deliveredText: String,
        snapshotValue: String,
        injectedUTF16Location: Int,
        injectedUTF16Length: Int,
        frontmostPID: pid_t,
        now: Date
    ) -> [Effect] {
        state = State(
            isActive: true,
            watchStartedAt: now,
            lastKeyDownAt: nil,
            keyDownCount: 0,
            deliveredText: deliveredText,
            injectedUTF16Location: injectedUTF16Location,
            injectedUTF16Length: injectedUTF16Length,
            snapshotValue: snapshotValue,
            frontmostPID: frontmostPID
        )
        return [
            .scheduleTimeout(deadline: now.addingTimeInterval(watchTimeout)),
            .cancelIdleSettle
        ]
    }

    static func noteKeyDown(state: inout State, now: Date) -> [Effect] {
        guard state.isActive else { return [] }
        state.keyDownCount += 1
        state.lastKeyDownAt = now
        return [.scheduleIdleSettle(deadline: now.addingTimeInterval(idleSettle))]
    }

    static func frontmostChanged(state: inout State, newPID: pid_t) -> [Effect] {
        guard state.isActive else { return [] }
        guard newPID != state.frontmostPID else { return [] }
        return end(state: &state, reason: .appSwitch)
    }

    static func idleFired(state: inout State) -> [Effect] {
        guard state.isActive else { return [] }
        return end(state: &state, reason: .idleSettle)
    }

    static func timeoutFired(state: inout State) -> [Effect] {
        guard state.isActive else { return [] }
        return end(state: &state, reason: .timeout)
    }

    static func nextRecording(state: inout State) -> [Effect] {
        guard state.isActive else { return [] }
        return end(state: &state, reason: .nextRecording)
    }

    static func cancel(state: inout State) -> [Effect] {
        guard state.isActive else { return [] }
        return end(state: &state, reason: .cancelled)
    }

    /// Whether learn is allowed for this end reason given keyDown history and `now`.
    static func shouldAttemptLearn(
        state: State,
        reason: EndReason,
        now: Date
    ) -> Bool {
        guard reason != .cancelled else { return false }
        if state.keyDownCount == 0 {
            switch reason {
            case .appSwitch, .timeout, .nextRecording:
                return true
            case .idleSettle, .cancelled:
                return false
            }
        }
        guard let last = state.lastKeyDownAt else { return false }
        return now.timeIntervalSince(last) >= idleSettle
    }

    private static func end(state: inout State, reason: EndReason) -> [Effect] {
        state.isActive = false
        // attemptLearn must precede tearDown: CorrectionWatcher.applyEffects runs in
        // list order and tearDown clears focusedElement needed for learning.
        var effects: [Effect] = [.cancelIdleSettle, .cancelTimeout]
        if reason != .cancelled {
            effects.append(.attemptLearn(reason))
        }
        effects.append(.tearDown)
        return effects
    }
}
