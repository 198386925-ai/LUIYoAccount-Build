import SwiftUI

/// 全局搜索（底栏右侧圆形按钮打开）：首次打开时拉账号 / 卡密 / 邮件三份列表，
/// 之后本地按关键词过滤、分组展示；点任意结果关掉搜索并切到对应页面
struct GlobalSearchView: View {
    @EnvironmentObject var api: AccountAPI
    @Environment(\.dismiss) private var dismiss
    let onSelect: (AppTab) -> Void

    @State private var query = ""
    @State private var accounts: [AccountUser] = []
    @State private var cards: [CardItem] = []
    @State private var mails: [MailLogItem] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var errorText: String?

    private var q: String { query.trimmingCharacters(in: .whitespaces).lowercased() }
    private var hitAccounts: [AccountUser] { q.isEmpty ? [] : accounts.filter { $0.email.lowercased().contains(q) } }
    private var hitCards: [CardItem] { q.isEmpty ? [] : cards.filter { $0.code.lowercased().contains(q) } }
    private var hitMails: [MailLogItem] {
        q.isEmpty ? [] : mails.filter { $0.toEmail.lowercased().contains(q) || $0.subject.lowercased().contains(q) }
    }
    private var noHits: Bool { !q.isEmpty && loaded && hitAccounts.isEmpty && hitCards.isEmpty && hitMails.isEmpty }

    var body: some View {
        NavigationView {
            Group {
                if loading && !loaded {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if errorText != nil && !loaded {
                    VStack(spacing: 12) {
                        Text(errorText ?? "")
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                        Button("重试") { Task { await loadIfNeeded() } }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if q.isEmpty {
                            Text("输入关键词，搜账号邮箱、卡密、邮件记录")
                                .foregroundColor(.secondary)
                        }
                        if noHits {
                            Text("无结果")
                                .foregroundColor(.secondary)
                        }
                        if !hitAccounts.isEmpty {
                            Section {
                                ForEach(hitAccounts) { u in
                                    Button { pick(.accounts) } label: {
                                        HStack {
                                            Text(u.email)
                                                .foregroundColor(.primary)
                                                .lineLimit(1)
                                            Spacer()
                                            Text(u.svip ? "SVIP" : "免费")
                                                .appFont(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                AppSectionHeader("账号")
                            }
                        }
                        if !hitCards.isEmpty {
                            Section {
                                ForEach(hitCards) { c in
                                    Button { pick(.cards) } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(c.code)
                                                .foregroundColor(.primary)
                                                .lineLimit(1)
                                            Text(cardMeta(c))
                                                .appFont(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                AppSectionHeader("卡密")
                            }
                        }
                        if !hitMails.isEmpty {
                            Section {
                                ForEach(hitMails) { m in
                                    Button { pick(.mail) } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(m.toEmail)
                                                .foregroundColor(.primary)
                                                .lineLimit(1)
                                            if !m.subject.isEmpty {
                                                Text(m.subject)
                                                    .appFont(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                AppSectionHeader("邮件")
                            }
                        }
                    }
                }
            }
            .navigationTitle("全局搜索")
            .searchable(text: $query, prompt: "搜索账号 / 卡密 / 邮件")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await loadIfNeeded() }
        }
    }

    private func cardMeta(_ c: CardItem) -> String {
        var parts = [c.daysText]
        if !c.remark.isEmpty { parts.append(c.remark) }
        parts.append(c.isBound ? "已绑定 " + c.boundEmail : "未使用")
        return parts.joined(separator: " · ")
    }

    private func pick(_ tab: AppTab) {
        onSelect(tab)
        dismiss()
    }

    private func loadIfNeeded() async {
        guard !loaded && !loading else { return }
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            async let a = api.accounts()
            async let c = api.cards()
            async let m = api.mailLogs()
            accounts = try await a
            cards = try await c
            mails = try await m
            loaded = true
        } catch {
            if !error.isCancelError {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
