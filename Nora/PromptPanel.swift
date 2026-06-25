import AppKit
import SwiftUI

extension Notification.Name {
    static let promptPanelShouldFocus = Notification.Name("PromptPanelShouldFocus")
}

final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class PromptPanelController {
    private var panel: NSPanel?

    func toggle() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }

        show()
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel

        position(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .promptPanelShouldFocus, object: nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = PromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 90),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(
            rootView: PromptPanelView { [weak panel] height in
                guard let panel else { return }
                Self.resize(panel, to: height)
            }
        )

        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else {
            panel.center()
            return
        }

        let visibleFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let x = visibleFrame.midX - panelSize.width / 2
        let y = visibleFrame.maxY - panelSize.height - 120
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private static func resize(_ panel: NSPanel, to height: CGFloat) {
        let clampedHeight = min(max(height, 90), 320)
        guard abs(panel.frame.height - clampedHeight) > 0.5 else { return }

        var frame = panel.frame
        frame.origin.y += frame.height - clampedHeight
        frame.size.height = clampedHeight
        panel.setFrame(frame, display: true, animate: false)
    }
}

struct PromptPanelView: View {
    private let models = [
        GemmaModel(id: "gemma4", displayName: "Gemma 4"),
        GemmaModel(id: "gemma4:2b", displayName: "Gemma 4 2B"),
        GemmaModel(id: "gemma4:12b", displayName: "Gemma 4 12B"),
        GemmaModel(id: "gemma4:26b", displayName: "Gemma 4 26B"),
        GemmaModel(id: "gemma4:31b", displayName: "Gemma 4 31B")
    ]
    private let client = GemmaClient()
    private let onHeightChange: (CGFloat) -> Void

    @State private var prompt = ""
    @State private var selectedModel = GemmaModel(id: "gemma4", displayName: "Gemma 4")
    @State private var editorHeight: CGFloat = 24
    @State private var focusRequest = 0
    @State private var isSending = false
    @State private var activeTask: Task<Void, Never>?
    @State private var inFlightPrompt = ""
    @State private var responseText = ""
    @State private var errorText = ""

    private var canSend: Bool {
        !isSending && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasStatusContent: Bool {
        isSending || !responseText.isEmpty || !errorText.isEmpty
    }

    private var panelHeight: CGFloat {
        let statusHeight: CGFloat = hasStatusContent ? 112 : 0
        return min(max(editorHeight + 66 + statusHeight, 90), 320)
    }

    init(onHeightChange: @escaping (CGFloat) -> Void = { _ in }) {
        self.onHeightChange = onHeightChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasStatusContent {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if isSending {
                            Text("送信中...")
                                .foregroundStyle(.secondary)
                        } else if !errorText.isEmpty {
                            Text(errorText)
                                .foregroundStyle(.red)
                        } else {
                            Text(responseText)
                                .foregroundStyle(.primary)
                        }
                    }
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 96)
            }

            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("質問してみましょう")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }

                GrowingPromptTextView(
                    text: $prompt,
                    height: $editorHeight,
                    focusRequest: focusRequest,
                    maxHeight: 140,
                    onSubmit: send
                )
            }
            .frame(height: editorHeight, alignment: .topLeading)

            HStack(spacing: 10) {
                Menu {
                    ForEach(models) { model in
                        Button(model.displayName) {
                            selectedModel = model
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedModel.displayName)
                            .font(.system(size: 13, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                    .frame(minWidth: 96, alignment: .leading)
                }
                .buttonStyle(.plain)
                .menuStyle(.borderlessButton)
                .help("Model")

                Spacer()

                Button(action: isSending ? cancelSend : send) {
                    Image(systemName: isSending ? "stop.fill" : "arrow.up")
                        .font(.system(size: isSending ? 12 : 15, weight: .bold))
                        .foregroundStyle((canSend || isSending) ? .black : .secondary)
                        .frame(width: 34, height: 34)
                        .background((canSend || isSending) ? .white : Color.white.opacity(0.16), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend && !isSending)
                .help(isSending ? "Cancel" : "Send")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: 520, height: panelHeight, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.86))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.secondary.opacity(0.48), lineWidth: 1)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            focusRequest += 1
            onHeightChange(panelHeight)
        }
        .onChange(of: panelHeight) { _, height in
            onHeightChange(height)
        }
        .onReceive(NotificationCenter.default.publisher(for: .promptPanelShouldFocus)) { _ in
            focusRequest += 1
        }
        .onDisappear {
            activeTask?.cancel()
            activeTask = nil
        }
    }

    private func send() {
        let message = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending && !message.isEmpty else { return }

        prompt = ""
        inFlightPrompt = message
        responseText = ""
        errorText = ""
        isSending = true
        focusRequest += 1

        activeTask = Task {
            do {
                let response = try await client.generate(prompt: message, model: selectedModel)
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    activeTask = nil
                    inFlightPrompt = ""
                    responseText = response.isEmpty ? "応答が空でした。" : response
                    isSending = false
                    focusRequest += 1
                }
            } catch is CancellationError {
                await MainActor.run {
                    finishCancellation()
                }
            } catch {
                guard !Task.isCancelled else {
                    await MainActor.run {
                        finishCancellation()
                    }
                    return
                }

                await MainActor.run {
                    activeTask = nil
                    prompt = message
                    inFlightPrompt = ""
                    errorText = error.localizedDescription
                    isSending = false
                    focusRequest += 1
                }
            }
        }
    }

    private func cancelSend() {
        activeTask?.cancel()
        finishCancellation()
    }

    private func finishCancellation() {
        activeTask = nil
        prompt = inFlightPrompt
        inFlightPrompt = ""
        responseText = "キャンセルしました。"
        errorText = ""
        isSending = false
        focusRequest += 1
    }
}

struct GrowingPromptTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat

    let focusRequest: Int
    let maxHeight: CGFloat
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PromptTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.minSize = NSSize(width: 0, height: 24)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if textView.string != text {
            textView.string = text
        }

        context.coordinator.maxHeight = maxHeight
        context.coordinator.recalculateHeight()

        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async {
                scrollView.window?.makeFirstResponder(textView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, height: $height, maxHeight: maxHeight)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        @Binding private var height: CGFloat

        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var maxHeight: CGFloat
        var lastFocusRequest = -1

        init(text: Binding<String>, height: Binding<CGFloat>, maxHeight: CGFloat) {
            _text = text
            _height = height
            self.maxHeight = maxHeight
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text = textView.string
            recalculateHeight()
        }

        func recalculateHeight() {
            guard let textView, let scrollView else { return }
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            let usedRect = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
            let newHeight = min(max(ceil(usedRect.height), 24), maxHeight)

            if abs(height - newHeight) > 0.5 {
                DispatchQueue.main.async {
                    self.height = newHeight
                }
            }

            let shouldScroll = usedRect.height > maxHeight
            if scrollView.hasVerticalScroller != shouldScroll {
                scrollView.hasVerticalScroller = shouldScroll
            }
        }
    }
}

final class PromptTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let isShiftPressed = event.modifierFlags.contains(.shift)

        if isReturn && !isShiftPressed {
            onSubmit?()
            return
        }

        super.keyDown(with: event)
    }
}

#Preview {
    PromptPanelView()
        .frame(width: 520, height: 90)
}
