import SwiftUI

/// 邮件发送记录：每次发注册验证码 / 换设备确认信的日志（后端 mail_log，与网页后台同一份数据）。
/// Build 34 起不是底栏页：从设置页推送打开，不再自带 NavigationView（借设置页的导航栈，和外观同款）
/// Build 35：一封一卡可收起——收起只显示收件邮箱 + 右侧状态标识（不加箭头），
/// 点卡展开才显示主题 / 时间
/// Build 40：展开/收起改成拉伸动效（StretchReveal，与账号卡同款），内容不变；
/// 展开显示的就是后端 mail_log 已返回的全部剩余字段（主题 + 时间），没有新增字段
/// Build 42：邮件行同为单单元格（一张卡面，邮箱与详情同处一行）；详情
/// 正文（主题 / 时间）从 caption/caption2 升到 headline 档（与账号卡
/// 详情同口径，用户：展开的字再大一些），卡面邮箱与状态胶囊不变
struct MailLogView: View {
    @EnvironmentObject var api: AccountAPI
    @EnvironmentObject var fontStore: FontStore
    /// 邮件记录直接读 App 级缓存（Build 38）：会话内只拉一次，
    /// 再进本页不重拉；只有下拉刷新才回源
    private var logs: [MailLogItem] { api.mailCache ?? [] }
    @State private var loaded = false
    @State private var error: String?
    /// 邮件卡收起/展开（Build 35）：按记录 id 记展开状态，默认全收起
    @State private var expandedMails: Set<Int> = []

    var body: some View {
        Form {
            Section {
                if logs.isEmpty {
                    Text(loaded ? "暂无发信记录" : "加载中…")
                        .foregroundColor(.secondary)
                }
                ForEach(logs) { m in
                    let expanded = expandedMails.contains(m.id)
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            // 收起标题行字号和账号卡的邮箱同口径（headline，Build 35）
                            Text(m.toEmail)
                                .appFont(.headline, weight: .bold)
                            // 详情只在展开时显示：主题 + 时间（原来的小字行，原样）
                            // Build 40：显隐改走 StretchReveal 拉伸动效（与账号卡同款）
                            StretchReveal(expanded: expanded) {
                                VStack(alignment: .leading, spacing: 2) {
                                    if !m.subject.isEmpty {
                                        Text(m.subject)
                                            .appFont(.headline, weight: .regular)
                                            .foregroundColor(.secondary)
                                    }
                                    Text(m.createdText)
                                        .appFont(.headline, weight: .regular)
                                        .foregroundColor(.secondary)
                                }
                            }
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
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Build 40：动效归 StretchReveal 的 spring 拉伸，这里只翻状态
                        if expanded { expandedMails.remove(m.id) } else { expandedMails.insert(m.id) }
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 26, bottom: 2, trailing: 26))
                }
            }
        }
        .compactSectionSpacing()
        .navigationTitle("邮件记录")
        .task { await load() }
        .refreshable { await load(force: true) }
        .alert("错误", isPresented: .constant(error != nil)) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func load(force: Bool = false) async {
        do {
            _ = try await api.mailLogs(force: force)
            loaded = true
        } catch {
            if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            loaded = true
        }
    }
}
