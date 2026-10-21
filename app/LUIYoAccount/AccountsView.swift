import SwiftUI
import UIKit

/// 邮箱账号管理：分组卡片列表（全部=已授权/未授权两张分组卡；切到分类=一个账号一张卡）
/// + 分类下方「封禁」表单（账号/标题/副标题/原因，被封用户在主 App 看到的就是这套文案）
/// + 「已封禁」列表 / 封禁(带理由)·解封 / 允许越狱开关 / 取消IP标红 / 复制账号
struct AccountsView: View {
    @EnvironmentObject var api: AccountAPI
    @EnvironmentObject var fontStore: FontStore
    /// 搜索胶囊离页面底边的距离（外壳注入）：胶囊浮在底栏上方、不和底栏重叠
    @Environment(\.searchBarBottom) private var searchBarBottom
    @State private var list: [AccountUser] = []
    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?
    @State private var query = ""
    @State private var banTarget: AccountUser?
    @State private var banReason = ""
    @State private var filter: AccountFilter = .all
    // 封禁表单（分类切换正下方）
    @State private var banEmail = ""
    @State private var banFormTitle = ""
    @State private var banFormSubtitle = ""
    @State private var banFormReason = ""

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

    var filtered: [AccountUser] {
        guard !query.isEmpty else { return list }
        let q = query.lowercased()
        return list.filter { $0.email.lowercased().contains(q) }
    }

    private var svipAccounts: [AccountUser] { filtered.filter { $0.svip } }
    private var freeAccounts: [AccountUser] { filtered.filter { !$0.svip } }
    private var bannedAccounts: [AccountUser] { list.filter { $0.isBanned } }

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

                        banFormSection

                        if !bannedAccounts.isEmpty {
                            Section {
                                ForEach(bannedAccounts) { u in bannedRow(u) }
                            } header: {
                                AppSectionHeader("已封禁（\(bannedAccounts.count)）")
                            }
                        }

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
                    .refreshable { await reload() }
                    // 列表底部再留一条空带，末尾卡片滚到底也不被搜索胶囊盖住
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear.frame(height: 56)
                    }
                }
            }
            .navigationTitle("账号管理")
            // 搜索胶囊是页面自己的子视图（不再用 .searchable——它的系统搜索框在窗口层
            // 贴底渲染，会和玻璃底栏重叠，见 SearchBarCapsule 注释）；显隐跟页面走，
            // 位置由外壳注入的 searchBarBottom 钉在底栏上方 10pt
            .overlay(alignment: .bottom) {
                SearchBarCapsule(query: $query, prompt: "搜索邮箱")
                    .padding(.horizontal, 16)
                    .padding(.bottom, searchBarBottom)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("退出") { api.logout() }
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
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
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
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
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

    // MARK: - 账号行

    private func accountRow(_ u: AccountUser) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(u.email)
                    .appFont(.headline)
                    .lineLimit(1)
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
                    Text("越狱允许：" + (u.allowJailbreak ? "是" : "否"))
                    Spacer()
                    if u.svip {
                        Text("SVIP 到期 " + u.svipExpiresText)
                    }
                }
                .appFont(.caption)
                .foregroundColor(.secondary)
            }
            Spacer(minLength: 6)
            // 状态标识成组放在右侧、对整行上下居中（不再贴在邮箱那一行）
            VStack(alignment: .trailing, spacing: 1) {
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

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            list = try await api.accounts()
        } catch {
            if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func run(_ op: @escaping () async throws -> Void) {
        Task {
            do {
                try await op()
                notice = "已生效"
                await reload()
            } catch {
                if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            }
        }
    }
}
