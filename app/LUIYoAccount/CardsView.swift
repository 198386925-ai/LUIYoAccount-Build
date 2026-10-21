import SwiftUI
import UIKit

/// 生成卡密：批量生成（数量 + SVIP 天数）→ 列表管理（复制 / 作废 / 恢复），用户在主 App 绑卡开通
struct CardsView: View {
    @EnvironmentObject var api: AccountAPI
    @EnvironmentObject var fontStore: FontStore
    @State private var cards: [CardItem] = []
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
                    HStack {
                        Text("数量")
                        Spacer()
                        TextField("1–100", text: $countText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SVIP 天数")
                        PillSegmented(options: [("30", "30天"), ("90", "90天"), ("180", "180天"), ("365", "365天"), ("36500", "永久")],
                                      selection: $daysValue)
                    }
                    .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                    HStack {
                        Text("备注")
                        Spacer()
                        TextField("客户名/用途，可空", text: $remarkText)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 180)
                    }
                    .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                    Button {
                        Task { await generate() }
                    } label: {
                        HStack {
                            Text("生成")
                            if generating { ProgressView() }
                        }
                    }
                    .disabled(generating)
                    .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
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
                    Button("刷新") { Task { await load() } }
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

    private func usedRow(_ card: CardItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(card.code)
                    .appFont(.footnote, design: .monospaced)
                Spacer()
                statusBadge(card)
            }
            if !card.remark.isEmpty {
                Text("备注：" + card.remark)
                    .appFont(.caption, weight: .medium)
            }
            Text("账号：" + card.boundEmail)
                .appFont(.caption)
                .foregroundColor(.green)
                .lineLimit(1)
            if !card.boundUdid.isEmpty {
                Text("UDID：" + card.boundUdid)
                    .appFont(.caption2, design: .monospaced)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else {
                Text("UDID：未获取")
                    .appFont(.caption)
                    .foregroundColor(.secondary)
            }
            Text("时长 " + card.daysText + " · 生成于 " + card.createdText)
                .appFont(.caption)
                .foregroundColor(.secondary)
            if card.boundAt > 0 {
                Text("绑定时间：" + card.boundAtText)
                    .appFont(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 1)
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
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
            if !card.boundUdid.isEmpty {
                Button("复制UDID") {
                    UIPasteboard.general.string = card.boundUdid
                    notice = "已复制UDID"
                }
            }
        }
    }

    private func unusedRow(_ card: CardItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(card.code)
                    .appFont(.footnote, design: .monospaced)
                Spacer()
                statusBadge(card)
            }
            if !card.remark.isEmpty {
                Text("备注：" + card.remark)
                    .appFont(.caption, weight: .medium)
            }
            Text(detailLine(card))
                .appFont(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 1)
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
        .swipeActions(edge: .trailing) {
            Button("删除", role: .destructive) { deleteTarget = card }
            Button(card.disabled ? "启用" : "作废") { Task { await toggle(card) } }
                .tint(card.disabled ? .green : .orange)
            Button("复制") {
                UIPasteboard.general.string = card.code
                notice = "已复制卡密"
            }
        }
    }

    private func copyAllUnused() {
        UIPasteboard.general.string = unusedCards.map(\.code).joined(separator: "\n")
        notice = "已复制 \(unusedCards.count) 张未使用卡密"
    }

    private func deleteAllUnused() async {
        do {
            for c in unusedCards { try await api.cardDelete(id: c.id) }
            notice = "已删除全部未使用卡密"
            await load()
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
            await load()
        } catch {
            if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func delete(_ card: CardItem) async {
        do {
            try await api.cardDelete(id: card.id)
            notice = "已删除"
            await load()
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

    private func detailLine(_ card: CardItem) -> String {
        "\(card.daysText) · 生成于 \(card.createdText)"
    }

    private func load() async {
        do {
            cards = try await api.cards()
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
            await load()
        } catch {
            if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func toggle(_ card: CardItem) async {
        do {
            try await api.cardDisable(id: card.id, disabled: !card.disabled)
            await load()
        } catch {
            if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }
}
