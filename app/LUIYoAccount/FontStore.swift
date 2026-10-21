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

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? ""
        psName = saved
        factor = Self.computeFactor(psName: saved)
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

    /// 全 App 统一的字体出口：没选自定义字体时是系统语义字体；
    /// 选了就用 Font.custom + 系数缩放（relativeTo 保留 Dynamic Type 相对缩放）
    func font(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
        if psName.isEmpty {
            var f = Font.system(style, design: design)
            if let w = weight { f = f.weight(w) }
            return f
        }
        var w = weight
        if w == nil && style == .headline { w = .semibold }  // headline 本来就带半粗，保持观感
        var f = Font.custom(psName, size: Self.baseSize(for: style) * factor, relativeTo: style)
        if let w { f = f.weight(w) }
        return f
    }

    /// 按 factor 缩放后的 UIKit 字体（给导航栏 / 分段切换 / 标签栏用）
    private static func uiFont(psName: String, size: CGFloat) -> UIFont? {
        UIFont(name: psName, size: size * computeFactor(psName: psName))
    }

    /// 把 UIKit 控件外观刷成当前字体：导航栏标题（17/34 × factor）、
    /// 分段切换（15 × factor，比正文小一号，白边看着才正常）、标签栏小字（10 × factor）
    static func applyUIKitAppearances() {
        let ps = shared.psName
        let bar = UINavigationBar.appearance()
        let seg = UISegmentedControl.appearance()
        let tabItem = UITabBarItem.appearance()
        if ps.isEmpty {
            bar.titleTextAttributes = nil
            bar.largeTitleTextAttributes = nil
            seg.setTitleTextAttributes(nil, for: .normal)
            seg.setTitleTextAttributes(nil, for: .selected)
            tabItem.setTitleTextAttributes(nil, for: .normal)
            tabItem.setTitleTextAttributes(nil, for: .selected)
            return
        }
        if let t = uiFont(psName: ps, size: 17) { bar.titleTextAttributes = [.font: t] }
        if let lt = uiFont(psName: ps, size: 34) { bar.largeTitleTextAttributes = [.font: lt] }
        if let sf = uiFont(psName: ps, size: 15) {
            let attrs: [NSAttributedString.Key: Any] = [.font: sf]
            seg.setTitleTextAttributes(attrs, for: .normal)
            seg.setTitleTextAttributes(attrs, for: .selected)
        }
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

/// 分组标题：显式走 fontStore，自定义字体时不再漏掉 Section 标题
struct AppSectionHeader: View {
    @EnvironmentObject var fontStore: FontStore
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(fontStore.font(.footnote))
            .foregroundColor(.secondary)
    }
}

extension View {
    /// iOS 17+ 收紧分组间距；iOS 16 没有这个 API 就跳过
    @ViewBuilder
    func compactSectionSpacing() -> some View {
        if #available(iOS 17, *) {
            self.listSectionSpacing(.compact)
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
