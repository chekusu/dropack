import Foundation

/// Converts durable job state plus actual worker state into presentation state.
/// A failed checkpoint may remain on disk during retry, so it cannot override
/// a worker that has actually restarted. A reset requirement remains blocking.
public enum TransferActivityStagePolicy {
    public static func resolve<Stage>(isFinished: Bool, needsReset: Bool,
                                      isWorking: Bool, hasPriorFailure: Bool,
                                      finished: Stage, failed: Stage,
                                      running: Stage, paused: Stage) -> Stage {
        if isFinished { return finished }
        if needsReset { return failed }
        if isWorking { return running }
        return hasPriorFailure ? failed : paused
    }
}
