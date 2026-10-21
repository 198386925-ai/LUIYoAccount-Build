import SwiftUI

/// 主 App（LUIYo UIKit 版）PillSegmentedControl 的 SwiftUI 复刻，几何参数一一对应原控件：
/// 高 32；轨道圆角 16、填充 rgba(120,120,128,0.10)；滑块白色（深色 #3A3A3C）、圆角 14、
/// 四边内缩 2pt、阴影 black 0.12 / 半径 3 / y+1；滑块宽 =（轨道宽 − 4）/ 选项数，
/// x = 2 + 槽宽 × 序号（只从轨道自身宽度算，不依赖按钮 frame——这是原控件修过的坑），
/// 切换时 0.22s easeInOut 滑动；标签 12.5pt 走 FontStore（含字距补偿），
/// 选中字色 #202832（深色 #F2F2F7），未选中 #6E6E73。
struct PillSegmented: View {
    @Environment(\.colorScheme) private var colorScheme
    let options: [(value: String, title: String)]
    @Binding var selection: String

    private var selectedIndex: Int {
        options.firstIndex { $0.value == selection } ?? 0
    }

    var body: some View {
        GeometryReader { geo in
            let slot = (geo.size.width - 4) / CGFloat(max(options.count, 1))
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color(red: 120.0 / 255, green: 120.0 / 255, blue: 128.0 / 255, opacity: 0.10))
                if !options.isEmpty {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(thumbColor)
                        .frame(width: slot, height: max(geo.size.height - 4, 0))
                        .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1)
                        .offset(x: 2 + slot * CGFloat(selectedIndex), y: 2)
                        .animation(.easeInOut(duration: 0.22), value: selectedIndex)
                }
                HStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                        Button {
                            if selection != opt.value { selection = opt.value }
                        } label: {
                            Text(opt.title)
                                .appFont(size: 12.5)
                                .foregroundColor(selection == opt.value ? selectedColor : unselectedColor)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
            }
        }
        .frame(height: 32)
    }

    private var thumbColor: Color {
        colorScheme == .dark
            ? Color(red: 58.0 / 255, green: 58.0 / 255, blue: 60.0 / 255)   // #3A3A3C
            : .white
    }

    private var selectedColor: Color {
        colorScheme == .dark
            ? Color(red: 0.95, green: 0.95, blue: 0.97)                    // #F2F2F7
            : Color(red: 32.0 / 255, green: 40.0 / 255, blue: 50.0 / 255)  // #202832
    }

    private var unselectedColor: Color {
        Color(red: 110.0 / 255, green: 110.0 / 255, blue: 115.0 / 255)     // #6E6E73
    }
}
