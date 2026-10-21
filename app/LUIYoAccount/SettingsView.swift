import SwiftUI

/// 设置：外观入口（全局字体 + 底栏排序在里面）/ 服务器信息 / 本机版本 / 退出登录
struct SettingsView: View {
    @EnvironmentObject var api: AccountAPI

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
                }
                Section {
                    Text("全局字体、底栏排序都在外观里。")
                        .appFont(.footnote)
                        .foregroundColor(.secondary)
                }
                Section {
                    LabeledContent("地址", value: "luioe.bbroot.com")
                    LabeledContent("账号接口", value: "user-auth-v2.php")
                    LabeledContent("更新源", value: "updates/latest.json")
                } header: {
                    AppSectionHeader("服务器")
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
                Section {
                    Text("退出后下次打开需要重新输入管理员密码。账号、卡密、应用更新三个页面共用这一个密码。")
                        .appFont(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .compactSectionSpacing()
            .navigationTitle("设置")
        }
    }
}
