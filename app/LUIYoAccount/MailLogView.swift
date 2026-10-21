import SwiftUI

/// 邮件发送记录：每次发注册验证码 / 换设备确认信的日志（后端 mail_log，与网页后台同一份数据）。
/// Build 34 起不是底栏页：从设置页推送打开，不再自带 NavigationView（借设置页的导航栈，和外观同款）
struct MailLogView: View {
    @EnvironmentObject var api: AccountAPI
    @EnvironmentObject var fontStore: FontStore
    @State private var logs: [MailLogItem] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                if logs.isEmpty {
                    Text(loaded ? "暂无发信记录" : "加载中…")
                        .foregroundColor(.secondary)
                }
                ForEach(logs) { m in
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.toEmail)
                                .appFont(.subheadline, weight: .bold)
                            if !m.subject.isEmpty {
                                Text(m.subject)
                                    .appFont(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text(m.createdText)
                                .appFont(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer(minLength: 6)
                        // 发送状态标识对整行上下居中（不再贴在邮箱那一行）
                        Text(m.ok ? "发送成功" : "发送失败")
                            .appFont(.caption, weight: .bold)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(m.ok ? Color.green : Color.red)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 26, bottom: 2, trailing: 26))
                }
            }
        }
        .compactSectionSpacing()
        .navigationTitle("邮件记录")
        .task { await load() }
        .refreshable { await load() }
        .alert("错误", isPresented: .constant(error != nil)) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func load() async {
        do {
            logs = try await api.mailLogs()
            loaded = true
        } catch {
            if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            loaded = true
        }
    }
}
