import CoreGraphics
import Foundation

/// What the target of an edit is, which is all a planner needs to know about the document.
///
/// A planner is given this rather than the image because planning is a language problem: the
/// vocabulary that means anything to a layer's pixels and the vocabulary that means anything
/// to an 8-bit matte barely overlap, and that is the only distinction the planning half cares
/// about.
nonisolated enum AssistantTarget: Sendable {
    case layer
    case mask

    var isMask: Bool { self == .mask }
}

/// Turning an instruction in English into an `AssistantPlan`.
///
/// This is the half of the assistant a model is actually needed for, split out from
/// `AssistantBackend` so the two can be swapped independently: the pixel half below a planner
/// never changes when the model above it does, and a planner can be tested without touching a
/// pixel.
protocol AssistantPlanner: Sendable {
    /// Shown in the panel so it is clear which planner answered.
    var name: String { get }
    /// False when this planner cannot answer right now — the on-device model is switched off,
    /// the Mac is not eligible, the weights are still downloading. Checked before every run
    /// rather than cached, because a user can turn Apple Intelligence on without relaunching.
    var isReady: Bool { get }
    /// Implementations must be genuinely cancellable, for the reason on `AssistantBackend.run`.
    func plan(_ instruction: String, for target: AssistantTarget,
              history: [AssistantTurn]) async throws -> AssistantPlan
}

// MARK: - Keywords

/// A planner with no model behind it at all: a phrase table over the app's own operations.
///
/// It exists because the on-device model is not always there. `SystemLanguageModel` is
/// unavailable on an ineligible Mac, with Apple Intelligence switched off, and on a CI runner,
/// and an assistant that simply stops working in those cases is worse than one that
/// understands a useful hundred phrasings. It is also the planner the pixel tests use, since
/// it is deterministic.
///
/// It reads several clauses from one instruction and scales each by how strongly it was asked
/// for, so "warm it up a lot and soften it slightly" is two steps with two different
/// strengths. It refuses what it does not recognize rather than guessing, because a compositor
/// that silently does the wrong thing to a layer is worse than one that says it did not follow.
nonisolated struct KeywordAssistantPlanner: AssistantPlanner {
    let name = "Keywords"
    var isReady: Bool { true }

    func plan(_ instruction: String, for target: AssistantTarget,
              history: [AssistantTurn]) async throws -> AssistantPlan {
        try Task.checkCancellation()
        // History is deliberately ignored: a phrase table cannot resolve "do that again" or
        // "a bit more" without inventing an intent, and inventing one is the failure mode this
        // planner exists to avoid.
        let text = Self.canonicalized(instruction)
        var steps: [AssistantStep] = []
        var notes: [String] = []
        for clause in Self.clauses(text) {
            guard let match = Self.match(clause, for: target) else { continue }
            steps.append(match.step)
            notes.append(match.note)
        }
        guard !steps.isEmpty else { throw AssistantError.notUnderstood(instruction) }
        return AssistantPlan(steps: steps, note: Self.sentence(from: notes))
    }

    // MARK: Reading the instruction

    /// Lowercased, with the few phrases that contain "and" folded into single words so that
    /// splitting on "and" below cannot cut one of them in half.
    static func canonicalized(_ instruction: String) -> String {
        var text = instruction.lowercased()
        for (phrase, word) in [("black and white", "monochrome"), ("black & white", "monochrome"),
                               ("black-and-white", "monochrome"), ("grayscale", "monochrome"),
                               ("greyscale", "monochrome")] {
            text = text.replacingOccurrences(of: phrase, with: word)
        }
        return text
    }

    /// One instruction split into the separate things it asks for.
    static func clauses(_ text: String) -> [String] {
        var parts = [text]
        for separator in [",", ";", " and ", " then ", " also ", " plus ", " & "] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// How hard the clause asked, as a multiplier on whatever the edit's normal strength is.
    /// 1 when nothing says otherwise.
    static func intensity(in clause: String) -> Double {
        let strong = ["a lot", "much ", "very ", "really ", "way ", "dramatically", "heavily",
                      "massively", "hugely", "far "]
        let weak = ["slightly", "a bit", "a little", "a touch", "barely", "subtle", "just a"]
        if weak.contains(where: { clause.contains($0) }) { return 0.5 }
        if strong.contains(where: { clause.contains($0) }) { return 2 }
        return 1
    }

    /// The first number written in the clause, so "blur by 12 pixels" means 12 rather than the
    /// default radius. Hand-scanned rather than matched with a regex: the only shape that has
    /// to be read is a run of digits with an optional decimal point.
    static func number(in clause: String) -> Double? {
        var digits = ""
        for character in clause {
            if character.isNumber || (character == "." && !digits.isEmpty && !digits.contains(".")) {
                digits.append(character)
            } else if !digits.isEmpty {
                break
            }
        }
        guard let value = Double(digits), value.isFinite else { return nil }
        return value
    }

    /// Joins the per-clause notes into one sentence, since the panel shows one line per turn.
    static func sentence(from notes: [String]) -> String {
        switch notes.count {
        case 0: "Done."
        case 1: notes[0]
        default: notes.dropLast().joined(separator: " ") + " " + notes[notes.count - 1]
        }
    }

    // MARK: The phrase table

    struct Match {
        let step: AssistantStep
        let note: String
    }

    /// The first rule whose phrases appear in the clause. Order is priority, so the specific
    /// phrases come before the general ones they contain: "motion blur" must be read before
    /// "blur", and "remove the background" before a bare "remove".
    static func match(_ clause: String, for target: AssistantTarget) -> Match? {
        target.isMask ? matchMask(clause) : matchLayer(clause)
    }

    static func matchLayer(_ clause: String) -> Match? {
        let strength = intensity(in: clause)
        let written = number(in: clause)
        func has(_ phrases: [String]) -> Bool { phrases.contains { clause.contains($0) } }
        func color(_ change: ColorChange, _ note: String) -> Match {
            Match(step: .color(change), note: note)
        }
        func filter(_ kind: FilterKind, _ settings: FilterSettings, _ note: String) -> Match {
            Match(step: .filter(kind, settings), note: note)
        }

        // Exposure in stops is read before "brighter" and "darker" so that a clause naming a
        // number of stops gets the real Exposure adjustment rather than a flat brightness shift.
        if has(["stop", "exposure"]) {
            let down = has(["down", "reduce", "less", "lower", "darker", "under"])
            let stops = (written ?? strength) * (down ? -1 : 1)
            return filter(.exposure, FilterSettings(exposure: ExposureSettings(exposure: stops)),
                          "Moved the exposure \(abs(stops).rounded(toPlaces: 1)) stops \(down ? "down" : "up").")
        }
        if has(["remove the background", "remove background", "cut out the subject", "cut out the background",
                "knock out the background", "isolate the subject", "drop the background", "no background"]) {
            // The Advanced matte refines the mask against the layer's own detail, which is what
            // recovers hair — worth the extra time only when the user asked for a careful job.
            let careful = strength > 1 || has(["careful", "hair", "fur", "precise", "clean"])
            return filter(.removeBackground, FilterSettings(backgroundQuality: careful ? .advanced : .basic),
                          careful ? "Removed the background, refining the edge." : "Removed the background.")
        }
        if has(["content-aware", "content aware", "fill the selection", "fill in the selection",
                "patch", "remove the selected", "erase the selected", "fill it in"]) {
            return filter(.contentAwareFill, FilterSettings(), "Filled the selection from what surrounds it.")
        }
        if has(["motion blur", "streak", "panned", "camera shake"]) {
            return filter(.motionBlur, FilterSettings(distance: written ?? 20 * strength),
                          "Added a motion blur.")
        }
        if has(["blur", "soften", "out of focus", "defocus", "dreamy"]) {
            return filter(.gaussianBlur, FilterSettings(radius: written ?? 4 * strength), "Softened it.")
        }
        if has(["grain", "filmic", "film look", "analog", "analogue"]) {
            return filter(.grain, FilterSettings(grain: GrainSettings(amount: min(100, 25 * strength))),
                          "Added film grain.")
        }
        if has(["noise", "speckle", "static"]) {
            return filter(.addNoise, FilterSettings(amount: written ?? 10 * strength), "Added noise.")
        }
        if has(["sepia", "duotone", "old photo", "vintage tone", "toned"]) {
            let sepia = GradientMapSettings(shadows: AdjustmentColor(red: 0.16, green: 0.09, blue: 0.05),
                                            highlights: AdjustmentColor(red: 1, green: 0.93, blue: 0.78))
            return filter(.gradientMap, FilterSettings(gradientMap: sepia), "Toned it sepia.")
        }
        if has(["distortion", "barrel", "pincushion", "lens"]) {
            let pincushion = clause.contains("pincushion")
            let amount = (written ?? 30 * strength) * (pincushion ? -1 : 1)
            return filter(.lensCorrection, FilterSettings(distortion: amount), "Straightened the lens distortion.")
        }
        if has(["monochrome", "desaturate", "take the color out", "take the colour out", "no color", "no colour"]) {
            let full = has(["monochrome"]) || strength > 1
            return color(ColorChange(saturation: full ? 0 : max(0, 1 - 0.4 * strength)),
                         full ? "Took the color out." : "Took some of the color out.")
        }
        if has(["saturate", "more color", "more colour", "vivid", "punchy", "richer", "vibrant"]) {
            return color(ColorChange(saturation: 1 + 0.35 * strength), "Deepened the color.")
        }
        if has(["warmer", "warm it", "warm up", "warmer tone", "golden", "sunnier"]) {
            return color(ColorChange(temperature: ColorChange.neutralTemperature + 900 * strength), "Warmed it up.")
        }
        if has(["cooler", "cool it", "cool down", "colder", "bluer"]) {
            return color(ColorChange(temperature: ColorChange.neutralTemperature - 900 * strength), "Cooled it down.")
        }
        if has(["more contrast", "punchier", "contrastier", "crush the blacks"]) {
            return color(ColorChange(contrast: 1 + 0.25 * strength), "Added contrast.")
        }
        if has(["less contrast", "flatter", "flat", "lift the blacks", "faded"]) {
            return color(ColorChange(contrast: max(0.25, 1 - 0.25 * strength)), "Took the contrast down.")
        }
        if has(["contrast"]) {
            return color(ColorChange(contrast: 1 + 0.25 * strength), "Added contrast.")
        }
        if has(["sharpen", "sharper", "crisper", "crispier"]) {
            return color(ColorChange(sharpness: 0.4 * strength), "Sharpened it.")
        }
        if has(["vignette", "darken the corners", "darken the edges"]) {
            return color(ColorChange(vignette: min(ColorChange.vignetteRange.upperBound, 0.5 * strength)),
                         "Darkened the corners.")
        }
        if has(["invert", "negative", "flip the colors", "flip the colours"]) {
            return color(ColorChange(invert: true), "Inverted the colors.")
        }
        if has(["brighter", "brighten", "lighter", "lighten", "lift it"]) {
            return color(ColorChange(brightness: 0.12 * strength), "Brightened it.")
        }
        if has(["darker", "darken", "dimmer", "moodier"]) {
            return color(ColorChange(brightness: -0.12 * strength), "Darkened it.")
        }
        return nil
    }

    static func matchMask(_ clause: String) -> Match? {
        let strength = intensity(in: clause)
        let written = number(in: clause)
        func has(_ phrases: [String]) -> Bool { phrases.contains { clause.contains($0) } }
        func mask(_ change: MaskChange, _ note: String) -> Match { Match(step: .mask(change), note: note) }

        if has(["invert", "flip", "swap", "other way", "opposite"]) {
            return mask(MaskChange(invert: true), "Inverted the mask.")
        }
        if has(["feather", "soften", "blur", "smooth the edge", "softer edge"]) {
            return mask(MaskChange(feather: written ?? 6 * strength), "Feathered the mask.")
        }
        if has(["choke", "contract", "pull it in", "pull in", "shrink", "tighter", "inset"]) {
            return mask(MaskChange(spread: -(written ?? 4 * strength)), "Pulled the mask in.")
        }
        if has(["spread", "expand", "grow", "widen", "wider", "outset"]) {
            return mask(MaskChange(spread: written ?? 4 * strength), "Spread the mask out.")
        }
        if has(["harden", "crisp", "sharpen", "clean up", "tighten", "punch"]) {
            return mask(MaskChange(contrast: 1 + 0.6 * strength), "Hardened the mask's edge.")
        }
        return nil
    }
}

extension Double {
    /// Rounded for display in a note, so a computed strength does not read as 1.2000000000002.
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
