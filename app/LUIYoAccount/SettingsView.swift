import SwiftUI

/// 设置：外观入口（全局字体 + 底栏排序在里面）/ 邮件、应用更新入口
/// （Build 34 从底栏搬入，就在外观下面，和外观同一个导航栈推送打开；
/// 邮件 / 应用更新两行带 selection 绑定，全局搜索点中它们时外壳经
/// SettingsNavRouter 置位，这里接住自动推页）/ 服务器信息 / 本机版本 / 退出登录
struct SettingsView: View {
    @EnvironmentObject var api: AccountAPI
    @EnvironmentObject var settingsNav: SettingsNavRouter
    /// 服务器组收起/展开（Build 35）：标题「服务器」可点切换，默认展开
    @State private var serverExpanded = true

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v)（Build \(b)）"
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    NavigationLink {
                        AppearanceView()
                    } label: {
                        Label("外观", systemImage: "paintpalette.fill")
                    }
                    NavigationLink(destination: MailLogView(),
                                   tag: SettingsPushTarget.mail,
                                   selection: $settingsNav.route) {
                        Label("邮件", systemImage: "envelope.fill")
                    }
                    NavigationLink(destination: UpdateView(),
                                   tag: SettingsPushTarget.update,
                                   selection: $settingsNav.route) {
                        Label("应用更新", systemImage: "arrow.up.circle.fill")
                    }
                }
                Section {
                    if serverExpanded {
                        LabeledContent("地址", value: "luioe.bbroot.com")
                        LabeledContent("账号接口", value: "user-auth-v2.php")
                        LabeledContent("更新源", value: "updates/latest.json")
                    }
                } header: {
                    // 标题可点：收起/展开下面三行（标题文字不变、不加箭头，同组卡片口径）
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { serverExpanded.toggle() }
                    } label: {
                        AppSectionHeader("服务器")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Section {
                    LabeledContent("版本", value: versionText)
                    LabeledContent("登录状态", value: api.loggedIn ? "已登录（密码已保存，自动登录）" : "未登录")
                } header: {
                    AppSectionHeader("本机 App")
                }
                Section {
                    Button("退出登录", role: .destructive) {
                        api.logout()
                    }
                }
            }
            .compactSectionSpacing()
            .navigationTitle("设置")
        }
    }
}
