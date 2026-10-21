import SwiftUI

/// 底栏选择值（旧 TabView 外壳用）：页面 tab /「更多」tab / 搜索 tab
enum ShellTab: Hashable {
    case page(AppTab)
    case more
    case search
}

/// 玻璃换组底栏的分组：A = 排序前 3 页 +「…」；B = 左边出处圆钮 + 其余页
enum BarGroup {
    case a, b
}

/// 外壳（iOS 26 与 16–25 两套）：
/// - iOS 26：液态玻璃换组底栏（照用户参考的 Rex 底栏）——浮动玻璃胶囊 + 右边一个独立玻璃
///   圆钮（搜索），全程只有图标、没有文字。A 组胶囊里是排序前 3 页 + 第 4 个「…」；点「…」
///   换到 B 组：刚才所在的页从胶囊里弹出来，变成胶囊左边一个独立玻璃圆钮（和右边搜索对称），
///   胶囊里换成其余页；点圆钮回 A 组并选中那个页。胶囊宽度两组恒定不缩短，B 组少的项按
///   等宽槽位摊满整个胶囊。选中项的玻璃高亮是一块带 glassEffectID 的玻璃胶囊，切换时在
///   项与项之间滑动变形。玻璃只用系统 GlassEffectContainer / glassEffect，不自绘、不贴图。
///   页面全部活在一个 ZStack 里（首次访问后挂载并保活，各自导航栈和状态不丢），搜索是
///   一个盖在 ZStack 上的伪页面。
/// - iOS 16–25：Build 11 的原生 TabView 外壳降级保留（原生底栏 +「更多」tab + 搜索 tab）。
/// 顺序由 TabOrderStore 管理（外观页里拖动排序）：前 3 个进 A 组，其余进 B 组。
struct ContentView: View {
    @EnvironmentObject var api: AccountAPI
    @StateObject private var tabOrder = TabOrderStore()
    @State private var autoDone = false
    // 旧外壳（iOS 16–25）状态
    @State private var selection: ShellTab = .page(.accounts)
    @State private var morePage: AppTab?
    // 玻璃外壳（iOS 26）状态
    @State private var currentPage: AppTab = .accounts
    @State private var barGroup: BarGroup = .a
    @State private var originTab: AppTab = .accounts
    @State private var searchShown = false
    @State private var savedPage: AppTab = .accounts
    @State private var savedGroup: BarGroup = .a
    @State private var savedOrigin: AppTab = .accounts
    @State private var mountedPages: Set<AppTab> = [.accounts]
    @Namespace private var glassNS

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

    // MARK: - 外壳分发

    @ViewBuilder
    private var mainShell: some View {
        Group {
            if #available(iOS 26.0, *) {
                glassShell
            } else {
                legacyShell
            }
        }
        .onChange(of: tabOrder.order) { _ in
            if #available(iOS 26.0, *) {
                resetGlassForOrderChange()
            } else {
                syncSelectionWithOrder()
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

    // MARK: - iOS 26 液态玻璃换组外壳

    /// 五个页面同住一个 ZStack：访问过的才挂载，挂载后一直保活（ opacity 切显隐），
    /// 各自的导航栈、滚动位置、已加载数据都不丢；搜索以伪页面盖在最上层。
    /// 底部 safeAreaInset 留出底栏高度，页面内容永远不被浮动底栏挡住。
    @available(iOS 26.0, *)
    private var glassShell: some View {
        ZStack {
            ForEach(AppTab.allCases) { tab in
                if mountedPages.contains(tab) {
                    pageView(tab)
                        .opacity(!searchShown && currentPage == tab ? 1 : 0)
                        .allowsHitTesting(!searchShown && currentPage == tab)
                        .accessibilityHidden(searchShown || currentPage != tab)
                }
            }
            if searchShown {
                GlobalSearchView(onSelect: { pickFromSearch($0) }, onClose: { closeSearch() })
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 92)
        }
        .overlay(alignment: .bottom) {
            glassBar
                .padding(.bottom, 6)
        }
        .onAppear { normalizeGlassOnAppear() }
        .onChange(of: currentPage) { mountedPages.insert($0) }
    }

    private var barSpring: Animation { .spring(response: 0.38, dampingFraction: 0.82) }

    /// 首次进入时把状态对齐当前排序：A 组里选中的必须是底栏前 3 页之一
    private func normalizeGlassOnAppear() {
        if barGroup == .a && !tabOrder.barTabs.contains(currentPage) {
            currentPage = tabOrder.barTabs.first ?? .accounts
        }
        originTab = currentPage
        mountedPages.insert(currentPage)
    }

    /// 排序变化（外观页拖动）：玻璃外壳一律重置回 A 组，保证状态和新顺序一致
    private func resetGlassForOrderChange() {
        searchShown = false
        barGroup = .a
        if !tabOrder.barTabs.contains(currentPage) {
            currentPage = tabOrder.barTabs.first ?? tabOrder.order.first ?? .accounts
        }
        originTab = currentPage
        mountedPages.insert(currentPage)
    }

    private func selectPage(_ tab: AppTab) {
        mountedPages.insert(tab)
        withAnimation(barSpring) { currentPage = tab }
    }

    /// 点「…」进 B 组：当前页记为出处（弹到胶囊左侧当圆钮），选中其余页的第一个
    private func enterGroupB() {
        guard let first = tabOrder.moreTabs.first else { return }
        mountedPages.insert(first)
        withAnimation(barSpring) {
            originTab = currentPage
            barGroup = .b
            currentPage = first
        }
    }

    /// 点出处圆钮：回 A 组并选中出处页
    private func backToOrigin() {
        withAnimation(barSpring) {
            barGroup = .a
            currentPage = originTab
        }
    }

    private func openSearch() {
        savedPage = currentPage
        savedGroup = barGroup
        savedOrigin = originTab
        withAnimation(barSpring) { searchShown = true }
    }

    /// 搜索里点「关闭」：原样回到进搜索前的页面和分组
    private func closeSearch() {
        withAnimation(barSpring) {
            searchShown = false
            currentPage = savedPage
            barGroup = savedGroup
            originTab = savedOrigin
        }
    }

    /// 搜索点中结果：底栏页 → 回 A 组选中它；其余页 → 进 B 组选中它，
    /// 出处 = 进搜索前所在分组的 A 组页面（A 组时就是当时页面，B 组时是当时的出处）
    private func pickFromSearch(_ tab: AppTab) {
        let returnOrigin = savedGroup == .a ? savedPage : savedOrigin
        mountedPages.insert(tab)
        withAnimation(barSpring) {
            searchShown = false
            if tabOrder.barTabs.contains(tab) {
                barGroup = .a
                currentPage = tab
            } else {
                barGroup = .b
                originTab = returnOrigin
                currentPage = tab
            }
        }
    }

    // MARK: - 玻璃底栏（胶囊 + 出处圆钮 + 搜索圆钮）

    /// 一行三段：[出处圆钮（仅 B 组）] [玻璃胶囊] [搜索圆钮]。
    /// 胶囊宽度按总宽扣掉固定预留算出（两侧边距 32 + 出处圆钮 56 + 搜索圆钮 56 +
    /// 三段间隔 30 + 余量 4 = 178），两组用同一个数——胶囊永不缩短；
    /// A 组时胶囊靠左，B 组时出处圆钮占住胶囊左边的预留位。
    @available(iOS 26.0, *)
    private var glassBar: some View {
        GeometryReader { geo in
            let pillWidth = max(180, geo.size.width - 178)
            HStack(spacing: 10) {
                if barGroup == .b {
                    glassCircle(icon: originTab.icon, tinted: false) { backToOrigin() }
                        .allowsHitTesting(!searchShown)
                }
                glassPill(width: pillWidth)
                    .allowsHitTesting(!searchShown)
                Spacer(minLength: 0)
                glassCircle(icon: "magnifyingglass", tinted: searchShown) {
                    if searchShown { closeSearch() } else { openSearch() }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
        }
        .frame(height: 56)
    }

    /// 玻璃胶囊本体：底是一块系统玻璃胶囊，项按等宽槽位排满；
    /// 选中项下面垫一块带 glassEffectID 的玻璃高亮，切换时系统让它在槽位间滑动变形
    @available(iOS 26.0, *)
    private func glassPill(width: CGFloat) -> some View {
        GlassEffectContainer(spacing: 10) {
            ZStack {
                Capsule()
                    .fill(Color.clear)
                    .glassEffect(.regular, in: Capsule())
                HStack(spacing: 0) {
                    if barGroup == .a {
                        ForEach(tabOrder.barTabs) { tab in
                            glassSlot(icon: tab.icon, selected: !searchShown && currentPage == tab) {
                                selectPage(tab)
                            }
                        }
                        glassSlot(icon: "ellipsis", selected: false) {
                            enterGroupB()
                        }
                    } else {
                        ForEach(tabOrder.moreTabs) { tab in
                            glassSlot(icon: tab.icon, selected: !searchShown && currentPage == tab) {
                                selectPage(tab)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .frame(width: width, height: 56)
    }

    /// 胶囊里的一个图标项：只有图标没有文字，点按区域是整个等宽槽位
    @available(iOS 26.0, *)
    private func glassSlot(icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if selected {
                    Capsule()
                        .fill(Color.clear)
                        .glassEffect(.regular.tint(Color.gray.opacity(0.28)), in: Capsule())
                        .glassEffectID("selection", in: glassNS)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 5)
                }
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    /// 独立玻璃圆钮：出处（B 组时在胶囊左侧）和搜索（永远在最右侧），都是系统玻璃
    @available(iOS 26.0, *)
    private func glassCircle(icon: String, tinted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tinted ? Color.accentColor : Color.primary)
                .frame(width: 56, height: 56)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - iOS 16–25 旧外壳（原生 TabView 降级）

    /// 经典 tabItem 写法：前 3 页 +「更多」tab + 搜索 tab（放大镜，排在最后）
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

    // MARK: - 「更多」tab 内容（旧外壳）

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
