import CoreGraphics
import CoreImage
import Foundation

/// What the assistant decided to do, in terms the app can execute and the user can read.
///
/// A plan exists so that the language half of the assistant and the pixel half never touch.
/// The model's only job is to produce one of these; everything below this line is ordinary,
/// testable Swift that runs with no model present at all. That split is what lets the whole
/// pixel path be covered by tests on a CI runner, where the on-device model is not available.
nonisolated struct AssistantPlan: Equatable, Sendable {
    /// Applied in order, each step's output feeding the next.
    var steps: [AssistantStep]
    /// What the assistant says it did, in the user's language. Shown in the conversation.
    var note: String

    /// Beyond this a plan is treated as a runaway rather than an instruction: each step is a
    /// full-resolution pass over the layer, so six on a 24-megapixel layer is already slow.
    static let stepLimit = 6

    init(steps: [AssistantStep], note: String) {
        self.steps = steps
        self.note = note
    }

    /// A plan that edits nothing and just says something back.
    static func answer(_ note: String) -> Self { Self(steps: [], note: note) }

    /// Rejects a plan the executor could not carry out, before any pixels are touched, so the
    /// user gets one clear reason instead of a partly applied edit.
    ///
    /// `hasSelection` is checked here rather than in the step itself because it is a fact
    /// about the document at this moment, not about the plan.
    func validated(targetIsMask: Bool, hasSelection: Bool) throws -> Self {
        guard steps.count <= Self.stepLimit else { throw AssistantPlanError.tooManySteps(steps.count) }
        for step in steps {
            try step.validate(targetIsMask: targetIsMask, hasSelection: hasSelection)
        }
        return self
    }
}

/// One operation in a plan.
///
/// Three cases rather than one because the three have genuinely different reach: `filter` is
/// the app's own Filter and Image menus, which only understand a layer's RGBA raster; `color`
/// is the colour work those menus have no entry for; `mask` is the short list of things that
/// mean anything to a single 8-bit channel.
nonisolated enum AssistantStep: Equatable, Sendable {
    /// One of the app's own filters, run at the layer's full resolution by the same
    /// `PixelFilter.run` the Filter menu uses. Nothing here is reimplemented: a plan that says
    /// "remove the background" runs the identical Vision path the menu item runs.
    case filter(FilterKind, FilterSettings)
    /// A colour grade: saturation, contrast, brightness, white balance, sharpening, vignette.
    /// These are one Core Image chain rather than one step each, so "warmer and less saturated"
    /// costs one pass over the pixels instead of two.
    case color(ColorChange)
    /// The operations a layer mask can take.
    case mask(MaskChange)

    /// The step named the way the user would name it, for the note and for error messages.
    var name: String {
        switch self {
        case .filter(let kind, _): kind.rawValue
        case .color: "Color"
        case .mask: "Mask"
        }
    }

    func validate(targetIsMask: Bool, hasSelection: Bool) throws {
        switch self {
        case .filter(let kind, _):
            // `PixelFilter.run` builds RGBA contexts throughout and blends with `isMask: false`.
            // Handing it an 8-bit gray mask would not fail loudly, it would produce garbage.
            guard !targetIsMask else { throw AssistantPlanError.notForMask(name) }
            // Content-Aware Fill synthesizes over the selection from what surrounds it, so
            // without a selection there is nothing for it to fill.
            if kind == .contentAwareFill, !hasSelection { throw AssistantPlanError.needsSelection(name) }
        case .color:
            guard !targetIsMask else { throw AssistantPlanError.notForMask(name) }
        case .mask:
            guard targetIsMask else { throw AssistantPlanError.onlyForMask }
        }
    }
}

nonisolated enum AssistantPlanError: LocalizedError, Equatable {
    case tooManySteps(Int)
    case notForMask(String)
    case onlyForMask
    case needsSelection(String)
    case emptyStep

    var errorDescription: String? {
        switch self {
        case .needsSelection(let name):
            "\(name) works over a selection, and nothing is selected. Select the part you want "
                + "it to work on first."
        case .tooManySteps(let count):
            "The assistant came back with \(count) steps for one instruction, which is more than "
                + "it is allowed to apply at once. Try asking for one change at a time."
        case .notForMask(let name):
            "\(name) works on a layer's pixels, and the layer mask is selected. Select the layer "
                + "itself to use it."
        case .onlyForMask:
            "That only applies to a layer mask, and the layer's pixels are selected."
        case .emptyStep:
            "The assistant produced a step that would not change anything."
        }
    }
}

// MARK: - Colour

/// A colour grade, as one clamped set of numbers.
///
/// Every field's neutral value is its default, so a change built from nothing does nothing,
/// and `isNeutral` can skip the render entirely. The ranges are deliberately narrower than
/// Core Image's: they are what a model is allowed to ask for, and a model asking for
/// saturation 400 gets 3, not a ruined layer.
nonisolated struct ColorChange: Equatable, Sendable {
    static let saturationRange: ClosedRange<Double> = 0...3
    static let contrastRange: ClosedRange<Double> = 0.25...4
    static let brightnessRange: ClosedRange<Double> = -1...1
    static let temperatureRange: ClosedRange<Double> = 2000...12000
    static let tintRange: ClosedRange<Double> = -150...150
    static let sharpnessRange: ClosedRange<Double> = 0...2
    static let vignetteRange: ClosedRange<Double> = 0...2
    /// Core Image's own neutral white point, and so the value that means "leave it alone".
    static let neutralTemperature: Double = 6500

    /// 1 leaves colour alone, 0 takes it all out, above 1 deepens it.
    var saturation: Double = 1
    /// 1 leaves contrast alone.
    var contrast: Double = 1
    /// 0 leaves brightness alone; this is Core Image's additive brightness, not a gamma.
    var brightness: Double = 0
    /// The white point the image is graded towards, in kelvin. Above 6500 warms it, below
    /// cools it — which reads backwards until you remember it is the light being described,
    /// not the picture.
    var temperature: Double = ColorChange.neutralTemperature
    /// Green (negative) to magenta (positive), the other half of white balance.
    var tint: Double = 0
    /// 0 leaves sharpness alone. This is luminance-only sharpening, so it does not fringe.
    var sharpness: Double = 0
    /// 0 leaves the corners alone; above that darkens them.
    var vignette: Double = 0
    /// Turns the image into its negative. Applied first, so a grade described alongside it
    /// grades the negative rather than the original.
    var invert = false

    var normalized: Self {
        var result = self
        result.saturation = Self.clamp(saturation, Self.saturationRange, 1)
        result.contrast = Self.clamp(contrast, Self.contrastRange, 1)
        result.brightness = Self.clamp(brightness, Self.brightnessRange, 0)
        result.temperature = Self.clamp(temperature, Self.temperatureRange, Self.neutralTemperature)
        result.tint = Self.clamp(tint, Self.tintRange, 0)
        result.sharpness = Self.clamp(sharpness, Self.sharpnessRange, 0)
        result.vignette = Self.clamp(vignette, Self.vignetteRange, 0)
        return result
    }

    /// True when every field is at its neutral, i.e. rendering this would be a no-op.
    var isNeutral: Bool {
        let n = normalized
        if n.invert { return false }
        return n.saturation == 1 && n.contrast == 1 && n.brightness == 0
            && n.temperature == Self.neutralTemperature && n.tint == 0 && n.sharpness == 0 && n.vignette == 0
    }

    /// The chain, neutral stages left out. Built as a sequence of statements rather than one
    /// chained expression: the file next door has a note about the type checker timing out on
    /// long Core Image chains, and this is one.
    func apply(to input: CIImage) -> CIImage {
        let settings = normalized
        var image = input
        if settings.invert {
            image = image.applyingFilter("CIColorInvert")
        }
        if settings.saturation != 1 || settings.contrast != 1 || settings.brightness != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: settings.saturation,
                kCIInputContrastKey: settings.contrast,
                kCIInputBrightnessKey: settings.brightness,
            ])
        }
        if settings.temperature != Self.neutralTemperature || settings.tint != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: Self.neutralTemperature, y: 0),
                "inputTargetNeutral": CIVector(x: settings.temperature, y: settings.tint),
            ])
        }
        if settings.sharpness != 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: settings.sharpness,
            ])
        }
        if settings.vignette != 0 {
            image = image.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: settings.vignette,
                kCIInputRadiusKey: 1.0,
            ])
        }
        return image
    }

    static func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

// MARK: - Masks

/// What can be done to a layer mask, which is one 8-bit channel and so has no colour to change.
///
/// The order the fields are applied in is fixed and is the order a retoucher would use: turn it
/// around, move the edge, soften it, then harden the greys that are left.
nonisolated struct MaskChange: Equatable, Sendable {
    static let featherRange: ClosedRange<Double> = 0...100
    static let spreadRange: ClosedRange<Double> = -50...50
    static let contrastRange: ClosedRange<Double> = 0.25...4

    /// Swaps what is hidden for what is shown.
    var invert = false
    /// Softens the matte's edge, in mask pixels.
    var feather: Double = 0
    /// Positive grows the matte outwards, negative pulls it in, in mask pixels.
    var spread: Double = 0
    /// Pushes the matte's greys towards black and white; 1 leaves them alone.
    var contrast: Double = 1

    var normalized: Self {
        var result = self
        result.feather = ColorChange.clamp(feather, Self.featherRange, 0)
        result.spread = ColorChange.clamp(spread, Self.spreadRange, 0)
        result.contrast = ColorChange.clamp(contrast, Self.contrastRange, 1)
        return result
    }

    var isNeutral: Bool {
        let n = normalized
        return !n.invert && n.feather == 0 && n.spread == 0 && n.contrast == 1
    }

    func apply(to input: CIImage) -> CIImage {
        let settings = normalized
        var image = input
        if settings.invert {
            image = image.applyingFilter("CIColorInvert")
        }
        if settings.spread != 0 {
            // Morphology reads past the edge of the extent, so clamp first and crop back, the
            // same guard the blur below needs.
            let name = settings.spread > 0 ? "CIMorphologyMaximum" : "CIMorphologyMinimum"
            let grown = image.clampedToExtent().applyingFilter(name, parameters: [
                kCIInputRadiusKey: abs(settings.spread),
            ])
            image = grown.cropped(to: input.extent)
        }
        if settings.feather != 0 {
            // Clamped, or the blur pulls black in from beyond the edge and eats the matte's border.
            let softened = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: settings.feather,
            ])
            image = softened.cropped(to: input.extent)
        }
        if settings.contrast != 1 {
            image = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: settings.contrast])
        }
        return image
    }
}

// MARK: - Execution

/// Turning a plan into pixels.
///
/// Deliberately has no opinion about where the plan came from: the same function runs a plan
/// from the on-device model, from the keyword planner, and from a test's literal.
nonisolated enum AssistantPlanRunner {
    /// Every step applied in order at the target's own resolution.
    ///
    /// `selection` is passed for one reason only: Content-Aware Fill needs to know what to fill.
    /// Every other step gets `selection: nil`, because `EditorSession` blends the finished
    /// result back through the selection itself — doing it here as well would blend twice and
    /// square the coverage at soft edges, which shows up as a selection edge that looks eaten.
    static func run(_ plan: AssistantPlan, on source: CGImage, targetIsMask: Bool,
                    selection: SelectionClip?, pixelToDocument: CGAffineTransform,
                    seed: UInt32) async throws -> CGImage {
        // Validated again here, although every caller already has. The cost is a walk over at
        // most six steps; the thing it stops is a layer filter running against an 8-bit matte,
        // which does not throw — it writes garbage into someone's document.
        let plan = try plan.validated(targetIsMask: targetIsMask, hasSelection: selection != nil)
        var image = source
        for step in plan.steps {
            try Task.checkCancellation()
            image = try apply(step, to: image, targetIsMask: targetIsMask,
                              selection: selection, pixelToDocument: pixelToDocument, seed: seed)
        }
        return image
    }

    private static func apply(_ step: AssistantStep, to image: CGImage, targetIsMask: Bool,
                              selection: SelectionClip?, pixelToDocument: CGAffineTransform,
                              seed: UInt32) throws -> CGImage {
        switch step {
        case .filter(let kind, let settings):
            let job = FilterJob(kind: kind, image: image, settings: settings,
                                // The backend is handed the layer's own full-resolution raster,
                                // never a preview, so a blur radius in layer pixels is a blur
                                // radius in these pixels.
                                scale: 1,
                                selection: kind == .contentAwareFill ? selection : nil,
                                mapping: pixelToDocument, seed: seed)
            return try PixelFilter.run(job)
        case .color(let change):
            guard !change.isNeutral else { throw AssistantPlanError.emptyStep }
            let graded = change.apply(to: CIImage(cgImage: image))
            return try PixelAdjust.render(graded.cropped(to: CGRect(x: 0, y: 0, width: image.width, height: image.height)),
                                          width: image.width, height: image.height, isMask: targetIsMask)
        case .mask(let change):
            guard !change.isNeutral else { throw AssistantPlanError.emptyStep }
            let changed = change.apply(to: CIImage(cgImage: image))
            return try PixelAdjust.render(changed.cropped(to: CGRect(x: 0, y: 0, width: image.width, height: image.height)),
                                          width: image.width, height: image.height, isMask: true)
        }
    }
}
