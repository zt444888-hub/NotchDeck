import SwiftUI
import UIKit

/// Remote AI conversation UI (v1.2.0 skeleton): conversation list + chat.
/// Drive the Mac's AI from your iPhone while away.
struct RemoteConversationView: View {
    @EnvironmentObject private var connection: CompanionConnection
    @StateObject private var viewModel = RemoteConversationViewModel()
    @State private var draft = ""
    @State private var selectedID: String?
    @State private var renameTarget: RemoteConversation?
    @State private var renameText = ""
    @State private var showClearConfirm = false
    @State private var searchText = ""
    // Observing the preference re-renders the window when the language
    // changes (L10n.t is evaluated at render time).
    @AppStorage("AppLanguage") private var appLanguage = "system"

    var body: some View {
        // Imported Mac codex tasks (recordName == codex session id) are
        // separated from phone conversations so the list isn't dominated by
        // dozens of mirrored tasks.
        let phone = viewModel.conversations.filter { !isLocalCodexTask($0) }
        let localTasks = viewModel.conversations.filter { isLocalCodexTask($0) }
        let filteredPhone = filter(phone)
        let filteredTasks = filter(localTasks)
        NavigationSplitView {
            List(selection: $selectedID) {
                Section {
                    ForEach(filteredPhone) { conv in
                        conversationLink(conv)
                    }
                } header: {
                    if !filteredPhone.isEmpty { Text(L10n.t(zh: "手机", en: "Phone")) }
                }
                Section {
                    ForEach(filteredTasks) { conv in
                        conversationLink(conv)
                    }
                } header: {
                    if !filteredTasks.isEmpty { Text(L10n.t(zh: "Mac Codex 任务", en: "Mac Codex tasks")) }
                }
            }
            .searchable(text: $searchText,
                        prompt: L10n.t(zh: "搜索会话", en: "Search conversations"))
            .navigationTitle("Mac 会话")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showClearConfirm = true
                    } label: {
                        Label(L10n.t(zh: "清空", en: "Clear all"),
                              systemImage: "trash")
                    }
                    .disabled(viewModel.conversations.isEmpty)
                    .accessibilityIdentifier("macSession.clearAll")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(L10n.t(zh: "跟随系统", en: "Follow System")) {
                            appLanguage = "system"
                        }
                        Button("简体中文") { appLanguage = "zh" }
                        Button("English") { appLanguage = "en" }
                    } label: {
                        Label(L10n.t(zh: "语言", en: "Language"),
                              systemImage: "globe")
                    }
                    .accessibilityIdentifier("macSession.language")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // send() surfaces a "not connected" hint when needed.
                        connection.send(.focus)
                    } label: {
                        Label(L10n.t(zh: "打开 Mac 会话", en: "Open Mac Session"),
                              systemImage: "arrow.up.forward.app.fill")
                    }
                    .disabled(connection.connectedPeer == nil)
                    .accessibilityIdentifier("macSession.focus")
                }
            }
            .overlay {
                if viewModel.conversations.isEmpty {
                    ContentUnavailableView(L10n.t(zh: "暂无会话", en: "No conversations yet"),
                                           systemImage: "bubble.left.and.bubble.right",
                                           description: Text(L10n.t(zh: "发一条消息,Mac 上的 AI 会回复你。",
                                                                     en: "Send a message — your Mac runs the AI.")))
                }
            }
            .confirmationDialog(L10n.t(zh: "清空全部会话?", en: "Clear all conversations?"),
                                isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button(L10n.t(zh: "全部删除", en: "Delete all"), role: .destructive) {
                    Task { await viewModel.deleteAll() }
                }
                Button(L10n.t(zh: "取消", en: "Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.t(zh: "将删除所有远程会话,不可恢复。",
                            en: "Deletes every remote conversation. This cannot be undone."))
            }
            .alert(L10n.t(zh: "重命名会话", en: "Rename conversation"),
                   isPresented: Binding(
                       get: { renameTarget != nil },
                       set: { if !$0 { renameTarget = nil } }
                   )) {
                TextField(L10n.t(zh: "标题", en: "Title"), text: $renameText)
                Button(L10n.t(zh: "保存", en: "Save")) {
                    if let target = renameTarget {
                        let text = renameText
                        Task { await viewModel.rename(target, to: text) }
                    }
                    renameTarget = nil
                }
                Button(L10n.t(zh: "取消", en: "Cancel"), role: .cancel) {
                    renameTarget = nil
                }
            }
        } detail: {
            if let id = selectedID, let conv = viewModel.conversations.first(where: { $0.id == id }) {
                ChatView(conversation: conv, viewModel: viewModel)
            } else {
                ContentUnavailableView(L10n.t(zh: "选择会话", en: "Select a conversation"),
                                       systemImage: "message",
                                       description: Text(L10n.t(zh: "用下方输入框开始新对话。",
                                                                 en: "Start a new one with the composer below.")))
            }
        }
        .task { await viewModel.refresh() }
        // The outer composer creates a NEW conversation — only show it when
        // no conversation is selected, otherwise it overlaps ChatView's own
        // composer (which appends to the current conversation). On iPhone's
        // collapsed NavigationSplitView both would be visible at once,
        // causing the second message to land in a new conversation.
        .safeAreaInset(edge: .bottom) {
            if selectedID == nil {
                composer
            }
        }
        .safeAreaInset(edge: .top) {
            if let message = viewModel.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField(L10n.t(zh: "给 Mac 的 AI 发消息…", en: "Message your Mac's AI…"),
                      text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
            Button {
                let text = draft
                draft = ""
                Task { await viewModel.send(text) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.4) : Color.accentColor)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Row with a destructive swipe-to-delete action (full swipe deletes).
    private func conversationLink(_ conv: RemoteConversation) -> some View {
        NavigationLink(value: conv.id) {
            conversationRow(conv)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                // iOS 17 known bug: deleting the SELECTED row while the
                // List selection is still active crashes NavigationSplitView
                // ("Index out of range" / AttributeGraph). Clear the
                // selection synchronously, then run the delete on the next
                // runloop so SwiftUI settles the selection diff first.
                if selectedID == conv.id {
                    selectedID = nil
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
                    await viewModel.delete(conv)
                }
            } label: {
                Label(L10n.t(zh: "删除", en: "Delete"), systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                renameTarget = conv
                renameText = conv.title
            } label: {
                Label(L10n.t(zh: "重命名", en: "Rename"), systemImage: "pencil")
            }
            .tint(.blue)
        }
    }

    /// Imported local codex tasks are mirrored with recordName == sessionId;
    /// phone conversations always have a distinct id.
    private func isLocalCodexTask(_ conv: RemoteConversation) -> Bool {
        conv.tool == "codex" && conv.id == conv.sessionId
    }

    /// Search filter: matches title or any message text (case-insensitive).
    private func filter(_ convs: [RemoteConversation]) -> [RemoteConversation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return convs }
        return convs.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    private func conversationRow(_ conv: RemoteConversation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conv.title)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 6) {
                statusIcon(conv.status)
                Text("\(conv.messages.count) \(L10n.t(zh: "条消息", en: "msgs")) · \(toolLabel(conv.tool))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(relativeTime(conv.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if isLocalCodexTask(conv) {
                    Text("Mac")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.2)))
                }
                if let executor = conv.executor {
                    Text(executor)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.blue.opacity(0.15)))
                }
            }
        }
    }

    /// Compact relative timestamp for the list ("now", "5m ago", …).
    private func relativeTime(_ date: Date) -> String {
        let secs = max(0, Int(Date().timeIntervalSince(date)))
        if secs < 60 { return L10n.t(zh: "刚刚", en: "now") }
        if secs < 3600 { return L10n.t(zh: "\(secs / 60) 分钟前", en: "\(secs / 60)m ago") }
        if secs < 86_400 { return L10n.t(zh: "\(secs / 3600) 小时前", en: "\(secs / 3600)h ago") }
        return L10n.t(zh: "\(secs / 86_400) 天前", en: "\(secs / 86_400)d ago")
    }

    /// Friendly agent name for the list/detail footer.
    private func toolLabel(_ tool: String) -> String {
        switch tool {
        case "auto": return "Auto"
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "opencode": return "OpenCode"
        case "gemini": return "Gemini"
        case "demo": return "Demo"
        default: return tool
        }
    }

    /// Semantic status icon for the list (running animates via ProgressView).
    @ViewBuilder
    private func statusIcon(_ status: RemoteConversationStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .font(.caption)
                .foregroundStyle(.blue)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
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
                    // Session info header: which agent drives this, status,
                    // and which Mac executes it.
                    HStack(spacing: 8) {
                        Image(systemName: toolIcon(conversation.tool))
                            .foregroundStyle(.secondary)
                        Text(toolName(conversation.tool))
                            .font(.subheadline.weight(.semibold))
                        if let executor = conversation.executor {
                            Text(L10n.t(zh: "· 执行:\(executor)", en: "· on \(executor)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(statusName(conversation.status))
                            .font(.caption)
                            .foregroundStyle(statusColor(conversation.status))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal)
                    ForEach(conversation.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if conversation.status.isActive {
                        HStack(spacing: 8) {
                            ProgressView()
                            // Live elapsed-time readout while the Mac works.
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(waitingText(since: conversation.updatedAt, at: context.date))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                Task { await viewModel.cancel(conversation) }
                            } label: {
                                Label(L10n.t(zh: "取消", en: "Cancel"),
                                      systemImage: "xmark.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                    }
                    if conversation.status == .done,
                       conversation.errorMessage == "cancelled by user" {
                        Text(L10n.t(zh: "已取消", en: "Cancelled"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }
                    if conversation.status == .error,
                       let hint = RemoteConversationViewModel.friendlyAgentError(conversation.errorMessage) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(hint)
                                .font(.caption)
                                .foregroundStyle(.red)
                            Button {
                                Task { await viewModel.retry(conversation) }
                            } label: {
                                Label(L10n.t(zh: "重试", en: "Retry"),
                                      systemImage: "arrow.clockwise")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.borderless)
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
                TextField(L10n.t(zh: "消息…", en: "Message…"), text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                Button {
                    let text = draft
                    draft = ""
                    Task { await viewModel.send(text, in: conversation) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.4) : Color.accentColor)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    /// Live "Mac is working · 12s" readout for the waiting row.
    private func waitingText(since date: Date, at now: Date) -> String {
        let secs = max(0, Int(now.timeIntervalSince(date)))
        let prefix = conversation.status == .running
            ? L10n.t(zh: "Mac 正在执行", en: "Mac is working")
            : L10n.t(zh: "等待 Mac", en: "Waiting for Mac")
        let mins = secs / 60
        if mins > 0 { return "\(prefix) · \(mins)m \(secs % 60)s" }
        return "\(prefix) · \(secs)s"
    }

    private func toolName(_ tool: String) -> String {
        switch tool {
        case "auto": return L10n.t(zh: "自动选择", en: "Auto")
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "opencode": return "OpenCode"
        case "gemini": return "Gemini CLI"
        case "demo": return L10n.t(zh: "演示模式", en: "Demo")
        default: return tool
        }
    }

    private func toolIcon(_ tool: String) -> String {
        switch tool {
        case "claude": return "sparkles"
        case "codex": return "terminal"
        case "opencode": return "chevron.left.forwardslash.chevron.right"
        case "gemini": return "sparkle"
        case "demo": return "wand.and.stars"
        default: return "cpu"
        }
    }

    private func statusName(_ status: RemoteConversationStatus) -> String {
        switch status {
        case .pending: return L10n.t(zh: "等待中", en: "Queued")
        case .running: return L10n.t(zh: "执行中", en: "Running")
        case .done: return L10n.t(zh: "已完成", en: "Done")
        case .error: return L10n.t(zh: "失败", en: "Error")
        }
    }

    private func statusColor(_ status: RemoteConversationStatus) -> Color {
        switch status {
        case .pending: return .blue
        case .running: return .blue
        case .done: return .green
        case .error: return .red
        }
    }
}

private struct MessageBubble: View {
    let message: RemoteConversationMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 60) }
            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
                bubbleText
                    .textSelection(.enabled)
                if let code = Self.firstCodeBlock(in: message.text) {
                    Button {
                        UIPasteboard.general.string = code
                    } label: {
                        Label(L10n.t(zh: "复制代码", en: "Copy code"),
                              systemImage: "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                // Timestamp inside the bubble, subtle.
                Text(message.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.8))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(message.role == "user" ? Color.accentColor.opacity(0.85) : Color(.systemGray5))
            .foregroundStyle(message.role == "user" ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contextMenu {
                Button {
                    UIPasteboard.general.string = message.text
                } label: {
                    Label(L10n.t(zh: "复制", en: "Copy"), systemImage: "doc.on.doc")
                }
                if let code = Self.firstCodeBlock(in: message.text) {
                    Button {
                        UIPasteboard.general.string = code
                    } label: {
                        Label(L10n.t(zh: "复制代码", en: "Copy code"),
                              systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
            }
            if message.role != "user" { Spacer(minLength: 60) }
        }
    }

    /// Assistant messages render as Markdown (code blocks, lists, bold…);
    /// user messages stay plain text. Falls back to plain text on parse
    /// errors (e.g. lone asterisks the markdown parser rejects).
    @ViewBuilder
    private var bubbleText: some View {
        if message.role == "user" {
            Text(message.text)
        } else if let attributed = try? AttributedString(markdown: message.text) {
            Text(attributed)
        } else {
            Text(message.text)
        }
    }

    /// Extract the first fenced code block (``` … ```) for the copy button.
    private static func firstCodeBlock(in text: String) -> String? {
        let parts = text.components(separatedBy: "```")
        guard parts.count >= 3 else { return nil }
        let block = parts[1]
        // Drop an optional language tag on the first line (e.g. ```swift).
        let lines = block.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard lines.count > 1 else { return block }
        return String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
