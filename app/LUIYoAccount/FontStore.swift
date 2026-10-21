import SwiftUI
import CoreText
import UIKit
import UniformTypeIdentifiers

/// 一个导入的字体：文件在 Documents/Fonts/ 里，用 PostScript 名做唯一标识
struct ImportedFont: Identifiable, Equatable {
    let psName: String        // PostScript 名（UserDefaults 里存的就是它）
    let displayName: String   // 展示名
    let fileURL: URL
    var id: String { psName }
}

/// 全局字体仓库：导入 / 注册 / 枚举 / 删除 Documents/Fonts/ 里的字体文件
/// 同时是全 App 的字体供应者：选中的字体 + 适配系数（factor）都从这里出，
/// 所有界面的文字都走 font(_:) 拿字体，不再直接写 .font(.caption) 这类系统语义字体
/// （那样会绕过自定义字体，出现一半自定义一半系统的混排）。
final class FontStore: ObservableObject {
    static let shared = FontStore()
    static let defaultsKey = "globalFontPS"

    @Published private(set) var fonts: [ImportedFont] = []
    /// 当前选中的字体 PostScript 名（空 = 系统默认），改了立刻全 App 重渲染
    @Published private(set) var psName: String = ""
    /// 适配系数：自定义字体的字面通常比系统字体大，按 capHeight 比例把字号压回正常观感
    @Published private(set) var factor: CGFloat = 1
    /// 字距补偿：已按用户要求整体撤下、恒为 0——他要改的从来是文本的上下间距，
    /// 不是字体的左右间距；左右一律按所选字体原本的设计渲染，不再做任何 tracking 修正。
    /// 这个属性只为兼容旧代码保留，永远是 0
    @Published private(set) var trackingCompensation: CGFloat = 0

    /// 固定字号系数：全 App 字号锁死 = 基准字号 × factor × fixedScale，不再带相对字号
    /// 跟随 Dynamic Type 浮动——之前输入框一获得焦点，环境重算字号就小一档（用户实拍），
    /// 现在按那个聚焦后的较小尺寸（×0.9）定死，点不点都不变。根视图再锁 .dynamicTypeSize(.large)。
    static let fixedScale: CGFloat = 0.9

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? ""
        psName = saved
        factor = Self.computeFactor(psName: saved)
        trackingCompensation = Self.computeTrackingCompensation(psName: saved)
        refresh()
    }

    static var fontsDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 当前选中的字体 PostScript 名（空 = 系统默认）
    static var selectedPS: String {
        get { UserDefaults.standard.string(forKey: defaultsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// 切换字体（空 = 系统默认）：存盘 + 重算系数 + 刷新 UIKit 外观（导航栏/分段切换/标签栏）
    func select(_ name: String) {
        psName = name
        UserDefaults.standard.set(name, forKey: Self.defaultsKey)
        factor = Self.computeFactor(psName: name)
        trackingCompensation = Self.computeTrackingCompensation(psName: name)
        Self.applyUIKitAppearances()
    }

    /// 适配系数 = 系统字体 capHeight / 自定义字体 capHeight（同为 17pt 时测），夹在 [0.6, 1.05]
    static func computeFactor(psName: String) -> CGFloat {
        guard !psName.isEmpty, let custom = UIFont(name: psName, size: 17) else { return 1 }
        let sys = UIFont.systemFont(ofSize: 17)
        guard custom.capHeight > 0 else { return 1 }
        let raw = sys.capHeight / custom.capHeight
        return min(1.05, max(0.6, raw))
    }

    /// 量墨迹边界用的位图上下文（只算几何、不真绘制，建一个小的复用）
    private static let measureContext: CGContext? = CGContext(
        data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)

    /// 字距补偿已停用：恒为 0（用户明确要求左右间距完全恢复字体原样，只调上下间距）。
    /// 下面的 inkGap / advanceDeltaPerChar 是旧墨迹测量代码，不再有人调用，留着备查。
    static func computeTrackingCompensation(psName: String) -> CGFloat {
        return 0
    }

    /// 一个字的墨迹间隙 = 字格总宽 − 墨迹总宽。
    /// 同字重复样本：墨迹跨度 = (n−1)×字格宽 + 单字墨迹宽，所以 字格总宽 − 墨迹跨度
    /// 恰好等于单字两侧留白之和，也就是相邻两字墨迹之间的空当。量不到返回 nil。
    private static func inkGap(for sample: String, font: UIFont) -> CGFloat? {
        let attr = NSAttributedString(string: sample, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attr)
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard advance > 0, let ctx = measureContext else { return nil }
        let ink = CTLineGetImageBounds(line, ctx)
        guard ink.width > 0, ink.width.isFinite, ink.width <= advance * 1.05 else { return nil }
        return advance - ink.width
    }

    /// 旧算法（兜底）：每字字格宽差
    private static func advanceDeltaPerChar(_ sample: String, custom: UIFont, sys: UIFont) -> CGFloat? {
        let cw = (sample as NSString).size(withAttributes: [.font: custom]).width
        let sw = (sample as NSString).size(withAttributes: [.font: sys]).width
        let n = CGFloat(sample.count)
        guard n > 0, cw > 0 else { return nil }
        return (cw - sw) / n
    }

    /// 字距：恒为 0。左右间距完全按所选字体的原始设计渲染，App 不做任何
    /// tracking 修正（墨迹补偿和 Build 13 的小字额外收紧都已撤下）
    func scaledTracking(for style: Font.TextStyle) -> CGFloat {
        return 0
    }

    /// 指定字号版的字距：同样恒为 0
    func scaledTracking(forSize size: CGFloat) -> CGFloat {
        return 0
    }

    /// 指定字号的字体出口（PillSegmented 的 12.5pt 标签等非语义字号用）：字号同样锁死
    func font(size: CGFloat, weight: Font.Weight? = nil) -> Font {
        if psName.isEmpty {
            var f = Font.system(size: size * Self.fixedScale)
            if let w = weight { f = f.weight(w) }
            return f
        }
        var f = Font.custom(psName, size: size * factor * Self.fixedScale)
        if let w = weight { f = f.weight(w) }
        return f
    }

    /// 语义样式对应的标准字号（Dynamic Type 默认档）
    static func baseSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline, .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        default: return 17
        }
    }

    /// 全 App 统一的字体出口：字号锁死 = 语义基准字号 × factor × fixedScale，
    /// 不带相对字号、不跟 Dynamic Type 浮动（输入框聚焦时字号不再跳变）；
    /// 没选自定义字体时是同尺寸的系统字体
    func font(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
        var w = weight
        if w == nil && style == .headline { w = .semibold }  // headline 本来就带半粗，保持观感
        let size = Self.baseSize(for: style) * Self.fixedScale
        if psName.isEmpty {
            var f = Font.system(size: size, design: design)
            if let w { f = f.weight(w) }
            return f
        }
        var f = Font.custom(psName, size: size * factor)
        if let w { f = f.weight(w) }
        return f
    }

    /// 按 factor 缩放后的 UIKit 字体（给导航栏 / 分段切换 / 标签栏用）
    private static func uiFont(psName: String, size: CGFloat) -> UIFont? {
        UIFont(name: psName, size: size * computeFactor(psName: psName))
    }

    /// 把 UIKit 控件外观刷成当前字体：导航栏标题（17/34 × factor）、标签栏小字（10 × factor）。
    /// 系统分段切换已全部换成 SwiftUI 的 PillSegmented 复刻（标签走 font(size:)），不再有 UISegmentedControl 外观
    static func applyUIKitAppearances() {
        let ps = shared.psName
        let bar = UINavigationBar.appearance()
        let tabItem = UITabBarItem.appearance()
        if ps.isEmpty {
            bar.titleTextAttributes = nil
            bar.largeTitleTextAttributes = nil
            tabItem.setTitleTextAttributes(nil, for: .normal)
            tabItem.setTitleTextAttributes(nil, for: .selected)
            return
        }
        if let t = uiFont(psName: ps, size: 17) { bar.titleTextAttributes = [.font: t] }
        if let lt = uiFont(psName: ps, size: 34) { bar.largeTitleTextAttributes = [.font: lt] }
        if let tf = uiFont(psName: ps, size: 10) {
            let attrs: [NSAttributedString.Key: Any] = [.font: tf]
            tabItem.setTitleTextAttributes(attrs, for: .normal)
            tabItem.setTitleTextAttributes(attrs, for: .selected)
        }
    }

    /// 兼容旧调用点：等价于 applyUIKitAppearances()
    static func applyNavigationBarFont(psName: String) {
        applyUIKitAppearances()
    }

    static func isFontFile(_ url: URL) -> Bool {
        ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased())
    }

    @discardableResult
    static func register(_ url: URL) -> Bool {
        var err: Unmanaged<CFError>?
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err)
    }

    /// App 启动时调用：把 Documents/Fonts 里所有字体注册进本进程
    static func registerAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: fontsDir, includingPropertiesForKeys: nil) else { return }
        for url in files where isFontFile(url) { register(url) }
    }

    /// 重新扫描目录，把每个字体文件解析成 ImportedFont（ttc 取第一个字体）
    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.fontsDir, includingPropertiesForKeys: nil)) ?? []
        var out: [ImportedFont] = []
        for url in files where Self.isFontFile(url) {
            Self.register(url)
            if let font = firstFont(of: url) {
                out.append(ImportedFont(psName: CTFontCopyPostScriptName(font) as String,
                                        displayName: CTFontCopyDisplayName(font) as String,
                                        fileURL: url))
            }
        }
        fonts = out.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    enum FontStoreError: LocalizedError {
        case unreadable
        var errorDescription: String? { "这个文件读不出字体信息，换个字体文件试试" }
    }

    /// 把外部文件拷进 Documents/Fonts/（同名覆盖），注册后刷新；返回新字体的 PostScript 名
    @discardableResult
    func importFont(from src: URL) throws -> String {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        let dest = Self.fontsDir.appendingPathComponent(src.lastPathComponent)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: src, to: dest)
        Self.register(dest)
        refresh()
        guard let font = fonts.first(where: { $0.fileURL == dest }) else { throw FontStoreError.unreadable }
        return font.psName
    }

    func delete(_ font: ImportedFont) {
        try? FileManager.default.removeItem(at: font.fileURL)
        if psName == font.psName { select("") }
        refresh()
    }

    private func firstFont(of url: URL) -> CTFont? {
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let d = descs.first else { return nil }
        return CTFontCreateWithFontDescriptor(d, 0, nil)
    }
}

/// 全局默认字体：没被单独指定字体的文字（输入框、LabeledContent、菜单标签等）走这里
struct GlobalFontModifier: ViewModifier {
    @EnvironmentObject var fontStore: FontStore
    func body(content: Content) -> some View {
        content.environment(\.font, fontStore.font(.body))
    }
}

/// 全 App 统一的文字出口（Modifier 版，替代散落的 .appFont(...))：
/// 字体走 FontStore；tracking 恒为 0（左右间距不做任何修正）
struct AppFontModifier: ViewModifier {
    @EnvironmentObject var fontStore: FontStore
    let style: Font.TextStyle
    let weight: Font.Weight?
    let design: Font.Design
    func body(content: Content) -> some View {
        content
            .font(fontStore.font(style, weight: weight, design: design))
            .tracking(fontStore.scaledTracking(for: style))
    }
}

/// 指定字号版（PillSegmented 的 12.5pt 标签等）
struct AppSizedFontModifier: ViewModifier {
    @EnvironmentObject var fontStore: FontStore
    let size: CGFloat
    let weight: Font.Weight?
    func body(content: Content) -> some View {
        content
            .font(fontStore.font(size: size, weight: weight))
            .tracking(fontStore.scaledTracking(forSize: size))
    }
}

extension View {
    /// 语义样式：字体 + 字距补偿一步到位
    func appFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design = .default) -> some View {
        modifier(AppFontModifier(style: style, weight: weight, design: design))
    }
    /// 指定字号：字体 + 字距补偿一步到位
    func appFont(size: CGFloat, weight: Font.Weight? = nil) -> some View {
        modifier(AppSizedFontModifier(size: size, weight: weight))
    }
}

/// 分组标题：显式走 fontStore，自定义字体时不再漏掉 Section 标题
struct AppSectionHeader: View {
    @EnvironmentObject var fontStore: FontStore
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .appFont(.footnote)
            .foregroundColor(.secondary)
    }
}

extension View {
    /// iOS 17+ 收紧分组间距（显式 6pt，比 .compact 再紧一点，分组标题贴卡片更近）；
    /// iOS 16 没有这个 API 就跳过
    @ViewBuilder
    func compactSectionSpacing() -> some View {
        if #available(iOS 17, *) {
            self.listSectionSpacing(6)
        } else {
            self
        }
    }
}

/// UIKit 字体文件选择器（.fileImporter 在姐妹 App 里出过问题，这里用原生 UIDocumentPicker，asCopy 直接拿本地副本）
struct FontDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        var types: [UTType] = [.font]
        for ext in ["ttf", "otf", "ttc"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        vc.delegate = context.coordinator
        vc.allowsMultipleSelection = false
        return vc
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void
        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls.first)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick(nil)
        }
    }
}
