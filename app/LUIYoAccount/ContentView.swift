import SwiftUI

/// 底栏选择值（Build 34 起底栏就是原生 TabView）：四个页面 tab / 搜索 tab。
/// 没有「更多」/「收起」伪 tab——邮件、应用更新已搬进设置页当入口行
enum ShellTab: Hashable {
    case page(AppTab)
    case search
}

/// 设置页待推送目标：全局搜索点中邮件 / 应用更新时，先切到设置 tab，
/// 再把路由置位——设置页里那两个入口行是带 selection 绑定的 NavigationLink，
/// 接住后推页；用户返回时系统把 selection 写回 nil，等于用完即清
enum SettingsPushTarget: Hashable {
    case mail, update
}

/// 设置页推送路由（外壳持有、设置页消费的一份共享状态）
@MainActor
final class SettingsNavRouter: ObservableObject {
    @Published var route: SettingsPushTarget? = nil
}

/// 外壳（Build 34 定版）：原生 SwiftUI TabView——底栏的玻璃、选中态、切换
/// 全是系统自己的，零自绘栏代码（换组玻璃栏 Build 16–33 的整套机器已删除）：
/// - 标签页只有四个：账号 / 生成卡密 / 版本管理 / 设置，顺序读 TabOrderStore
///   （外观页里可拖动排序）；外加一个搜索 tab，内容是全局搜索页。
/// - iOS 26：新 Tab 写法，搜索是 Tab(role: .search)——系统的独立搜索圆钮；
///   iOS 16–25：经典 tabItem 写法，搜索是普通「搜索」tab（老降级壳同款）。
/// - 邮件 / 应用更新不在底栏：它们是设置页里外观下面的两个入口行（同一导航
///   栈推送打开）；全局搜索点中它们时经 SettingsNavRouter 推页。
/// 每个标签页的内容自带导航栈（各页自己的 NavigationView 不动）。
struct ContentView: View {
    @EnvironmentObject var api: AccountAPI
    @StateObject private var tabOrder = TabOrderStore()
    @StateObject private var settingsNav = SettingsNavRouter()
    @State private var autoDone = false
    @State private var selection: ShellTab = .page(.accounts)
    /// 进搜索前所在的 tab：搜索页那颗独立 ✕ 关掉时回到这里
    @State private var previousTab: ShellTab = .page(.accounts)

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
        .environmentObject(settingsNav)
        .onChange(of: selection) { newValue in
            // 只记非搜索 tab：✕ 关闭搜索时的回落点永远是真实页面
            if newValue != .search { previousTab = newValue }
        }
        // 搜索胶囊下边距（Build 36 实测校准）：胶囊 overlay 的底锚停在
        // 底栏安全线（离物理底边约 83），渲染位置 = 83 + 这个值；底栏顶边
        // 在离底边约 110 处——27 让胶囊贴在底栏上方、留约 7pt 缝（旧值 93
        // 按「锚在物理底边」估，渲染缝隙约 73，用户嫌远）
        .environment(\.searchBarBottom, 27)
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

    // MARK: - 外壳分发

    @ViewBuilder
    private var mainShell: some View {
        if #available(iOS 26.0, *) {
            tabShell26
        } else {
            tabShellLegacy
        }
    }

    @ViewBuilder
    private func pageView(_ tab: AppTab) -> some View {
        switch tab {
        case .accounts: AccountsView()
        case .cards: CardsView()
        case .mail: MailLogView()
        case .update: UpdateView()
        case .versions: VersionsView()
        case .settings: SettingsView()
        }
    }

    /// 标签项的标签：四个标签页全用用户模板图（TabIcon* 资产，系统着色同 SF 符号）
    @ViewBuilder
    private func tabLabel(_ tab: AppTab) -> some View {
        if let asset = tab.customIconAsset {
            Label { Text(tab.title) } icon: { Image(asset) }
        } else {
            Label(tab.title, systemImage: tab.icon)
        }
    }

    // MARK: - iOS 26 原生底栏（新 Tab 写法 + 搜索角色 tab）

    @available(iOS 26.0, *)
    private var tabShell26: some View {
        TabView(selection: $selection) {
            ForEach(tabOrder.order) { tab in
                Tab(value: ShellTab.page(tab)) {
                    pageView(tab)
                } label: {
                    tabLabel(tab)
                }
            }
            Tab("搜索", image: "TabIconSearch", value: ShellTab.search, role: .search) {
                GlobalSearchView(onSelect: { navigateFromSearch($0) },
                                 onClose: { selection = previousTab })
            }
        }
    }

    // MARK: - iOS 16–25 原生底栏（经典 tabItem 写法，搜索是普通 tab）

    private var tabShellLegacy: some View {
        TabView(selection: $selection) {
            ForEach(tabOrder.order) { tab in
                pageView(tab)
                    .tabItem { tabLabel(tab) }
                    .tag(ShellTab.page(tab))
            }
            GlobalSearchView(onSelect: { navigateFromSearch($0) },
                             onClose: { selection = previousTab })
                .tabItem { Label { Text("搜索") } icon: { Image("TabIconSearch") } }
                .tag(ShellTab.search)
        }
    }

    // MARK: - 搜索跳转

    /// 全局搜索点中结果：标签页（账号 / 卡密 / 版本管理 / 设置）→ 直接选中
    /// 那个 tab；邮件 / 应用更新 → 切到设置 tab 并经路由推页（路由置位在前、
    /// 切 tab 在后，同一帧完成，设置页一出现就接住推送）
    private func navigateFromSearch(_ tab: AppTab) {
        switch tab {
        case .mail:
            settingsNav.route = .mail
            selection = .page(.settings)
        case .update:
            settingsNav.route = .update
            selection = .page(.settings)
        default:
            selection = .page(tab)
        }
    }
}
