import SwiftUI
import UIKit

/// 生成卡密：批量生成（数量 + SVIP 天数）→ 列表管理（复制 / 作废 / 恢复），用户在主 App 绑卡开通
struct CardsView: View {
    @EnvironmentObject var api: AccountAPI
    @State private var cards: [CardItem] = []
    @State private var countText = "10"
    @State private var days = 30
    @State private var cardFilter: CardFilter = .all
    @State private var remarkText = ""
    @State private var deleteTarget: CardItem?
    @State private var newCodes: [String] = []
    @State private var generating = false
    @State private var error: String?
    @State private var notice: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("分类", selection: $cardFilter) {
                        ForEach(CardFilter.allCases, id: \.self) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))

                Section("生成卡密") {
                    HStack {
                        Text("数量")
                        Spacer()
                        TextField("1–100", text: $countText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    HStack {
                        Text("SVIP 天数")
                        Spacer()
                        Picker("SVIP 天数", selection: $days) {
                            ForEach(dayOptions, id: \.self) { d in
                                Text(d >= 36500 ? "永久" : "\(d) 天").tag(d)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    HStack {
                        Text("备注")
                        Spacer()
                        TextField("客户名/用途，可空", text: $remarkText)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 180)
                    }
                    Button {
                        Task { await generate() }
                    } label: {
                        HStack {
                            Text("生成")
                            if generating { ProgressView() }
                        }
                    }
                    .disabled(generating)
                    Text("格式：LUI-备注-随机码（备注可空）。天数从上面选，选「永久」就是永久卡。生成的卡发给用户，用户在主 App 登录后绑卡开通 SVIP。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                if !newCodes.isEmpty {
                    Section("刚生成（\(newCodes.count) 张）") {
                        Button("复制全部") {
                            UIPasteboard.general.string = newCodes.joined(separator: "\n")
                            notice = "已复制 \(newCodes.count) 张卡密"
                        }
                        ForEach(newCodes, id: \.self) { code in
                            HStack {
                                Text(code)
                                    .font(.system(.footnote, design: .monospaced))
                                Spacer()
                                Button("复制") { UIPasteboard.general.string = code }
                                    .font(.footnote)
                            }
                            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        }
                    }
                }

                if cardFilter != .unused {
                Section("已使用（\(usedCards.count)）") {
                    if usedCards.isEmpty {
                        Text("暂无已使用的卡密")
                            .foregroundColor(.secondary)
                    }
                    ForEach(usedCards) { card in
                        usedRow(card)
                    }
                }
                }

                if cardFilter != .used {
                Section("未使用（\(unusedCards.count)）") {
                    if unusedCards.isEmpty {
                        Text("暂无未使用的卡密")
                            .foregroundColor(.secondary)
                    }
                    ForEach(unusedCards) { card in
                        unusedRow(card)
                    }
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
        }
    }

    private var usedCards: [CardItem] { cards.filter { $0.isBound } }
    private var unusedCards: [CardItem] { cards.filter { !$0.isBound } }

    enum CardFilter: String, CaseIterable {
        case all = "全部"
        case used = "已使用"
        case unused = "未使用"
    }

    private let dayOptions = [30, 90, 180, 365, 36500]

    private func usedRow(_ card: CardItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(card.code)
                    .font(.system(.footnote, design: .monospaced))
                Spacer()
                statusBadge(card)
            }
            if !card.remark.isEmpty {
                Text("备注：" + card.remark)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            copyLine("账号", card.boundEmail, color: .green)
            if !card.boundUdid.isEmpty {
                copyLine("UDID", card.boundUdid, mono: true)
            } else {
                Text("UDID：未获取")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text("时长 " + card.daysText + " · 生成于 " + card.createdText)
                .font(.caption)
                .foregroundColor(.secondary)
            if card.boundAt > 0 {
                Text("绑定时间：" + card.boundAtText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            actionRow(card)
        }
        .padding(.vertical, 1)
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
    }

    private func unusedRow(_ card: CardItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(card.code)
                    .font(.system(.footnote, design: .monospaced))
                Spacer()
                statusBadge(card)
            }
            if !card.remark.isEmpty {
                Text("备注：" + card.remark)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            Text(detailLine(card))
                .font(.caption)
                .foregroundColor(.secondary)
            actionRow(card)
        }
        .padding(.vertical, 1)
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
    }

    private func copyLine(_ label: String, _ value: String, mono: Bool = false, color: Color = .primary) -> some View {
        HStack(spacing: 8) {
            Text(label + "：" + value)
                .font(mono ? .system(.caption2, design: .monospaced) : .caption)
                .foregroundColor(color)
                .lineLimit(1)
            Button("复制") {
                UIPasteboard.general.string = value
                notice = "已复制" + label
            }
            .font(.caption)
        }
    }

    private func actionRow(_ card: CardItem) -> some View {
        HStack(spacing: 16) {
            Button("复制卡密") { UIPasteboard.general.string = card.code }
            Button(card.disabled ? "恢复" : "作废") {
                Task { await toggle(card) }
            }
            .foregroundColor(card.disabled ? .green : .orange)
            Button("删除") { deleteTarget = card }
                .foregroundColor(.red)
        }
        .font(.footnote)
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
            .font(.caption2)
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
