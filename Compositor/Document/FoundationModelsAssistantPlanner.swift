#if canImport(FoundationModels)
import FoundationModels
#endif
import Foundation

#if canImport(FoundationModels)

/// The planner that reads an instruction with Apple's on-device language model.
///
/// Why this model and not an image model: the assistant's hard problem in this app is
/// *understanding*, not generating. Compositor already owns a good set of full-resolution pixel
/// operations — the Filter and Image menus, Vision's subject mask, Content-Aware Fill — and
/// what it has never had is a way to say "warm it up a bit and take the edge off" and have the
/// right ones run with the right numbers. `SystemLanguageModel` is exactly that piece: it ships
/// with the OS, so there are no weights to download and no key to store in an app that has
/// nowhere to store one, and guided generation makes it emit a typed plan rather than prose to
/// be parsed.
///
/// What it cannot do is make pixels. It is a text model, and on this app's deployment target it
/// never sees the layer either — `Attachment` and `ImageReference` are macOS 27 and up — so
/// anything that needs new image content ("add a hat", "make the sky stormy") is outside this
/// planner and outside what the app can do on device today. It also cannot ask for a region it
/// has no way to find: Vision on macOS 26 segments the subject and the foreground, and nothing
/// class-labelled, so "the sky" is as far out of reach as painting one.
/// See `docs/ai-model-backend.md`.
///
/// ## Unverified
/// These containers are Linux, so what follows is read from Apple's documentation rather than
/// measured: that `respond(to:generating:)` honors task cancellation mid-inference, and how
/// long a plan of this size takes on a given chip. Both need a real Mac to confirm.
nonisolated struct FoundationModelsAssistantPlanner: AssistantPlanner {
    let name = "Apple Intelligence"

    /// Read fresh every time rather than cached: a user can switch Apple Intelligence on, or
    /// the model can finish downloading, without relaunching the app.
    var isReady: Bool { SystemLanguageModel.default.isAvailable }

    func plan(_ instruction: String, for target: AssistantTarget,
              history: [AssistantTurn]) async throws -> AssistantPlan {
        try Task.checkCancellation()
        guard case .available = SystemLanguageModel.default.availability else {
            throw AssistantModelError.unavailable(SystemLanguageModel.default.availability)
        }
        // A fresh session per instruction. The alternative — one session held across the
        // conversation — grows a transcript that eventually trips the context limit in the
        // middle of an edit, and the few turns that matter are re-sent below anyway.
        let session = LanguageModelSession {
            Self.instructions(for: target)
        }
        let response = try await session.respond(to: Self.prompt(instruction, history: history),
                                                 generating: ModelPlan.self)
        try Task.checkCancellation()
        return try response.content.resolved(for: target, instruction: instruction)
    }

    /// The few most recent turns, so "a bit more" and "undo that, try warmer" have something to
    /// refer to, without re-sending a conversation that could be hours long.
    static func prompt(_ instruction: String, history: [AssistantTurn]) -> String {
        let recent = history.suffix(6).map { "\($0.role == .user ? "User" : "You"): \($0.text)" }
        guard !recent.isEmpty else { return instruction }
        return recent.joined(separator: "\n") + "\nUser: " + instruction
    }

    static func instructions(for target: AssistantTarget) -> String {
        let common = """
        You turn a photo editor's instruction into a short list of edits. You never see the \
        image, so never describe what is in it and never claim to have seen it.

        Each step is one operation and one amount. Amount runs from -1 to 1: 0 changes nothing, \
        positive is more of the thing the operation names, negative is less. Use about 0.3 for \
        "slightly", 0.6 for a plain request, and 1 for "a lot". Use `exact` only when the user \
        names a number themselves — pixels of blur, stops of exposure, degrees of angle — and \
        leave it 0 otherwise.

        Prefer one step. Use two or three only when the user genuinely asked for separate \
        changes. Never use more than three.

        You cannot crop, resize, straighten, move or rotate anything, add or remove objects, \
        change what the picture is of, or generate new image content. You only adjust the \
        pixels that are already there, and the picture always comes back the same size.

        Most requests ask for more than one thing, and some of those things will be off that \
        list. Do the parts you can and put every part you cannot into `skipped`. NEVER quietly \
        do the part you can and report success — a user who asked for a crop and a colour fix \
        must be told the crop did not happen. Never substitute an operation you can do for one \
        you cannot. If you can do none of it, return no steps and say why in `skipped`.

        The note is one short sentence in the past tense, in plain English, that the user will \
        read in a chat panel, and it describes ONLY what you actually did. No lists, no markup, \
        no emoji. If you did nothing, leave it empty and fill in `skipped`.
        """
        let vocabulary = target.isMask ? """

        The layer MASK is selected, so the only operations available are maskInvert, \
        maskFeather, maskSpread and maskContrast. maskSpread with a negative amount chokes the \
        matte inwards. Never use any other operation.
        """ : """

        The layer's PIXELS are selected. Available operations: brightness, contrast, \
        saturation, temperature (positive is warmer), tint, sharpen, vignette, invert, blur, \
        motionBlur, grain, noise, exposure, sepiaTone, lensCorrection, removeBackground, \
        fillSelection. removeBackground cuts the subject out of its background. fillSelection \
        is content-aware fill and only works when the user has something selected. Never use a \
        mask operation.
        """
        return common + vocabulary
    }
}

// MARK: - What the model is allowed to say

/// The shape the model generates.
///
/// Deliberately flat and small. The framework turns every `Generable` type into a JSON schema
/// that is spent out of the context window, and a 3-billion-parameter model is far more
/// reliable filling in one enum and two numbers than a nest of per-operation structures. The
/// ranges are described in the instructions and enforced in Swift rather than with a
/// `GenerationGuide`, so that nothing here depends on a guide overload existing for `Double` —
/// and because `normalized` has to clamp anyway, guided or not.
@Generable
nonisolated struct ModelPlan {
    @Guide(description: "One short past-tense sentence saying what you did, for the user to read.")
    var note: String
    @Guide(description: "The edits to apply in order. At most three. Empty if you cannot do what was asked.")
    var steps: [ModelStep]
    @Guide(description: "One sentence naming any part of the request you could NOT do, and why, for the user to read. Example: \"I cannot crop, so the framing is unchanged.\" Empty only if you did everything asked.")
    var skipped: String

    /// Spelled out rather than left to the memberwise initializer, which a macro that adds its
    /// own initializer would suppress. The tests build these directly.
    init(note: String, steps: [ModelStep], skipped: String = "") {
        self.note = note
        self.steps = steps
        self.skipped = skipped
    }
}

@Generable
nonisolated struct ModelStep {
    var operation: ModelOperation
    @Guide(description: "How much, from -1 to 1. 0 changes nothing.")
    var amount: Double
    @Guide(description: "The number the user named themselves — pixels, stops or degrees — or 0 if they named none.")
    var exact: Double

    init(operation: ModelOperation, amount: Double, exact: Double = 0) {
        self.operation = operation
        self.amount = amount
        self.exact = exact
    }
}

@Generable
nonisolated enum ModelOperation {
    case brightness, contrast, saturation, temperature, tint, sharpen, vignette, invert
    case blur, motionBlur, grain, noise, exposure, sepiaTone, lensCorrection
    case removeBackground, fillSelection
    case maskInvert, maskFeather, maskSpread, maskContrast
}

nonisolated enum AssistantModelError: LocalizedError {
    case unavailable(SystemLanguageModel.Availability)

    var errorDescription: String? {
        switch self {
        case .unavailable(.unavailable(.deviceNotEligible)):
            "This Mac does not support Apple Intelligence, so the assistant is using its smaller built-in vocabulary."
        case .unavailable(.unavailable(.modelNotReady)):
            "Apple Intelligence is still getting ready. Try again in a few minutes."
        case .unavailable:
            "Apple Intelligence is not switched on, so the assistant is using its smaller built-in vocabulary."
        }
    }
}

// MARK: - Turning what the model said into a plan

extension ModelPlan {
    /// The model's answer as an `AssistantPlan`, with every number brought back inside a range
    /// the app is willing to apply.
    ///
    /// Nothing here trusts the model. A step naming an operation that does not belong to the
    /// target is dropped rather than translated, because translating it would be guessing at an
    /// intent; if that empties the plan, the instruction is refused outright.
    func resolved(for target: AssistantTarget, instruction: String) throws -> AssistantPlan {
        let considered = Array(steps.prefix(AssistantPlan.stepLimit))
        let resolved = considered.compactMap { $0.resolved(for: target) }
        let done = self.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let couldNot = skipped.trimmingCharacters(in: .whitespacesAndNewlines)
        // A step the model named that cannot reach what is selected — a mask operation aimed at
        // a layer's pixels, say. Dropping it is right; dropping it silently is not, because the
        // user asked for it and would otherwise read the note as having got it.
        let unreachable = considered.count - resolved.count

        guard !resolved.isEmpty else {
            // No steps is a real answer when the model said why: that is how it declines. The
            // reason lives in `skipped` now, and the note is the fallback for a model that put
            // it there instead. Neither means it produced nothing, which the user has to hear.
            let reason = couldNot.isEmpty ? done : couldNot
            guard !reason.isEmpty else { throw AssistantError.notUnderstood(instruction) }
            return AssistantPlan.answer(reason)
        }
        return AssistantPlan(steps: resolved,
                             note: Self.sentences(done: done, couldNot: couldNot, unreachable: unreachable))
    }

    /// What the user reads: what ran, then anything that did not, in that order. The second half
    /// is the point — an instruction that asks for a crop and a colour fix gets the colour fix,
    /// and saying only that reads as having done both.
    static func sentences(done: String, couldNot: String, unreachable: Int) -> String {
        var parts = [done.isEmpty ? "Done." : done]
        if !couldNot.isEmpty { parts.append(couldNot) }
        if unreachable > 0 {
            parts.append(unreachable == 1
                ? "I left out one step that does not apply to what is selected."
                : "I left out \(unreachable) steps that do not apply to what is selected.")
        }
        return parts.joined(separator: " ")
    }
}

extension ModelStep {
    /// This step as something the executor can run, or `nil` when it cannot reach the target.
    func resolved(for target: AssistantTarget) -> AssistantStep? {
        let strength = ColorChange.clamp(amount, -1...1, 0)
        let named = exact.isFinite && exact != 0 ? abs(exact) : nil
        switch operation {
        case .maskInvert, .maskFeather, .maskSpread, .maskContrast:
            guard target.isMask else { return nil }
            return maskStep(strength: strength, named: named)
        default:
            guard !target.isMask else { return nil }
            return layerStep(strength: strength, named: named)
        }
    }

    private func maskStep(strength: Double, named: Double?) -> AssistantStep? {
        switch operation {
        case .maskInvert:
            .mask(MaskChange(invert: true))
        case .maskFeather:
            .mask(MaskChange(feather: named ?? abs(strength) * 20))
        case .maskSpread:
            // The sign carries the meaning here, so it is taken from `amount` even when the
            // user named a number: "choke it by 4" is -4, not 4.
            .mask(MaskChange(spread: (named ?? abs(strength) * 12) * (strength < 0 ? -1 : 1)))
        case .maskContrast:
            .mask(MaskChange(contrast: 1 + strength * 0.75))
        default:
            nil
        }
    }

    private func layerStep(strength: Double, named: Double?) -> AssistantStep? {
        switch operation {
        case .brightness: return .color(ColorChange(brightness: strength * 0.25))
        case .contrast: return .color(ColorChange(contrast: 1 + strength * 0.6))
        case .saturation: return .color(ColorChange(saturation: 1 + strength * (strength < 0 ? 1 : 1.5)))
        case .temperature: return .color(ColorChange(temperature: ColorChange.neutralTemperature + strength * 2500))
        case .tint: return .color(ColorChange(tint: strength * 60))
        case .sharpen: return .color(ColorChange(sharpness: abs(strength) * 0.8))
        case .vignette: return .color(ColorChange(vignette: abs(strength) * 1.2))
        case .invert: return .color(ColorChange(invert: true))
        case .blur: return .filter(.gaussianBlur, FilterSettings(radius: named ?? max(0.1, abs(strength) * 25)))
        case .motionBlur: return .filter(.motionBlur, FilterSettings(distance: named ?? max(1, abs(strength) * 60)))
        case .grain: return .filter(.grain, FilterSettings(grain: GrainSettings(amount: abs(strength) * 60)))
        case .noise: return .filter(.addNoise, FilterSettings(amount: max(0.1, abs(strength) * 40)))
        case .exposure:
            // `exact` is in stops here, and the sign comes from `amount` for the same reason as
            // the mask's spread.
            let stops = (named ?? abs(strength) * 2) * (strength < 0 ? -1 : 1)
            return .filter(.exposure, FilterSettings(exposure: ExposureSettings(exposure: stops)))
        case .sepiaTone:
            let sepia = GradientMapSettings(shadows: AdjustmentColor(red: 0.16, green: 0.09, blue: 0.05),
                                            highlights: AdjustmentColor(red: 1, green: 0.93, blue: 0.78))
            return .filter(.gradientMap, FilterSettings(gradientMap: sepia))
        case .lensCorrection:
            return .filter(.lensCorrection, FilterSettings(distortion: (named ?? abs(strength) * 60) * (strength < 0 ? -1 : 1)))
        case .removeBackground:
            return .filter(.removeBackground, FilterSettings(backgroundQuality: abs(strength) > 0.7 ? .advanced : .basic))
        case .fillSelection:
            return .filter(.contentAwareFill, FilterSettings())
        default:
            return nil
        }
    }
}

#endif
