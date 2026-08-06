import SwiftUI
import CodeIslandCore

/// Mac-side window mirroring the phone's Remote AI conversations.
///
/// This is the visible "agent window" on the desktop: every conversation the
/// iPhone drives is shown here in real time — messages, agent status, and
/// replies — so the Mac's agent tasks are visible and followable while the
/// phone acts as the remote control.
struct RemoteConversationPanelView: View {
    @ObservedObject var service = RemoteConversationService.shared
    @State private var selectedID: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                ForEach(service.conversations) { conv in
                    NavigationLink(value: conv.id) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(conv.title)
                                .font(.headline)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(statusColor(conv.status))
                                    .frame(width: 8, height: 8)
                                Text(statusText(conv.status))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(conv.tool)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Remote AI")
            .overlay {
                if service.conversations.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No conversations yet")
                            .foregroundStyle(.secondary)
                        Text("Send a message from the iPhone companion.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        } detail: {
            if let id = selectedID,
               let conv = service.conversations.first(where: { $0.id == id }) {
                ChatTranscriptView(conversation: conv)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "message")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Select a conversation")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 380)
    }

    private func statusColor(_ status: RemoteConversationStatus) -> Color {
        switch status {
        case .pending, .running: return .blue
        case .done: return .green
        case .error: return .red
        }
    }

    private func statusText(_ status: RemoteConversationStatus) -> String {
        switch status {
        case .pending: return "Waiting for agent…"
        case .running: return "Agent working…"
        case .done: return "Done"
        case .error: return "Error"
        }
    }
}

/// Read-only transcript for one conversation (same bubble layout as the
/// iPhone companion so both ends look identical).
private struct ChatTranscriptView: View {
    let conversation: RemoteConversation

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(conversation.messages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }
                    if conversation.status.isActive {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(conversation.status == .running
                                 ? "Mac is working…"
                                 : "Waiting for Mac…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                    }
                    if conversation.status == .error,
                       let hint = conversation.errorMessage {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
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
    }
}

private struct MessageBubbleView: View {
    let message: RemoteConversationMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 80) }
            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 2) {
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.role == "user" ? Color.accentColor.opacity(0.85)
                                                       : Color(nsColor: .controlBackgroundColor))
                    .foregroundStyle(message.role == "user" ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if message.role != "user" { Spacer(minLength: 80) }
        }
    }
}
