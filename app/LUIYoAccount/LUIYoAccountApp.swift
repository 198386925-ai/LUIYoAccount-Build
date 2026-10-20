import SwiftUI

/// LUIYo账号：邮箱账号授权系统的独立管理 App（新域名 luioe.bbroot.com）
@main
struct LUIYoAccountApp: App {
    @StateObject private var api = AccountAPI()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(api)
        }
    }
}
