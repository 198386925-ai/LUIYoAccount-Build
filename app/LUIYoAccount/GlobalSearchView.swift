import SwiftUI

/// 全局搜索（底栏搜索 tab 的内容）：首次出现时拉账号 / 卡密 / 邮件三份列表，
/// 之后本地按关键词过滤、分组展示；点任意结果切到对应页面（底栏页直接切，
/// 「更多」里的页由外壳切到更多 tab 并打开）
struct GlobalSearchView: View {
    @EnvironmentObject var api: AccountAPI
    /// 搜索胶囊离页面底边的距离（外壳注入）：打开搜索时胶囊浮在底栏上方、不和底栏重叠
    @Environment(\.searchBarBottom) private var searchBarBottom
    let onSelect: (AppTab) -> Void
    /// 关闭回调（玻璃外壳里搜索是盖在页面上的伪页面，需要返回入口）；
    /// 旧 TabView 外壳里搜索本身就是一个 tab，传 nil 就不显示关闭按钮
    var onClose: (() -> Void)? = nil

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
            // 结果列表底部留空带，末尾结果不被搜索胶囊盖住
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 56)
            }
            .navigationTitle("全局搜索")
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("关闭") { onClose() }
                    }
                }
            }
            // 搜索胶囊是页面自己的子视图（不再用 .searchable——系统搜索框在窗口层贴底
            // 渲染、会和玻璃底栏重叠，见 SearchBarCapsule 注释）；本页在外壳里是条件组合
            // （关搜索时整页不在层级中），胶囊随页面一起出现/消失，下边距由外壳注入，
            // 钉在底栏顶边上方 10pt：底栏在下方照常可见，两者零重叠、零透字
            .overlay(alignment: .bottom) {
                SearchBarCapsule(query: $query, prompt: "搜索账号 / 卡密 / 邮件")
                    .padding(.horizontal, 16)
                    .padding(.bottom, searchBarBottom)
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
