import SwiftUI

/// 底栏选择值：页面 tab /「更多」tab / 搜索 tab
enum ShellTab: Hashable {
    case page(AppTab)
    case more
    case search
}

/// 外壳：标准原生底栏，不自绘、不改外观——iOS 26 上系统底栏自带液态玻璃，
/// 照主 App 的做法（标准 UITabBar + UISearchTab）：前 3 个页面是普通 tab，
/// 第 4 个是「更多」tab（里面先列其余页面，点中整页换入），
/// 最后是搜索 tab（iOS 26 用 Tab(role: .search)，渲染成右侧分离的原生玻璃搜索；
/// iOS 16–25 降级为普通放大镜 tab）。顺序由 TabOrderStore 管理（外观页里拖动排序）。
struct ContentView: View {
    @EnvironmentObject var api: AccountAPI
    @StateObject private var tabOrder = TabOrderStore()
    @State private var selection: ShellTab = .page(.accounts)
    @State private var morePage: AppTab?
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
        Group {
            if #available(iOS 26.0, *) {
                modernShell
            } else {
                legacyShell
            }
        }
        .onChange(of: tabOrder.order) { _ in syncSelectionWithOrder() }
    }

    /// iOS 26：Tab 构建写法，搜索是 role: .search 的 tab——系统把它拆到
    /// 底栏右端单独渲染（原生液态玻璃），和主 App 的 UISearchTab 一致
    @available(iOS 26.0, *)
    private var modernShell: some View {
        TabView(selection: selectionBinding) {
            ForEach(tabOrder.barTabs) { tab in
                Tab(tab.title, systemImage: tab.icon, value: ShellTab.page(tab)) {
                    pageView(tab)
                }
            }
            Tab("更多", systemImage: "ellipsis.circle", value: ShellTab.more) {
                moreContainer
            }
            Tab(value: ShellTab.search, role: .search) {
                GlobalSearchView { navigateFromSearch($0) }
            }
        }
    }

    /// iOS 16–25：经典 tabItem 写法，搜索降级为普通 tab（放大镜图标，排在最后）
    private var legacyShell: some View {
        TabView(selection: selectionBinding) {
            ForEach(tabOrder.barTabs) { tab in
                pageView(tab)
                    .tabItem { Label(tab.title, systemImage: tab.icon) }
                    .tag(ShellTab.page(tab))
            }
            moreContainer
                .tabItem { Label("更多", systemImage: "ellipsis.circle") }
                .tag(ShellTab.more)
            GlobalSearchView { navigateFromSearch($0) }
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                .tag(ShellTab.search)
        }
    }

    /// 选中绑定：再次点已选中的「更多」tab → 回到更多列表
    private var selectionBinding: Binding<ShellTab> {
        Binding(
            get: { selection },
            set: { newValue in
                if newValue == .more && selection == .more { morePage = nil }
                selection = newValue
            }
        )
    }

    /// 排序变化后修正状态：打开中的更多页进了底栏就关掉；
    /// 当前选中的页面掉出底栏，就转到「更多」tab 里继续打开着
    private func syncSelectionWithOrder() {
        if let page = morePage, !tabOrder.moreTabs.contains(page) { morePage = nil }
        if case .page(let tab) = selection, !tabOrder.barTabs.contains(tab) {
            morePage = tab
            selection = .more
        }
    }

    /// 全局搜索点中结果：在底栏的页面直接切 tab；在「更多」里的切更多 tab 并打开该页
    private func navigateFromSearch(_ tab: AppTab) {
        if tabOrder.barTabs.contains(tab) {
            selection = .page(tab)
        } else {
            morePage = tab
            selection = .more
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

    // MARK: - 「更多」tab 内容

    /// 没打开页面时是其余页面的列表；打开后把该页整页换进来
    /// （页面自带导航栈，直接平铺替换，不再套一层导航），顶部一条「‹ 更多」返回列表
    private var moreContainer: some View {
        Group {
            if let page = morePage {
                VStack(spacing: 0) {
                    HStack {
                        Button {
                            morePage = nil
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "chevron.left")
                                Text("更多")
                            }
                            .appFont(.body)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    pageView(page)
                }
            } else {
                List {
                    ForEach(tabOrder.moreTabs) { tab in
                        Button {
                            morePage = tab
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: tab.icon)
                                    .frame(width: 24)
                                Text(tab.title)
                                    .appFont(.body)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.primary)
                    }
                }
            }
        }
    }
}
