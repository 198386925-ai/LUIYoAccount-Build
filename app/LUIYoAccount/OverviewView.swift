import SwiftUI

/// 总览页（Build 43）：后台 App 的第一页，正常格式——NavigationView +
/// Form + 分组，和账号/卡密/邮件页同一套骨架。全部按「能折叠的尽量
/// 折叠」做：每组默认收起，标题行只露 headline 数字，点标题行用
/// StretchReveal 拉伸展开看明细（和账号卡同一套临界阻尼动效）。
/// 数据只读 App 级缓存（账号/卡密/邮件三份，会话内零重复请求）；
/// 今日验证沿 Build 38 的规矩：老后端没 captcha_today 字段整段不显示。
struct OverviewView: View {
    @EnvironmentObject var api: AccountAPI
    @EnvironmentObject var fontStore: FontStore
    let onJump: (AppTab) -> Void

    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?
    /// 各组展开状态（默认全收起）
    @State private var expanded: Set<String> = []

    private var users: [AccountUser] { api.accountsCache ?? [] }
    private var cards: [CardItem] { api.cardsCache ?? [] }
    private var mails: [MailLogItem] { api.mailCache ?? [] }

    /// 今天 0 点（Asia/Shanghai）的时间戳：今日新增 / 今日邮件都按它切
    private var todayStart: Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return Int(cal.startOfDay(for: Date()).timeIntervalSince1970)
    }

    private var svipCount: Int { users.filter { $0.svip }.count }
    private var bannedCount: Int { users.filter { $0.isBanned }.count }
    private var flagged: [AccountUser] { users.filter { $0.ipFlagged } }
    private var newTodayCount: Int { users.filter { $0.createdAt >= todayStart }.count }
    private var hasCaptcha: Bool { users.contains { $0.captchaToday != nil } }
    private var captchaTotal: Int { users.compactMap { $0.captchaToday }.reduce(0, +) }
    private var topCaptcha: [(String, Int)] {
        users.compactMap { u in u.captchaToday.map { (u.email, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map { $0 }
    }
    private var boundCount: Int { cards.filter { $0.isBound }.count }
    private var disabledCount: Int { cards.filter { $0.disabled }.count }
    private var mailsToday: [MailLogItem] { mails.filter { $0.createdAt >= todayStart } }

    var body: some View {
        NavigationView {
            Group {
                if loading && users.isEmpty && cards.isEmpty && mails.isEmpty {
                    ProgressView()
                } else {
                    Form {
                        userSection
                        cardSection
                        mailSection
                        if hasCaptcha { captchaSection }
                        pendingSection
                    }
                    .compactSectionSpacing()
                    .refreshable { await reload(force: true) }
                }
            }
            .navigationTitle("总览")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("刷新") { Task { await reload(force: true) } }
                }
            }
            .task { await reload() }
            .alert("错误", isPresented: .constant(error != nil)) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
            .alert("操作成功", isPresented: .constant(notice != nil)) {
                Button("好") { notice = nil }
            } message: { Text(notice ?? "") }
        }
    }

    // MARK: - 分组

    private var userSection: some View {
        Section {
            StretchReveal(expanded: expanded.contains("users")) {
                VStack(alignment: .leading, spacing: 8) {
                    jumpRow("已授权", count: svipCount) { onJump(.accounts) }
                    jumpRow("未授权", count: users.count - svipCount) { onJump(.accounts) }
                    jumpRow("已封禁", count: bannedCount) { onJump(.bans) }
                    jumpRow("今日新增", count: newTodayCount) { onJump(.accounts) }
                }
            }
        } header: {
            sectionHeader(key: "users", title: "用户 · 共 \(users.count)")
        }
    }

    private var cardSection: some View {
        Section {
            StretchReveal(expanded: expanded.contains("cards")) {
                VStack(alignment: .leading, spacing: 8) {
                    jumpRow("已用", count: boundCount) { onJump(.cards) }
                    jumpRow("未用", count: cards.count - boundCount) { onJump(.cards) }
                    jumpRow("已作废", count: disabledCount) { onJump(.cards) }
                }
            }
        } header: {
            sectionHeader(key: "cards", title: "卡密 · 共 \(cards.count)（已用 \(boundCount)）")
        }
    }

    private var mailSection: some View {
        Section {
            StretchReveal(expanded: expanded.contains("mail")) {
                VStack(alignment: .leading, spacing: 8) {
                    jumpRow("成功", count: mailsToday.filter { $0.ok }.count) { onJump(.mail) }
                    jumpRow("失败", count: mailsToday.filter { !$0.ok }.count) { onJump(.mail) }
                }
            }
        } header: {
            sectionHeader(key: "mail", title: "邮件 · 今日 \(mailsToday.count) 封")
        }
    }

    private var captchaSection: some View {
        Section {
            StretchReveal(expanded: expanded.contains("captcha")) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(topCaptcha, id: \.0) { email, count in
                        jumpRow(email, count: count) { onJump(.accounts) }
                    }
                }
            }
        } header: {
            sectionHeader(key: "captcha", title: "今日验证 · 共 \(captchaTotal) 次")
        }
    }

    private var pendingSection: some View {
        Section {
            StretchReveal(expanded: expanded.contains("pending")) {
                VStack(alignment: .leading, spacing: 8) {
                    if flagged.isEmpty {
                        Text("暂无待处理")
                            .appFont(.headline, weight: .regular)
                            .foregroundColor(.secondary)
                    }
                    ForEach(flagged) { u in
                        HStack {
                            Text(u.email)
                                .appFont(.headline, weight: .regular)
                                .lineLimit(1)
                            Spacer()
                            Button("取消标红") { run { try await api.accountUnflag(email: u.email) } }
                                .appFont(.headline, weight: .regular)
                                .foregroundColor(.green)
                            Button("封禁") { run { try await api.accountBan(email: u.email, ban: true) } }
                                .appFont(.headline, weight: .regular)
                                .foregroundColor(.red)
                        }
                    }
                }
            }
        } header: {
            sectionHeader(key: "pending", title: "待处理 · \(flagged.count) 个")
        }
    }

    // MARK: - 小组件

    /// 可折叠分组的标题行：标题 + headline 数字 + 展开/收起箭头
    private func sectionHeader(key: String, title: String) -> some View {
        Button {
            if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
        } label: {
            HStack {
                Text(title)
                    .appFont(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: expanded.contains(key) ? "chevron.up" : "chevron.down")
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    /// 跳转行：点数字行跳到对应标签页（邮件走设置页的邮件入口路由）
    private func jumpRow(_ label: String, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .appFont(.headline, weight: .regular)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .appFont(.headline)
                    .foregroundColor(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 数据

    private func reload(force: Bool = false) async {
        loading = true
        defer { loading = false }
        do { _ = try await api.accounts(force: force) } catch {
            if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
        do { _ = try await api.cards(force: force) } catch {
            if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
        do { _ = try await api.mailLogs(force: force) } catch {
            if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func run(_ op: @escaping () async throws -> Void) {
        Task {
            do {
                try await op()
                notice = "已生效"
                // API 已就地把缓存行改好（@Published），本页跟着自动刷新
            } catch {
                if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            }
        }
    }
}
