import SwiftUI

/// 邮箱账号管理：分组卡片列表（全部=已授权/未授权两张分组卡；切到分类=一个账号一张卡）
/// + 封禁(带理由)·解封 / 允许越狱开关 / 取消IP标红
struct AccountsView: View {
    @EnvironmentObject var api: AccountAPI
    @State private var list: [AccountUser] = []
    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?
    @State private var query = ""
    @State private var banTarget: AccountUser?
    @State private var banReason = ""
    @State private var filter: AccountFilter = .all

    enum AccountFilter: String, CaseIterable {
        case all = "全部"
        case svip = "已授权"
        case free = "未授权"
    }

    var filtered: [AccountUser] {
        guard !query.isEmpty else { return list }
        let q = query.lowercased()
        return list.filter { $0.email.lowercased().contains(q) }
    }

    private var svipAccounts: [AccountUser] { filtered.filter { $0.svip } }
    private var freeAccounts: [AccountUser] { filtered.filter { !$0.svip } }

    var body: some View {
        NavigationView {
            Group {
                if loading && list.isEmpty {
                    ProgressView()
                } else if list.isEmpty {
                    Text("暂无账号（确认新后端已部署到 luioe.bbroot.com）")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    Form {
                        Section {
                            Picker("分类", selection: $filter) {
                                ForEach(AccountFilter.allCases, id: \.self) { f in
                                    Text(f.rawValue).tag(f)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))

                        switch filter {
                        case .all:
                            Section("已授权（\(svipAccounts.count)）") {
                                if svipAccounts.isEmpty {
                                    Text("暂无已授权账号")
                                        .foregroundColor(.secondary)
                                }
                                ForEach(svipAccounts) { u in accountRow(u) }
                            }
                            Section("未授权（\(freeAccounts.count)）") {
                                if freeAccounts.isEmpty {
                                    Text("暂无未授权账号")
                                        .foregroundColor(.secondary)
                                }
                                ForEach(freeAccounts) { u in accountRow(u) }
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
                }
            }
            .navigationTitle("账号管理")
            .searchable(text: $query, prompt: "搜索邮箱")
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

    private func accountRow(_ u: AccountUser) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(u.email)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
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
            if u.isBanned && !u.banReason.isEmpty {
                Text("封禁理由：" + u.banReason)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            HStack {
                Text("注册 " + u.createdText)
                Text("·")
                Text("最后登录 " + u.lastLoginText)
            }
            .font(.caption)
            .foregroundColor(.secondary)
            if !u.udid.isEmpty {
                Text("UDID " + u.udid)
                    .font(.system(.caption2, design: .monospaced))
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
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
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
        }
    }

    private func tag(_ s: String, bg: Color, fg: Color) -> some View {
        Text(s)
            .font(.caption)
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
