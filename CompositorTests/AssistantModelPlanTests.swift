#if canImport(FoundationModels)
import Testing
@testable import Compositor

/// What the on-device model is allowed to talk the app into.
///
/// The model itself cannot run here — `SystemLanguageModel` is unavailable on a runner, and
/// these containers have no Mac at all — but the translation from what it says into what the
/// app does is ordinary Swift, and it is the part where a wrong answer reaches a layer. So it
/// is tested directly, by handing it the structures the model would have generated.
struct AssistantModelPlanTests {
    enum Wrong: Error { case step }

    private func color(_ step: AssistantStep?) throws -> ColorChange {
        guard case .color(let change) = step else { throw Wrong.step }
        return change
    }

    private func filter(_ step: AssistantStep?) throws -> (FilterKind, FilterSettings) {
        guard case .filter(let kind, let settings) = step else { throw Wrong.step }
        return (kind, settings)
    }

    @Test func aMaskOperationAimedAtTheLayersPixelsIsDroppedRatherThanTranslated() {
        // Translating it would be guessing at an intent the user never expressed.
        #expect(ModelStep(operation: .maskFeather, amount: 1).resolved(for: .layer) == nil)
    }

    @Test func aPixelOperationAimedAtTheMaskIsDropped() {
        #expect(ModelStep(operation: .saturation, amount: 1).resolved(for: .mask) == nil)
        #expect(ModelStep(operation: .removeBackground, amount: 1).resolved(for: .mask) == nil)
    }

    @Test func theSignOfTheAmountIsTheDirectionOfTheChange() throws {
        let warmer = try color(ModelStep(operation: .temperature, amount: 0.8).resolved(for: .layer))
        let cooler = try color(ModelStep(operation: .temperature, amount: -0.8).resolved(for: .layer))
        #expect(warmer.temperature > ColorChange.neutralTemperature)
        #expect(cooler.temperature < ColorChange.neutralTemperature)
    }

    @Test func aNumberTheUserNamedBeatsTheModelsOwnStrength() throws {
        let step = ModelStep(operation: .blur, amount: 0.2, exact: 18)
        #expect(try filter(step.resolved(for: .layer)).1.radius == 18)
    }

    @Test func aNamedNumberStillTakesItsDirectionFromTheAmount() throws {
        // "Two stops down" arrives as a positive 2 with a negative amount, and going up instead
        // would be the opposite of what was asked.
        let step = ModelStep(operation: .exposure, amount: -0.6, exact: 2)
        #expect(try filter(step.resolved(for: .layer)).1.exposure.exposure == -2)
    }

    @Test func anAmountOutsideItsRangeCannotReachThePixels() throws {
        let wild = try color(ModelStep(operation: .brightness, amount: 99).resolved(for: .layer))
        #expect(ColorChange.brightnessRange.contains(wild.normalized.brightness))
        let broken = try color(ModelStep(operation: .contrast, amount: .nan).resolved(for: .layer))
        #expect(broken.normalized.contrast == 1, "Not a number falls back to neutral")
    }

    @Test func whatItCouldNotDoIsSaidRatherThanLeftOut() throws {
        // The failure J hit on the first real run: "fix the cropping and lighting" adjusted the
        // lighting, could not crop, and said only the first half — which reads as having done
        // both. What ran and what did not both have to reach the note.
        let plan = try ModelPlan(note: "I adjusted the brightness and contrast.",
                                 steps: [ModelStep(operation: .brightness, amount: 0.4)],
                                 skipped: "I cannot crop, so the framing is unchanged.")
            .resolved(for: .layer, instruction: "fix the cropping and lighting for a headshot")
        #expect(plan.steps.count == 1)
        #expect(plan.note.hasPrefix("I adjusted"), "What it did comes first")
        #expect(plan.note.contains("cannot crop"), "What it could not do is not dropped")
    }

    @Test func aStepThatCannotReachTheTargetIsReportedNotOnlyDropped() throws {
        // Dropping it is right. Dropping it in silence is the same failure in a different place:
        // the user asked for it and the note would otherwise read as though they got it.
        let plan = try ModelPlan(note: "Feathered the mask.",
                                 steps: [ModelStep(operation: .maskFeather, amount: 0.5),
                                         ModelStep(operation: .brightness, amount: 0.4)])
            .resolved(for: .mask, instruction: "feather it and brighten it")
        #expect(plan.steps.count == 1)
        #expect(plan.note.contains("left out one step"))
    }

    @Test func decliningEverythingUsesTheReasonItGave() throws {
        let plan = try ModelPlan(note: "", steps: [],
                                 skipped: "I cannot add things to a picture, only adjust it.")
            .resolved(for: .layer, instruction: "put a hat on the cat")
        #expect(plan.steps.isEmpty)
        #expect(plan.note == "I cannot add things to a picture, only adjust it.")
    }

    @Test func doingEverythingAskedAddsNothingToTheNote() throws {
        let plan = try ModelPlan(note: "Warmed it up.", steps: [ModelStep(operation: .temperature, amount: 0.5)])
            .resolved(for: .layer, instruction: "warmer")
        #expect(plan.note == "Warmed it up.", "No apology when there is nothing to apologise for")
    }

    @Test func theInstructionsSayTheThingsItCannotDo() {
        // Cropping was the one that got silently swallowed, so it is named outright.
        let forLayer = FoundationModelsAssistantPlanner.instructions(for: .layer)
        #expect(forLayer.contains("cannot crop"))
        #expect(forLayer.contains("skipped"), "The model is told where to put what it could not do")
    }

    @Test func decliningIsAnAnswerRatherThanAFailure() throws {
        // How the model refuses "add a hat": no steps, and a sentence saying why.
        let plan = try ModelPlan(note: "This assistant only adjusts the pixels already there.", steps: [])
            .resolved(for: .layer, instruction: "put a hat on the cat")
        #expect(plan.steps.isEmpty)
        #expect(plan.note.hasPrefix("This assistant"))
    }

    @Test func decliningWithNothingToSayIsAFailure() {
        // An empty plan and an empty note is the model having produced nothing at all, which the
        // user has to hear about rather than see as a silent no-op.
        #expect(throws: AssistantError.notUnderstood("something")) {
            try ModelPlan(note: "  ", steps: []).resolved(for: .layer, instruction: "something")
        }
    }

    @Test func aPlanLongerThanTheLimitIsCutRatherThanRefused() throws {
        let many = Array(repeating: ModelStep(operation: .brightness, amount: 0.3),
                         count: AssistantPlan.stepLimit + 4)
        let plan = try ModelPlan(note: "Brightened it.", steps: many)
            .resolved(for: .layer, instruction: "brighter")
        #expect(plan.steps.count == AssistantPlan.stepLimit)
    }

    @Test func aMaskTargetGetsMaskSteps() throws {
        let step = ModelStep(operation: .maskSpread, amount: -0.5).resolved(for: .mask)
        guard case .mask(let change) = step else { throw Wrong.step }
        #expect(change.spread < 0, "A negative amount chokes the matte inwards")
    }

    @Test func theHistorySentToTheModelIsTheRecentTurnsAndTheNewOne() {
        let history = (1...10).map { AssistantTurn(role: .user, text: "turn \($0)") }
        let prompt = FoundationModelsAssistantPlanner.prompt("warmer", history: history)
        #expect(prompt.hasSuffix("User: warmer"))
        #expect(!prompt.contains("turn 1\n"), "The oldest turns are left out")
        #expect(prompt.contains("turn 10"))
    }

    @Test func theInstructionsNameOnlyTheVocabularyTheTargetCanUse() {
        let forMask = FoundationModelsAssistantPlanner.instructions(for: .mask)
        #expect(forMask.contains("maskFeather"))
        #expect(!forMask.contains("removeBackground"))
        let forLayer = FoundationModelsAssistantPlanner.instructions(for: .layer)
        #expect(forLayer.contains("removeBackground"))
        #expect(!forLayer.contains("maskFeather"))
    }
}
#endif
