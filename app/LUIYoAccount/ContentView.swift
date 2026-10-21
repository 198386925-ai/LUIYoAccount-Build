import SwiftUI

struct ContentView: View {
    @EnvironmentObject var api: AccountAPI
    @State private var autoDone = false
    @AppStorage(FontStore.defaultsKey) private var globalFontPS = ""

    var body: some View {
        Group {
            if api.loggedIn {
                TabView {
                    AccountsView()
                        .tabItem { Label("账号", systemImage: "person.2.fill") }
                    CardsView()
                        .tabItem { Label("生成卡密", systemImage: "ticket.fill") }
                    MailLogView()
                        .tabItem { Label("邮件", systemImage: "envelope.fill") }
                    UpdateView()
                        .tabItem { Label("应用更新", systemImage: "arrow.up.circle.fill") }
                    SettingsView()
                        .tabItem { Label("设置", systemImage: "gearshape.fill") }
                }
            } else if !autoDone {
                ProgressView("登录中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LoginView()
            }
        }
        .modifier(GlobalFontModifier(psName: globalFontPS))
        .onChange(of: globalFontPS) { newValue in
            FontStore.applyNavigationBarFont(psName: newValue)
        }
        .onAppear {
            FontStore.applyNavigationBarFont(psName: globalFontPS)
            // 自动登录：有保存的密码就直接进，不用每次输
            guard !autoDone else { return }
            if let saved = Keychain.load(), !saved.isEmpty {
                Task {
                    try? await api.login(password: saved)
                    autoDone = true
                }
            } else {
                autoDone = true
            }
        }
    }
}
