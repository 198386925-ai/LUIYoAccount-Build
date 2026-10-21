import SwiftUI

/// 全局搜索（底栏搜索 tab 的内容）：首次出现时拉账号 / 卡密 / 邮件三份列表，
/// 之后本地按关键词过滤、分组展示；点任意结果由外壳跳转——标签页直接选中，
/// 邮件切到设置 tab 并推开设置页里的邮件页
struct GlobalSearchView: View {
    @EnvironmentObject var api: AccountAPI
    /// 搜索胶囊离页面底边的距离（外壳注入）：打开搜索时胶囊浮在底栏上方、不和底栏重叠
    @Environment(\.searchBarBottom) private var searchBarBottom
    let onSelect: (AppTab) -> Void
    /// 关闭回调（Build 36）：胶囊右边那颗独立 ✕ 点了触发——先清关键词，
    /// 再由外壳切回进搜索前的 tab；两个壳都传
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
            // 结果列表底部留空带：胶囊在列表区内占的高度 = 下边距 27 + 高 40
            // ≈ 67，留 74 让末尾结果不被胶囊 + ✕ 那一行盖住
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 74)
            }
            .navigationTitle("全局搜索")
            // 搜索胶囊是页面自己的子视图（不再用 .searchable——系统搜索框在窗口层贴底
            // 渲染、会和底栏重叠，见 SearchBarCapsule 注释）；本页是搜索 tab 的内容，
            // 只在搜索 tab 打开时存在，胶囊随页面一起出现/消失。Build 36：整页
            // 只剩这一个输入框（顶部那行白卡片同款提示行已删）；下边距由外壳
            // 注入并校准到贴底栏上方约 7pt；胶囊右边一颗独立 ✕——自己一颗
            // 40pt 圆玻璃钮、不在胶囊里面，点了清词并回进搜索前的 tab
            .overlay(alignment: .bottom) {
                HStack(alignment: .center, spacing: 8) {
                    SearchBarCapsule(query: $query, prompt: "搜索账号 / 卡密 / 邮件")
                    Button {
                        query = ""
                        onClose?()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(width: 40, height: 40)
                            .modifier(SearchCapsuleSurface())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
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
