import SwiftUI

/// 底栏选择值：页面 tab / 搜索 tab
enum ShellTab: Hashable {
    case page(AppTab)
    case search
}

/// 外壳：系统原生底栏，绝不自绘、不隐藏、不改外观——iOS 26 上系统底栏自带
/// 液态玻璃，选中胶囊的果冻滑动也是系统自己的（用户参考视频展示的是这种
/// 系统切换效果，不是要自绘一个像的）。结构照主 App 的做法（标准底栏 +
/// 分离搜索）：五个页面全部直排进底栏、逐个可点，不再有「更多」收纳；
/// 最后是搜索 tab（iOS 26 用 Tab(role: .search)，渲染成右侧分离的原生
/// 玻璃搜索圆钮；iOS 16–25 降级为普通放大镜 tab）。所有 tab 只放图标、
/// 不放文字，和参考视频一致。顺序由 TabOrderStore 管理（外观页里拖动排序）。
struct ContentView: View {
    @EnvironmentObject var api: AccountAPI
    @StateObject private var tabOrder = TabOrderStore()
    @State private var selection: ShellTab = .page(.accounts)
    @State private var autoDone = false

    var body: some View {
        Group {
            if api.loggedIn {
                mainShell
            } else if !autoDone {
                ProgressView("登录中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LoginView()
            }
        }
        .modifier(GlobalFontModifier())
        // 字号全局锁死：根上把 Dynamic Type 钉在默认档，和 FontStore 的固定字号一起，
        // 保证任何环境重算（输入框聚焦等）都不会让全 App 字号跳变
        .dynamicTypeSize(.large)
        .environmentObject(tabOrder)
        .onAppear {
            FontStore.applyUIKitAppearances()
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

    // MARK: - 主外壳（原生底栏）

    @ViewBuilder
    private var mainShell: some View {
        if #available(iOS 26.0, *) {
            modernShell
        } else {
            legacyShell
        }
    }

    /// iOS 26：Tab 构建写法；tab 只给图标不给标题，系统栏渲染成纯图标项；
    /// 搜索是 role: .search 的 tab——系统把它拆到栏右端单独渲染
    /// （原生液态玻璃），和主 App 的 UISearchTab 一致
    @available(iOS 26.0, *)
    private var modernShell: some View {
        TabView(selection: $selection) {
            ForEach(tabOrder.order) { tab in
                Tab(value: ShellTab.page(tab)) {
                    pageView(tab)
                } label: {
                    Image(systemName: tab.icon)
                }
            }
            Tab(value: ShellTab.search, role: .search) {
                GlobalSearchView { navigateFromSearch($0) }
            }
        }
    }

    /// iOS 16–25：经典 tabItem 写法（同样只放图标），搜索降级为普通 tab（排在最后）
    private var legacyShell: some View {
        TabView(selection: $selection) {
            ForEach(tabOrder.order) { tab in
                pageView(tab)
                    .tabItem { Image(systemName: tab.icon) }
                    .tag(ShellTab.page(tab))
            }
            GlobalSearchView { navigateFromSearch($0) }
                .tabItem { Image(systemName: "magnifyingglass") }
                .tag(ShellTab.search)
        }
    }

    /// 全局搜索点中结果：五个页都在底栏里，直接切到对应 tab
    private func navigateFromSearch(_ tab: AppTab) {
        selection = .page(tab)
    }

    @ViewBuilder
    private func pageView(_ tab: AppTab) -> some View {
        switch tab {
        case .accounts: AccountsView()
        case .cards: CardsView()
        case .mail: MailLogView()
        case .update: UpdateView()
        case .settings: SettingsView()
        }
    }
}
