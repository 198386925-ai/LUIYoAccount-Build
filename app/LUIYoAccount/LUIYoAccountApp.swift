import SwiftUI

/// LUIYo账号：邮箱账号授权系统的独立管理 App（新域名 luioe.bbroot.com）
@main
struct LUIYoAccountApp: App {
    @StateObject private var api = AccountAPI()

    init() {
        // 启动先把用户导入的字体注册进进程，全局字体设置才能生效
        FontStore.registerAll()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(api)
        }
    }
}
