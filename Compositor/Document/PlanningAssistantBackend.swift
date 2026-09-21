import CoreGraphics
import Foundation

/// The assistant as it actually ships: a chain of planners over one pixel executor.
///
/// The split is the whole design. Planning is the part that needs a model and cannot be relied
/// on — the on-device model is missing on an ineligible Mac, switched off by preference, and
/// absent on a CI runner. Execution is the part that must never be wrong, and here it is the
/// app's own `PixelFilter` and Core Image, at the layer's full resolution, with no model in the
/// loop at all.
///
/// So the planners are tried in order and the first one that is ready and produces a plan wins.
/// In practice that is the on-device model when it is available and the phrase table when it is
/// not, which means the assistant degrades to a smaller vocabulary rather than to nothing.
nonisolated struct PlanningAssistantBackend: AssistantBackend {
    /// Tried in order. The last one should be a planner whose `isReady` is always true, or an
    /// instruction can fail for a reason the user cannot act on.
    let planners: [any AssistantPlanner]
    /// Fixes the random pattern for the two filters that have one (Add Noise and Grain). `nil`
    /// means a fresh pattern per run, which is what `FilterEdit` does for the same filters from
    /// the menu; the tests pin it so a grain result can be compared.
    let seed: UInt32?

    init(planners: [any AssistantPlanner] = [KeywordAssistantPlanner()], seed: UInt32? = nil) {
        self.planners = planners
        self.seed = seed
    }

    /// The planner that would answer right now, so the panel names the model actually in use
    /// rather than the one that was available at launch.
    var name: String { planners.first(where: { $0.isReady })?.name ?? "Assistant" }

    func run(_ request: AssistantRequest, history: [AssistantTurn]) async throws -> AssistantResult {
        try Task.checkCancellation()
        guard let source = request.image else {
            return AssistantResult(output: .none, note: "There are no pixels to work on.")
        }
        let target: AssistantTarget = request.targetIsMask ? .mask : .layer
        let plan = try await plan(request.instruction, for: target, history: history,
                                  hasSelection: request.selection != nil)
        try Task.checkCancellation()
        // An answer with no steps is a real outcome, not a failure: the user asked something
        // rather than asking for an edit.
        guard !plan.steps.isEmpty else { return AssistantResult(output: .none, note: plan.note) }
        let produced = try await AssistantPlanRunner.run(
            plan, on: source, targetIsMask: request.targetIsMask,
            selection: request.selection, pixelToDocument: request.pixelToDocument,
            seed: seed ?? UInt32.random(in: .min ... .max))
        try Task.checkCancellation()
        return AssistantResult(output: request.targetIsMask ? .mask(produced) : .pixels(produced), note: plan.note)
    }

    /// The first ready planner whose plan survives validation.
    ///
    /// A planner that throws is not fatal, because the reason is usually about that planner and
    /// not about the instruction: the on-device model can decline an instruction its guardrails
    /// dislike, or become unavailable between `isReady` and the call. Falling through to the
    /// phrase table turns that into a smaller vocabulary rather than a dead assistant. The one
    /// error that is never swallowed is cancellation, which is the user's own decision.
    private func plan(_ instruction: String, for target: AssistantTarget, history: [AssistantTurn],
                      hasSelection: Bool) async throws -> AssistantPlan {
        var failure: Error?
        for planner in planners where planner.isReady {
            do {
                let plan = try await planner.plan(instruction, for: target, history: history)
                return try plan.validated(targetIsMask: target.isMask, hasSelection: hasSelection)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = error
            }
        }
        throw failure ?? AssistantError.notUnderstood(instruction)
    }
}

extension PlanningAssistantBackend {
    /// The assistant the app installs: the on-device model when the Mac has one, the phrase
    /// table when it does not.
    static var standard: PlanningAssistantBackend {
        var planners: [any AssistantPlanner] = []
        // No `#available` check: the app's deployment target is already past the release that
        // introduced the framework, so the only question is whether the Mac in front of us has
        // the model switched on, which is `isReady`'s job and is asked per instruction.
        #if canImport(FoundationModels)
        planners.append(FoundationModelsAssistantPlanner())
        #endif
        planners.append(KeywordAssistantPlanner())
        return PlanningAssistantBackend(planners: planners)
    }
}
