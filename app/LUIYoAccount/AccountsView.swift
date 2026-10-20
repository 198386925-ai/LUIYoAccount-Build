import SwiftUI

/// 邮箱账号管理：列表（SVIP/免费/已封禁/IP异常）+ 封禁(带理由)·解封 / 允许越狱开关 / 取消IP标红
struct AccountsView: View {
    @EnvironmentObject var api: AccountAPI
    @State private var list: [AccountUser] = []
    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?
    @State private var query = ""
    @State private var banTarget: AccountUser?
    @State private var banReason = ""

    var filtered: [AccountUser] {
        guard !query.isEmpty else { return list }
        let q = query.lowercased()
        return list.filter { $0.email.lowercased().contains(q) }
    }

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
                    List(filtered) { u in
                        VStack(alignment: .leading, spacing: 5) {
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
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
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
                    .listStyle(.plain)
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
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func run(_ op: @escaping () async throws -> Void) {
        Task {
            do {
                try await op()
                notice = "已生效"
                await reload()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
