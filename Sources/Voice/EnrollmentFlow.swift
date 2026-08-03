import Foundation

enum EnrollmentPhase: Equatable {
    case notStarted
    case downloadingModel
    case recording(step: Int)
    case computing
    case done
    case failed(String)
}

struct EnrollmentFlow: Equatable {
    let totalSteps: Int
    private(set) var phase: EnrollmentPhase = .notStarted

    init(totalSteps: Int = 3) { self.totalSteps = totalSteps }

    mutating func beginDownload() {
        switch phase {
        case .notStarted, .failed:
            phase = .downloadingModel
        default:
            break
        }
    }

    mutating func modelReady() {
        guard case .downloadingModel = phase else { return }
        phase = .recording(step: 0)
    }

    mutating func downloadFailed(_ message: String) {
        guard case .downloadingModel = phase else { return }
        phase = .failed(message)
    }

    mutating func finishedStep() {
        guard case .recording(let step) = phase else { return }
        let next = step + 1
        if next < totalSteps {
            phase = .recording(step: next)
        } else {
            phase = .computing
        }
    }

    mutating func stepFailed(_ message: String) {
        guard case .recording = phase else { return }
        phase = .failed(message)
    }

    mutating func computingSucceeded() {
        guard case .computing = phase else { return }
        phase = .done
    }

    mutating func computingFailed(_ message: String) {
        guard case .computing = phase else { return }
        phase = .failed(message)
    }

    mutating func cancel() {
        phase = .notStarted
    }
}
