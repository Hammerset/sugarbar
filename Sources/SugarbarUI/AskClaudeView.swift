import SwiftUI
import SugarbarCore

public struct AskClaudeView: View {
    private let model: AskClaudeModel
    private let onAddKey: () -> Void
    @State private var draft = ""

    public init(model: AskClaudeModel, onAddKey: @escaping () -> Void) {
        self.model = model
        self.onAddKey = onAddKey
    }

    public var body: some View {
        if model.hasAPIKey {
            VStack(spacing: 0) {
                conversation
                Divider()
                composer
            }
        } else {
            noKey
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.messages.isEmpty {
                        intro
                    }
                    ForEach(model.messages) { message in
                        bubble(message).id(message.id)
                    }
                    if model.isSending {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Claude is reading your data…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .id("progress")
                    }
                    if let error = model.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                .padding()
            }
            .onChange(of: model.messages) { _, messages in
                guard let last = messages.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: last.isUser ? .bottom : .top) }
            }
            .onChange(of: model.isSending) { _, sending in
                if sending { withAnimation { proxy.scrollTo("progress", anchor: .bottom) } }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask about your glucose, insulin and meals from the last \(defaultSummaryDays) days.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(AskClaudeModel.starters, id: \.self) { starter in
                Button(starter) { send(starter) }
                    .buttonStyle(.bordered)
                    .disabled(model.isSending)
            }
            privacyNote
        }
    }

    private var privacyNote: some View {
        Text("A summary of your glucose, dose and meal data goes to the Claude API with your own key; nothing else leaves the device. Answers are not medical advice.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func bubble(_ message: AskClaudeModel.Message) -> some View {
        HStack {
            if message.isUser { Spacer(minLength: 40) }
            Text(markdown(message.text))
                .textSelection(.enabled)
                .padding(10)
                .background(
                    message.isUser ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            if !message.isUser { Spacer(minLength: 0) }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask Claude…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send(draft) }
                Button {
                    send(draft)
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending)
                .accessibilityLabel("Send")
            }
            if let dataThrough = model.dataThrough {
                Text("Using data up to \(dataThrough.formatted(date: .omitted, time: .shortened)). Not medical advice.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
    }

    private var noKey: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a Claude API key to ask questions about your data.")
                .font(.headline)
            Text("A pay-per-use key from console.anthropic.com, stored in this device's Keychain. The same key is used for meal photos.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Add Claude API Key", action: onAddKey)
                .buttonStyle(.borderedProminent)
            privacyNote
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !model.isSending else { return }
        draft = ""
        Task {
            if !(await model.ask(question)) && draft.isEmpty { draft = question }
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
