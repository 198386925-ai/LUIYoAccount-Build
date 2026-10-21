import SwiftUI

/// 页面标识（六个页面共用一套）：账号 / 生成卡密 / 版本管理 / 设置是底栏
/// 标签页，顺序由 TabOrderStore 管理；邮件 / 应用更新不是标签页——它们是
/// 设置页里外观下面的入口行（Build 34 从底栏搬入），标识保留给全局搜索
/// 结果和设置页推送路由用
enum AppTab: String, CaseIterable, Identifiable {
    case accounts, cards, mail, update, versions, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accounts: return "账号"
        case .cards: return "生成卡密"
        case .mail: return "邮件"
        case .update: return "应用更新"
        case .versions: return "版本管理"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .accounts: return "person.2.fill"
        case .cards: return "ticket.fill"
        case .mail: return "envelope.fill"
        case .update: return "arrow.up.circle.fill"
        case .versions: return "rectangle.stack.fill"
        case .settings: return "gearshape"
        }
    }

    /// 用户自定义图标（Assets 里的模板图，系统按选中态着色，和 SF 符号同等待遇）；
    /// 非 nil 时底栏和外观排序列表都用它，nil = 用上面的 SF 符号
    var customIconAsset: String? {
        switch self {
        case .accounts: return "TabIconAccount"
        case .cards: return "TabIconCard"
        case .versions: return "TabIconVersions"
        case .settings: return "TabIconSettings"
        default: return nil
        }
    }

    /// 是底栏标签页的四个（邮件 / 应用更新不是，它们在设置页里）
    var isTabPage: Bool {
        switch self {
        case .accounts, .cards, .versions, .settings: return true
        case .mail, .update: return false
        }
    }
}

/// 底栏顺序仓库：UserDefaults 持久化（tabOrderV1），只管四个标签页的顺序，
/// 默认 账号/生成卡密/版本管理/设置；改动立即写盘，底栏和外观页的
/// 「底栏排序」共用同一份顺序。
/// Build 34 迁移：老存档里有六页（含已搬进设置页的邮件 / 应用更新）——
/// 读档时剔除这两个，其余页的相对顺序原样保留，缺的标签页补到末尾
@MainActor
final class TabOrderStore: ObservableObject {
    @Published var order: [AppTab] {
        didSet { UserDefaults.standard.set(order.map(\.rawValue), forKey: Self.key) }
    }

    private static let key = "tabOrderV1"
    /// 全部标签页（默认顺序 = 迁移补齐顺序）
    static let tabPages: [AppTab] = [.accounts, .cards, .versions, .settings]

    init() {
        let saved = (UserDefaults.standard.array(forKey: Self.key) as? [String]) ?? []
        var list = saved.compactMap { AppTab(rawValue: $0) }.filter { $0.isTabPage }
        // 去重 + 补齐缺失的标签页（补到末尾，用户自定义的顺序不动）
        var seen = Set<AppTab>()
        list = list.filter { seen.insert($0).inserted }
        for t in Self.tabPages where !list.contains(t) {
            list.append(t)
        }
        order = list
    }

    func move(from source: IndexSet, to destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
    }
}
