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
///   （访问过才挂载、保活），搜索是盖在上面的伪页面。动画只有一个时钟
///   （swapSpring 0.38/0.86，Build 25）：切页 / 换组时，条目集替换、条横移、
///   出处圆钮跟随条的左缘、页面缩放过渡全部同 tick 同弹簧驱动——Build 24
///   三套动画各走各的时钟（条弹簧 / 系统条目动画 / 页面瞬切）、录屏里满是
///   重影，这版从结构上杜绝。
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
    /// 出处圆钮的不透明度：和条横移、页面过渡同一个弹簧驱动（swapSpring）；
    /// A 组 = 0（圆钮停在条左缘外的起始位、不可见），B 组 = 1
    @State private var originOpacity: Double = 0
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

    /// 五个页面同住一个 ZStack：访问过的才挂载，挂载后一直保活（各自的导航栈、
    /// 滚动位置、已加载数据都不丢），显隐由 PageFocusModifier 的设计过渡承担
    /// （见下）；搜索以伪页面盖在最上层。
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
                        .modifier(PageFocusModifier(focus: currentPage == tab ? 1 : 0))
                        .zIndex(currentPage == tab ? 1 : 0)
                        .allowsHitTesting(!searchShown && currentPage == tab)
                        .accessibilityHidden(searchShown || currentPage != tab)
                }
            }
            if searchShown {
                GlobalSearchView(onSelect: { pickFromSearch($0) }, onClose: { closeSearch() })
            }
        }
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

    /// 全外壳唯一的动画时钟（Build 25 定版）：切页的页面过渡、换组时条的
    /// 横移与出处圆钮的跟随 / 淡入淡出，全部由这一个弹簧在同一 tick 里
    /// 驱动。Build 24 的教训是三套动画各走各的时钟（条的横移弹簧、系统
    /// 底栏自己的条目动画、页面的瞬切），录屏里互相打架全是重影——这版
    /// 只许这一个节拍，任何切页 / 换组路径都不许再引入别的曲线
    private let swapSpring = Animation.spring(response: 0.38, dampingFraction: 0.86)

    /// 禁用动画的事务：只剩排序变化时的状态归一走它——那是设置页里的数据
    /// 重置，不是一次切页 / 换组，不该带任何动画；切页 / 换组 / 搜索往返
    /// 的动画全部走 swapSpring
    private var instant: Transaction {
        var t = Transaction()
        t.disablesAnimations = true
        return t
    }

    /// 页面焦点过渡（Build 25 的设计动作，不是系统默认交叉淡化）：focus 1 =
    /// 当前页、0 = 非当前页，切页时由 swapSpring 插值 animatableData，
    /// 每一帧的缩放 / 透明 / 下沉都从 focus 算——进场页缩放 0.96→1、透明
    /// 0→1、下沉 10pt 归位；离场页缩放只降到 0.985 且透明度取 focus 的
    /// 1.8 次幂（前段陡降、弹簧中途就已淡没）。两页永远不会同时以高透明
    /// 度在场：Build 24 的标题重影就是两页同帧全显，这版从曲线上杜绝
    private struct PageFocusModifier: ViewModifier, Animatable {
        var focus: Double
        var animatableData: Double {
            get { focus }
            set { focus = newValue }
        }
        func body(content: Content) -> some View {
            let f = min(1, max(0, focus))
            // 缩放分段：focus [0, 0.5] 走 0.96→0.985（离场页在它还看得见的
            // 前半程只缩到 0.985），[0.5, 1] 走 0.985→1（进场页后半程长满）
            let scale: CGFloat = f < 0.5
                ? 0.96 + 0.025 * CGFloat(f / 0.5)
                : 0.985 + 0.015 * CGFloat((f - 0.5) / 0.5)
            return content
                .scaleEffect(scale)
                .offset(y: CGFloat(1 - f) * 10)
                .opacity(pow(f, 1.8))
        }
    }

    /// 首次进入时把状态对齐当前排序：A 组里选中的必须是底栏前 3 页之一
    private func normalizeNativeOnAppear() {
        if barGroup == .a && !tabOrder.barTabs.contains(currentPage) {
            currentPage = tabOrder.barTabs.first ?? .accounts
        }
        originTab = currentPage
        mountedPages.insert(currentPage)
    }

    /// 排序变化（外观页拖动）：一律重置回 A 组，保证状态和新顺序一致（无动画，
    /// 这是设置页里的数据重置、不是一次换组动作）
    private func resetNativeForOrderChange() {
        withTransaction(instant) {
            searchShown = false
            barGroup = .a
            originOpacity = 0
            if !tabOrder.barTabs.contains(currentPage) {
                currentPage = tabOrder.barTabs.first ?? tabOrder.order.first ?? .accounts
            }
            originTab = currentPage
        }
        mountedPages.insert(currentPage)
    }

    /// 点底栏里的真实页（经 TBC 代理 didSelect 同步回报，和底栏自身的选中
    /// 动画同 tick）：页面以 PageFocusModifier 的设计过渡到位（swapSpring）；
    /// A 组里出处恒等于当前页（点「更多」时独立出去的就是它），随选随同步
    private func selectPage(_ tab: AppTab) {
        mountedPages.insert(tab)
        withAnimation(swapSpring) {
            currentPage = tab
            if barGroup == .a { originTab = tab }
        }
    }

    /// 点「更多」进 B 组：当前页记为出处（它将以独立圆钮出现在左边），
    /// 选中其余页的第一个。全部状态在同一个 withAnimation 里变更——条目集
    /// 在 representable 的同帧更新里换成 B 组、条的 leading 横移、出处圆钮
    /// 跟随条左缘并淡入、页面过渡，全部由 swapSpring 一个节拍驱动
    private func enterGroupB() {
        guard let first = tabOrder.moreTabs.first else { return }
        mountedPages.insert(first)
        withAnimation(swapSpring) {
            originTab = currentPage
            barGroup = .b
            currentPage = first
            originOpacity = 1
        }
    }

    /// 点出处圆钮：回 A 组并选中出处页——同一个弹簧里条横移回全宽、圆钮
    /// 跟随条左缘退场并淡出、页面过渡回出处页
    private func backToOrigin() {
        withAnimation(swapSpring) {
            barGroup = .a
            currentPage = originTab
            originOpacity = 0
        }
    }

    private func openSearch() {
        savedPage = currentPage
        savedGroup = barGroup
        savedOrigin = originTab
        searchShown = true
    }

    /// 搜索里点「关闭」：原样回到进搜索前的页面和分组（同一弹簧，
    /// 若页面 / 分组与当前一致则只有搜索页退场、无可见变化）
    private func closeSearch() {
        withAnimation(swapSpring) {
            searchShown = false
            currentPage = savedPage
            barGroup = savedGroup
            originTab = savedOrigin
            originOpacity = savedGroup == .b ? 1 : 0
        }
    }

    /// 搜索点中结果：底栏页 → 回 A 组选中它；其余页 → 进 B 组选中它，
    /// 出处 = 进搜索前所在分组的 A 组页面（A 组时就是当时页面，B 组时是当时的出处）。
    /// 分组若变，和换组同一个编排：条目集、条横移、圆钮跟随、页面过渡同 tick 同弹簧
    private func pickFromSearch(_ tab: AppTab) {
        let returnOrigin = savedGroup == .a ? savedPage : savedOrigin
        mountedPages.insert(tab)
        withAnimation(swapSpring) {
            searchShown = false
            if tabOrder.barTabs.contains(tab) {
                barGroup = .a
                originTab = tab
                currentPage = tab
                originOpacity = 0
            } else {
                barGroup = .b
                originTab = returnOrigin
                currentPage = tab
                originOpacity = 1
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
    /// 横移由全外壳唯一的 swapSpring 驱动 leading：换组的状态变更在同一
    /// tick 里提交，条的条目集在 representable 更新里同帧替换，系统底栏的
    /// 玻璃与条目变形是它自己的事、与条作为一个整体同进同退
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
            // 出处圆钮常驻（不在换组时挂载 / 卸载）：它的中心和条的左缘锁死
            // 在同一个弹簧上——A 态 = 左缘外 24pt 处（originOpacity 0、
            // 不可见、不可点），B 态 = 左缘内、腾空区中心 44pt；换组全程
            // 圆钮随条左缘同进同退并同步淡入 / 淡出，不瞬移、不独立计时、
            // 不从屏幕外飞入
            originCircle
                .position(x: barGroup == .b ? 44 : -24, y: barStripHeight - barCenterFromBottom)
                .opacity(originOpacity)
                .accessibilityHidden(barGroup != .b)
        }
        .frame(maxWidth: .infinity)
        .frame(height: barStripHeight)
        .animation(swapSpring, value: barGroup)
        .ignoresSafeArea(edges: .bottom)
    }

    /// 出处圆钮（B 组时落在底栏左侧腾出的空间里）：56pt 系统玻璃圆按钮，
    /// 字形 = 出处页自己的图标（和它在条里时同一个来源），纵向和系统底栏
    /// 的中心对齐（读量测 barCenterFromBottom）。点它回 A 组并选中出处页。
    /// 它不是选中元素：没有任何高亮 / 透镜 / 染色，选中态的表达只有系统
    /// 底栏那一份（在条里），圆钮字形保持主色。位置 / 透明的动画不在这里：
    /// 由 nativeBar 的布局层按 barGroup / originOpacity 用 swapSpring 统一
    /// 驱动（常驻 + 跟随条左缘，见 nativeBar 注释）；A 组时不可点
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
        .allowsHitTesting(barGroup == .b && !searchShown)
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
/// 和条目集切换引起的回调一律丢弃，不许反过来改外壳状态。代理回调全部
/// 同步直达外壳（Build 25 起不再 DispatchQueue.main.async 转发）：切页
/// 过渡要在与底栏自身选中动画同一个 tick 里起步，异步转发会把两者错开
/// 一帧以上——Build 24 的页面重影有一份就来自这条被延迟的同步路径
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
                parent.onSearch()
                return false
            }
            if tab.identifier == "more" {
                parent.onMore()
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
            parent.onSelectPage(tab)
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
