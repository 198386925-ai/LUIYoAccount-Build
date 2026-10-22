import SwiftUI
import UIKit

/// 邮箱账号管理：分组卡片列表（全部=已授权/未授权两张分组卡；切到分类=一个账号一张卡）
/// + 行侧滑 封禁(带理由)·解封 / 允许越狱开关 / 取消IP标红 / 复制账号
/// Build 39：分类下方的「封禁」表单（账号/标题/副标题/原因）和「已封禁」
/// 列表整块搬去底栏「封禁」页（本文件末尾的 BansView），本页只留账号行
/// 侧滑里的快捷封禁 / 解封（只带理由，和表单那套标题/副标题文案无关）
/// Build 35：账号卡可收起——收起只显示邮箱 + 右侧标识（免费/SVIP/已封禁，
/// 不加箭头），点卡展开才显示注册/最后登录/UDID/越狱允许等详情行
struct AccountsView: View {
    @EnvironmentObject var api: AccountAPI
    @EnvironmentObject var fontStore: FontStore
    /// 列表直接读 App 级缓存（Build 38）：切 tab / 页面再出现都不整表
    /// 重拉；封禁 / 越狱 / 取消标红由 API 就地改缓存行，本页自动刷新；
    /// 只有右上「刷新」和下拉刷新才回源
    private var list: [AccountUser] { api.accountsCache ?? [] }
    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?
    @State private var banTarget: AccountUser?
    @State private var banReason = ""
    @State private var filter: AccountFilter = .all
    /// 账号卡收起/展开（Build 35）：按邮箱记展开状态，默认全收起
    @State private var expandedAccounts: Set<String> = []

    enum AccountFilter: String, CaseIterable {
        case all = "全部"
        case svip = "已授权"
        case free = "未授权"

        var key: String {
            switch self {
            case .all: return "all"
            case .svip: return "svip"
            case .free: return "free"
            }
        }
        init?(key: String) {
            switch key {
            case "all": self = .all
            case "svip": self = .svip
            case "free": self = .free
            default: return nil
            }
        }
    }

    private var filterBinding: Binding<String> {
        Binding(get: { filter.key }, set: { filter = AccountFilter(key: $0) ?? .all })
    }

    var filtered: [AccountUser] { list }

    private var svipAccounts: [AccountUser] { filtered.filter { $0.svip } }
    private var freeAccounts: [AccountUser] { filtered.filter { !$0.svip } }

    var body: some View {
        NavigationView {
            Group {
                if loading && list.isEmpty {
                    ProgressView()
                } else {
                    Form {
                        Section {
                            PillSegmented(options: [("all", "全部"), ("svip", "已授权"), ("free", "未授权")],
                                          selection: filterBinding)
                        }
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        .listRowBackground(Color.clear)

                        switch filter {
                        case .all:
                            Section {
                                if svipAccounts.isEmpty {
                                    Text("暂无已授权账号")
                                        .foregroundColor(.secondary)
                                }
                                ForEach(svipAccounts) { u in accountRow(u) }
                            } header: {
                                AppSectionHeader("已授权（\(svipAccounts.count)）")
                            }
                            Section {
                                if freeAccounts.isEmpty {
                                    Text("暂无未授权账号")
                                        .foregroundColor(.secondary)
                                }
                                ForEach(freeAccounts) { u in accountRow(u) }
                            } header: {
                                AppSectionHeader("未授权（\(freeAccounts.count)）")
                            }
                        case .svip:
                            if svipAccounts.isEmpty {
                                Section { Text("暂无已授权账号").foregroundColor(.secondary) }
                            }
                            ForEach(svipAccounts) { u in
                                Section { accountRow(u) }
                            }
                        case .free:
                            if freeAccounts.isEmpty {
                                Section { Text("暂无未授权账号").foregroundColor(.secondary) }
                            }
                            ForEach(freeAccounts) { u in
                                Section { accountRow(u) }
                            }
                        }
                    }
                    .compactSectionSpacing()
                    .refreshable { await reload(force: true) }
                }
            }
            .navigationTitle("账号管理")
            // 本页不放常驻搜索框（用户规矩：搜索框只有点开搜索才会显示）；找账号走
            // 底栏搜索圆钮打开的全局搜索——它能搜账号/卡密/邮件并点结果直达本页
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    // Build 37：右上「退出」按用户要求删掉，换成「刷新」
                    //（退出登录在设置页里，本来就有，不受影响）
                    // Build 38：这是本页唯一的整表回源入口（连同下拉刷新）
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
            .alert("封禁账号", isPresented: .constant(banTarget != nil)) {
                TextField("封禁理由（可空）", text: $banReason)
                Button("封禁", role: .destructive) {
                    if let u = banTarget {
                        let reason = banReason
                        banTarget = nil
                        run { try await api.accountBan(email: u.email, ban: true, reason: reason) }
                    }
                }
                Button("取消", role: .cancel) { banTarget = nil }
            } message: {
                if let u = banTarget { Text("封禁 \(u.email)？30 秒内在用户 App 生效。") }
            }
        }
    }

    // MARK: - 账号行

    private func accountRow(_ u: AccountUser) -> some View {
        let expanded = expandedAccounts.contains(u.email)
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(u.email)
                    .appFont(.headline)
                    .lineLimit(1)
                // 详情只在展开时显示（Build 35）：收起 = 邮箱 + 右侧标识，不加箭头
                if expanded {
                    if u.isBanned && !u.banReason.isEmpty {
                        Text("封禁理由：" + u.banReason)
                            .appFont(.caption)
                            .foregroundColor(.red)
                    }
                    Text("注册 \(u.createdText) · 最后登录 \(u.lastLoginText)")
                        .appFont(.caption)
                        .foregroundColor(.secondary)
                    if !u.udid.isEmpty {
                        Text("UDID " + u.udid)
                            .appFont(.caption2, design: .monospaced)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                    HStack {
                        // 今日验证（Build 38）：后端 captcha_today 在才拼
                        // 「· 今日验证 X 次」；老后端没这字段整段不显示
                        Text("越狱允许：" + (u.allowJailbreak ? "是" : "否")
                             + (u.captchaToday.map { " · 今日验证 \($0) 次" } ?? ""))
                        Spacer()
                        if u.svip {
                            Text("SVIP 到期 " + u.svipExpiresText)
                        }
                    }
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 6)
            // 状态标识成组放在右侧、对整行上下居中（不再贴在邮箱那一行）；
            // Build 38：整列左边缘对齐——免费/SVIP 和下面 IP异常 的左边缘
            // 在同一条竖线上（原来各自右对齐，左边缘参差不齐）
            VStack(alignment: .leading, spacing: 1) {
                if u.isBanned {
                    tag("已封禁", bg: Color.red.opacity(0.15), fg: .red)
                } else if u.svip {
                    tag("SVIP", bg: Color.green.opacity(0.15), fg: .green)
                } else {
                    tag("免费", bg: Color.gray.opacity(0.15), fg: .secondary)
                }
                if u.ipFlagged {
                    tag("IP异常", bg: Color.orange.opacity(0.18), fg: .orange)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // 点卡收起/展开详情（侧滑不受影响，各走各的手势）
            withAnimation(.easeInOut(duration: 0.2)) {
                if expanded { expandedAccounts.remove(u.email) } else { expandedAccounts.insert(u.email) }
            }
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 26, bottom: 2, trailing: 26))
        .swipeActions(edge: .trailing) {
            if u.isBanned {
                Button("解封") { run { try await api.accountBan(email: u.email, ban: false) } }
                    .tint(.green)
            } else {
                Button("封禁") { banTarget = u; banReason = "" }
                    .tint(.red)
            }
            if u.allowJailbreak {
                Button("禁止越狱") { run { try await api.accountJailbreak(email: u.email, allow: false) } }
                    .tint(.gray)
            } else {
                Button("允许越狱") { run { try await api.accountJailbreak(email: u.email, allow: true) } }
                    .tint(.blue)
            }
            if u.ipFlagged {
                Button("取消标红") { run { try await api.accountUnflag(email: u.email) } }
                    .tint(.orange)
            }
            Button("复制账号") {
                UIPasteboard.general.string = u.email
                notice = "已复制账号"
            }
            .tint(.indigo)
        }
    }

    private func tag(_ s: String, bg: Color, fg: Color) -> some View {
        Text(s)
            .appFont(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(bg)
            .foregroundColor(fg)
            .cornerRadius(8)
    }

    private func reload(force: Bool = false) async {
        loading = true
        defer { loading = false }
        do {
            _ = try await api.accounts(force: force)
        } catch {
            if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func run(_ op: @escaping () async throws -> Void) {
        Task {
            do {
                try await op()
                notice = "已生效"
                // Build 38：不再操作完就整表重拉——API 已就地把缓存行
                // 改好（@Published），本页跟着自动刷新
            } catch {
                if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            }
        }
    }
}

// MARK: - 封禁页（Build 39 从账号页搬出）

/// 封禁管理：封禁表单（账号 / 标题 / 副标题 / 原因，被封用户在主 App
/// 看到的就是这套文案）+「已封禁」列表（侧滑解封 / 复制账号）。
/// Build 39 以前这两块挂在账号页分类切换下方，现整块搬到底栏「封禁」
/// 页单独成页，表单字段、文案与操作一字未改；数据和账号页一样直接读
/// App 级缓存（Build 38），封禁 / 解封由 API 就地改缓存行、本页自动
/// 刷新，只有右上「刷新」和下拉刷新才回源
struct BansView: View {
    @EnvironmentObject var api: AccountAPI
    @EnvironmentObject var fontStore: FontStore
    private var list: [AccountUser] { api.accountsCache ?? [] }
    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?
    // 封禁表单
    @State private var banEmail = ""
    @State private var banFormTitle = ""
    @State private var banFormSubtitle = ""
    @State private var banFormReason = ""

    private var bannedAccounts: [AccountUser] { list.filter { $0.isBanned } }

    var body: some View {
        NavigationView {
            Group {
                if loading && list.isEmpty {
                    ProgressView()
                } else {
                    Form {
                        banFormSection

                        if !bannedAccounts.isEmpty {
                            Section {
                                ForEach(bannedAccounts) { u in bannedRow(u) }
                            } header: {
                                AppSectionHeader("已封禁（\(bannedAccounts.count)）")
                            }
                        }
                    }
                    .compactSectionSpacing()
                    .refreshable { await reload(force: true) }
                }
            }
            .navigationTitle("封禁")
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

    // MARK: - 封禁表单（账号 / 标题 / 副标题 / 原因）

    private var banFormSection: some View {
        Section {
            banField("账号", placeholder: "填要封禁的邮箱", text: $banEmail, keyboard: .emailAddress)
            banField("标题", placeholder: "如：账号已被封禁", text: $banFormTitle)
            banField("副标题", placeholder: "如：你的账号已被停用", text: $banFormSubtitle)
            banField("原因", placeholder: "如：多次违规使用", text: $banFormReason)
            Button {
                submitBanForm()
            } label: {
                Text("封禁")
                    .appFont(.body, weight: .semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(banEmail.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            AppSectionHeader("封禁")
        }
    }

    private func banField(_ label: String, placeholder: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .appFont(.body)
                .frame(width: 52, alignment: .leading)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        // 封禁表单行上下压紧（布局/标签不变，只收行高）
        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
    }

    private func submitBanForm() {
        let email = banEmail.trimmingCharacters(in: .whitespaces).lowercased()
        guard !email.isEmpty else { return }
        let t = banFormTitle, s = banFormSubtitle, r = banFormReason
        run {
            try await api.accountBan(email: email, ban: true, reason: r, title: t, subtitle: s)
            banEmail = ""; banFormTitle = ""; banFormSubtitle = ""; banFormReason = ""
        }
    }

    // MARK: - 已封禁行

    private func bannedRow(_ u: AccountUser) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(u.email)
                    .appFont(.headline)
                    .lineLimit(1)
                Text(banMeta(u))
                    .appFont(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 6)
            tag("已封禁", bg: Color.red.opacity(0.15), fg: .red)
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 26, bottom: 2, trailing: 26))
        .swipeActions(edge: .trailing) {
            Button("解封") { run { try await api.accountBan(email: u.email, ban: false) } }
                .tint(.green)
            Button("复制账号") {
                UIPasteboard.general.string = u.email
                notice = "已复制账号"
            }
            .tint(.indigo)
        }
    }

    private func banMeta(_ u: AccountUser) -> String {
        var parts: [String] = []
        if !u.banTitle.isEmpty { parts.append("标题：" + u.banTitle) }
        if !u.banSubtitle.isEmpty { parts.append("副标题：" + u.banSubtitle) }
        if !u.banReason.isEmpty { parts.append("原因：" + u.banReason) }
        return parts.isEmpty ? "未填弹窗文案" : parts.joined(separator: " · ")
    }

    private func tag(_ s: String, bg: Color, fg: Color) -> some View {
        Text(s)
            .appFont(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(bg)
            .foregroundColor(fg)
            .cornerRadius(8)
    }

    private func reload(force: Bool = false) async {
        loading = true
        defer { loading = false }
        do {
            _ = try await api.accounts(force: force)
        } catch {
            if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func run(_ op: @escaping () async throws -> Void) {
        Task {
            do {
                try await op()
                notice = "已生效"
            } catch {
                if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            }
        }
    }
}
