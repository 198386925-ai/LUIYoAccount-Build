import SwiftUI
import UIKit

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

/// 选中胶囊的一帧几何（中心 x / 宽 / 高），换组行程在停靠帧之间插值用
struct LensGeom {
    var cx: CGFloat
    var w: CGFloat
    var h: CGFloat
    static func lerp(_ a: LensGeom, _ b: LensGeom, _ t: CGFloat) -> LensGeom {
        LensGeom(cx: a.cx + (b.cx - a.cx) * t,
                 w: a.w + (b.w - a.w) * t,
                 h: a.h + (b.h - a.h) * t)
    }
}

/// 同组内点选时滑行的选中胶囊（纯色 systemGray5）：中心 / 宽 / 高都是
/// 可动画值，跟着 capsuleTab 的弹簧事务连续插值；滑行中途按离落位中心
/// 的距离把宽度微微拉长（原生选中胶囊滑行时的果冻感），落位自动收回。
/// 换组时不用它——换组走 swapProgress 插值的行程帧（travelLensFrame）
private struct GlideLens: View, Animatable {
    var centerX: CGFloat
    var width: CGFloat
    var height: CGFloat
    /// 落位中心（不参与插值）：离它越远拉得越长，到位归零
    var targetCenterX: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(centerX, AnimatablePair(width, height)) }
        set {
            centerX = newValue.first
            width = newValue.second.first
            height = newValue.second.second
        }
    }

    var body: some View {
        let stretch = min(26, abs(centerX - targetCenterX) * 0.45)
        Capsule()
            .fill(Color(UIColor.systemGray5))
            .frame(width: max(width + stretch, 0), height: height)
            .position(x: centerX, y: 32)
    }
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
///   （accent），未选中是次级灰；选中高亮是一块整槽宽的纯色不透明浅灰胶囊
///   （systemGray5，不带玻璃不带透明——Build 27 用户从三版对比图里选的
///   2 号；Build 26 的白色 50% 被否），铺在栏本体的上面一层框住图标+标题，
///   同组内切换时随弹簧滑动；
///   图标按钮在最上层。
///   换组动画（Build 28 照原生底栏的切换手感，全栏一根弹簧）：槽位项各自
///   钉在本组静止帧上只淡入淡出（不横移）；出处字形沿底栏轴线直线滑进
///   左侧圆钮；选中胶囊实地滑行——同组内滑到新槽（中途微微拉长），
///   换组时先滑出到圆钮帧、再滑回胶囊条落到新选中槽。
///   页面一律同帧硬切不淡入淡出。
///   页面全部活在一个 ZStack 里（首次访问后挂载并保活），搜索是盖在上面的伪页面。
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
    /// 只有这份状态在同一组内点选时用 withAnimation 更新，让高亮胶囊在底栏内部
    /// 自己滑动——动画上下文被关在底栏子树里，泄不到页面 ZStack 上。
    @State private var capsuleTab: AppTab? = .accounts
    /// 换组动画进度：0 = A 组布局，1 = B 组布局。胶囊玻璃的位置/宽度、出处
    /// 圆钮的淡入淡出、出处字形的滑行、选中胶囊的换组行程全部由它插值；
    /// 其余槽位项的帧按各自组别的静止几何算（A 组项永远用 A 组帧、B 组项
    /// 永远用 B 组帧），只随进度淡入淡出、绝不横移（Build 27 定版）。
    /// 换组时用底栏唯一的那根弹簧推到另一端；逻辑状态（barGroup /
    /// currentPage）仍然同帧硬切，页面不参与这个动画
    @State private var swapProgress: CGFloat = 0
    /// 换组动画进行中：底栏项暂时不可点，防止动画中途误触把状态打乱
    @State private var barAnimating = false
    /// 选中胶囊的换组行程（Build 28）：(aTab, bTab) = 这次换组两端的选中页
    /// （进 B 组：aTab = 出处页、bTab = 第一个 B 组页；回 A 组：aTab = 出处
    /// 页、bTab = 离开的 B 组页）。行程路径两个方向共用一条：A 组槽（p=0）
    /// → 出处圆钮帧（p≈0.5）→ B 组槽（p=1）——进组正着走、回组倒着走，
    /// 两头和落位帧严丝合缝。只在换组动画期间非 nil，落位后清掉，
    /// 常态高亮（GlideLens）接管
    @State private var lensTravel: (aTab: AppTab, bTab: AppTab)?
    /// 窗口底安全区的活值（Build 31 引入、32 沿用）：从当前 key window
    /// 读回，不写死 34。玻璃外壳的几何换算全用它：底栏下边距、页面底部
    /// 留白、搜索胶囊下边距这三个锚都停在安全线（或以安全线为锚），
    /// 代码值一律 = 渲染值 − 这个活值（渲染口径见各处注释）
    @State private var windowBottomInset: CGFloat = 0

    /// 刷新窗口底安全区：key window 优先，没有就退任意 window；
    /// 根 body 和玻璃外壳出现时各刷一次（登录转场前就已就位）
    private func refreshWindowBottomInset() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        if let w = windows.first(where: { $0.isKeyWindow }) ?? windows.first {
            windowBottomInset = w.safeAreaInsets.bottom
        }
    }

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
        // 搜索胶囊的渲染下边距按玻璃外壳算 = 84（栏顶渲染 74 + 10，Build 33）；
        // 胶囊的锚（GlobalSearchView 的 overlay）停在安全线上，注入的代码值 =
        // 渲染值 − 窗口底安全区活值；旧 TabView 外壳自己改成 93
        .environment(\.searchBarBottom, max(84 - windowBottomInset, 0))
        .onAppear {
            refreshWindowBottomInset()
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
            // 玻璃外壳：排序变了重置回 A 组；旧外壳：出处/分组跟着新顺序归一（页面不跳）
            if #available(iOS 26.0, *) {
                resetGlassForOrderChange()
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
        case .versions: VersionsView()
        case .settings: SettingsView()
        }
    }

    // MARK: - iOS 26 液态玻璃换组外壳

    /// 六个页面同住一个 ZStack：访问过的才挂载，挂载后一直保活（opacity 切显隐），
    /// 各自的导航栈、滚动位置、已加载数据都不丢；搜索以伪页面盖在最上层。
    /// 底部 safeAreaInset 留出底栏高度，页面内容永远不被浮动底栏挡住。
    ///
    /// 底栏定位（Build 32）：回到 Build 30 的 overlay 锚——底栏挂在页面层
    /// 的 .overlay(alignment: .bottom) 上，这个锚的行为真机量过、可预测：
    /// 渲染下边距 = 代码下边距 + 窗口底安全区（Build 27: 55 = 21 + 34、
    /// Build 30: 44 = 10 + 34）。31 版改用 GeometryReader 显式公式，
    /// 在「层真沉到物理底边」的那种布局结果下把安全区重复加了一遍，
    /// 栏被推到屏外（用户截图：只剩胶囊顶边一条露在屏幕底边上），整层
    /// 删掉。32 版下边距 = 4 − 窗口底安全区活值（用户机上 = 4 − 34
    /// = −30，渲染下边距恰好 4，贴底停靠）；33 版按用户要求把目标
    /// 改成 10：下边距 = 10 − 窗口底安全区活值（用户机上 = 10 − 34
    /// = −24），渲染下边距恰好 10，栏占 [10, 74]；钳制保证代码
    /// 下边距不小于 −安全区，渲染间隙永不为负。
    /// 页面留白和搜索胶囊这两个锚同样停在安全线，代码值 = 渲染值 −
    /// 窗口底安全区活值（31 版的换算保留）：页面留白渲染 104（栏顶
    /// 渲染 74 + 上方间隔 30），搜索胶囊渲染 84（栏顶 + 10，注入处换算）。
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
        .ignoresSafeArea(edges: .bottom)
        // 页面显隐永远硬切：容器这一层把动画钉死，任何来源的动画都别想让页面淡入淡出
        .transaction { $0.animation = nil }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: max(104 - windowBottomInset, 0))
        }
        .overlay(alignment: .bottom) {
            glassBar
                .padding(.bottom, barBottomPadding)
        }
        .onAppear {
            refreshWindowBottomInset()
            normalizeGlassOnAppear()
        }
        .onChange(of: currentPage) { mountedPages.insert($0) }
    }

    /// 底栏下边距（代码值）：渲染下边距 10 − 窗口底安全区活值（见 glassShell
    /// 注释）；钳制下限 −安全区，保证渲染间隙不会被拉成负数
    private var barBottomPadding: CGFloat {
        max(10 - windowBottomInset, -windowBottomInset)
    }

    /// 底栏唯一的一根弹簧（Build 28 定版，照原生底栏的切换手感调的
    /// 0.35 / 0.8）：同组内选中胶囊的滑行（capsuleTab）和换组时
    /// swapProgress 的推进全用它——同一条栏上不许再有第二根弹簧，
    /// 两根弹簧各走各的就是之前切换糊成一团的原因之一
    private var barSpring: Animation { .spring(response: 0.35, dampingFraction: 0.8) }

    /// 推 swapProgress 到目标端：动画只动底栏几何，页面和逻辑状态在此之前已经硬切到位；
    /// 收尾时清掉选中胶囊的换组行程——行程终点帧和落位帧是同一个帧，接管无跳变
    private func animateSwap(to target: CGFloat) {
        barAnimating = true
        withAnimation(barSpring) { swapProgress = target }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            barAnimating = false
            lensTravel = nil
        }
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
        lensTravel = nil
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
        lensTravel = nil
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
    /// 只有高亮胶囊的状态带动画更新——高亮胶囊在底栏内部从旧槽位滑到新槽位，
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
    /// 底栏几何随后裂开：出处槽位在胶囊里原地淡出、独立圆钮在左侧终点位原地淡入
    /// （不横穿整条栏飞过去），B 组项摊开填满剩下的胶囊宽度
    private func enterGroupB() {
        guard let first = tabOrder.moreTabs.first else { return }
        mountedPages.insert(first)
        // 选中胶囊的行程：从当前页（出处）的 A 组槽出发，中途停圆钮帧，
        // 落到第一个 B 组槽——和下面的硬切同帧登记，动画随后由 animateSwap 推
        lensTravel = (aTab: currentPage, bTab: first)
        withTransaction(instant) {
            originTab = currentPage
            barGroup = .b
            currentPage = first
            capsuleTab = first
        }
        animateSwap(to: 1)
    }

    /// 点出处圆钮：回 A 组并选中出处页——页面硬切，底栏几何反向合拢：
    /// 圆钮原地淡出、出处槽位在胶囊里原地淡入，A 组项摊回原样
    private func backToOrigin() {
        // 行程反着走同一条路：从当前 B 组槽出发，中途停圆钮帧，落回出处槽
        lensTravel = (aTab: originTab, bTab: currentPage)
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
        lensTravel = nil
        withTransaction(instant) {
            searchShown = true
            capsuleTab = nil
        }
    }

    /// 搜索里点「关闭」：原样回到进搜索前的页面和分组（硬切，底栏布局也直接对齐那一组）
    private func closeSearch() {
        lensTravel = nil
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
        lensTravel = nil
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

    /// 底栏分三层（从下到上），手工布局（槽位帧自己算）：栏高 64（图标 + 标题
    /// 两行）；胶囊高、出处圆钮直径、搜索圆钮直径全是 64——两组同一个尺寸。
    /// 尺寸位置照原生底栏（Build 27 定版：量用户 Build 24 真机录屏——胶囊与
    /// 圆钮在帧里同高约 105px ≈ 64pt、左边距与圆钮右边距约 20pt；底边间隙
    /// 原为 21pt（总 footprint 64 + 21 = 85），Build 30 按用户要求整栏下调，
    /// 间隙改成 10（footprint 64 + 10 = 74））
    /// 1. 栏本体：一个 GlassEffectContainer 装胶囊条、出处圆底、搜索圆钮，全是裸
    ///    形状 + .glassEffect(.regular.interactive())，没有任何颜色填充或自绘背景
    /// 2. 选中高亮：整槽宽的纯色不透明浅灰胶囊（systemGray5，不带玻璃）骑在栏
    ///    本体表面，框住选中槽（图标 + 标题）。整层不吃点按
    /// 3. 槽位按钮：图标在上、标题在下（标题走 App 字体，约 11pt）；选中槽图标和
    ///    标题一起变蓝读 currentPage（跟页面瞬间到位），未选中是次级灰；圆钮只有图标
    /// 几何：总宽恒定，左边距 20、搜索圆钮 64 钉在最右（中心 = 总宽 − 52），两组
    /// 都不动；元素间隔 12。A 组胶囊从 20 到搜索左缘前 12；B 组胶囊让出出处圆钮
    /// （64）+ 一个间隔（12），即起点右移 76、宽度少 76——只少这一截，不大幅缩短。
    /// 尺寸审计（Build 28）：全栏只有一个尺寸数 64——胶囊高、出处圆钮直径、
    /// 搜索圆钮直径、槽位项高全是它（代码常量和用户截图上量到的渲染高度
    /// 都是 64、上下边对齐）；选中胶囊高 52、圆钮高亮 60 是在 64 里留的
    /// 边距（上下各 6 / 各 2），不是第二个尺寸。栏的纵向位置（Build 32）：
    /// 本体高 64，挂页面层的 overlay 底部锚，下边距 = 10 − 窗口底
    /// 安全区活值，渲染下边距恰好 10——栏占 [10, 74]（Build 33：32 版
    /// 离底 4，用户要求上抬到 10），沉进主屏幕指示条区，指示条压在
    /// 胶囊下部玻璃上。
    /// 换组时随进度插值的是胶囊玻璃的位置/宽度、出处字形的滑行和选中胶囊
    /// 的行程；其余槽位项各自永远用本组的静止帧，只淡入淡出、绝不横移；
    /// A 组字形在进度前 35% 淡出、B 组字形 8% 起淡入 40% 全显，永不叠压。
    /// 出处字形沿轴线滑行：出处页在胶囊里的槽位原地淡出（和其余 A 组项
    /// 一样），字形本体沿底栏轴线（y 恒定、x 单调）直线滑到左侧圆钮位
    /// （52），和槽位项的淡出互补交接；圆底在终点位随进度原地淡入；
    /// 回 A 组时字形反向滑回槽位
    @available(iOS 26.0, *)
    private var glassBar: some View {
        GeometryReader { geo in
            let gw = geo.size.width
            let p = swapProgress
            let pillFull = gw - 116              // A 组胶囊宽：总宽 −（左 20 + 搜索 64 + 间隔 12 + 右 20）
            let pillX = 20 + 76 * p              // 胶囊玻璃的起点（只有玻璃随进度走）：B 组让出处圆钮 64 + 间隔 12
            let pillW = pillFull - 76 * p        // B 组胶囊只少出处圆钮 + 一个间隔
            let pillXB: CGFloat = 96             // B 组胶囊的静止起点 = 20 + 76，B 组项的帧按它算
            let na = CGFloat(tabOrder.barTabs.count + 1)
            let nb = CGFloat(max(tabOrder.moreTabs.count, 1))
            // 槽位静止帧（Build 27）：A 组项永远用 A 组等分、B 组项永远用 B 组等分，
            // 换组时项的帧不动、只有透明度随进度走——不许再有横着混过去的滑动
            let slotWA = pillFull / na
            let slotWB = (pillFull - 76) / nb
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
                                .frame(width: 64, height: 64)
                                .position(x: 52, y: 32)
                                .opacity(p)
                        }
                        glassCircle(icon: "magnifyingglass", tinted: searchShown) {
                            if searchShown { closeSearch() } else { openSearch() }
                        }
                        .position(x: gw - 52, y: 32)
                    }
                    .frame(width: gw, height: 64)
                }
                // 第二层：选中高亮（纯色不透明浅灰，整层不吃点按）
                selectionLens(slotWA: slotWA, slotWB: slotWB, p: p)
                    .frame(width: gw, height: 64)
                    .allowsHitTesting(false)
                // 第三层：槽位按钮（图标 + 标题）：两组项各用本组静止帧，只淡入
                // 淡出；只有出处字形（originBarItem）沿轴线滑行
                ZStack {
                    aBarItems(pillX: 20, slotW: slotWA, p: p)
                    bBarItems(pillX: pillXB, slotW: slotWB, p: p)
                    originBarItem(p: p, slotWA: slotWA)
                }
                .frame(width: gw, height: 64)
            }
            .frame(width: gw, height: 64)
        }
        .frame(height: 64)
    }

    /// 选中高亮（第二层的内容）：纯色不透明浅灰胶囊（systemGray5，不带玻璃
    /// 不带透明），框住选中槽（图标 + 标题）；停在哪一格读 capsuleTab。
    /// Build 28 的动效照原生底栏，和栏本体同一根弹簧（barSpring）：
    /// - 同组内点选：胶囊实地滑过去（GlideLens：中心/宽/高连续插值，中途按
    ///   离落位中心的距离微微拉长，落位收回——原生选中胶囊的果冻感）；
    /// - 换组：胶囊走行程（lensTravel）沿底栏轴线实地滑：A 组槽 → 出处圆钮
    ///   帧（进度 45%–55% 停在圆钮帧，胶囊收成圆钮的高亮）→ B 组槽；回组
    ///   时同一条路径倒着走。行程帧由 swapProgress 插值算出，不再原地
    ///   淡入淡出；
    /// - 出处被选中时圆钮里另有一块圆形高亮（和行程的圆钮帧同位同尺寸）。
    /// capsuleTab 为 nil（搜索打开时）整层为空、没有高亮
    @available(iOS 26.0, *)
    private func selectionLens(slotWA: CGFloat, slotWB: CGFloat, p: CGFloat) -> some View {
        ZStack {
            if let sel = capsuleTab {
                if let travel = lensTravel {
                    let f = travelLensFrame(travel, p: p, slotWA: slotWA, slotWB: slotWB)
                    Capsule()
                        .fill(Color(UIColor.systemGray5))
                        .frame(width: f.w, height: f.h)
                        .position(x: f.cx, y: 32)
                } else {
                    let f = lensFrame(for: sel, slotWA: slotWA, slotWB: slotWB)
                    GlideLens(centerX: f.cx, width: f.w, height: f.h, targetCenterX: f.cx)
                    if sel == originTab {
                        Circle()
                            .fill(Color(UIColor.systemGray5))
                            .frame(width: 60, height: 60)
                            .position(x: 52, y: 32)
                            .opacity(p)
                    }
                }
            }
        }
    }

    /// 选中胶囊的落位帧：A 组槽读 A 组等分、B 组槽读 B 组等分（整槽宽 −8、
    /// 高 52，和槽位项同帧）；哪组都查不到时退到出处圆钮帧
    private func lensFrame(for sel: AppTab, slotWA: CGFloat, slotWB: CGFloat) -> LensGeom {
        if let idx = tabOrder.barTabs.firstIndex(of: sel) {
            return LensGeom(cx: 20 + (CGFloat(idx) + 0.5) * slotWA, w: slotWA - 8, h: 52)
        }
        if let idx = tabOrder.moreTabs.firstIndex(of: sel) {
            return LensGeom(cx: 96 + (CGFloat(idx) + 0.5) * slotWB, w: max(slotWB - 8, 0), h: 52)
        }
        return LensGeom(cx: 52, w: 60, h: 60)
    }

    /// 换组时选中胶囊的行程帧：A 组槽 → 出处圆钮帧 → B 组槽，全部由
    /// swapProgress 插值（进组 p 从 0 到 1、回组从 1 到 0，同一条路径
    /// 反着走）；两头和落位帧是同一个帧，行程开始/结束都不跳
    private func travelLensFrame(_ travel: (aTab: AppTab, bTab: AppTab),
                                 p: CGFloat, slotWA: CGFloat, slotWB: CGFloat) -> LensGeom {
        let a = lensFrame(for: travel.aTab, slotWA: slotWA, slotWB: slotWB)
        let b = lensFrame(for: travel.bTab, slotWA: slotWA, slotWB: slotWB)
        let c = LensGeom(cx: 52, w: 60, h: 60)   // 出处圆钮的高亮帧
        if p < 0.45 { return LensGeom.lerp(a, c, p / 0.45) }
        if p > 0.55 { return LensGeom.lerp(c, b, (p - 0.55) / 0.45) }
        return c
    }

    /// 换组时 A 组字形的淡出：进度前 35% 内消失
    private func swapFadeOut(_ p: CGFloat) -> CGFloat { min(1, max(0, 1 - p / 0.35)) }
    /// B 组字形的淡入：稍晚起步、进度 40% 时全显，和淡出错开，字形永不同时抢眼
    private func swapFadeIn(_ p: CGFloat) -> CGFloat { min(1, max(0, (p - 0.08) / 0.32)) }

    /// 底栏字形来源：SF 符号或用户自定义模板图（Assets）。全部槽位同一个光学
    /// 尺寸：SF 符号 21pt semibold；模板图放进 24×24 框（图本身 25pt 画布、
    /// 墨迹约占 88%，落框后墨迹 ≈21pt）——Build 20 的 SF「ellipsis」三个点在
    /// 同字号下明显比别的字形小、看着不对称，换成用户的圆圈省略号模板图后
    /// 和其他槽位齐平
    private enum BarGlyph {
        case system(String)
        case asset(String)
    }

    /// 页面在玻璃栏里的字形：账号 / 生成卡密用用户的模板图，其余页用线框 SF
    /// 符号（和模板图的线条风格一致）：邮件 envelope、更新 arrow.up.circle、版本管理 rectangle.stack、设置 gearshape
    private func barGlyph(for tab: AppTab) -> BarGlyph {
        if let asset = tab.customIconAsset { return .asset(asset) }
        switch tab {
        case .mail: return .system("envelope")
        case .update: return .system("arrow.up.circle")
        case .versions: return .system("rectangle.stack")
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

    /// 胶囊里的一个槽位项（最上层，手工定位）：图标在上、标题在下——玻璃表面在
    /// 栏本体层、选中高亮在高亮层，都不在按钮里。内容尺寸固定不变形，动的是中心
    /// 和槽宽；选中长相照原生底栏：图标和标题一起变蓝，读 capsuleTab（和选中
    /// 胶囊同一份状态——点选时颜色随那根弹簧跟胶囊一起过渡，略领先胶囊落位；
    /// 页面本身仍是瞬间到位），未选中图标和标题都是次级灰
    @available(iOS 26.0, *)
    private func barItem(glyph: BarGlyph, title: String, tinted: Bool,
                         frameWidth: CGFloat, centerX: CGFloat, opacity: CGFloat,
                         hittable: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                barGlyphView(glyph)
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

    /// A 组项：底栏前 3 页（出处页在 A 组里就是普通槽位项，和其它页一样
    /// 原地淡入淡出）+ 末尾的「…」
    @available(iOS 26.0, *)
    private func aBarItems(pillX: CGFloat, slotW: CGFloat, p: CGFloat) -> some View {
        let op = swapFadeOut(p)
        let hittable = barGroup == .a && !searchShown && !barAnimating
        return ZStack {
            ForEach(Array(tabOrder.barTabs.enumerated()), id: \.element) { idx, tab in
                barItem(glyph: barGlyph(for: tab), title: tab.title,
                        tinted: capsuleTab == tab,
                        frameWidth: slotW,
                        centerX: pillX + (CGFloat(idx) + 0.5) * slotW,
                        opacity: op, hittable: hittable) { selectPage(tab) }
            }
            barItem(glyph: .asset("TabIconMore"), title: "更多", tinted: false,
                    frameWidth: slotW,
                    centerX: pillX + (CGFloat(tabOrder.barTabs.count) + 0.5) * slotW,
                    opacity: op, hittable: hittable) { enterGroupB() }
        }
    }

    /// B 组项：其余页，永远用 B 组胶囊的等分静止帧，只随进度淡入（不横移）
    @available(iOS 26.0, *)
    private func bBarItems(pillX: CGFloat, slotW: CGFloat, p: CGFloat) -> some View {
        let op = swapFadeIn(p)
        let hittable = barGroup == .b && !searchShown && !barAnimating
        return ZStack {
            ForEach(Array(tabOrder.moreTabs.enumerated()), id: \.element) { idx, tab in
                barItem(glyph: barGlyph(for: tab), title: tab.title,
                        tinted: capsuleTab == tab,
                        frameWidth: slotW,
                        centerX: pillX + (CGFloat(idx) + 0.5) * slotW,
                        opacity: op, hittable: hittable) { selectPage(tab) }
            }
        }
    }

    /// 出处圆钮按钮（最上层）：只有图标的内容。圆底在栏本体层、圆形高亮在
    /// 高亮层，都钉在左侧终点位（52）只随进度 p 原地淡入淡出；字形本体是
    /// 全栏唯一平移的项（Build 28）：换组时沿底栏轴线直线滑行（y 恒 32、
    /// x 从它在 A 组里的槽位中心单调滑到圆钮中心 52），透明度和它的槽位
    /// 项的淡出互补——同在进度前 35% 内交接（槽位项淡出多少、字形淡入
    /// 多少）；回 A 组时反向滑回槽位。轨迹是一条直线，不绕弧、不穿过
    /// 别的槽位项（字形在最上层、从胶囊表面上滑过去）。
    /// 点它：回 A 组并选中出处页（只在 B 组可点，滑行中不可点）
    @available(iOS 26.0, *)
    private func originBarItem(p: CGFloat, slotWA: CGFloat) -> some View {
        let hittable = barGroup == .b && !searchShown && !barAnimating
        let tint: Color = !searchShown && currentPage == originTab ? Color.accentColor : Color.primary
        // 滑行轨迹：x 从出处在 A 组里的槽位中心 → 圆钮中心（52），只动 x
        let originIdx = tabOrder.barTabs.firstIndex(of: originTab) ?? 0
        let slotCX = 20 + (CGFloat(originIdx) + 0.5) * slotWA
        let cx = slotCX + (52 - slotCX) * p
        return Button {
            backToOrigin()
        } label: {
            barGlyphView(barGlyph(for: originTab))
                .foregroundStyle(tint)
                .frame(width: 64, height: 64)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(min(1, p / 0.35))
        .position(x: cx, y: 32)
        .allowsHitTesting(hittable)
        .accessibilityHidden(!hittable)
    }

    /// 独立玻璃圆钮：搜索（永远钉在最右，位置不动），系统玻璃——住在栏本体层里
    @available(iOS 26.0, *)
    private func glassCircle(icon: String, tinted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tinted ? Color.accentColor : Color.primary)
                .frame(width: 64, height: 64)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
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
