import AppKit
import MarkdownUI
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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 56),
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
            rootView: PromptPanelView(
                onHeightChange: { [weak panel] height in
                    guard let panel else { return }
                    Self.resize(panel, to: height)
                },
                onClose: { [weak panel] in
                    panel?.orderOut(nil)
                },
                onScreenshot: { [weak self, weak panel] completion in
                    panel?.orderOut(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        ScreenshotOverlay.capture { image in
                            DispatchQueue.main.async {
                                self?.show()
                                completion(image)
                            }
                        }
                    }
                }
            )
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
        let clampedHeight = min(max(height, 56), 520)
        guard abs(panel.frame.height - clampedHeight) > 0.5 else { return }

        var frame = panel.frame
        frame.origin.y += frame.height - clampedHeight
        frame.size.height = clampedHeight
        panel.setFrame(frame, display: true, animate: false)
    }
}

// MARK: - Message model

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    let content: String
    var image: NSImage?

    enum Role { case user, assistant }
}

// MARK: - Main view

struct PromptPanelView: View {
    private let client = GemmaClient()
    private let onHeightChange: (CGFloat) -> Void
    private let onClose: () -> Void
    private let onScreenshot: (@escaping (NSImage?) -> Void) -> Void

    @State private var models: [GemmaModel] = []
    @State private var prompt = ""
    @State private var isPromptEmpty = true
    @State private var editorHeight: CGFloat = 24
    @State private var focusRequest = 0
    @State private var selectedModel = GemmaModel(id: "", displayName: "読込中...")
    @State private var isModelPickerPresented = false
    @State private var messages: [ChatMessage] = []
    @State private var isSending = false
    @State private var activeTask: Task<Void, Never>?
    @State private var errorText = ""
    @State private var isInputFocused = false
    @State private var pendingImage: NSImage?

    private var isExpanded: Bool { !messages.isEmpty || isSending }

    private var canSend: Bool {
        !isSending && (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingImage != nil)
    }

    private var thumbnailHeight: CGFloat { pendingImage != nil ? 64 : 0 }

    private var panelHeight: CGFloat {
        isExpanded ? 480 + thumbnailHeight : max(editorHeight + 32, 56) + thumbnailHeight
    }

    private var cornerRadius: CGFloat { isExpanded ? 20 : 28 }

    init(
        onHeightChange: @escaping (CGFloat) -> Void = { _ in },
        onClose: @escaping () -> Void = {},
        onScreenshot: @escaping (@escaping (NSImage?) -> Void) -> Void = { $0(nil) }
    ) {
        self.onHeightChange = onHeightChange
        self.onClose = onClose
        self.onScreenshot = onScreenshot
    }

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                headerView
                conversationView
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 0.5)
            }
            inputBarView
        }
        .frame(width: 520, height: panelHeight, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    isInputFocused ? Color.white.opacity(0.65) : Color.secondary.opacity(0.48),
                    lineWidth: isInputFocused ? 1.5 : 1
                )
        }
        .preferredColorScheme(.dark)
        .onAppear {
            focusRequest += 1
            onHeightChange(panelHeight)
            Task { await loadModels() }
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

    // MARK: Header

    private var headerView: some View {
        HStack(spacing: 6) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 14)
            .help("閉じる")

            Spacer()

            Button(action: clearConversation) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("新しいチャット")

            Button(action: {}) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 14)
        }
        .frame(height: 44)
    }

    // MARK: Conversation

    private var conversationView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(messages) { message in
                        messageRow(message)
                    }

                    if isSending {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "sparkle")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.blue)
                                .padding(.top, 1)
                            Text("考え中...")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !errorText.isEmpty {
                        Text(errorText)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom") }
            }
            .onChange(of: isSending) { _, _ in
                withAnimation { proxy.scrollTo("bottom") }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 4) {
                    if let img = message.image {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 80, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    if !message.content.isEmpty {
                        Text(message.content)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                }
            }
        case .assistant:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.blue)
                    .padding(.top, 2)
                renderedMarkdown(message.content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func renderedMarkdown(_ content: String) -> some View {
        Markdown(content)
            .markdownTheme(.chat)
    }

    // MARK: Input bar

    @ViewBuilder
    private func thumbnailStrip(_ image: NSImage) -> some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Button {
                    pendingImage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .background(Color.black.opacity(0.5), in: Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var inputBarView: some View {
        VStack(spacing: 0) {
            if let img = pendingImage {
                thumbnailStrip(img)
            }
        HStack(alignment: .center, spacing: 8) {
            Button {
                onScreenshot { image in
                    DispatchQueue.main.async { pendingImage = image }
                }
            } label: {
                Image(systemName: "camera")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("スクリーンショット")

            ZStack(alignment: .topLeading) {
                if isPromptEmpty {
                    Text("Gemma に相談")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
                GrowingPromptTextView(
                    text: $prompt,
                    isEmpty: $isPromptEmpty,
                    height: $editorHeight,
                    isFocused: $isInputFocused,
                    focusRequest: focusRequest,
                    maxHeight: isExpanded ? 24 : 140,
                    onSubmit: send
                )
                .frame(height: editorHeight)
            }
            .frame(height: editorHeight)
            .frame(maxHeight: .infinity, alignment: .center)

            ModelPickerButton(
                selectedModel: selectedModel,
                isPresented: $isModelPickerPresented
            )
            .popover(isPresented: $isModelPickerPresented, arrowEdge: .bottom) {
                ModelPickerPopover(
                    models: models,
                    selectedModel: $selectedModel,
                    isPresented: $isModelPickerPresented
                )
            }

            Button(action: isSending ? cancelSend : send) {
                Image(systemName: isSending ? "stop.fill" : "arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle((canSend || isSending) ? .black : .secondary)
                    .frame(width: 28, height: 28)
                    .background((canSend || isSending) ? .white : Color.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend && !isSending)
            .help(isSending ? "キャンセル" : "送信")
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: isExpanded ? 56 : max(editorHeight + 32, 56))
        }
    }

    // MARK: Actions

    private func loadModels() async {
        guard let fetched = try? await client.fetchModels(), !fetched.isEmpty else { return }
        models = fetched
        if !fetched.contains(where: { $0.id == selectedModel.id }) {
            selectedModel = fetched[0]
        }
    }

    private func clearConversation() {
        messages = []
        errorText = ""
        prompt = ""
        isPromptEmpty = true
        editorHeight = 24
        pendingImage = nil
        focusRequest += 1
    }

    private func send() {
        let message = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageToSend = pendingImage
        guard !isSending && (!message.isEmpty || imageToSend != nil) else { return }

        prompt = ""
        isPromptEmpty = true
        errorText = ""
        isSending = true
        focusRequest += 1
        pendingImage = nil

        messages.append(ChatMessage(role: .user, content: message, image: imageToSend))

        let ollamaMessages = messages.map { msg -> OllamaChatMessage in
            let imageBase64 = msg.image.flatMap { $0.jpegBase64() }
            var omsg = OllamaChatMessage(role: msg.role == .user ? "user" : "assistant", content: msg.content)
            omsg.images = imageBase64.map { [$0] }
            return omsg
        }

        activeTask = Task {
            do {
                let response = try await client.chat(messages: ollamaMessages, model: selectedModel)
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    activeTask = nil
                    isSending = false
                    messages.append(ChatMessage(role: .assistant, content: response.isEmpty ? "応答が空でした。" : response))
                    focusRequest += 1
                }
            } catch is CancellationError {
                // cancelSend() already updated UI
            } catch {
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    activeTask = nil
                    isSending = false
                    if messages.last?.role == .user {
                        let restored = messages.removeLast().content
                        prompt = restored
                        isPromptEmpty = false
                    }
                    errorText = error.localizedDescription
                    focusRequest += 1
                }
            }
        }
    }

    private func cancelSend() {
        activeTask?.cancel()
        activeTask = nil
        isSending = false
        if let last = messages.last, last.role == .user {
            prompt = last.content
            isPromptEmpty = false
            messages.removeLast()
        }
        focusRequest += 1
    }
}

// MARK: - Model picker

struct ModelPickerButton: View {
    let selectedModel: GemmaModel
    @Binding var isPresented: Bool

    @State private var isHovered = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Text(selectedModel.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isHovered || isPresented ? .primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill((isHovered || isPresented) ? Color.white.opacity(0.10) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("モデルを選択")
    }
}

struct ModelPickerPopover: View {
    let models: [GemmaModel]
    @Binding var selectedModel: GemmaModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(models) { model in
                Button {
                    selectedModel = model
                    isPresented = false
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.displayName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(subtitle(for: model))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if selectedModel == model {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 240)
        .background(.regularMaterial)
        .preferredColorScheme(.dark)
    }

    private func subtitle(for model: GemmaModel) -> String {
        model.id
    }
}

// MARK: - Text view

struct GrowingPromptTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isEmpty: Bool
    @Binding var height: CGFloat
    @Binding var isFocused: Bool

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

        textView.onFocusChange = { focused in
            DispatchQueue.main.async { context.coordinator.isFocused = focused }
        }

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if textView.string != text {
            textView.string = text
        }

        context.coordinator.syncEmptyState()
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
        Coordinator(text: $text, isEmpty: $isEmpty, height: $height, isFocused: $isFocused, maxHeight: maxHeight)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        @Binding private var isEmpty: Bool
        @Binding private var height: CGFloat
        @Binding var isFocused: Bool

        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var maxHeight: CGFloat
        var lastFocusRequest = -1

        init(text: Binding<String>, isEmpty: Binding<Bool>, height: Binding<CGFloat>, isFocused: Binding<Bool>, maxHeight: CGFloat) {
            _text = text
            _isEmpty = isEmpty
            _height = height
            _isFocused = isFocused
            self.maxHeight = maxHeight
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text = textView.string
            let newEmpty = textView.string.isEmpty
            if isEmpty != newEmpty { isEmpty = newEmpty }
            recalculateHeight()
        }

        func syncEmptyState() {
            guard let textView else { return }
            let newValue = textView.string.isEmpty
            if isEmpty != newValue {
                DispatchQueue.main.async { self.isEmpty = newValue }
            }
        }

        func recalculateHeight() {
            guard let textView, let scrollView else { return }
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            let usedRect = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
            let newHeight = min(max(ceil(usedRect.height), 24), maxHeight)

            if abs(height - newHeight) > 0.5 {
                DispatchQueue.main.async { self.height = newHeight }
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
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocusChange?(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onFocusChange?(false) }
        return result
    }

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
        .frame(width: 520, height: 56)
}

// MARK: - Chat markdown theme

extension Theme {
    static let chat = Theme()
        .text {
            ForegroundColor(.primary)
            FontSize(14)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.9))
            BackgroundColor(Color.white.opacity(0.12))
        }
        .strong {
            FontWeight(.bold)
        }
        .heading1 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 14, bottom: 6)
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(18)
                }
        }
        .heading2 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 12, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(16)
                }
        }
        .heading3 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 10, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(15)
                }
        }
        .heading4 { configuration in
            configuration.label
                .markdownMargin(top: 8, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(14)
                }
        }
        .heading5 { configuration in
            configuration.label
                .markdownMargin(top: 6, bottom: 2)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(14)
                }
        }
        .heading6 { configuration in
            configuration.label
                .markdownMargin(top: 6, bottom: 2)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(14)
                    ForegroundColor(.secondary)
                }
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.2))
                .markdownMargin(top: 0, bottom: 8)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.5))
                    .relativeFrame(width: .em(0.2))
                configuration.label
                    .markdownTextStyle { ForegroundColor(.secondary) }
                    .relativePadding(.horizontal, length: .em(1))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .codeBlock { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.2))
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(12)
                }
                .padding(10)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .markdownMargin(top: 0, bottom: 8)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.15))
        }
}

