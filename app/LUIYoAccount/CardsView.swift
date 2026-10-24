import SwiftUI
import UIKit

/// 生成卡密：批量生成（数量 + SVIP 天数）→ 列表管理（复制 / 作废 / 恢复），用户在主 App 绑卡开通
struct CardsView: View {
    @EnvironmentObject var api: AccountAPI
    @EnvironmentObject var fontStore: FontStore
    /// 卡密列表直接读 App 级缓存（Build 38）：这份表没有行数上限、是最重
    /// 的一份——会话内只拉一次；作废 / 删除由 API 就地改缓存行，不再
    /// 每次操作都整表重拉；只有右上「刷新」才回源（生成后例外：接口只回
    /// 卡号拼不出整行，API 已把缓存置失效，load 只重拉这一份）
    private var cards: [CardItem] { api.cardsCache ?? [] }
    @State private var countText = "10"
    @State private var daysValue = "30"
    @State private var cardFilter: CardFilter = .all
    @State private var remarkText = ""
    @State private var deleteTarget: CardItem?
    @State private var confirmDeleteNewBatch = false
    @State private var confirmDeleteAllUnused = false
    @State private var newCodes: [String] = []
    @State private var generating = false
    @State private var error: String?
    @State private var notice: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    PillSegmented(options: [("all", "全部"), ("used", "已使用"), ("unused", "未使用")],
                                  selection: cardFilterBinding)
                }
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                .listRowBackground(Color.clear)

                Section {
                    // Build 41：数量值改左对齐——标签固定宽在左、值紧随其后
                    // 从同一值列起（和封禁表单的字段同一排法），不再右对齐
                    // 贴在行尾；字段与行为不变
                    HStack(spacing: 10) {
                        Text("数量")
                            .frame(width: 52, alignment: .leading)
                        TextField("1–100", text: $countText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.leading)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SVIP 天数")
                        PillSegmented(options: [("30", "30天"), ("90", "90天"), ("180", "180天"), ("365", "365天"), ("36500", "永久")],
                                      selection: $daysValue)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    // Build 41：备注同数量——左对齐，值从标签后同一列起
                    HStack(spacing: 10) {
                        Text("备注")
                            .frame(width: 52, alignment: .leading)
                        TextField("用户名/用途…", text: $remarkText)
                            .multilineTextAlignment(.leading)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    // 生成按钮 = 账号页封禁按钮同款（Build 36）：整宽胶囊按钮
                    Button {
                        Task { await generate() }
                    } label: {
                        HStack(spacing: 6) {
                            Text("生成")
                            if generating { ProgressView() }
                        }
                        .appFont(.body, weight: .semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(generating)
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                } header: {
                    AppSectionHeader("生成卡密")
                }

                if !newCodes.isEmpty {
                    Section {
                        Button("复制全部") {
                            UIPasteboard.general.string = newCodes.joined(separator: "\n")
                            notice = "已复制 \(newCodes.count) 张卡密"
                        }
                        Button("删除这批") { confirmDeleteNewBatch = true }
                            .foregroundColor(.red)
                        ForEach(newCodes, id: \.self) { code in
                            HStack {
                                Text(code)
                                    .appFont(.footnote, design: .monospaced)
                                Spacer()
                                Button("复制") { UIPasteboard.general.string = code }
                                    .appFont(.footnote)
                            }
                            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        }
                    } header: {
                        AppSectionHeader("刚生成（\(newCodes.count) 张）")
                    }
                }

                if cardFilter != .unused {
                Section {
                    if usedCards.isEmpty {
                        Text("暂无已使用的卡密")
                            .foregroundColor(.secondary)
                    }
                    ForEach(usedCards) { card in
                        usedRow(card)
                    }
                } header: {
                    AppSectionHeader("已使用（\(usedCards.count)）")
                }
                }

                if cardFilter != .used {
                Section {
                    if !unusedCards.isEmpty {
                        HStack(spacing: 18) {
                            Button("批量复制") { copyAllUnused() }
                            Button("批量删除") { confirmDeleteAllUnused = true }
                                .foregroundColor(.red)
                            Spacer()
                            Text("\(unusedCards.count) 张")
                                .appFont(.caption)
                                .foregroundColor(.secondary)
                        }
                        .appFont(.footnote)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    }
                    if unusedCards.isEmpty {
                        Text("暂无未使用的卡密")
                            .foregroundColor(.secondary)
                    }
                    ForEach(unusedCards) { card in
                        unusedRow(card)
                    }
                } header: {
                    AppSectionHeader("未使用（\(unusedCards.count)）")
                }
                }
            }
            .compactSectionSpacing()
            .navigationTitle("生成卡密")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    // Build 38：本页唯一的整表回源入口
                    Button("刷新") { Task { await load(force: true) } }
                }
            }
            .task { await load() }
            .alert("错误", isPresented: .constant(error != nil)) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
            .alert("完成", isPresented: .constant(notice != nil)) {
                Button("好") { notice = nil }
            } message: { Text(notice ?? "") }
            .confirmationDialog("删除这张卡密？", isPresented: .constant(deleteTarget != nil), titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let t = deleteTarget { Task { await delete(t) } }
                    deleteTarget = nil
                }
                Button("取消", role: .cancel) { deleteTarget = nil }
            } message: {
                Text(deleteTarget?.code ?? "")
            }
            .confirmationDialog("删除这批卡密？", isPresented: $confirmDeleteNewBatch, titleVisibility: .visible) {
                Button("全部删除", role: .destructive) { Task { await deleteNewBatch() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("刚生成的 \(newCodes.count) 张卡密会被全部删除")
            }
            .confirmationDialog("删除全部未使用卡密？", isPresented: $confirmDeleteAllUnused, titleVisibility: .visible) {
                Button("全部删除", role: .destructive) { Task { await deleteAllUnused() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("\(unusedCards.count) 张未使用卡密会被全部删除，已使用的不受影响")
            }
        }
    }

    private var usedCards: [CardItem] { cards.filter { $0.isBound } }
    private var unusedCards: [CardItem] { cards.filter { !$0.isBound } }

    enum CardFilter: String, CaseIterable {
        case all = "全部"
        case used = "已使用"
        case unused = "未使用"

        var key: String {
            switch self {
            case .all: return "all"
            case .used: return "used"
            case .unused: return "unused"
            }
        }
        init?(key: String) {
            switch key {
            case "all": self = .all
            case "used": self = .used
            case "unused": self = .unused
            default: return nil
            }
        }
    }

    private var cardFilterBinding: Binding<String> {
        Binding(get: { cardFilter.key }, set: { cardFilter = CardFilter(key: $0) ?? .all })
    }

    private var days: Int { Int(daysValue) ?? 30 }

    // Build 49：已使用卡行改标准表格行（账号页同款）——卡号是一行，
    // 备注、账号、时长、生成于、绑定时间每条各占标准的一行，不再挤
    // 在一张卡里；明细一直都显示着，不收起；侧滑挂在卡号那一行上
    private func usedRow(_ card: CardItem) -> some View {
        let insets = EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16)
        return Group {
            HStack {
                Text(card.code)
                    .appFont(.footnote, design: .monospaced)
                Spacer()
                statusBadge(card)
            }
            .listRowInsets(insets)
            .swipeActions(edge: .trailing) {
                Button("删除", role: .destructive) { deleteTarget = card }
                Button("复制卡密") {
                    UIPasteboard.general.string = card.code
                    notice = "已复制卡密"
                }
                if !card.boundEmail.isEmpty {
                    Button("复制账号") {
                        UIPasteboard.general.string = card.boundEmail
                        notice = "已复制账号"
                    }
                }
            }
            if !card.remark.isEmpty {
                Text("备注：" + card.remark)
                    .appFont(.caption, weight: .medium)
                    .listRowInsets(insets)
            }
            Text("账号：" + card.boundEmail)
                .appFont(.caption)
                .foregroundColor(.green)
                .lineLimit(1)
                .listRowInsets(insets)
            Text("时长 " + card.daysText)
                .appFont(.caption)
                .foregroundColor(.secondary)
                .listRowInsets(insets)
            Text("生成于 " + card.createdText)
                .appFont(.caption)
                .foregroundColor(.secondary)
                .listRowInsets(insets)
            if card.boundAt > 0 {
                Text("绑定时间：" + card.boundAtText)
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                    .listRowInsets(insets)
            }
        }
    }

    // Build 49：未使用卡行同样改标准表格行——卡号是一行，备注、时长、
    // 生成于每条各占标准的一行；侧滑挂在卡号那一行上
    private func unusedRow(_ card: CardItem) -> some View {
        let insets = EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16)
        return Group {
            HStack {
                Text(card.code)
                    .appFont(.footnote, design: .monospaced)
                Spacer()
                statusBadge(card)
            }
            .listRowInsets(insets)
            .swipeActions(edge: .trailing) {
                Button("删除", role: .destructive) { deleteTarget = card }
                Button(card.disabled ? "启用" : "作废") { Task { await toggle(card) } }
                    .tint(card.disabled ? .green : .orange)
                Button("复制") {
                    UIPasteboard.general.string = card.code
                    notice = "已复制卡密"
                }
            }
            if !card.remark.isEmpty {
                Text("备注：" + card.remark)
                    .appFont(.caption, weight: .medium)
                    .listRowInsets(insets)
            }
            Text(card.daysText)
                .appFont(.caption)
                .foregroundColor(.secondary)
                .listRowInsets(insets)
            Text("生成于 " + card.createdText)
                .appFont(.caption)
                .foregroundColor(.secondary)
                .listRowInsets(insets)
        }
    }

    private func copyAllUnused() {
        UIPasteboard.general.string = unusedCards.map(\.code).joined(separator: "\n")
        notice = "已复制 \(unusedCards.count) 张未使用卡密"
    }

    private func deleteAllUnused() async {
        // 先拍快照再逐张删：删除会就地改缓存，边遍历边改会跳行
        let targets = unusedCards
        do {
            for c in targets { try await api.cardDelete(id: c.id) }
            notice = "已删除全部未使用卡密"
            // Build 38：缓存已被逐张就地删净，不再整表重拉
        } catch {
            if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func deleteNewBatch() async {
        let targets = cards.filter { newCodes.contains($0.code) }
        do {
            var remaining = newCodes
            for t in targets {
                try await api.cardDelete(id: t.id)
                remaining.removeAll { $0 == t.code }
            }
            newCodes = remaining
            notice = "已删除这批卡密"
            // Build 38：同上，缓存已就地同步
        } catch {
            if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func delete(_ card: CardItem) async {
        do {
            try await api.cardDelete(id: card.id)
            notice = "已删除"
            // Build 38：缓存已就地同步，不再整表重拉
        } catch {
            if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func statusBadge(_ card: CardItem) -> some View {
        let (text, color): (String, Color) = card.disabled
            ? ("已作废", .red)
            : (card.isBound ? ("已绑定", .green) : ("未使用", .gray))
        return Text(text)
            .appFont(.caption2)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(6)
    }


    private func load(force: Bool = false) async {
        do {
            _ = try await api.cards(force: force)
        } catch {
            if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func generate() async {
        let count = max(1, min(100, Int(countText) ?? 10))
        let days = self.days
        generating = true
        defer { generating = false }
        do {
            let codes = try await api.genCards(count: count, days: days, remark: remarkText.trimmingCharacters(in: .whitespaces))
            newCodes = codes
            notice = "已生成 \(codes.count) 张（每张 \(days >= 36500 ? "永久" : "\(days) 天")）"
            // 生成接口只回卡号：API 已把卡密缓存置失效，这次 load 只重拉卡密这一份
            await load()
        } catch {
            if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func toggle(_ card: CardItem) async {
        do {
            try await api.cardDisable(id: card.id, disabled: !card.disabled)
            // Build 38：作废状态已就地写进缓存行，不再整表重拉
        } catch {
            if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }
}
