import CoreGraphics
import Foundation
import Observation

/// The assistant panel's state: the conversation so far, the request in flight, and the last
/// error. It lives on `EditorSession` rather than in the view because `ProjectTabs` applies
/// `.id(workspace.current.id)` to `ContentView`, which throws `@State` away on every tab
/// switch — a conversation and an in-flight `Task` must not go with it.
@Observable
final class AssistantConversation {
    var turns: [AssistantTurn] = []
    /// What the user is typing.
    var draft = ""
    var isRunning = false
    var error: String?
    /// Distinguishes runs, so a cancelled one cannot clear the state of the one after it.
    @ObservationIgnored var runID = 0
    @ObservationIgnored var task: Task<Void, Never>?
}

extension EditorSession {
    /// Whether the assistant has something it can read and write back.
    ///
    /// `canPaint` alone is not enough: it is written *for* mask targets and never checks that
    /// the layer has pixels at all, so a blank layer would pass it. This is `canInvert`'s
    /// stricter tail on top.
    var canRunAssistant: Bool {
        guard canPaint else { return false }
        return isMaskSelected ? activeLayer?.mask?.isEnabled == true : activeLayer?.asset != nil
    }

    /// What the assistant is pointed at right now, for the panel to show — getting this wrong
    /// is the one mistake that silently destroys a layer's pixels.
    var assistantTargetDescription: String {
        guard let layer = activeLayer else { return "No layer selected" }
        return isMaskSelected ? "\(layer.name) · layer mask" : layer.name
    }

    func openAssistant() {
        guard document != nil else { return }
        if assistant == nil { assistant = AssistantConversation() }
    }

    func closeAssistant() {
        cancelAssistant()
        assistant = nil
    }

    /// Cancels the request in flight. Unlike the app's other Cancel buttons this one really
    /// stops the work: `submitAssistant` awaits the backend in this task rather than inside a
    /// detached one, so cancelling the task cancels the backend too.
    func cancelAssistant() {
        guard let conversation = assistant, conversation.isRunning else { return }
        conversation.task?.cancel()
        conversation.task = nil
        conversation.isRunning = false
        // The conversation is not a `DisplayState` member, so without this the canvas diff
        // compares equal and anything the run put on screen would never repaint away.
        brushRevision += 1
    }

    func submitAssistant() {
        guard let conversation = assistant, !conversation.isRunning else { return }
        let instruction = conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        conversation.draft = ""
        conversation.error = nil
        conversation.turns.append(AssistantTurn(role: .user, text: instruction))
        conversation.isRunning = true
        conversation.runID += 1
        let run = conversation.runID
        // A plain `Task`, not `Task.detached`: a detached task runs to completion whatever the
        // caller does, so `cancel()` on one would leave a remote model working and billing.
        conversation.task = Task { [weak self] in
            await self?.runAssistant(instruction, on: conversation, run: run)
        }
    }

    /// One prompt, end to end. The order of these steps is load-bearing; each comment says why.
    private func runAssistant(_ instruction: String, on conversation: AssistantConversation, run: Int) async {
        defer {
            // A cancelled run must not clear the state of the run that replaced it.
            if conversation.runID == run {
                conversation.isRunning = false
                conversation.task = nil
            }
            // Every terminal path repaints, commit and failure alike, for the reason in
            // `cancelAssistant`.
            brushRevision += 1
        }
        // Gate, and settle the target before reading anything from the layer.
        guard canRunAssistant, let document, let layer = activeLayer,
              document.layers.contains(where: { $0.id == layer.id }) else {
            conversation.error = AssistantError.noTarget.localizedDescription
            return
        }
        let targetIsMask = isMaskSelected
        guard let source = targetIsMask ? layer.mask?.asset.image : layer.asset?.image else {
            conversation.error = AssistantError.noTarget.localizedDescription
            return
        }
        // Staleness keys, captured while this is still synchronous.
        let layerID = layer.id, layerName = layer.name
        let startImage = layer.asset?.image
        let startMaskImage = layer.mask?.asset.image
        let startTransform = layer.transform
        let history = conversation.turns
        let backend = assistantBackend
        do {
            // A uniform 1x1 mask carries no shape for a model to read and cannot hold a partial
            // selection, so it gets the layer's own pixel grid first, as `invertPixels` does.
            var source = source
            if targetIsMask, source.width == 1, source.height == 1 {
                source = try AssistantPixels.normalized(source,
                    width: layer.asset?.image.width ?? Int(layer.size.width.rounded()),
                    height: layer.asset?.image.height ?? Int(layer.size.height.rounded()), isMask: true)
            }
            // A mask moved apart from its layer sits on its own grid; mapping through the
            // layer's transform instead would misregister the blend with no error at all.
            let mapping = BrushRaster.pixelToDocument(targetIsMask ? layer.maskTransform : layer.transform,
                                                      width: source.width, height: source.height)
            // Freeze the selection here, on the main actor. A live `DocumentSelection` must
            // never be carried across a suspension.
            let clip = try selection?.clip(canvas: document.size)
            let request = AssistantRequest(image: source, targetIsMask: targetIsMask,
                                           instruction: instruction, canvasSize: document.size)
            // Awaited in this task. `isProjectBusy` is deliberately *not* held across this leg:
            // a model can take seconds and the editor has to stay usable. The price is that the
            // document may change underneath, which the guard further down catches.
            let result = try await backend.run(request, history: history)
            try Task.checkCancellation()

            let produced: CGImage
            switch result.output {
            case .none:
                conversation.turns.append(AssistantTurn(role: .assistant, text: result.note))
                return
            case .pixels(let image):
                // The target is the app's to choose. A backend that returns the wrong kind is
                // refused rather than redirected, because writing pixels onto a mask target
                // destroys the layer silently.
                guard !targetIsMask else { throw AssistantError.wrongOutput(wantedMask: true) }
                produced = image
            case .mask(let image):
                guard targetIsMask else { throw AssistantError.wrongOutput(wantedMask: false) }
                produced = image
            }

            // Resample onto the target's grid and constrain to the selection, off the main
            // actor. Resampling here is what keeps the backend free to work at its own
            // resolution, and it leaves the document's pixel budget untouched.
            let made = try await AssistantPixels.asset(from: produced, over: source, through: clip,
                                                       pixelToDocument: mapping, isMask: targetIsMask,
                                                       name: layerName)
            try Task.checkCancellation()
            // The gate dropped `isProjectBusy` for the model leg, so the whole thing has to
            // hold again here, including the target.
            guard canRunAssistant, isMaskSelected == targetIsMask else { throw AssistantError.targetChanged }
            // Re-read through `self`: `document` above is the value as it was before the await.
            // By id rather than by the index captured then, because the layer may have moved.
            guard let layers = self.document?.layers,
                  let row = layers.firstIndex(where: { $0.id == layerID }) else { throw AssistantError.targetChanged }
            let current = layers[row]
            guard current.asset?.image === startImage,
                  current.mask?.asset.image === startMaskImage,
                  current.transform == startTransform else { throw AssistantError.targetChanged }
            isProjectBusy = true
            defer { isProjectBusy = false }
            // Write, synchronously, with nothing that can suspend between the brackets. The
            // `defer` is mandatory: a throw between them leaves the history depth non-zero and
            // undo dead for the rest of the session, with no rollback short of wiping it.
            beginEdit(instruction)
            defer { endEdit() }
            if targetIsMask {
                // Assign the mask directly. Rebuilding the `ImageLayer` here would be a way to
                // drop something from it for nothing.
                self.document?.layers[row].mask = current.mask.map { $0.replacing(made) } ?? LayerMask(asset: made)
                self.document?.layers[row].mask?.isEnabled = true
            } else {
                // `isGroup` and `effects` are carried, not defaulted: eight commit paths in
                // this app quietly drop a layer's drop shadow by leaving `effects` out.
                self.document?.layers[row] = ImageLayer(id: current.id, asset: made, name: current.name,
                    isVisible: current.isVisible, transform: current.transform, parentID: current.parentID,
                    isGroup: current.isGroup, opacity: current.opacity, blendMode: current.blendMode,
                    mask: current.mask, maskSourceID: current.maskSourceID, effects: current.effects)
            }
            conversation.turns.append(AssistantTurn(role: .assistant, text: result.note))
            // Nothing to call to repaint: a new `CGImage` is a new `ObjectIdentifier`, which the
            // canvas's `DisplayState` diff catches on its own, caches and all.
        } catch is CancellationError {
            // The user asked for it; the repaint is in the `defer` above.
        } catch {
            // Every other path in the app drops a stale or failed result in silence. A model
            // edit is slow enough that the user has moved on and is owed the reason.
            conversation.error = error.localizedDescription
        }
    }
}
