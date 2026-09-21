import AppKit
import CoreImage
import Testing
@testable import Compositor

/// A backend the test supplies the answer for. `@unchecked Sendable` because it carries a
/// closure over `CGImage`, which is what every raster type in this app does.
struct StubAssistantBackend: AssistantBackend, @unchecked Sendable {
    let name = "Stub"
    let answer: @Sendable (AssistantRequest) throws -> AssistantResult
    func run(_ request: AssistantRequest, history: [AssistantTurn]) async throws -> AssistantResult {
        try Task.checkCancellation()
        return try answer(request)
    }
}

/// Waits until it is cancelled, and records that it was reached.
final class HangingAssistantBackend: AssistantBackend, @unchecked Sendable {
    let name = "Hanging"
    private let lock = NSLock()
    private var _started = false
    var started: Bool { lock.lock(); defer { lock.unlock() }; return _started }

    func run(_ request: AssistantRequest, history: [AssistantTurn]) async throws -> AssistantResult {
        lock.lock(); _started = true; lock.unlock()
        try await Task.sleep(for: .seconds(30))
        return AssistantResult(output: .none, note: "never")
    }
}

/// Carries a request out of a stub closure that runs off the test's own actor.
final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var request: AssistantRequest?
    func record(_ request: AssistantRequest) { lock.lock(); self.request = request; lock.unlock() }
    var seen: AssistantRequest? { lock.lock(); defer { lock.unlock() }; return request }
}

/// Raster fixtures. Outside the test type so the stub closures, which run off the test's
/// own actor, capture nothing main-actor-isolated.
nonisolated enum TestRasters {
    static func inverted(_ image: CGImage?) throws -> CGImage {
        guard let image else { throw AssistantError.noTarget }
        return try PixelAdjust.render(CIImage(cgImage: image).applyingFilter("CIColorInvert"),
                                      width: image.width, height: image.height, isMask: false)
    }

    /// A solid RGBA image of one color, at any size the caller likes.
    static func solid(_ gray: CGFloat, width: Int, height: Int) throws -> CGImage {
        let ctx = try BrushRaster.context(width: width, height: height, mask: false)
        ctx.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { throw ExportError.render }
        return image
    }

    static func solidMask(_ gray: CGFloat, width: Int, height: Int) throws -> CGImage {
        let ctx = try BrushRaster.context(width: width, height: height, mask: true)
        ctx.setFillColor(gray: gray, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { throw ExportError.render }
        return image
    }
}

@MainActor struct AssistantTests {
    /// A 64x48 blue layer with a red block in it, and no selection.
    private func fixture() throws -> EditorSession {
        let s = EditorSession()
        s.createDocument(width: 64, height: 48)
        let ctx = try BrushRaster.context(width: 64, height: 48, mask: false)
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 16, width: 12, height: 10))
        let image = try #require(ctx.makeImage())
        s.insert(ImportedImage(image: image, thumbnail: image, name: "Object"))
        return s
    }

    /// Sends a prompt and waits for the whole round trip.
    @discardableResult
    private func send(_ s: EditorSession, _ prompt: String) async throws -> AssistantConversation {
        s.openAssistant()
        let conversation = try #require(s.assistant)
        conversation.draft = prompt
        s.submitAssistant()
        let task = try #require(conversation.task)
        await task.value
        return conversation
    }

    private func pixels(of image: CGImage) throws -> (data: UnsafePointer<UInt8>, rowBytes: Int, context: CGContext) {
        let ctx = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: ctx)
        let data = try #require(ctx.data)
        return (UnsafePointer(data.assumingMemoryBound(to: UInt8.self)), ctx.bytesPerRow, ctx)
    }

    // MARK: The loop

    @Test func promptReplacesThePixelsAndUndoesInOneStep() async throws {
        let s = try fixture()
        let original = try #require(s.activeLayer?.asset?.image)
        s.assistantBackend = StubAssistantBackend { request in
            AssistantResult(output: .pixels(try TestRasters.inverted(request.image)), note: "Inverted it.")
        }
        let undoCount = s.history.undoCount
        let conversation = try await send(s, "invert the colors")

        let result = try #require(s.activeLayer?.asset?.image)
        #expect(result !== original, "A new CGImage is what makes the canvas repaint")
        #expect(s.history.undoCount == undoCount + 1, "The whole edit is one undo step")
        #expect(s.history.undoName == "invert the colors", "The undo step is named with the user's own words")
        #expect(conversation.turns.map(\.role) == [.user, .assistant])
        #expect(conversation.error == nil)
        #expect(conversation.isRunning == false)

        s.undo()
        #expect(s.activeLayer?.asset?.image === original, "Undo restores the very same CGImage")
    }

    @Test func requestCarriesTheInstructionAndTheLayersOwnPixels() async throws {
        let s = try fixture()
        let original = try #require(s.activeLayer?.asset?.image)
        let recorder = RequestRecorder()
        s.assistantBackend = StubAssistantBackend { request in
            recorder.record(request)
            return AssistantResult(output: .pixels(try TestRasters.inverted(request.image)), note: "Done.")
        }
        _ = try await send(s, "make it warmer")
        let request = try #require(recorder.seen)
        #expect(request.instruction == "make it warmer")
        #expect(request.image === original)
        #expect(request.targetIsMask == false)
        #expect(request.canvasSize == CGSize(width: 64, height: 48))
    }

    // MARK: Resolution

    @Test func resultAtTheModelsOwnResolutionIsResampledOntoTheLayer() async throws {
        let s = try fixture()
        // Half size, so the backend is exercising the resolution-agnostic path.
        s.assistantBackend = StubAssistantBackend { _ in
            AssistantResult(output: .pixels(try TestRasters.solid(0.5, width: 32, height: 24)), note: "Done.")
        }
        _ = try await send(s, "flatten it")
        let result = try #require(s.activeLayer?.asset?.image)
        #expect(result.width == 64 && result.height == 48, "The write-back is always the target's own size")
        let read = try pixels(of: result)
        // Mid gray through sRGB, sampled away from any edge.
        #expect(abs(Int(read.data[24 * read.rowBytes + 32 * 4]) - 128) <= 2)
    }

    @Test func aResultBeyondThePixelBudgetIsRefused() throws {
        let tiny = try TestRasters.solid(0.5, width: 2, height: 2)
        #expect(throws: AssistantError.tooLarge) {
            _ = try AssistantPixels.normalized(tiny, width: 20_000, height: 20_000, isMask: false)
        }
    }

    // MARK: Selection

    @Test func theEditStaysInsideTheSelection() async throws {
        let s = try fixture()
        s.applySelection(CGPath(rect: CGRect(x: 20, y: 16, width: 12, height: 10), transform: nil),
                         mode: .replace, name: "Select")
        s.assistantBackend = StubAssistantBackend { _ in
            AssistantResult(output: .pixels(try TestRasters.solid(0, width: 64, height: 48)), note: "Blacked it out.")
        }
        _ = try await send(s, "black it out")
        let read = try pixels(of: try #require(s.activeLayer?.asset?.image))
        // Inside the selection: black.
        #expect(read.data[20 * read.rowBytes + 24 * 4] < 8)
        // Outside it: still the blue background, untouched.
        #expect(read.data[4 * read.rowBytes + 4 * 4 + 2] > 180)
    }

    // MARK: The mask target

    @Test func aMaskTargetWritesTheMaskAndLeavesThePixelsAlone() async throws {
        let s = try fixture()
        s.addMask(revealing: true)
        s.isMaskSelected = true
        let originalPixels = try #require(s.activeLayer?.asset?.image)
        let originalMask = try #require(s.activeLayer?.mask?.asset.image)
        let recorder = RequestRecorder()
        s.assistantBackend = StubAssistantBackend { request in
            recorder.record(request)
            return AssistantResult(output: .mask(try TestRasters.solidMask(0, width: 64, height: 48)), note: "Hid it.")
        }
        let undoCount = s.history.undoCount
        let conversation = try await send(s, "hide the layer")

        #expect(conversation.error == nil)
        // The uniform 1x1 mask is given the layer's grid before the model sees it, or there
        // would be nothing for it to work with.
        #expect(recorder.seen?.targetIsMask == true)
        #expect(recorder.seen?.image?.width == 64 && recorder.seen?.image?.height == 48)
        #expect(s.activeLayer?.asset?.image === originalPixels, "A mask edit must not touch the layer's pixels")
        #expect(s.activeLayer?.mask?.asset.image !== originalMask)
        #expect(s.activeLayer?.mask?.isEnabled == true)
        #expect(s.history.undoCount == undoCount + 1)
    }

    @Test func pixelsAreRefusedWhileTheMaskIsTheTarget() async throws {
        let s = try fixture()
        s.addMask(revealing: true)
        s.isMaskSelected = true
        let originalPixels = try #require(s.activeLayer?.asset?.image)
        s.assistantBackend = StubAssistantBackend { _ in
            AssistantResult(output: .pixels(try TestRasters.solid(0, width: 64, height: 48)), note: "Wrong target.")
        }
        let undoCount = s.history.undoCount
        let conversation = try await send(s, "black it out")

        #expect(s.activeLayer?.asset?.image === originalPixels, "The layer's pixels survive a wrong-target result")
        #expect(s.history.undoCount == undoCount, "A refused result makes no undo step")
        #expect(conversation.error != nil, "And the user is told, rather than left guessing")
        #expect(conversation.turns.map(\.role) == [.user], "Nothing is claimed in the transcript")
    }

    // MARK: Failure and cancellation

    @Test func aBackendErrorIsReportedAndChangesNothing() async throws {
        let s = try fixture()
        let original = try #require(s.activeLayer?.asset?.image)
        s.assistantBackend = StubAssistantBackend { _ in throw AssistantError.noTarget }
        let undoCount = s.history.undoCount
        let conversation = try await send(s, "do something impossible")

        #expect(s.activeLayer?.asset?.image === original)
        #expect(s.history.undoCount == undoCount)
        #expect(conversation.error != nil)
        #expect(conversation.isRunning == false)
        #expect(s.isProjectBusy == false, "A failure must not leave the editor wedged")
    }

    @Test func cancelStopsTheBackendAndLeavesNoUndoStep() async throws {
        let s = try fixture()
        let original = try #require(s.activeLayer?.asset?.image)
        let backend = HangingAssistantBackend()
        s.assistantBackend = backend
        let undoCount = s.history.undoCount
        s.openAssistant()
        let conversation = try #require(s.assistant)
        conversation.draft = "take your time"
        s.submitAssistant()
        let task = try #require(conversation.task)
        // Let the request reach the backend before pulling the rug.
        while !backend.started { try await Task.sleep(for: .milliseconds(5)) }

        s.cancelAssistant()
        await task.value

        #expect(conversation.isRunning == false)
        #expect(s.activeLayer?.asset?.image === original)
        #expect(s.history.undoCount == undoCount, "A cancelled edit adds no undo step")
        #expect(conversation.error == nil, "Cancelling is not an error")
        #expect(s.isProjectBusy == false)
    }

    // MARK: Things the surrounding code gets wrong

    @Test func layerEffectsSurviveTheWriteBack() async throws {
        let s = try fixture()
        var effects = LayerEffects()
        effects.shadow = ShadowEffect()
        s.document?.layers[0].effects = effects
        s.assistantBackend = StubAssistantBackend { request in
            AssistantResult(output: .pixels(try TestRasters.inverted(request.image)), note: "Done.")
        }
        _ = try await send(s, "invert it")
        #expect(s.activeLayer?.effects == effects,
                "Eight commit paths in this app drop a drop shadow here; this one must not")
    }

    @Test func aBlankLayerIsNotSomethingTheAssistantWillTouch() async throws {
        let s = EditorSession()
        s.createDocument(width: 32, height: 32)
        s.addBlankLayer()
        #expect(s.activeLayer?.asset == nil)
        // `canPaint` is true here — it never checks that the layer has any pixels.
        #expect(s.canRunAssistant == false)
    }

    // MARK: The shipping backend

    @Test func theAssistantEditsWhatItUnderstands() async throws {
        let s = try fixture()
        // Pinned to the phrase table: on a Mac where Apple Intelligence is on, the standard
        // backend would plan with the model instead and this would not be a fixed assertion.
        s.assistantBackend = PlanningAssistantBackend(planners: [KeywordAssistantPlanner()])
        let original = try #require(s.activeLayer?.asset?.image)
        let conversation = try await send(s, "make it black and white")
        #expect(conversation.error == nil)
        #expect(s.activeLayer?.asset?.image !== original)
        let read = try pixels(of: try #require(s.activeLayer?.asset?.image))
        let r = Int(read.data[4 * read.rowBytes + 4 * 4])
        let b = Int(read.data[4 * read.rowBytes + 4 * 4 + 2])
        #expect(abs(r - b) <= 2, "Desaturated, so the channels agree")
    }

    @Test func theAssistantSaysSoRatherThanGuessing() async throws {
        let s = try fixture()
        s.assistantBackend = PlanningAssistantBackend(planners: [KeywordAssistantPlanner()])
        let original = try #require(s.activeLayer?.asset?.image)
        let conversation = try await send(s, "put a hat on the cat")
        #expect(s.activeLayer?.asset?.image === original)
        #expect(conversation.error?.contains("did not follow") == true)
    }
}
