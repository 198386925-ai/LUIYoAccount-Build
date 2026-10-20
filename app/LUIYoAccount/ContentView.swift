import SwiftUI

struct ContentView: View {
    @EnvironmentObject var api: AccountAPI
    @State private var autoDone = false

    var body: some View {
        Group {
            if api.loggedIn {
                AccountsView()
            } else if !autoDone {
                ProgressView("登录中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LoginView()
            }
        }
        .onAppear {
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
