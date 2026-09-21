import CoreGraphics
import CoreImage
import Foundation

/// One turn of the assistant conversation, kept so a backend can read what was asked before.
nonisolated struct AssistantTurn: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable { case user, assistant }
    let id = UUID()
    let role: Role
    let text: String
}

/// What the assistant is asked to do, and the pixels it is asked to do it to.
nonisolated struct AssistantRequest: @unchecked Sendable {
    /// The target's own pixels: the layer's raster, or — when `targetIsMask` — the mask's
    /// 8-bit DeviceGray raster, which is a different format. `nil` for a turn that asks a
    /// question rather than an edit.
    let image: CGImage?
    /// True when `image` is the layer mask. The target is the app's to choose, never the
    /// backend's: a result that does not match it is refused.
    let targetIsMask: Bool
    /// The instruction in the user's own words. It also becomes the undo step's name.
    let instruction: String
    /// The canvas in document points, for a backend that needs to know where the layer sits.
    let canvasSize: CGSize
    /// The selection as it stood when the run began, frozen on the main actor, or `nil` when
    /// nothing is selected.
    ///
    /// A backend does not have to honor this and most should not: `EditorSession` blends the
    /// finished result back through the same selection, so constraining the edit here as well
    /// would apply the coverage twice and eat soft selection edges. It is carried for the one
    /// operation that cannot work without knowing the shape — Content-Aware Fill synthesizes
    /// over the selection from the pixels around it, so with no selection it has nothing to do.
    let selection: SelectionClip?
    /// Maps the target's own pixels into document space, which is the space `selection` is in.
    let pixelToDocument: CGAffineTransform

    init(image: CGImage?, targetIsMask: Bool, instruction: String, canvasSize: CGSize,
         selection: SelectionClip? = nil, pixelToDocument: CGAffineTransform = .identity) {
        self.image = image
        self.targetIsMask = targetIsMask
        self.instruction = instruction
        self.canvasSize = canvasSize
        self.selection = selection
        self.pixelToDocument = pixelToDocument
    }
}

/// What came back. A backend may work at whatever resolution suits it: the result is
/// resampled onto the target's own pixel grid before it is written.
nonisolated struct AssistantResult: @unchecked Sendable {
    enum Output {
        case pixels(CGImage)
        case mask(CGImage)
        /// The assistant answered without editing anything.
        case none
    }
    let output: Output
    /// What the assistant says it did, shown in the conversation.
    let note: String

    init(output: Output, note: String) {
        self.output = output
        self.note = note
    }
}

/// The model behind the assistant, and the one thing a new model has to implement.
///
/// `: Sendable`, deliberately not `: Actor`. Cancellation propagates through structured
/// `await`, not through actor isolation, and `: Actor` would serialize every call to one
/// backend and rule out the plain-struct fake the tests use.
///
/// Neutral on the two decisions still open: it says nothing about where inference runs, and
/// nothing about what resolution the model sees — `run` may return an image of any size.
protocol AssistantBackend: Sendable {
    /// Shown in the panel so it is always clear which model answered.
    var name: String { get }
    /// Implementations must be genuinely cancellable. The caller awaits this in its own task,
    /// so a `Task.detached { … }.value` inside would run to completion after a cancel and, for
    /// a remote model, keep burning tokens; await the work instead.
    func run(_ request: AssistantRequest, history: [AssistantTurn]) async throws -> AssistantResult
}

nonisolated enum AssistantError: LocalizedError, Equatable {
    case noTarget
    case targetChanged
    /// The backend returned pixels for a mask target, or the other way round.
    case wrongOutput(wantedMask: Bool)
    case tooLarge
    case notUnderstood(String)

    var errorDescription: String? {
        switch self {
        case .noTarget:
            "Select a layer with pixels first, or a layer mask."
        case .targetChanged:
            "The layer changed while the assistant was working, so its result was not applied. Try again."
        case .wrongOutput(let wantedMask):
            wantedMask ? "The assistant returned image pixels while the layer mask was the target."
                       : "The assistant returned a mask while the layer's pixels were the target."
        case .tooLarge:
            "The assistant returned an image beyond the 100-megapixel budget."
        case .notUnderstood(let instruction):
            "The assistant did not follow \"\(instruction)\". Try naming the change directly — "
                + "brighter, more contrast, warmer, black and white, blur, sharpen, remove the "
                + "background — or turn on Apple Intelligence for instructions in your own words."
        }
    }
}

// MARK: - Pixel plumbing

/// Putting a backend's output onto the target's own grid, in the target's own format.
nonisolated enum AssistantPixels {
    static let pixelLimit = 100_000_000

    /// The result resampled to `width` × `height`, as sRGB/RGBA8 premultiplied or as 8-bit
    /// DeviceGray. Resampling here is what lets a backend work at its own resolution, and it
    /// keeps the document's pixel budget unchanged by construction: the write-back is always
    /// exactly the size of what it replaces.
    static func normalized(_ image: CGImage, width: Int, height: Int, isMask: Bool) throws -> CGImage {
        guard width > 0, height > 0, width * height <= pixelLimit,
              image.width * image.height <= pixelLimit else { throw AssistantError.tooLarge }
        let context = try BrushRaster.context(width: width, height: height, mask: isMask)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        // Same size is an exact copy; a different size is a real resample, so it gets real
        // interpolation rather than `BrushRaster.draw`'s nearest neighbour.
        draw(image, in: rect, mask: isMask,
             quality: image.width == width && image.height == height ? .none : .high, context: context)
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }

    /// The finished asset for the target, off the main actor: the backend's output resampled
    /// onto the target's grid, constrained to the selection, and wrapped in the format the
    /// target stores. `nonisolated async` runs this off the main actor without a detached
    /// task, so cancelling the caller cancels it.
    static func asset(from produced: CGImage, over source: CGImage, through selection: SelectionClip?,
                      pixelToDocument: CGAffineTransform, isMask: Bool, name: String) async throws -> ImportedImage {
        try Task.checkCancellation()
        var image = try normalized(produced, width: source.width, height: source.height, isMask: isMask)
        if let selection {
            image = try PixelAdjust.blend(image, over: source, through: selection,
                                          pixelToDocument: pixelToDocument, isMask: isMask)
        }
        try Task.checkCancellation()
        return isMask ? try LayerMask.asset(from: image)
                      : ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: name)
    }

    /// `BrushRaster.draw`, with the interpolation left to the caller.
    private static func draw(_ image: CGImage, in rect: CGRect, mask: Bool,
                             quality: CGInterpolationQuality, context: CGContext) {
        context.saveGState()
        context.interpolationQuality = quality
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        let bounds = CGRect(origin: .zero, size: rect.size)
        if mask {
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(bounds)
            context.clip(to: bounds, mask: image)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(bounds)
        } else {
            context.setBlendMode(.copy)
            context.draw(image, in: bounds)
        }
        context.restoreGState()
    }
}
