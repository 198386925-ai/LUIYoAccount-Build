import SwiftUI

/// 邮件发送记录：每次发注册验证码 / 换设备确认信的日志（后端 mail_log，与网页后台同一份数据）
struct MailLogView: View {
    @EnvironmentObject var api: AccountAPI
    @EnvironmentObject var fontStore: FontStore
    @State private var logs: [MailLogItem] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    if logs.isEmpty {
                        Text(loaded ? "暂无发信记录" : "加载中…")
                            .foregroundColor(.secondary)
                    }
                    ForEach(logs) { m in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(m.toEmail)
                                    .font(fontStore.font(.subheadline, weight: .bold))
                                Spacer()
                                Text(m.ok ? "发送成功" : "发送失败")
                                    .font(fontStore.font(.caption, weight: .bold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(m.ok ? Color.green : Color.red)
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                            }
                            if !m.subject.isEmpty {
                                Text(m.subject)
                                    .font(fontStore.font(.caption))
                                    .foregroundColor(.secondary)
                            }
                            Text(m.createdText)
                                .font(fontStore.font(.caption2))
                                .foregroundColor(.secondary)
                        }
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
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
