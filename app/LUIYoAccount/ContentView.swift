import SwiftUI

/// 底栏选择值（旧 TabView 外壳用）：页面 tab /「更多」伪 tab /「收起」伪 tab / 搜索 tab。
/// .more / .collapse 永远不会真正被选中——旧外壳的选择绑定 setter 拦截它们（见 handleLegacySelection）
enum ShellTab: Hashable {
    case page(AppTab)
    case more
    case collapse
    case search
}

/// 玻璃换组底栏的分组：A = 排序前 3 页 +「…」；B = 左边出处圆钮 + 其余页
enum BarGroup {
    case a, b
}

/// 外壳（iOS 26 与 16–25 两套）：
/// - iOS 26：原生底栏换组外壳——底栏本体是一个只供底栏的真 UITabBarController
///   （NativeTabBarView，子 VC 全是透明占位，页面不住在里面），玻璃、选中透镜、
///   果冻滑动、着色排版全部由系统渲染，本外壳不碰它的任何 appearance，选中也
///   只有系统那一份：没有任何自加的高亮层 / 透镜 / 染色（Build 23 的白透镜被
///   用户否掉——「搞得底栏两层液态玻璃」）。换组靠切换条的条目集：A 组 = 排序
///   前 3 页 +「更多」（点它在代理层被拦下、只翻组，永远不会被选中），搜索是
///   真的 UISearchTab（右侧独立圆钮）；B 组条目 = 其余页，此时整条底栏向右
///   横移 68pt，出处页变成左腾空处一个独立的系统玻璃圆钮（图标按钮，不是
///   选中元素，不带任何高亮），点它回 A 组。两组 footprint 恒定（圆钮区 + 条
///   永远占满边距到边距、同高）。页面住在 SwiftUI 的 ZStack 里整屏托管
///   （访问过才挂载、保活、硬切显隐），搜索是盖在上面的伪页面。
/// - iOS 16–25：Build 22 的原生 TabView 降级保留——同样是换组模式（条件 tab 集 +
///   拦截式选择绑定，前 3 页 +「更多」/ 出处打头 + 其余页 +「收起」），图标 + 文字，
///   含用户自定义模板图（账号 / 生成卡密 / 更多）。
/// 顺序由 TabOrderStore 管理（外观页里拖动排序）：前 3 个进 A 组，其余进 B 组。
struct ContentView: View {
    @EnvironmentObject var api: AccountAPI
    @StateObject private var tabOrder = TabOrderStore()
    @State private var autoDone = false
    // 旧外壳（iOS 16–25）状态：原生 TabView + 换组（Build 22 定版），
    // 分组/出处是它自己的一份，和玻璃外壳的 barGroup / originTab 互不干扰
    @State private var selection: ShellTab = .page(.accounts)
    @State private var legacyGroup: BarGroup = .a
    @State private var legacyOrigin: AppTab = .accounts
    // 原生底栏外壳（iOS 26）状态
    @State private var currentPage: AppTab = .accounts
    @State private var barGroup: BarGroup = .a
    @State private var originTab: AppTab = .accounts
    @State private var searchShown = false
    @State private var savedPage: AppTab = .accounts
    @State private var savedGroup: BarGroup = .a
    @State private var savedOrigin: AppTab = .accounts
    @State private var mountedPages: Set<AppTab> = [.accounts]
    /// 底栏量测（由真 UITabBarController 布局后回填，不猜常量）：
    /// 条总高（栏顶到窗口底边）、选中胶囊中心距条底的距离、条跨过的底部
    /// 安全区高度。初值按 iPhone 的常见尺寸给，首帧布局后即被真实量测覆盖
    @State private var barStripHeight: CGFloat = 100
    @State private var barCenterFromBottom: CGFloat = 57
    @State private var barSafeBottom: CGFloat = 34

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
        // 搜索胶囊离底边距离的默认值；原生底栏外壳按量测动态覆盖，旧 TabView 外壳自己改成 93
        .environment(\.searchBarBottom, 80)
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
                nativeBarShell
            } else {
                legacyShell
            }
        }
        .onChange(of: tabOrder.order) { _ in
            // 原生底栏外壳：排序变了重置回 A 组；旧外壳：出处/分组跟着新顺序归一（页面不跳）
            if #available(iOS 26.0, *) {
                resetNativeForOrderChange()
            } else {
                normalizeLegacyForOrderChange()
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

    // MARK: - iOS 26 原生底栏换组外壳（真 UITabBarController 只供底栏 + 页面 ZStack）

    /// 五个页面同住一个 ZStack：访问过的才挂载，挂载后一直保活（opacity 切显隐），
    /// 各自的导航栈、滚动位置、已加载数据都不丢；搜索以伪页面盖在最上层。
    /// 底栏本体是 NativeTabBarView 包着的真 UITabBarController（见文件末尾）：
    /// 玻璃、选中透镜、果冻滑动、着色全部是系统的，我们一行 appearance 都不碰；
    /// 选中也只有系统那一份——本外壳没有任何自加的高亮层 / 染色（Build 23 的
    /// 白透镜被用户否掉：「搞得底栏两层液态玻璃」）。页面底部留白读底栏量测
    /// （barPageInset），内容永远不被底栏挡住
    @available(iOS 26.0, *)
    private var nativeBarShell: some View {
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
        // 页面显隐永远硬切：容器这一层把动画钉死，任何来源的动画都别想让页面淡入淡出
        .transaction { $0.animation = nil }
        // 搜索胶囊浮在底栏上方 10pt：底边距离 = 页面底部留白 + 10，随底栏量测走
        .environment(\.searchBarBottom, barPageInset + 10)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: barPageInset)
        }
        .overlay(alignment: .bottom) {
            nativeBar
        }
        .onAppear { normalizeNativeOnAppear() }
        .onChange(of: currentPage) { mountedPages.insert($0) }
    }

    /// 页面底部留白：底栏条总高（栏顶到窗口底边）减去条自己跨过的底部安全区
    /// （条钉在窗口底边、home indicator 间距是系统底栏自己留的），页面只需
    /// 让出伸进安全区的那截
    private var barPageInset: CGFloat { max(0, barStripHeight - barSafeBottom) }

    /// 禁用动画的事务：切页、换组、开关搜索的逻辑状态变更全部走它——
    /// 新页同帧全显、旧页同帧全消，两组永不同时在场（底栏条的横移是它自己的
    /// 布局动画，发生在条那一层，进不了页面 ZStack）
    private var instant: Transaction {
        var t = Transaction()
        t.disablesAnimations = true
        return t
    }

    /// 首次进入时把状态对齐当前排序：A 组里选中的必须是底栏前 3 页之一
    private func normalizeNativeOnAppear() {
        if barGroup == .a && !tabOrder.barTabs.contains(currentPage) {
            currentPage = tabOrder.barTabs.first ?? .accounts
        }
        originTab = currentPage
        mountedPages.insert(currentPage)
    }

    /// 排序变化（外观页拖动）：一律重置回 A 组，保证状态和新顺序一致（硬切）
    private func resetNativeForOrderChange() {
        withTransaction(instant) {
            searchShown = false
            barGroup = .a
            if !tabOrder.barTabs.contains(currentPage) {
                currentPage = tabOrder.barTabs.first ?? tabOrder.order.first ?? .accounts
            }
            originTab = currentPage
        }
        mountedPages.insert(currentPage)
    }

    /// 点底栏里的真实页（经 TBC 代理 didSelect 回报）：页面瞬间到位；
    /// A 组里出处恒等于当前页（点「更多」时独立出去的就是它），随选随同步
    private func selectPage(_ tab: AppTab) {
        mountedPages.insert(tab)
        withTransaction(instant) {
            currentPage = tab
            if barGroup == .a { originTab = tab }
        }
    }

    /// 点「更多」进 B 组：当前页记为出处（它将以独立圆钮出现在左边），
    /// 选中其余页的第一个——逻辑状态同帧硬切；底栏条随后横移让位
    /// （条的条目集合同帧换成 B 组，横移动画在 nativeBar 的布局层）
    private func enterGroupB() {
        guard let first = tabOrder.moreTabs.first else { return }
        mountedPages.insert(first)
        withTransaction(instant) {
            originTab = currentPage
            barGroup = .b
            currentPage = first
        }
    }

    /// 点出处圆钮：回 A 组并选中出处页——页面硬切，底栏条横移回全宽
    private func backToOrigin() {
        withTransaction(instant) {
            barGroup = .a
            currentPage = originTab
        }
    }

    private func openSearch() {
        savedPage = currentPage
        savedGroup = barGroup
        savedOrigin = originTab
        withTransaction(instant) {
            searchShown = true
        }
    }

    /// 搜索里点「关闭」：原样回到进搜索前的页面和分组（硬切）
    private func closeSearch() {
        withTransaction(instant) {
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
        withTransaction(instant) {
            searchShown = false
            if tabOrder.barTabs.contains(tab) {
                barGroup = .a
                originTab = tab
                currentPage = tab
            } else {
                barGroup = .b
                originTab = returnOrigin
                currentPage = tab
            }
        }
    }

    // MARK: - 底栏条（真系统底栏 + B 组时左侧独立出处圆钮）

    /// 当前分组的底栏条目：A = 前 3 页 +「更多」；B = 其余页（出处不在条里，
    /// 它是左边那个独立圆钮）；两组末尾都是搜索（真的 UISearchTab）
    private var nativeBarItems: [NativeBarItemSpec] {
        let search = NativeBarItemSpec(id: "search", title: nil, tab: nil)
        switch barGroup {
        case .a:
            return tabOrder.barTabs.map { NativeBarItemSpec(id: "page.\($0.rawValue)", title: $0.title, tab: $0) }
                + [NativeBarItemSpec(id: "more", title: "更多", tab: nil), search]
        case .b:
            return tabOrder.moreTabs.map { NativeBarItemSpec(id: "page.\($0.rawValue)", title: $0.title, tab: $0) }
                + [search]
        }
    }

    /// 底部条本体：高度 = 量测到的底栏条总高，钉在窗口底边（忽略底部安全区，
    /// 让系统底栏按它自己的方式留 home indicator 间距）。
    /// A 组：条全宽。B 组：条的 leading 右移 68（出处圆钮 56 + 间隔 12），
    /// 系统底栏在变窄的条里自己重排——玻璃和选中永远是系统的；腾出的左侧
    /// 空间放出处圆钮（系统玻璃圆按钮，只是按钮、不是选中元素：不带任何
    /// 高亮层，出处页的字形用主色，和系统未选中项一个读法）。
    /// 两组 footprint 恒定：圆钮区（68）+ 条 = 永远占满边距到边距、同高。
    /// 横移用弹簧（≈0.35s）驱动 leading，逻辑状态在此之前已硬切到位
    @available(iOS 26.0, *)
    private var nativeBar: some View {
        ZStack(alignment: .topLeading) {
            NativeTabBarView(
                items: nativeBarItems,
                selectedID: "page.\(currentPage.rawValue)",
                interactionEnabled: !searchShown,
                onSelectPage: { selectPage($0) },
                onMore: { enterGroupB() },
                onSearch: { openSearch() },
                onMetrics: { h, c, s in
                    if abs(barStripHeight - h) > 0.5 { barStripHeight = h }
                    if abs(barCenterFromBottom - c) > 0.5 { barCenterFromBottom = c }
                    if abs(barSafeBottom - s) > 0.5 { barSafeBottom = s }
                }
            )
            .padding(.leading, barGroup == .b ? 68 : 0)
            if barGroup == .b {
                originCircle
                    .position(x: 44, y: barStripHeight - barCenterFromBottom)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: barStripHeight)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: barGroup)
        .ignoresSafeArea(edges: .bottom)
    }

    /// 出处圆钮（B 组时出现在底栏左侧腾出的空间里）：56pt 系统玻璃圆按钮，
    /// 字形 = 出处页自己的图标（和它在条里时同一个来源），纵向和系统底栏
    /// 的中心对齐（读量测 barCenterFromBottom）。点它回 A 组并选中出处页。
    /// 它不是选中元素：没有任何高亮 / 透镜 / 染色，选中态的表达只有系统
    /// 底栏那一份（在条里），圆钮字形保持主色
    @available(iOS 26.0, *)
    private var originCircle: some View {
        Button {
            backToOrigin()
        } label: {
            barGlyphView(barGlyph(for: originTab))
                .foregroundStyle(Color.primary)
                .frame(width: 56, height: 56)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!searchShown)
    }

    /// 底栏字形来源：SF 符号或用户自定义模板图（Assets）。出处圆钮用：
    /// 账号 / 生成卡密是用户的模板图，其余页用线框 SF 符号（和模板图的
    /// 线条风格一致）：邮件 envelope、更新 arrow.up.circle、设置 gearshape
    private enum BarGlyph {
        case system(String)
        case asset(String)
    }

    private func barGlyph(for tab: AppTab) -> BarGlyph {
        if let asset = tab.customIconAsset { return .asset(asset) }
        switch tab {
        case .mail: return .system("envelope")
        case .update: return .system("arrow.up.circle")
        case .settings: return .system("gearshape")
        default: return .system(tab.icon)
        }
    }

    @ViewBuilder
    private func barGlyphView(_ glyph: BarGlyph) -> some View {
        switch glyph {
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: 21, weight: .semibold))
        case .asset(let name):
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
        }
    }


    // MARK: - iOS 16–25 旧外壳（Build 22 的原生 TabView + 换组降级，图标 + 文字）

    /// 当前分组的 tab 集（不含搜索 tab，它在两组里都固定排在最后）：
    /// A = 前 3 页 +「更多」；B = 出处页 + 其余页 +「收起」
    private var legacyTabItems: [ShellTab] {
        switch legacyGroup {
        case .a:
            return tabOrder.barTabs.map(ShellTab.page) + [.more]
        case .b:
            return [.page(legacyOrigin)] + tabOrder.moreTabs.map(ShellTab.page) + [.collapse]
        }
    }

    @ViewBuilder
    private func legacyTabContent(_ item: ShellTab) -> some View {
        switch item {
        case .page(let tab):
            pageView(tab)
        case .more, .collapse, .search:
            // 伪 tab 的内容永远不会被显示：选择在 setter 里被拦截，落不到它们身上
            EmptyView()
        }
    }

    @ViewBuilder
    private func legacyTabLabel(_ item: ShellTab) -> some View {
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

    /// 经典 tabItem 写法 + 换组（Build 22 定版）：tab 集随分组切换，
    /// 「更多」「收起」由拦截式选择绑定翻译成分组翻转，选中永远落不到它们身上；
    /// 所有项（含伪 tab）都是系统按同一规格渲染的 tab 项，图标 + 文字
    private var legacyShell: some View {
        TabView(selection: legacySelection) {
            ForEach(legacyTabItems, id: \.self) { item in
                legacyTabContent(item)
                    .tabItem { legacyTabLabel(item) }
                    .tag(item)
            }
            GlobalSearchView { navigateFromSearch($0) }
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                .tag(ShellTab.search)
        }
        // 旧外壳的系统底栏更高：搜索胶囊离底边按「底栏约 83 + 间隙 10」浮在它上方
        .environment(\.searchBarBottom, 93)
        .onAppear { normalizeLegacyOnAppear() }
    }

    /// 拦截式选择绑定（旧外壳）：TabView 读到的永远是真实选中项；写入先过
    /// handleLegacySelection，「更多」「收起」在这层被翻译成分组翻转
    private var legacySelection: Binding<ShellTab> {
        Binding(
            get: { selection },
            set: { handleLegacySelection($0) }
        )
    }

    private func handleLegacySelection(_ newValue: ShellTab) {
        switch newValue {
        case .more:
            // 只翻到 B 组：当前页就是出处、它在 B 组里打头，选中不动、页面不跳
            legacyGroup = .b
        case .collapse:
            // 回 A 组并选中出处页
            legacyGroup = .a
            selection = .page(legacyOrigin)
        case .page(let tab):
            selection = .page(tab)
            // 选中 A 组页时同步出处：下次进 B 组，弹出去打头的就是它
            if tabOrder.barTabs.contains(tab) { legacyOrigin = tab }
        case .search:
            selection = .search
        }
    }

    /// 全局搜索点中结果（旧外壳）：A 组页 → 回 A 组选中它；其余页 → 进 B 组选中它
    /// （出处保持最近选中的 A 组页，不动）
    private func navigateFromSearch(_ tab: AppTab) {
        if tabOrder.barTabs.contains(tab) {
            legacyGroup = .a
            legacyOrigin = tab
        } else {
            legacyGroup = .b
        }
        selection = .page(tab)
    }

    /// 首次出现（旧外壳）：已保存的排序可能把默认选中的账号页排进「更多」里——
    /// 出处先对齐到 A 组第一页，分组跟着选中页所在的组走
    private func normalizeLegacyOnAppear() {
        if !tabOrder.barTabs.contains(legacyOrigin) {
            legacyOrigin = tabOrder.barTabs.first ?? .accounts
        }
        if case .page(let t) = selection, !tabOrder.barTabs.contains(t) {
            legacyGroup = .b
        }
    }

    /// 排序变化（旧外壳）：出处失效（被拖出前 3）时换成 A 组第一页；
    /// 选中的页跟着它现在所在的组走——页面本身不跳，栏重新分组即可
    private func normalizeLegacyForOrderChange() {
        if !tabOrder.barTabs.contains(legacyOrigin) {
            legacyOrigin = tabOrder.barTabs.first ?? .accounts
        }
        if case .page(let t) = selection {
            if tabOrder.barTabs.contains(t) {
                legacyGroup = .a
                legacyOrigin = t
            } else {
                legacyGroup = .b
            }
        }
    }
}

// MARK: - 原生底栏包装（真 UITabBarController 只供底栏）

/// 底栏条目描述：id 定身份（page.<rawValue> / more / search），title 进原生
/// tab 项（系统标签），tab 非 nil = 真实页面（点选切页），nil = 伪条目
/// （更多 / 搜索，点选在代理里被拦下，永远不会被选中）
private struct NativeBarItemSpec: Equatable {
    var id: String
    var title: String?
    var tab: AppTab?
}

/// 只供底栏的 UITabBarController 子类：每次布局后回调一次，让外壳量到
/// 系统底栏的真实帧（条高 / 中心 / 底部安全区都读它，不猜常量）
@available(iOS 26.0, *)
private final class BarOnlyTabBarController: UITabBarController {
    var onLayout: (() -> Void)?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }
}

/// 只供底栏的 UITabBarController 包装：子 VC 全是透明占位（页面由 SwiftUI
/// 的 ZStack 整屏托管），这个控制器唯一的产物就是它那条系统底栏——玻璃、
/// 选中透镜、果冻滑动、图标与标签的着色排版全部由系统渲染，本文件不碰它
/// 的任何 appearance，选中也只有系统那一份、没有任何自加的高亮层。
/// 条目集随分组切换（A = 前 3 页 +「更多」；B = 其余页，出处不在条里），
/// 搜索是真的 UISearchTab（iOS 26 里它在底栏右侧独立成圆钮，和 SwiftUI 的
/// Tab(role: .search) 是同一个系统组件）。「更多」和搜索的点选在代理
/// shouldSelectTab 里被拦下（不许选中），分别翻译成外壳的换组与打开搜索
/// 伪页面；真实页面的点选经 didSelectTab 回报外壳切页——且 didSelect 只
/// 转发紧跟着 shouldSelect 放行的那次（userInitiated 标记），程序化改选中
/// 和条目集切换引起的回调一律丢弃，不许反过来改外壳状态
@available(iOS 26.0, *)
private struct NativeTabBarView: UIViewControllerRepresentable {
    var items: [NativeBarItemSpec]
    var selectedID: String
    var interactionEnabled: Bool
    var onSelectPage: (AppTab) -> Void
    var onMore: () -> Void
    var onSearch: () -> Void
    var onMetrics: (_ stripHeight: CGFloat, _ centerFromBottom: CGFloat, _ safeBottom: CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> BarOnlyTabBarController {
        let tbc = BarOnlyTabBarController()
        tbc.delegate = context.coordinator
        context.coordinator.parent = self
        tbc.onLayout = { [weak tbc] in
            guard let tbc else { return }
            context.coordinator.reportMetrics(from: tbc)
        }
        apply(to: tbc, context: context)
        return tbc
    }

    func updateUIViewController(_ tbc: BarOnlyTabBarController, context: Context) {
        context.coordinator.parent = self
        apply(to: tbc, context: context)
    }

    private func apply(to tbc: BarOnlyTabBarController, context: Context) {
        // 条目集只在分组 / 排序真的变了时才重建（描述比对），避免每次刷新都换一遍 tab
        if context.coordinator.lastSpecs != items {
            context.coordinator.lastSpecs = items
            tbc.tabs = items.map(makeTab)
        }
        // 选中同步（程序化设置；和用户点选分开，见 Coordinator 的 userInitiated）
        if let target = tbc.tabs.first(where: { $0.identifier == selectedID }),
           tbc.selectedTab?.identifier != selectedID {
            tbc.selectedTab = target
        }
        // 搜索伪页面打开时整条底栏不吃点按（和旧玻璃外壳的行为一致：
        // 关闭走搜索页自己的「关闭」按钮）
        tbc.view.isUserInteractionEnabled = interactionEnabled
    }

    private func makeTab(_ spec: NativeBarItemSpec) -> UITab {
        if spec.id == "search" {
            return UISearchTab(viewControllerProvider: { _ in Self.placeholder() })
        }
        return UITab(title: spec.title ?? "", image: image(for: spec), identifier: spec.id,
                     viewControllerProvider: { _ in Self.placeholder() })
    }

    /// 条目图标：账号 / 生成卡密用用户模板图（资源目录里是 template 渲染，
    /// 系统按选中态着色，和 SF 符号同等待遇），其余页用 AppTab 的 SF 符号；
    /// 「更多」用用户的圆圈省略号模板图
    private func image(for spec: NativeBarItemSpec) -> UIImage? {
        if let tab = spec.tab {
            if let asset = tab.customIconAsset { return UIImage(named: asset) }
            return UIImage(systemName: tab.icon)
        }
        if spec.id == "more" { return UIImage(named: "TabIconMore") }
        return nil
    }

    /// 占位子 VC：透明空视图——页面不在这里渲染（SwiftUI ZStack 整屏托管），
    /// 它存在的唯一意义是让系统底栏有合法的 tab 条目可排
    private static func placeholder() -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        return vc
    }

    final class Coordinator: NSObject, UITabBarControllerDelegate {
        var parent: NativeTabBarView?
        var lastSpecs: [NativeBarItemSpec] = []
        /// 最近一次被 shouldSelect 放行的真实页面点选 id：didSelect 只转发它，
        /// 程序化 set selectedTab / 换条目集引发的回调没有这个标记，一律丢弃
        private var userInitiated: String?

        func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
            guard let parent else { return true }
            if tab is UISearchTab {
                DispatchQueue.main.async { parent.onSearch() }
                return false
            }
            if tab.identifier == "more" {
                DispatchQueue.main.async { parent.onMore() }
                return false
            }
            userInitiated = tab.identifier
            return true
        }

        func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
            guard let parent,
                  userInitiated == selectedTab.identifier,
                  let spec = parent.items.first(where: { $0.id == selectedTab.identifier }),
                  let tab = spec.tab else { return }
            userInitiated = nil
            DispatchQueue.main.async { parent.onSelectPage(tab) }
        }

        /// 量系统底栏的真实帧回填外壳：条高 = 栏顶到条底（条钉在窗口底边，
        /// 条底 = 控制器视图底边）；中心距底、视图底部安全区一并报出，
        /// 页面留白和出处圆钮对齐都读这份量测，不猜常量
        func reportMetrics(from tbc: UITabBarController) {
            guard let parent else { return }
            let bar = tbc.tabBar
            let bounds = tbc.view.bounds
            guard bounds.height > 1, bar.frame.height > 1 else { return }
            parent.onMetrics(bounds.height - bar.frame.minY,
                             bounds.height - bar.frame.midY,
                             tbc.view.safeAreaInsets.bottom)
        }
    }
}
