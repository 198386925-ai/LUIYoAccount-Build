import SwiftUI

/// 底栏页面标识：五个页面的顺序由 TabOrderStore 统一管理，
/// 底栏（前 3 个 + 更多）和外观页的「底栏排序」共用同一份顺序
enum AppTab: String, CaseIterable, Identifiable {
    case accounts, cards, mail, update, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accounts: return "账号"
        case .cards: return "生成卡密"
        case .mail: return "邮件"
        case .update: return "应用更新"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .accounts: return "person.2.fill"
        case .cards: return "ticket.fill"
        case .mail: return "envelope.fill"
        case .update: return "arrow.up.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }

    /// 用户自定义图标（Assets 里的模板图，系统按选中态着色，和 SF 符号同等待遇）；
    /// 非 nil 时底栏和外观排序列表都用它，nil = 用上面的 SF 符号
    var customIconAsset: String? {
        switch self {
        case .accounts: return "TabIconAccount"
        case .cards: return "TabIconCard"
        default: return nil
        }
    }
}

/// 底栏顺序仓库：UserDefaults 持久化（tabOrderV1），默认 账号/生成卡密/邮件/应用更新/设置；
/// 改动立即写盘，底栏和排序列表都观察这一份数据
@MainActor
final class TabOrderStore: ObservableObject {
    @Published var order: [AppTab] {
        didSet { UserDefaults.standard.set(order.map(\.rawValue), forKey: Self.key) }
    }

    private static let key = "tabOrderV1"

    init() {
        let saved = (UserDefaults.standard.array(forKey: Self.key) as? [String]) ?? []
        var list = saved.compactMap { AppTab(rawValue: $0) }
        // 去重 + 补齐缺失页面，保证五个页面都在且只出现一次
        var seen = Set<AppTab>()
        list = list.filter { seen.insert($0).inserted }
        for t in AppTab.allCases where !list.contains(t) { list.append(t) }
        order = list
    }

    /// 底栏直接显示的前 3 个
    var barTabs: [AppTab] { Array(order.prefix(3)) }
    /// 收进「更多」的其余页面
    var moreTabs: [AppTab] { Array(order.dropFirst(3)) }

    func move(from source: IndexSet, to destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
    }
}
