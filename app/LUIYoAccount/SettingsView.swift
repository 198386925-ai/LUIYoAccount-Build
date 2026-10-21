import SwiftUI
import UIKit

/// 设置：全局字体（可导入自己的字体文件）/ 服务器信息 / 本机版本 / 退出登录
struct SettingsView: View {
    @EnvironmentObject var api: AccountAPI
    @StateObject private var fontStore = FontStore.shared
    @AppStorage(FontStore.defaultsKey) private var globalFontPS = ""
    @State private var showFontPicker = false
    @State private var fontError: String?

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v)（Build \(b)）"
    }

    var body: some View {
        NavigationView {
            Form {
                Section("全局字体") {
                    Button {
                        globalFontPS = ""
                    } label: {
                        HStack {
                            Text("系统默认")
                                .foregroundColor(.primary)
                            Spacer()
                            if globalFontPS.isEmpty {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    ForEach(fontStore.fonts) { f in
                        Button {
                            globalFontPS = f.psName
                        } label: {
                            HStack {
                                Text(f.displayName)
                                    .font(Font.custom(f.psName, size: 17))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Spacer()
                                if globalFontPS == f.psName {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                    .onDelete { idx in
                        for i in idx { fontStore.delete(fontStore.fonts[i]) }
                    }
                    Button {
                        showFontPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("导入字体（ttf / otf / ttc）")
                        }
                    }
                    Text("选中后立即全局生效，标题和正文都会换成该字体；少数系统控件可能仍用系统字体。导入的字体向左滑可删除，存本机、重启也在。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section("服务器") {
                    LabeledContent("地址", value: "luioe.bbroot.com")
                    LabeledContent("账号接口", value: "user-auth-v2.php")
                    LabeledContent("更新源", value: "updates/latest.json")
                }
                Section("本机 App") {
                    LabeledContent("版本", value: versionText)
                    LabeledContent("登录状态", value: api.loggedIn ? "已登录（密码已保存，自动登录）" : "未登录")
                }
                Section {
                    Button("退出登录", role: .destructive) {
                        api.logout()
                    }
                }
                Section {
                    Text("退出后下次打开需要重新输入管理员密码。账号、卡密、应用更新三个页面共用这一个密码。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .compactSectionSpacing()
            .navigationTitle("设置")
            .sheet(isPresented: $showFontPicker) {
                FontDocumentPicker { url in
                    guard let url else { return }
                    do {
                        globalFontPS = try fontStore.importFont(from: url)
                    } catch {
                        fontError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
            }
            .alert("导入失败", isPresented: .constant(fontError != nil)) {
                Button("好") { fontError = nil }
            } message: { Text(fontError ?? "") }
        }
    }
}
