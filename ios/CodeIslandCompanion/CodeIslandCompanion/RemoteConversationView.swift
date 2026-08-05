import SwiftUI

/// Remote AI conversation UI (v1.2.0 skeleton): conversation list + chat.
/// Drive the Mac's AI from your iPhone while away.
struct RemoteConversationView: View {
    @StateObject private var viewModel = RemoteConversationViewModel()
    @State private var draft = ""
    @State private var selectedID: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                ForEach(viewModel.conversations) { conv in
                    NavigationLink(value: conv.id) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(conv.title)
                                .font(.headline)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                statusDot(conv.status)
                                Text("\(conv.messages.count) msgs · \(conv.tool)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Remote AI")
            .overlay {
                if viewModel.conversations.isEmpty {
                    ContentUnavailableView("No conversations yet",
                                           systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Send a message — your Mac runs the AI."))
                }
            }
        } detail: {
            if let id = selectedID, let conv = viewModel.conversations.first(where: { $0.id == id }) {
                ChatView(conversation: conv, viewModel: viewModel)
            } else {
                ContentUnavailableView("Select a conversation",
                                       systemImage: "message",
                                       description: Text("Start a new one with the composer below."))
            }
        }
        .task { await viewModel.refresh() }
        .safeAreaInset(edge: .bottom) {
            composer
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Message your Mac's AI…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
            Button {
                let text = draft
                draft = ""
                Task { await viewModel.send(text) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func statusDot(_ status: RemoteConversationStatus) -> some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 8, height: 8)
    }

    private func statusColor(_ status: RemoteConversationStatus) -> Color {
        switch status {
        case .pending, .running: return .blue
        case .done: return .green
        case .error: return .red
        }
    }
}

/// Chat transcript + composer for one conversation.
private struct ChatView: View {
    let conversation: RemoteConversation
    @ObservedObject var viewModel: RemoteConversationViewModel
    @State private var draft = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(conversation.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if conversation.status.isActive {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text(conversation.status == .running ? "Mac is working…" : "Waiting for Mac…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                    }
                }
                .padding()
            }
            .onChange(of: conversation.messages.count) {
                if let last = conversation.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .navigationTitle(conversation.title)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                TextField("Message…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                Button {
                    let text = draft
                    draft = ""
                    Task { await viewModel.send(text, in: conversation) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

private struct MessageBubble: View {
    let message: RemoteConversationMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 60) }
            Text(message.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(message.role == "user" ? Color.accentColor.opacity(0.85) : Color(.systemGray5))
                .foregroundStyle(message.role == "user" ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            if message.role != "user" { Spacer(minLength: 60) }
        }
    }
}
