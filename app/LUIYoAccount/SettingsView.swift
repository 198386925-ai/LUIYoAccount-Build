import SwiftUI

/// 设置：外观入口（全局字体 + 底栏排序在里面）/ 邮件、应用更新入口
/// （Build 34 从底栏搬入，就在外观下面，和外观同一个导航栈推送打开；
/// 邮件 / 应用更新两行带 selection 绑定，全局搜索点中它们时外壳经
/// SettingsNavRouter 置位，这里接住自动推页）/ 服务器（Build 36：
/// 一张卡——卡内首行「服务器」整行就是开关，点它收起/展开卡内三行；
/// Build 38：默认收起，首行右端加箭头指示收起/展开状态）/
/// 本机版本 / 退出登录
struct SettingsView: View {
    @EnvironmentObject var api: AccountAPI
    @EnvironmentObject var settingsNav: SettingsNavRouter
    /// 服务器卡收起/展开：卡内首行「服务器」整行可点切换；
    /// Build 38 起默认收起——每次新进设置页都是收起状态
    @State private var serverExpanded = false

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
                    // 卡内首行「服务器」= 开关本身（Build 36）：整行可点、整行
                    // 都是热区，点它收起/展开同卡下面三行（地址 / 账号接口 /
                    // 更新源）；卡外不再另挂标题
                    // Build 38：默认收起；首行右端加箭头——收起时向下、
                    // 展开时向上，和卡片展开方向一致
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { serverExpanded.toggle() }
                    } label: {
                        HStack {
                            Text("服务器")
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: serverExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if serverExpanded {
                        LabeledContent("地址", value: "luioe.bbroot.com")
                        LabeledContent("账号接口", value: "user-auth-v2.php")
                        LabeledContent("更新源", value: "updates/latest.json")
                    }
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
