import AppKit
import CoreImage
import Testing
@testable import Compositor

/// A planner the test supplies the answer for, so the chain's behavior can be driven directly.
struct StubPlanner: AssistantPlanner, @unchecked Sendable {
    let name: String
    let isReady: Bool
    let answer: @Sendable (String, AssistantTarget) throws -> AssistantPlan

    init(name: String = "Stub", isReady: Bool = true,
         answer: @escaping @Sendable (String, AssistantTarget) throws -> AssistantPlan) {
        self.name = name
        self.isReady = isReady
        self.answer = answer
    }

    func plan(_ instruction: String, for target: AssistantTarget,
              history: [AssistantTurn]) async throws -> AssistantPlan {
        try answer(instruction, target)
    }
}

/// The plan layer on its own: what the phrase table reads, what a plan is allowed to be, and
/// what the executor does to pixels. None of this needs a model, which is the point — it is the
/// half of the assistant that must never be wrong, and it is covered on a runner with no
/// Apple Intelligence.
struct AssistantPlanTests {
    enum Wrong: Error { case step }

    private func color(_ plan: AssistantPlan, _ index: Int = 0) throws -> ColorChange {
        guard case .color(let change) = plan.steps[index] else { throw Wrong.step }
        return change
    }

    private func filter(_ plan: AssistantPlan, _ index: Int = 0) throws -> (FilterKind, FilterSettings) {
        guard case .filter(let kind, let settings) = plan.steps[index] else { throw Wrong.step }
        return (kind, settings)
    }

    private func mask(_ plan: AssistantPlan, _ index: Int = 0) throws -> MaskChange {
        guard case .mask(let change) = plan.steps[index] else { throw Wrong.step }
        return change
    }

    /// The gray level of the top-left pixel, 0–255, read without color management so it can be
    /// compared with what went in.
    private func firstPixel(of image: CGImage) throws -> Int {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                         mask: false, context: context)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Int(data[0])
    }

    private func run(_ plan: AssistantPlan, on image: CGImage, isMask: Bool = false) async throws -> CGImage {
        try await AssistantPlanRunner.run(plan, on: image, targetIsMask: isMask,
                                          selection: nil, pixelToDocument: .identity, seed: 7)
    }

    // MARK: Reading an instruction

    @Test func oneInstructionCanAskForSeveralChanges() async throws {
        let plan = try await KeywordAssistantPlanner().plan("warm it up and take the color out",
                                                            for: .layer, history: [])
        #expect(plan.steps.count == 2)
        #expect(try color(plan, 0).temperature > ColorChange.neutralTemperature)
        #expect(try color(plan, 1).saturation < 1)
    }

    @Test func blackAndWhiteSurvivesBeingSplitOnAnd() async throws {
        // "black and white" contains the word the clause splitter cuts on, so it has to be
        // folded into one word before the split or it becomes "black" plus "white".
        let plan = try await KeywordAssistantPlanner().plan("make it black and white", for: .layer, history: [])
        #expect(plan.steps.count == 1)
        #expect(try color(plan).saturation == 0)
    }

    @Test func howHardTheUserAskedScalesTheChange() async throws {
        let planner = KeywordAssistantPlanner()
        let slight = try await planner.plan("slightly brighter", for: .layer, history: [])
        let lots = try await planner.plan("much brighter", for: .layer, history: [])
        let plain = try await planner.plan("brighter", for: .layer, history: [])
        #expect(try color(slight).brightness < color(plain).brightness)
        #expect(try color(plain).brightness < color(lots).brightness)
    }

    @Test func aNumberInTheInstructionSetsTheAmount() async throws {
        let plan = try await KeywordAssistantPlanner().plan("blur it by 12 pixels", for: .layer, history: [])
        let (kind, settings) = try filter(plan)
        #expect(kind == .gaussianBlur)
        #expect(settings.radius == 12)
    }

    @Test func stopsReachTheExposureAdjustmentRatherThanAFlatBrightness() async throws {
        let plan = try await KeywordAssistantPlanner().plan("bring the exposure down 2 stops",
                                                            for: .layer, history: [])
        let (kind, settings) = try filter(plan)
        #expect(kind == .exposure)
        #expect(settings.exposure.exposure == -2)
    }

    @Test func theSubjectMaskIsReachableByName() async throws {
        let plan = try await KeywordAssistantPlanner().plan("remove the background", for: .layer, history: [])
        #expect(try filter(plan).0 == .removeBackground)
    }

    @Test func aMaskTargetGetsTheMaskVocabulary() async throws {
        let planner = KeywordAssistantPlanner()
        #expect(try mask(await planner.plan("feather the edge by 3", for: .mask, history: [])).feather == 3)
        #expect(try mask(await planner.plan("choke it in", for: .mask, history: [])).spread < 0)
        #expect(try mask(await planner.plan("invert it", for: .mask, history: [])).invert)
    }

    @Test func anInstructionItCannotFollowIsRefusedRatherThanGuessedAt() async throws {
        await #expect(throws: AssistantError.notUnderstood("put a hat on the cat")) {
            try await KeywordAssistantPlanner().plan("put a hat on the cat", for: .layer, history: [])
        }
    }

    // MARK: What a plan is allowed to be

    @Test func aFilterIsRefusedWhenTheMaskIsTheTarget() throws {
        // The Filter menu's code builds RGBA contexts throughout. Handing it an 8-bit matte
        // would not fail, it would quietly produce garbage, so the plan is stopped first.
        let plan = AssistantPlan(steps: [.filter(.gaussianBlur, FilterSettings())], note: "")
        #expect(throws: AssistantPlanError.notForMask("Gaussian Blur")) {
            try plan.validated(targetIsMask: true, hasSelection: false)
        }
    }

    @Test func aMaskStepIsRefusedWhenTheLayerIsTheTarget() throws {
        let plan = AssistantPlan(steps: [.mask(MaskChange(invert: true))], note: "")
        #expect(throws: AssistantPlanError.onlyForMask) {
            try plan.validated(targetIsMask: false, hasSelection: false)
        }
    }

    @Test func contentAwareFillIsRefusedWithNothingSelected() throws {
        let plan = AssistantPlan(steps: [.filter(.contentAwareFill, FilterSettings())], note: "")
        #expect(throws: AssistantPlanError.needsSelection("Content-Aware Fill")) {
            try plan.validated(targetIsMask: false, hasSelection: false)
        }
        #expect(throws: Never.self) { try plan.validated(targetIsMask: false, hasSelection: true) }
    }

    @Test func aRunawayPlanIsStoppedBeforeAnyPixelsAreTouched() throws {
        let steps = Array(repeating: AssistantStep.color(ColorChange(invert: true)),
                          count: AssistantPlan.stepLimit + 1)
        #expect(throws: AssistantPlanError.tooManySteps(AssistantPlan.stepLimit + 1)) {
            try AssistantPlan(steps: steps, note: "").validated(targetIsMask: false, hasSelection: false)
        }
    }

    @Test func amountsBeyondTheirRangeAreClampedRatherThanApplied() throws {
        // A model asking for saturation 400 gets the top of the range, not a ruined layer.
        let wild = ColorChange(saturation: 400, contrast: -9, brightness: 88, temperature: 1,
                               tint: 9999, sharpness: .nan, vignette: 50)
        let safe = wild.normalized
        #expect(safe.saturation == ColorChange.saturationRange.upperBound)
        #expect(safe.contrast == ColorChange.contrastRange.lowerBound)
        #expect(safe.brightness == ColorChange.brightnessRange.upperBound)
        #expect(safe.temperature == ColorChange.temperatureRange.lowerBound)
        #expect(safe.tint == ColorChange.tintRange.upperBound)
        #expect(safe.sharpness == 0, "A value that is not a number falls back to neutral")
        #expect(safe.vignette == ColorChange.vignetteRange.upperBound)
    }

    // MARK: Executing a plan

    @Test func aStepChangesThePixelsAndKeepsTheGrid() async throws {
        let source = try TestRasters.solid(0.2, width: 40, height: 30)
        let result = try await run(AssistantPlan(steps: [.color(ColorChange(invert: true))], note: ""), on: source)
        #expect(result.width == 40 && result.height == 30)
        #expect(try abs(firstPixel(of: result) - (255 - firstPixel(of: source))) <= 2)
    }

    @Test func stepsApplyInOrderRatherThanAllAtOnce() async throws {
        let source = try TestRasters.solid(0.2, width: 16, height: 16)
        let twice = AssistantPlan(steps: [.color(ColorChange(invert: true)), .color(ColorChange(invert: true))],
                                  note: "")
        let result = try await run(twice, on: source)
        #expect(try abs(firstPixel(of: result) - firstPixel(of: source)) <= 2,
                "Inverted twice is where it started")
    }

    @Test func theExecutorRunsTheAppsOwnFilterRatherThanItsOwn() async throws {
        let source = try TestRasters.solid(0.5, width: 32, height: 32)
        let plan = AssistantPlan(steps: [.filter(.exposure, FilterSettings(exposure: ExposureSettings(exposure: 1)))],
                                 note: "")
        let result = try await run(plan, on: source)
        #expect(try firstPixel(of: result) > firstPixel(of: source), "One stop up is brighter")
    }

    @Test func aMaskPlanStaysInTheMasksOwnFormat() async throws {
        let source = try TestRasters.solidMask(0.25, width: 24, height: 24)
        let result = try await run(AssistantPlan(steps: [.mask(MaskChange(invert: true))], note: ""),
                                   on: source, isMask: true)
        #expect(result.width == 24 && result.height == 24)
        // An 8-bit gray raster, not RGBA: writing the wrong format back is what destroys a layer.
        #expect(result.bitsPerPixel == 8)
    }

    @Test func aStepThatWouldChangeNothingIsAnError() async throws {
        let source = try TestRasters.solid(0.4, width: 8, height: 8)
        await #expect(throws: AssistantPlanError.emptyStep) {
            try await run(AssistantPlan(steps: [.color(ColorChange())], note: ""), on: source)
        }
    }

    @Test func aLongPlanStopsWhenTheRunIsCancelled() async throws {
        let source = try TestRasters.solid(0.4, width: 600, height: 600)
        let steps = Array(repeating: AssistantStep.color(ColorChange(saturation: 1.2)),
                          count: AssistantPlan.stepLimit)
        let task = Task { try await run(AssistantPlan(steps: steps, note: ""), on: source) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: The chain of planners

    @Test func theFirstReadyPlannerAnswers() async throws {
        let backend = PlanningAssistantBackend(planners: [
            StubPlanner(name: "First") { _, _ in AssistantPlan(steps: [], note: "from the first") },
            StubPlanner(name: "Second") { _, _ in AssistantPlan(steps: [], note: "from the second") },
        ], seed: 1)
        #expect(backend.name == "First")
        let result = try await backend.run(request(), history: [])
        #expect(result.note == "from the first")
    }

    @Test func aPlannerThatIsNotReadyIsSkipped() async throws {
        let backend = PlanningAssistantBackend(planners: [
            StubPlanner(name: "Asleep", isReady: false) { _, _ in AssistantPlan(steps: [], note: "asleep") },
            StubPlanner(name: "Awake") { _, _ in AssistantPlan(steps: [], note: "awake") },
        ], seed: 1)
        #expect(backend.name == "Awake")
        #expect(try await backend.run(request(), history: []).note == "awake")
    }

    @Test func aPlannerThatFailsFallsThroughToTheNextOne() async throws {
        // The on-device model can decline an instruction, or go away between the readiness
        // check and the call. That should cost the user vocabulary, not the assistant.
        let backend = PlanningAssistantBackend(planners: [
            StubPlanner(name: "Declines") { _, _ in throw AssistantError.noTarget },
            KeywordAssistantPlanner(),
        ], seed: 1)
        let result = try await backend.run(request("make it black and white"), history: [])
        guard case .pixels = result.output else { throw Wrong.step }
    }

    @Test func cancellationIsNotTreatedAsAPlannerFailure() async throws {
        // Falling through on a cancel would run the whole instruction again under the phrase
        // table, after the user had already asked for it to stop.
        let backend = PlanningAssistantBackend(planners: [
            StubPlanner(name: "Cancelled") { _, _ in throw CancellationError() },
            KeywordAssistantPlanner(),
        ], seed: 1)
        await #expect(throws: CancellationError.self) {
            try await backend.run(request("make it black and white"), history: [])
        }
    }

    @Test func anAnswerWithNoStepsEditsNothing() async throws {
        let backend = PlanningAssistantBackend(planners: [
            StubPlanner { _, _ in AssistantPlan.answer("That layer is already black and white.") },
        ], seed: 1)
        let result = try await backend.run(request(), history: [])
        guard case .none = result.output else { throw Wrong.step }
        #expect(result.note == "That layer is already black and white.")
    }

    @Test func theTargetDecidesWhichVocabularyThePlannerIsAskedFor() async throws {
        let seen = TargetRecorder()
        let backend = PlanningAssistantBackend(planners: [
            StubPlanner { _, target in seen.record(target); return AssistantPlan(steps: [], note: "") },
        ], seed: 1)
        _ = try await backend.run(request(targetIsMask: true), history: [])
        #expect(seen.seen == .mask)
    }

    private func request(_ instruction: String = "brighter", targetIsMask: Bool = false) throws -> AssistantRequest {
        let image = targetIsMask ? try TestRasters.solidMask(0.5, width: 16, height: 16)
                                 : try TestRasters.solid(0.5, width: 16, height: 16)
        return AssistantRequest(image: image, targetIsMask: targetIsMask, instruction: instruction,
                                canvasSize: CGSize(width: 16, height: 16))
    }
}

/// Carries a target out of a stub closure that runs off the test's own actor.
final class TargetRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var target: AssistantTarget?
    func record(_ target: AssistantTarget) { lock.lock(); self.target = target; lock.unlock() }
    var seen: AssistantTarget? { lock.lock(); defer { lock.unlock() }; return target }
}
