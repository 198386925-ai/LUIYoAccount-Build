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
    /// 底栏选中高亮胶囊当前停在哪个槽位：和 currentPage 分开的一份状态。
    /// 切页/换组时 currentPage 一律走禁用动画的事务（瞬间到位、不串页），
    /// 只有这份状态在同一组内点选时用 withAnimation 更新，让玻璃高亮在底栏内部
    /// 自己滑动变形——动画上下文被关在底栏子树里，泄不到页面 ZStack 上。
    @State private var capsuleTab: AppTab? = .accounts
    /// 换组动画进度：0 = A 组布局，1 = B 组布局。底栏的几何（胶囊位置、各槽位中心/宽度、
    /// 出处项位置）全部由它算出，换组时用弹簧把它推到另一端，整栏像 Rex 那样「裂开/合拢」；
    /// 逻辑状态（barGroup / currentPage）仍然同帧硬切，页面不参与这个动画
    @State private var swapProgress: CGFloat = 0
    /// 换组动画进行中：底栏项暂时不可点，防止动画中途误触把状态打乱
    @State private var barAnimating = false
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
        // 页面显隐永远硬切：容器这一层把动画钉死，任何来源的动画都别想让页面淡入淡出
        .transaction { $0.animation = nil }
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

    /// 选中胶囊同组内滑动的弹簧：阻尼略低，让宽胶囊滑过去时带一点果冻过冲（照参考视频）
    private var barSpring: Animation { .spring(response: 0.38, dampingFraction: 0.78) }

    /// 换组「裂开/合拢」的弹簧（0.35–0.45s 一档）：驱动 swapProgress，槽位帧和出处项跟着它走
    private var swapSpring: Animation { .spring(response: 0.42, dampingFraction: 0.82) }

    /// 推 swapProgress 到目标端：动画只动底栏几何，页面和逻辑状态在此之前已经硬切到位
    private func animateSwap(to target: CGFloat) {
        barAnimating = true
        withAnimation(swapSpring) { swapProgress = target }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { barAnimating = false }
    }

    /// 禁用动画的事务：切页、换组、开关搜索的状态变更全部走它——
    /// 新页同帧全显、旧页同帧全消，项集和出处圆钮也是硬切，两组永不同时在场
    private var instant: Transaction {
        var t = Transaction()
        t.disablesAnimations = true
        return t
    }

    /// 首次进入时把状态对齐当前排序：A 组里选中的必须是底栏前 3 页之一
    private func normalizeGlassOnAppear() {
        if barGroup == .a && !tabOrder.barTabs.contains(currentPage) {
            currentPage = tabOrder.barTabs.first ?? .accounts
        }
        originTab = currentPage
        capsuleTab = currentPage
        swapProgress = barGroup == .b ? 1 : 0
        mountedPages.insert(currentPage)
    }

    /// 排序变化（外观页拖动）：玻璃外壳一律重置回 A 组，保证状态和新顺序一致（硬切）
    private func resetGlassForOrderChange() {
        withTransaction(instant) {
            searchShown = false
            barGroup = .a
            if !tabOrder.barTabs.contains(currentPage) {
                currentPage = tabOrder.barTabs.first ?? tabOrder.order.first ?? .accounts
            }
            originTab = currentPage
            capsuleTab = currentPage
            swapProgress = 0
        }
        mountedPages.insert(currentPage)
    }

    /// 点胶囊里同组的另一页：页面本身瞬间到位（禁用动画事务），
    /// 只有高亮胶囊的状态带动画更新——玻璃胶囊在底栏内部从旧槽位滑到新槽位，
    /// 这份动画只影响读 capsuleTab 的槽位视图，进不了页面 ZStack
    private func selectPage(_ tab: AppTab) {
        mountedPages.insert(tab)
        withTransaction(instant) {
            currentPage = tab
            // A 组里出处恒等于当前页（点「…」时弹出去的就是它），随选随同步
            if barGroup == .a { originTab = tab }
        }
        withAnimation(barSpring) { capsuleTab = tab }
    }

    /// 点「…」进 B 组：当前页记为出处，选中其余页的第一个——页面和逻辑状态同帧硬切，
    /// 底栏几何随后裂开：出处项从胶囊里滑到左边圆钮位、B 组项摊开填满同一条胶囊宽度
    private func enterGroupB() {
        guard let first = tabOrder.moreTabs.first else { return }
        mountedPages.insert(first)
        withTransaction(instant) {
            originTab = currentPage
            barGroup = .b
            currentPage = first
            capsuleTab = first
        }
        animateSwap(to: 1)
    }

    /// 点出处圆钮：回 A 组并选中出处页——页面硬切，底栏几何反向合拢：
    /// 圆钮滑回胶囊里的原槽位，A 组项摊回原样
    private func backToOrigin() {
        withTransaction(instant) {
            barGroup = .a
            currentPage = originTab
            capsuleTab = originTab
        }
        animateSwap(to: 0)
    }

    private func openSearch() {
        savedPage = currentPage
        savedGroup = barGroup
        savedOrigin = originTab
        withTransaction(instant) {
            searchShown = true
            capsuleTab = nil
        }
    }

    /// 搜索里点「关闭」：原样回到进搜索前的页面和分组（硬切，底栏布局也直接对齐那一组）
    private func closeSearch() {
        withTransaction(instant) {
            searchShown = false
            currentPage = savedPage
            barGroup = savedGroup
            originTab = savedOrigin
            capsuleTab = savedPage
            swapProgress = savedGroup == .b ? 1 : 0
        }
    }

    /// 搜索点中结果：底栏页 → 回 A 组选中它；其余页 → 进 B 组选中它，
    /// 出处 = 进搜索前所在分组的 A 组页面（A 组时就是当时页面，B 组时是当时的出处）。
    /// 跨组跳转，高亮直接到位、不滑动（硬切）
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
            capsuleTab = tab
            // 搜索是盖在上面的伪页面，跳转直接落位：底栏布局硬切到目标组，不走裂开动画
            swapProgress = barGroup == .b ? 1 : 0
        }
    }

    // MARK: - 玻璃底栏（胶囊 + 出处项 + 搜索圆钮）

    /// 几何全部由 swapProgress 驱动的手工布局（不走 HStack 排版，槽位帧自己算）：
    /// - 胶囊宽度恒定 = 总宽 − 178（两侧边距 32 + 出处圆钮 56 + 搜索圆钮 56 + 间隔 30 + 余量 4），
    ///   两组同一个数、永不缩短；进度 0 时胶囊靠左（x=16），进度 1 时右移 66，出处项停在左边圆钮位
    /// - A 组项（出处页除外，出处由滑动项单独画）+「…」按 A 槽宽骑在胶囊上，随进度前段快速淡出；
    ///   B 组项从 A 槽宽的间距起步、随进度摊开到 B 槽宽填满整条胶囊，淡入稍晚于淡出——
    ///   动的是槽位帧，字形固定尺寸永不叠压、永不同时抢眼
    /// - 出处项是独立的一项：中心在「A 组原槽位」与「左侧圆钮位」之间插值，玻璃圆底随进度淡入，
    ///   看起来就是它从胶囊里滑出来变成圆钮（回 A 组时反向滑回合拢）
    /// - 搜索圆钮永远钉在最右、位置不动。玻璃只用系统 glassEffect / GlassEffectContainer
    @available(iOS 26.0, *)
    private var glassBar: some View {
        GeometryReader { geo in
            let gw = geo.size.width
            let pw = max(180, gw - 178)
            let p = swapProgress
            let pillX = 16 + 66 * p
            let na = CGFloat(tabOrder.barTabs.count + 1)
            let nb = CGFloat(max(tabOrder.moreTabs.count, 1))
            let slotWA = pw / na
            let slotWB = pw * ((1 - p) / na + p / nb)
            ZStack {
                GlassEffectContainer(spacing: 10) {
                    ZStack {
                        Capsule()
                            .fill(Color.clear)
                            .glassEffect(.regular, in: Capsule())
                            .frame(width: pw, height: 56)
                            .position(x: pillX + pw / 2, y: 28)
                        aBarItems(pillX: pillX, slotW: slotWA, p: p)
                        bBarItems(pillX: pillX, slotW: slotWB, p: p)
                        originBarItem(slotWA: slotWA, p: p)
                    }
                    .frame(width: gw, height: 56)
                }
                .frame(width: gw, height: 56)
                glassCircle(icon: "magnifyingglass", tinted: searchShown) {
                    if searchShown { closeSearch() } else { openSearch() }
                }
                .position(x: gw - 44, y: 28)
            }
            .frame(width: gw, height: 56)
        }
        .frame(height: 56)
    }

    /// 换组时 A 组字形的淡出：进度前 35% 内消失（约动画前 0.15s）
    private func swapFadeOut(_ p: CGFloat) -> CGFloat { min(1, max(0, 1 - p / 0.35)) }
    /// B 组字形的淡入：稍晚起步、进度 40% 时全显，和淡出错开
    private func swapFadeIn(_ p: CGFloat) -> CGFloat { min(1, max(0, (p - 0.08) / 0.32)) }

    /// 胶囊里的一个图标项（手工定位）：字形固定 23pt 不变形，动的是中心和槽宽。
    /// capsule = 整槽宽的大玻璃高亮（宽 = 槽宽 − 8，高 44 = 胶囊高 56 − 12），带 glassEffectID；
    /// 它挂在哪一格读 capsuleTab（带弹簧），图标变蓝读 currentPage（跟页面瞬间到位）
    @available(iOS 26.0, *)
    private func barItem(icon: String, capsule: Bool, capsuleWidth: CGFloat, tinted: Bool,
                         frameWidth: CGFloat, centerX: CGFloat, opacity: CGFloat,
                         hittable: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if capsule {
                    Capsule()
                        .fill(Color.clear)
                        .glassEffect(.regular.tint(Color.gray.opacity(0.28)), in: Capsule())
                        .glassEffectID("selection", in: glassNS)
                        .frame(width: capsuleWidth, height: 44)
                }
                Image(systemName: icon)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(tinted ? Color.accentColor : Color.primary)
            }
            .frame(width: frameWidth, height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(opacity)
        .position(x: centerX, y: 28)
        .allowsHitTesting(hittable)
        .accessibilityHidden(!hittable)
    }

    /// A 组项：底栏前 3 页里除出处页（出处由滑动项单独画）+ 末尾的「…」
    @available(iOS 26.0, *)
    private func aBarItems(pillX: CGFloat, slotW: CGFloat, p: CGFloat) -> some View {
        let op = swapFadeOut(p)
        let hittable = barGroup == .a && !searchShown && !barAnimating
        return ZStack {
            ForEach(Array(tabOrder.barTabs.enumerated()), id: \.element) { idx, tab in
                if tab != originTab {
                    barItem(icon: tab.icon,
                            capsule: capsuleTab == tab,
                            capsuleWidth: slotW - 8,
                            tinted: !searchShown && currentPage == tab,
                            frameWidth: slotW,
                            centerX: pillX + (CGFloat(idx) + 0.5) * slotW,
                            opacity: op, hittable: hittable) { selectPage(tab) }
                }
            }
            barItem(icon: "ellipsis", capsule: false, capsuleWidth: 0, tinted: false,
                    frameWidth: slotW,
                    centerX: pillX + (CGFloat(tabOrder.barTabs.count) + 0.5) * slotW,
                    opacity: op, hittable: hittable) { enterGroupB() }
        }
    }

    /// B 组项：其余页，槽宽随进度从 A 组的间距摊开到填满整条胶囊
    @available(iOS 26.0, *)
    private func bBarItems(pillX: CGFloat, slotW: CGFloat, p: CGFloat) -> some View {
        let op = swapFadeIn(p)
        let hittable = barGroup == .b && !searchShown && !barAnimating
        return ZStack {
            ForEach(Array(tabOrder.moreTabs.enumerated()), id: \.element) { idx, tab in
                barItem(icon: tab.icon,
                        capsule: capsuleTab == tab,
                        capsuleWidth: max(slotW - 8, 0),
                        tinted: !searchShown && currentPage == tab,
                        frameWidth: slotW,
                        centerX: pillX + (CGFloat(idx) + 0.5) * slotW,
                        opacity: op, hittable: hittable) { selectPage(tab) }
            }
        }
    }

    /// 出处项：A 组时就是出处页在胶囊里的那一格（和普通项无异），换组时沿水平线滑到
    /// 胶囊左侧变成独立玻璃圆钮；圆底随进度淡入，高亮胶囊宽度从整槽宽收成圆钮内径。
    /// 点它：B 组时回 A 组，A 组时等于重选当前页（无副作用）
    @available(iOS 26.0, *)
    private func originBarItem(slotWA: CGFloat, p: CGFloat) -> some View {
        let idx = tabOrder.barTabs.firstIndex(of: originTab) ?? 0
        let slotCenter = 16 + (CGFloat(idx) + 0.5) * slotWA
        let cx = slotCenter + (44 - slotCenter) * p
        let frameW = slotWA + (56 - slotWA) * p
        let capW = (slotWA - 8) + (52 - (slotWA - 8)) * p
        let hittable = !searchShown && !barAnimating
        return Button {
            if barGroup == .b { backToOrigin() } else { selectPage(originTab) }
        } label: {
            ZStack {
                if p > 0.001 {
                    Circle()
                        .fill(Color.clear)
                        .glassEffect(.regular, in: Circle())
                        .frame(width: 56, height: 56)
                        .opacity(p)
                }
                if capsuleTab == originTab {
                    Capsule()
                        .fill(Color.clear)
                        .glassEffect(.regular.tint(Color.gray.opacity(0.28)), in: Capsule())
                        .glassEffectID("selection", in: glassNS)
                        .frame(width: capW, height: 44)
                }
                Image(systemName: originTab.icon)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(!searchShown && currentPage == originTab ? Color.accentColor : Color.primary)
            }
            .frame(width: frameW, height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .position(x: cx, y: 28)
        .allowsHitTesting(hittable)
    }

    /// 独立玻璃圆钮：搜索（永远钉在最右，位置不动），系统玻璃
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
