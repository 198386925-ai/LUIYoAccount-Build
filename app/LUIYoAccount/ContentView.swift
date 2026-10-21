import SwiftUI

/// 底栏选择值（旧 TabView 外壳用）：页面 tab / 搜索 tab
enum ShellTab: Hashable {
    case page(AppTab)
    case search
}

/// 玻璃换组底栏的分组：A = 排序前 3 页 +「…」；B = 左边出处圆钮 + 其余页
enum BarGroup {
    case a, b
}

/// 外壳（iOS 26 与 16–25 两套）：
/// - iOS 26：液态玻璃换组底栏（照用户参考的 Rex 底栏的切换方式）——栏里所有表面
///   只用系统 Liquid Glass 组件（GlassEffectContainer + glassEffect），不给任何
///   表面填颜色、不贴自绘背景；只有「排布」是自定义的。胶囊里的每个槽位 =
///   图标在上、标题在下（原生 tab 项的长相）；出处圆钮和搜索圆钮仍只有图标。
///   A 组胶囊里是排序前 3 页 + 第 4 个「…」（标题「更多」），右边是独立玻璃圆钮
///   （搜索）；点「…」换到 B 组：刚才所在的页从胶囊里滑出来，变成胶囊左边一个
///   独立玻璃圆钮，胶囊里换成其余页（同样带标题）；点圆钮回 A 组并选中那个页。
///   整栏总宽恒定（左边距到搜索圆钮右缘永不动）：B 组胶囊只让出出处圆钮 + 一个
///   间隔的宽度，不大幅缩短。选中长相照原生底栏：选中槽的图标和标题一起变蓝
///   （accent），未选中是次级灰；选中高亮是一块整槽宽的玻璃透镜（框住图标+标题），
///   它单独住一个 GlassEffectContainer、铺在栏本体的上面一层，用和栏本体同族的
///   .regular 玻璃（和栏同住一个容器时两块玻璃会融成一体、透镜没有边界看不见——
///   Build 16/17 的教训，所以必须分层），带 glassEffectID、同组内切换时弹簧变形；
///   图标按钮在最上层。
///   换组动画只动底栏几何（出处项滑出、B 组槽位摊开），页面一律同帧硬切不淡入淡出。
///   页面全部活在一个 ZStack 里（首次访问后挂载并保活），搜索是盖在上面的伪页面。
/// - iOS 16–25：Build 19 的原生 TabView 外壳降级保留（五个页全部直排、带文字 + 搜索 tab）。
/// 顺序由 TabOrderStore 管理（外观页里拖动排序）：前 3 个进 A 组，其余进 B 组。
struct ContentView: View {
    @EnvironmentObject var api: AccountAPI
    @StateObject private var tabOrder = TabOrderStore()
    @State private var autoDone = false
    // 旧外壳（iOS 16–25）状态
    @State private var selection: ShellTab = .page(.accounts)
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
    /// 换组动画进度：0 = A 组布局，1 = B 组布局。底栏几何（胶囊位置/宽度、各槽位
    /// 中心/宽度、出处项位置）全部由它插值算出，换组时用弹簧推到另一端；
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
        // 搜索胶囊离底边距离默认按玻璃外壳算（6 + 64 + 10）；旧 TabView 外壳自己改成 93
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
                glassShell
            } else {
                legacyShell
            }
        }
        .onChange(of: tabOrder.order) { _ in
            // 玻璃外壳：排序变了重置回 A 组；旧外壳五个页都在栏里，选中天然有效，不用修
            if #available(iOS 26.0, *) {
                resetGlassForOrderChange()
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

    /// 五个页面同住一个 ZStack：访问过的才挂载，挂载后一直保活（opacity 切显隐），
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
            Color.clear.frame(height: 100)
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

    /// 换组「裂开/合拢」的弹簧：驱动 swapProgress，槽位帧和出处项跟着它走
    private var swapSpring: Animation { .spring(response: 0.42, dampingFraction: 0.82) }

    /// 推 swapProgress 到目标端：动画只动底栏几何，页面和逻辑状态在此之前已经硬切到位
    private func animateSwap(to target: CGFloat) {
        barAnimating = true
        withAnimation(swapSpring) { swapProgress = target }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { barAnimating = false }
    }

    /// 禁用动画的事务：切页、换组、开关搜索的逻辑状态变更全部走它——
    /// 新页同帧全显、旧页同帧全消，两组永不同时在场
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
    /// 底栏几何随后裂开：出处项从胶囊里滑到左边圆钮位、B 组项摊开填满剩下的胶囊宽度
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

    // MARK: - 玻璃底栏（胶囊 + 出处圆钮 + 搜索圆钮，全系统玻璃）

    /// 底栏分三层（从下到上），手工布局（槽位帧自己算）：栏高 64（图标 + 标题两行）
    /// 1. 栏本体：一个 GlassEffectContainer 装胶囊条、出处圆底、搜索圆钮，全是裸
    ///    形状 + .glassEffect(.regular.interactive())，没有任何颜色填充或自绘背景
    /// 2. 选中透镜：独立的 GlassEffectContainer + 独立命名空间，整槽宽的 .regular
    ///    玻璃胶囊骑在栏本体表面——Build 16/17 它和栏同住一个容器，两块玻璃融成
    ///    一体、透镜没有边界，真机截图里选中态看不见；分层后它像原生底栏的选中
    ///    胶囊一样框住选中槽（图标 + 标题）。整层不吃点按
    /// 3. 槽位按钮：图标在上、标题在下（标题走 App 字体，约 11pt）；选中槽图标和
    ///    标题一起变蓝读 currentPage（跟页面瞬间到位），未选中是次级灰；圆钮只有图标
    /// 几何：总宽恒定，左边距 16、搜索圆钮 56 钉在最右（中心 = 总宽 − 44），两组都
    /// 不动；元素间隔 12。A 组胶囊从 16 到搜索左缘前 12；B 组胶囊让出出处圆钮
    /// （56）+ 一个间隔（12），即起点右移 68、宽度少 68——只少这一截，不大幅缩短。
    /// 槽宽随进度在「A 组等分」与「B 组等分」之间插值，各组项骑着胶囊走；A 组字形
    /// 在进度前 35% 淡出、B 组字形 8% 起淡入 40% 全显，槽位内容永不叠压。
    /// 出处项的圆底和透镜位置在「A 组原槽位」与「左侧圆钮位（44）」之间插值
    @available(iOS 26.0, *)
    private var glassBar: some View {
        GeometryReader { geo in
            let gw = geo.size.width
            let p = swapProgress
            let pillFull = gw - 100              // A 组胶囊宽：总宽 −（左 16 + 搜索 56 + 间隔 12 + 右 16）
            let pillX = 16 + 68 * p              // B 组起点：让出处圆钮 56 + 间隔 12
            let pillW = pillFull - 68 * p        // B 组胶囊只少出处圆钮 + 一个间隔
            let na = CGFloat(tabOrder.barTabs.count + 1)
            let nb = CGFloat(max(tabOrder.moreTabs.count, 1))
            let slotW = pillW * ((1 - p) / na + p / nb)
            let slotWA = pillFull / na
            ZStack {
                // 第一层：栏本体（胶囊条 + 出处圆底 + 搜索圆钮）
                GlassEffectContainer(spacing: 10) {
                    ZStack {
                        Capsule()
                            .foregroundStyle(.clear)
                            .glassEffect(.regular.interactive(), in: Capsule())
                            .frame(width: pillW, height: 64)
                            .position(x: pillX + pillW / 2, y: 32)
                        if p > 0.001 {
                            Circle()
                                .foregroundStyle(.clear)
                                .glassEffect(.regular.interactive(), in: Circle())
                                .frame(width: 56, height: 56)
                                .position(x: originCenterX(slotWA: slotWA, p: p), y: 32)
                                .opacity(p)
                        }
                        glassCircle(icon: "magnifyingglass", tinted: searchShown) {
                            if searchShown { closeSearch() } else { openSearch() }
                        }
                        .position(x: gw - 44, y: 32)
                    }
                    .frame(width: gw, height: 64)
                }
                // 第二层：选中透镜（独立容器 + 独立玻璃，整层不吃点按）
                GlassEffectContainer(spacing: 10) {
                    selectionLens(pillX: pillX, slotW: slotW, slotWA: slotWA, p: p)
                        .frame(width: gw, height: 64)
                }
                .allowsHitTesting(false)
                // 第三层：槽位按钮（图标 + 标题）
                ZStack {
                    aBarItems(pillX: pillX, slotW: slotW, p: p)
                    bBarItems(pillX: pillX, slotW: slotW, p: p)
                    originBarItem(slotWA: slotWA, p: p)
                }
                .frame(width: gw, height: 64)
            }
            .frame(width: gw, height: 64)
        }
        .frame(height: 64)
    }

    /// 出处项中心：A 组原槽位 ↔ 左侧圆钮位（44），随换组进度插值
    private func originCenterX(slotWA: CGFloat, p: CGFloat) -> CGFloat {
        let idx = tabOrder.barTabs.firstIndex(of: originTab) ?? 0
        let slotCenter = 16 + (CGFloat(idx) + 0.5) * slotWA
        return slotCenter + (44 - slotCenter) * p
    }

    /// 出处项上的透镜宽度：整槽宽 ↔ 圆钮内径（52），随换组进度插值
    private func originLensWidth(slotWA: CGFloat, p: CGFloat) -> CGFloat {
        (slotWA - 8) + (52 - (slotWA - 8)) * p
    }

    /// 选中透镜（第二层的内容）：整槽宽的 .regular 玻璃胶囊（框住图标 + 标题），带 glassEffectID 在本层
    /// 自己的命名空间里变形滑动；停在哪一格读 capsuleTab（带弹簧的那份状态）。
    /// A 组项、出处项、B 组项的透镜帧和对应图标项的槽位帧完全一致，淡入淡出节奏
    /// 也跟着各组走；capsuleTab 为 nil（搜索打开时）整层为空、没有透镜
    @available(iOS 26.0, *)
    private func selectionLens(pillX: CGFloat, slotW: CGFloat, slotWA: CGFloat, p: CGFloat) -> some View {
        ZStack {
            if let sel = capsuleTab {
                if sel == originTab {
                    lensCapsule(centerX: originCenterX(slotWA: slotWA, p: p),
                                width: originLensWidth(slotWA: slotWA, p: p),
                                opacity: 1)
                } else if let idx = tabOrder.barTabs.firstIndex(of: sel) {
                    lensCapsule(centerX: pillX + (CGFloat(idx) + 0.5) * slotW,
                                width: slotW - 8,
                                opacity: swapFadeOut(p))
                } else if let idx = tabOrder.moreTabs.firstIndex(of: sel) {
                    lensCapsule(centerX: pillX + (CGFloat(idx) + 0.5) * slotW,
                                width: max(slotW - 8, 0),
                                opacity: swapFadeIn(p))
                }
            }
        }
    }

    @available(iOS 26.0, *)
    private func lensCapsule(centerX: CGFloat, width: CGFloat, opacity: CGFloat) -> some View {
        Capsule()
            .foregroundStyle(.clear)
            .glassEffect(.regular.interactive(), in: Capsule())
            .glassEffectID("selection", in: glassNS)
            .frame(width: width, height: 52)
            .position(x: centerX, y: 32)
            .opacity(opacity)
    }

    /// 换组时 A 组字形的淡出：进度前 35% 内消失
    private func swapFadeOut(_ p: CGFloat) -> CGFloat { min(1, max(0, 1 - p / 0.35)) }
    /// B 组字形的淡入：稍晚起步、进度 40% 时全显，和淡出错开，字形永不同时抢眼
    private func swapFadeIn(_ p: CGFloat) -> CGFloat { min(1, max(0, (p - 0.08) / 0.32)) }

    /// 胶囊里的一个槽位项（最上层，手工定位）：图标在上、标题在下——玻璃表面在
    /// 栏本体层、选中透镜在透镜层，都不在按钮里。内容尺寸固定不变形，动的是中心
    /// 和槽宽；选中长相照原生底栏：图标和标题一起变蓝读 currentPage（跟页面瞬间
    /// 到位），未选中图标和标题都是次级灰
    @available(iOS 26.0, *)
    private func barItem(icon: String, title: String, tinted: Bool,
                         frameWidth: CGFloat, centerX: CGFloat, opacity: CGFloat,
                         hittable: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .semibold))
                Text(title)
                    .appFont(size: 12)
                    .lineLimit(1)
            }
            .foregroundStyle(tinted ? Color.accentColor : Color.secondary)
            .frame(width: frameWidth, height: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(opacity)
        .position(x: centerX, y: 32)
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
                    barItem(icon: tab.icon, title: tab.title,
                            tinted: !searchShown && currentPage == tab,
                            frameWidth: slotW,
                            centerX: pillX + (CGFloat(idx) + 0.5) * slotW,
                            opacity: op, hittable: hittable) { selectPage(tab) }
                }
            }
            barItem(icon: "ellipsis", title: "更多", tinted: false,
                    frameWidth: slotW,
                    centerX: pillX + (CGFloat(tabOrder.barTabs.count) + 0.5) * slotW,
                    opacity: op, hittable: hittable) { enterGroupB() }
        }
    }

    /// B 组项：其余页，槽宽随进度从 A 组的等分摊开到填满 B 组胶囊
    @available(iOS 26.0, *)
    private func bBarItems(pillX: CGFloat, slotW: CGFloat, p: CGFloat) -> some View {
        let op = swapFadeIn(p)
        let hittable = barGroup == .b && !searchShown && !barAnimating
        return ZStack {
            ForEach(Array(tabOrder.moreTabs.enumerated()), id: \.element) { idx, tab in
                barItem(icon: tab.icon, title: tab.title,
                        tinted: !searchShown && currentPage == tab,
                        frameWidth: slotW,
                        centerX: pillX + (CGFloat(idx) + 0.5) * slotW,
                        opacity: op, hittable: hittable) { selectPage(tab) }
            }
        }
    }

    /// 出处项按钮（最上层）：A 组时就是出处页在胶囊里的那一格——图标 + 标题和普通
    /// 项无异（它是当前页，图标标题一起变蓝）；换组时沿水平线滑到胶囊左侧变成
    /// 独立圆钮，标题随进度淡出、圆钮只剩图标——圆底在栏本体层、透镜在透镜层，
    /// 都跟着同一个进度走，这里只负责内容位置和点按。
    /// 点它：B 组时回 A 组，A 组时等于重选当前页（无副作用）
    @available(iOS 26.0, *)
    private func originBarItem(slotWA: CGFloat, p: CGFloat) -> some View {
        let cx = originCenterX(slotWA: slotWA, p: p)
        let frameW = slotWA + (56 - slotWA) * p
        let hittable = !searchShown && !barAnimating
        let tint: Color = !searchShown && currentPage == originTab ? Color.accentColor : Color.primary
        return Button {
            if barGroup == .b { backToOrigin() } else { selectPage(originTab) }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: originTab.icon)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(tint)
                Text(originTab.title)
                    .appFont(size: 12)
                    .lineLimit(1)
                    .foregroundStyle(tint)
                    .opacity(1 - p)
            }
            .frame(width: frameW, height: 64)
            .contentShape(Rectangle())
            // 标题淡出后不再占视觉重心：整列随进度下移半个标题高，
            // 让图标在 B 组圆钮里落到正中心
            .offset(y: 8 * p)
        }
        .buttonStyle(.plain)
        .position(x: cx, y: 32)
        .allowsHitTesting(hittable)
    }

    /// 独立玻璃圆钮：搜索（永远钉在最右，位置不动），系统玻璃——住在栏本体层里
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

    // MARK: - iOS 16–25 旧外壳（Build 19 的原生 TabView 降级，带文字）

    /// 经典 tabItem 写法：五个页全部直排（图标 + 文字）+ 搜索 tab（排在最后，同样带文字）
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
        // 旧外壳的系统底栏更高：搜索胶囊离底边按「底栏约 83 + 间隙 10」浮在它上方
        .environment(\.searchBarBottom, 93)
    }

    /// 全局搜索点中结果（旧外壳）：五个页都在底栏里，直接切到对应 tab
    private func navigateFromSearch(_ tab: AppTab) {
        selection = .page(tab)
    }
}
