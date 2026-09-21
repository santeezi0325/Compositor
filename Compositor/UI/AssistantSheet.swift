import SwiftUI

/// The AI assistant's panel: what has been asked so far, what to ask next, and what it is
/// pointed at. The panel is sized once when it opens, so everything in here has a fixed
/// width and a fixed transcript height — growing content must not resize the window.
struct AssistantSheet: View {
    @Bindable var session: EditorSession
    @FocusState private var promptFocused: Bool
    private var conversation: AssistantConversation? { session.assistant }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            target
            Divider()
            transcript
            if let error = conversation?.error {
                Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            prompt
        }
        .padding(20).frame(width: 380).fixedSize()
    }

    /// Named, because writing to the mask when you meant the pixels is the one mistake here
    /// that destroys work without saying anything.
    private var target: some View {
        HStack(spacing: 6) {
            Image(systemName: session.isMaskSelected ? "theatermasks" : "photo")
                .foregroundStyle(.secondary).accessibilityHidden(true)
            Text(session.assistantTargetDescription).font(.callout).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(session.assistantBackend.name).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if conversation?.turns.isEmpty != false {
                        Text("Describe the change you want on this layer. The edit lands on the layer itself, "
                             + "inside the selection if there is one, as a single undo step.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(conversation?.turns ?? []) { turn in
                        turnView(turn).id(turn.id)
                    }
                    if conversation?.isRunning == true {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Working…").font(.callout).foregroundStyle(.secondary)
                        }
                        .id(Self.workingAnchor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .frame(height: 200)
            .onChange(of: conversation?.turns.count ?? 0) { _, _ in scrollToEnd(proxy) }
            .onChange(of: conversation?.isRunning ?? false) { _, _ in scrollToEnd(proxy) }
        }
    }

    private static let workingAnchor = "assistant.working"

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if conversation?.isRunning == true { proxy.scrollTo(Self.workingAnchor, anchor: .bottom) }
        else if let last = conversation?.turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    private func turnView(_ turn: AssistantTurn) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(turn.role == .user ? "You" : "Assistant")
                .font(.caption).foregroundStyle(.secondary)
            Text(turn.text).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var prompt: some View {
        VStack(spacing: 10) {
            // Single line on purpose: Return sends. A vertical-axis field would swallow it.
            TextField("Make it warmer", text: Binding(get: { conversation?.draft ?? "" },
                                                      set: { conversation?.draft = $0 }))
                .textFieldStyle(.roundedBorder).focused($promptFocused)
                .onSubmit { session.submitAssistant() }
                .disabled(conversation?.isRunning == true)
            HStack {
                Button("Close") { session.closeAssistant() }.configuredNativeShortcut(.escape)
                Spacer()
                if conversation?.isRunning == true {
                    // Real cancellation, not the app's usual kind: the request is awaited in the
                    // session's own task, so this stops the backend rather than just discarding
                    // whatever it eventually returns.
                    Button("Cancel") { session.cancelAssistant() }
                } else {
                    Button("Send") { session.submitAssistant() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!session.canRunAssistant
                                  || conversation?.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
                }
            }
        }
        .onAppear { promptFocused = true }
    }
}
