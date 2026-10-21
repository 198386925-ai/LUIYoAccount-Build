import SwiftUI

/// 底栏选择值：页面 tab /「更多」伪 tab /「收起」伪 tab / 搜索 tab。
/// .more / .collapse 永远不会真正被选中——选择绑定的 setter 拦截它们，
/// 只翻转分组、不动当前页面（见 handleSelection）
enum ShellTab: Hashable {
    case page(AppTab)
    case more
    case collapse
    case search
}

/// 底栏分组：A = 排序前 3 页 +「更多」；B = 出处页打头 + 其余页 +「收起」
enum BarGroup {
    case a, b
}

/// 外壳：100% 系统原生 TabView + 换组模式（用户定版：「原生底栏液态玻璃，
/// 套上这个模式」）。栏本身从不自绘、从不隐藏、外观从不定制——iOS 26 的
/// 液态玻璃、选中透镜/着色、tab 项尺寸（图标 + 文字）全部是系统原生底栏
/// 自己的，所以 Build 20 自拼栏「更多按钮和图标大小不对称」的毛病天然消失：
/// 所有项（含「更多」「收起」）都是系统按同一规格渲染的 tab 项。
/// 换组靠条件 tab 集 + 拦截式选择绑定实现：
/// - A 组 tab 集：排序前 3 页 +「更多」伪 tab + 搜索 tab（iOS 26 是
///   Tab(role: .search)，系统拆到右端渲染成独立玻璃圆钮；iOS 16–25 降级
///   为普通「搜索」tab）
/// - B 组 tab 集：出处页（进 B 时所在的 A 组页）打头 + 其余页 +「收起」伪 tab
///   + 搜索 tab
/// - 拦截：点「更多」→ 只把分组翻到 B，选中保持出处页（它在 B 组里打头，
///   页面不跳）；点「收起」→ 回 A 组并选中出处页；点真页 → 选中它，若是
///   A 组页则同步记为最新出处；搜索里点中结果 → A 组页回 A 组选中、其余页
///   进 B 组选中（出处保持最近选中的 A 组页）
/// 页面仍是原来的 SwiftUI 页面视图，没有 ZStack 托管、没有任何自绘栏代码。
/// 顺序由 TabOrderStore 管理（外观页排序：前 3 个进 A 组，其余在「更多」里）。
struct ContentView: View {
    @EnvironmentObject var api: AccountAPI
    @StateObject private var tabOrder = TabOrderStore()
    @State private var selection: ShellTab = .page(.accounts)
    @State private var barGroup: BarGroup = .a
    /// 出处页：最近选中的 A 组页。进 B 组时它排在第一个，选中也停在它身上；
    /// 点「收起」回 A 组时选中的就是它
    @State private var originTab: AppTab = .accounts
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

    // MARK: - 主外壳（原生底栏 + 换组）

    @ViewBuilder
    private var mainShell: some View {
        Group {
            if #available(iOS 26.0, *) {
                modernShell
            } else {
                legacyShell
            }
        }
        .onAppear { normalizeOnAppear() }
        .onChange(of: tabOrder.order) { _ in normalizeForOrderChange() }
    }

    /// 当前分组的 tab 集（不含搜索 tab，它在两组里都固定排在最后）：
    /// A = 前 3 页 +「更多」；B = 出处页 + 其余页 +「收起」
    private var tabItems: [ShellTab] {
        switch barGroup {
        case .a:
            return tabOrder.barTabs.map(ShellTab.page) + [.more]
        case .b:
            return [.page(originTab)] + tabOrder.moreTabs.map(ShellTab.page) + [.collapse]
        }
    }

    @ViewBuilder
    private func tabContent(_ item: ShellTab) -> some View {
        switch item {
        case .page(let tab):
            pageView(tab)
        case .more, .collapse, .search:
            // 伪 tab 的内容永远不会被显示：选择在 setter 里被拦截，落不到它们身上
            EmptyView()
        }
    }

    @ViewBuilder
    private func tabLabel(_ item: ShellTab) -> some View {
        switch item {
        case .page(let tab):
            if let asset = tab.customIconAsset {
                // 用户自定义模板图（资源目录 template 渲染，系统着色同 SF 符号）
                Label { Text(tab.title) } icon: { Image(asset) }
            } else {
                Label(tab.title, systemImage: tab.icon)
            }
        case .more:
            Label { Text("更多") } icon: { Image("TabIconMore") }
        case .collapse:
            Label { Text("收起") } icon: { Image("TabIconMore") }
        case .search:
            Label("搜索", systemImage: "magnifyingglass")
        }
    }

    /// iOS 26：Tab 构建写法；所有 tab 项 = 图标 + 文字（系统标准 Label，尺寸由
    /// 系统统一）；搜索是 role: .search 的 tab——系统把它拆到栏右端单独渲染
    /// （原生液态玻璃圆钮），和主 App 的 UISearchTab 一致
    @available(iOS 26.0, *)
    private var modernShell: some View {
        TabView(selection: tabSelection) {
            ForEach(tabItems, id: \.self) { item in
                Tab(value: item) {
                    tabContent(item)
                } label: {
                    tabLabel(item)
                }
            }
            Tab(value: ShellTab.search, role: .search) {
                GlobalSearchView { navigateFromSearch($0) }
            }
        }
    }

    /// iOS 16–25：经典 tabItem 写法（同样图标 + 文字、同样换组），
    /// 搜索降级为普通 tab（排在最后，带文字「搜索」）
    private var legacyShell: some View {
        TabView(selection: tabSelection) {
            ForEach(tabItems, id: \.self) { item in
                tabContent(item)
                    .tabItem { tabLabel(item) }
                    .tag(item)
            }
            GlobalSearchView { navigateFromSearch($0) }
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                .tag(ShellTab.search)
        }
    }

    // MARK: - 选择拦截

    /// 拦截式选择绑定：TabView 读到的永远是真实选中项；写入先过 handleSelection，
    /// 「更多」「收起」在这层被翻译成分组翻转，永远不会成为真正的选中值
    private var tabSelection: Binding<ShellTab> {
        Binding(
            get: { selection },
            set: { handleSelection($0) }
        )
    }

    private func handleSelection(_ newValue: ShellTab) {
        switch newValue {
        case .more:
            // 只翻到 B 组：当前页就是出处、它在 B 组里打头，选中不动、页面不跳
            barGroup = .b
        case .collapse:
            // 回 A 组并选中出处页
            barGroup = .a
            selection = .page(originTab)
        case .page(let tab):
            selection = .page(tab)
            // 选中 A 组页时同步出处：下次进 B 组，弹出去打头的就是它
            if tabOrder.barTabs.contains(tab) { originTab = tab }
        case .search:
            selection = .search
        }
    }

    /// 全局搜索点中结果：A 组页 → 回 A 组选中它；其余页 → 进 B 组选中它
    /// （出处保持最近选中的 A 组页，不动）
    private func navigateFromSearch(_ tab: AppTab) {
        if tabOrder.barTabs.contains(tab) {
            barGroup = .a
            originTab = tab
        } else {
            barGroup = .b
        }
        selection = .page(tab)
    }

    // MARK: - 排序变化 / 首次出现的归一

    /// 首次出现：已保存的排序可能把默认选中的账号页排进「更多」里——
    /// 出处先对齐到 A 组第一页，分组跟着选中页所在的组走
    private func normalizeOnAppear() {
        if !tabOrder.barTabs.contains(originTab) {
            originTab = tabOrder.barTabs.first ?? .accounts
        }
        if case .page(let t) = selection, !tabOrder.barTabs.contains(t) {
            barGroup = .b
        }
    }

    /// 排序变化（外观页拖动）：出处失效（被拖出前 3）时换成 A 组第一页；
    /// 选中的页跟着它现在所在的组走——页面本身不跳，栏重新分组即可
    private func normalizeForOrderChange() {
        if !tabOrder.barTabs.contains(originTab) {
            originTab = tabOrder.barTabs.first ?? .accounts
        }
        if case .page(let t) = selection {
            if tabOrder.barTabs.contains(t) {
                barGroup = .a
                originTab = t
            } else {
                barGroup = .b
            }
        }
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
