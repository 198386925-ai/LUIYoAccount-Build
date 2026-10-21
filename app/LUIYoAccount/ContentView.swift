import SwiftUI

/// 底栏选择值：页面 tab / 搜索 tab
enum ShellTab: Hashable {
    case page(AppTab)
    case search
}

/// 外壳：系统原生底栏，绝不自绘、不隐藏、不改外观——iOS 26 上系统底栏自带
/// 液态玻璃，选中效果（果冻滑动的选中胶囊）也是系统自己的。用户最终定版：
/// 底栏要显示文字、选中要原生底栏的效果，Build 16–18 的玻璃换组外壳（分组、
/// 出处圆钮、独立透镜层）整体删除。结构：五个页面全部直排进原生底栏、逐个
/// 可点，tab 项 = 图标 + 文字（Label，系统标准长相）；最后是搜索 tab
/// （iOS 26 用 Tab(role: .search)，系统渲染成右侧分离的原生玻璃搜索圆钮，
/// 点开后搜索页里的胶囊浮在底栏上方；iOS 16–25 降级为普通的「搜索」tab，
/// 同样带文字）。顺序由 TabOrderStore 管理（外观页里拖动只调顺序）。
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
        // 搜索胶囊离底边距离：系统底栏（含主屏幕指示条区）约 83 + 间隙 10 = 93，
        // 胶囊底边落在底栏顶边上方 10pt（只在搜索打开时存在，零重叠）
        .environment(\.searchBarBottom, 93)
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

    /// iOS 26：Tab 构建写法；tab 项 = 图标 + 文字（系统标准 Label），
    /// 选中长相完全是系统自己的；搜索是 role: .search 的 tab——系统把它
    /// 拆到栏右端单独渲染（原生液态玻璃圆钮），和主 App 的 UISearchTab 一致
    @available(iOS 26.0, *)
    private var modernShell: some View {
        TabView(selection: $selection) {
            ForEach(tabOrder.order) { tab in
                Tab(value: ShellTab.page(tab)) {
                    pageView(tab)
                } label: {
                    Label(tab.title, systemImage: tab.icon)
                }
            }
            Tab(value: ShellTab.search, role: .search) {
                GlobalSearchView { navigateFromSearch($0) }
            }
        }
    }

    /// iOS 16–25：经典 tabItem 写法（同样图标 + 文字），搜索降级为普通 tab（排在最后）
    private var legacyShell: some View {
        TabView(selection: $selection) {
            ForEach(tabOrder.order) { tab in
                pageView(tab)
                    .tabItem { Label(tab.title, systemImage: tab.icon) }
                    .tag(ShellTab.page(tab))
            }
            GlobalSearchView { navigateFromSearch($0) }
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
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
