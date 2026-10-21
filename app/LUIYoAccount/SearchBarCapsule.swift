import SwiftUI

/// 搜索胶囊离页面底边的距离，由外壳注入：
/// - 玻璃外壳：底栏下边距 6 + 栏高 64 + 间隙 10 = 80，胶囊底边正好落在底栏顶边上方 10pt
/// - 旧 TabView 外壳：系统底栏（含主屏幕指示条区）约 83 + 间隙 10 = 93
/// 胶囊永远浮在底栏上方、和底栏零重叠
private struct SearchBarBottomKey: EnvironmentKey {
    static let defaultValue: CGFloat = 80
}

extension EnvironmentValues {
    var searchBarBottom: CGFloat {
        get { self[SearchBarBottomKey.self] }
        set { self[SearchBarBottomKey.self] = newValue }
    }
}

/// 页面内搜索胶囊：放大镜 + 输入框 + 清除钮，表面是系统玻璃（iOS 26）/ 系统材质（旧系统）。
/// 为什么不用系统 searchable：iOS 26 把它的搜索框托管在窗口层、贴屏幕最底部渲染——
/// 它不在页面视图树里，页面的 opacity 隐藏和外壳的底部预留区都管不住它，于是它比
/// 玻璃胶囊更宽、从底栏下方伸出来透过玻璃（Build 16 截图的重叠缺陷）。
/// 改成页面自己的子视图后：显隐完全跟页面走，位置由 searchBarBottom 精确钉在底栏上方
struct SearchBarCapsule: View {
    @Binding var query: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField(prompt, text: $query)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if query.isEmpty == false {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .appFont(.body)
        .padding(.horizontal, 14)
        .frame(height: 48)
        .modifier(SearchCapsuleSurface())
    }
}

/// 胶囊表面：iOS 26 用系统液态玻璃（和底栏同一种玻璃），旧系统退系统材质 + 轻影
private struct SearchCapsuleSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
    }
}
