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
final class FontStore: ObservableObject {
    static let shared = FontStore()
    static let defaultsKey = "globalFontPS"

    @Published private(set) var fonts: [ImportedFont] = []

    private init() { refresh() }

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
        if Self.selectedPS == font.psName { Self.selectedPS = "" }
        refresh()
    }

    private func firstFont(of url: URL) -> CTFont? {
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let d = descs.first else { return nil }
        return CTFontCreateWithFontDescriptor(d, 0, nil)
    }

    /// 把导航栏标题字体切到指定字体；空 = 恢复系统默认
    static func applyNavigationBarFont(psName: String) {
        let bar = UINavigationBar.appearance()
        if psName.isEmpty {
            bar.titleTextAttributes = nil
            bar.largeTitleTextAttributes = nil
        } else {
            if let t = UIFont(name: psName, size: 17) {
                bar.titleTextAttributes = [.font: t]
            }
            if let lt = UIFont(name: psName, size: 34) {
                bar.largeTitleTextAttributes = [.font: lt]
            }
        }
    }
}

/// 选中了自定义字体时，把环境默认字体换掉（没写死字体的文字都会跟着变）
struct GlobalFontModifier: ViewModifier {
    let psName: String
    func body(content: Content) -> some View {
        Group {
            if psName.isEmpty {
                content
            } else {
                content.environment(\.font, Font.custom(psName, size: 17))
            }
        }
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
