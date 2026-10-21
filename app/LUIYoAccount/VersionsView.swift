import SwiftUI

/// 版本管理（Build 32 从「应用更新」页拆出来，单独一个底栏页）：
/// 版本列表，一条版本一张卡——卡顶是信息块（版本号 · Build + 状态胶囊、
/// 发布于、本次更新：老「应用更新」页列表行的长相，Build 33 按用户
/// 要求搬进卡里），下面三行输入框直接改弹窗文案（一级标题 / 二级
/// 文案 / 三级文案），保存按钮写回（version_set 只带文案、不带状态，
/// 后端保持当前状态）。状态不在卡里改：对着卡顶信息行左滑出侧滑
/// 按钮（弹更新 / 禁用 / 恢复正常，按当前状态只显示适用的——和
/// Build 32 以前版本行的侧滑同一套）。
/// 行高按 Build 33 的压缩口径：输入行上下内边距 4（Build 32 是 7）。
struct VersionsView: View {
    @EnvironmentObject var api: AccountAPI
    @EnvironmentObject var fontStore: FontStore
    @State private var versions: [VersionEntry] = []
    @State private var loaded = false
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            Form {
                if versions.isEmpty {
                    Section {
                        Text(loaded ? "暂无版本记录（在「应用更新」里发布一个新版本后自动生成；需新版 app-update.php）" : "读取中…")
                            .foregroundColor(.secondary)
                    }
                }
                ForEach(versions) { v in
                    VersionEditCard(entry: v) { newList in
                        versions = newList
                    }
                }
            }
            .compactSectionSpacing()
            .navigationTitle("版本管理")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("刷新") { Task { await load() } }
                }
            }
            .task { await load() }
            .alert("版本管理", isPresented: .constant(errorText != nil)) {
                Button("好") { errorText = nil }
            } message: { Text(errorText ?? "") }
        }
    }

    private func load() async {
        // 后端没升级时报错提示，列表保持空
        do {
            versions = try await api.versionsList()
            loaded = true
        } catch {
            loaded = true
            if !error.isCancelError {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// 单条版本的编辑卡：卡顶信息块（只显示）+ 三行文案输入框 + 保存；
/// 状态不在卡里改——信息行左滑出侧滑按钮改状态（见文件头注释）
private struct VersionEditCard: View {
    @EnvironmentObject var api: AccountAPI
    let entry: VersionEntry
    let onSaved: ([VersionEntry]) -> Void
    @State private var title: String
    @State private var l2: String
    @State private var l3: String
    @State private var saving = false
    @State private var saved = false
    @State private var err: String?

    init(entry: VersionEntry, onSaved: @escaping ([VersionEntry]) -> Void) {
        self.entry = entry
        self.onSaved = onSaved
        _title = State(initialValue: entry.title)
        _l2 = State(initialValue: entry.l2)
        _l3 = State(initialValue: entry.l3)
    }

    var body: some View {
        Section {
            // 信息块（老列表行的长相）：版本号 · Build + 右侧状态胶囊（只显示），
            // 下面发布于 / 本次更新两行只读小字（值空的那行不显示）。
            // 改状态的侧滑挂在这一行上（弹更新 / 禁用 / 恢复正常，按当前状态
            // 只显示适用的；点了直接 version_set 只带状态，文案不动）
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(entry.version) · Build \(entry.build)")
                        .appFont(.headline)
                    if entry.publishedAt > 0 {
                        Text("发布于 " + entry.publishedText)
                            .appFont(.caption)
                            .foregroundColor(.secondary)
                    }
                    if !entry.notes.isEmpty {
                        Text("本次更新：" + entry.notes)
                            .appFont(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 6)
                versionChip
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .swipeActions(edge: .trailing) {
                if entry.state != "soft" {
                    Button("弹更新") { Task { await setState("soft") } }
                        .tint(.orange)
                }
                if entry.state != "banned" {
                    Button("禁用") { Task { await setState("banned") } }
                        .tint(.red)
                }
                if entry.state != "normal" {
                    Button("恢复正常") { Task { await setState("normal") } }
                        .tint(.gray)
                }
            }
            fieldRow("一级标题", placeholder: "弹窗标题", text: $title)
            fieldRow("二级文案", placeholder: "第二行文案", text: $l2)
            fieldRow("三级文案", placeholder: "第三行文案", text: $l3)
            HStack {
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 6) {
                        Text("保存")
                        if saving { ProgressView() }
                    }
                }
                .disabled(saving)
                Spacer()
                if saved {
                    Text("已保存")
                        .appFont(.caption)
                        .foregroundColor(.green)
                } else if let err {
                    Text(err)
                        .appFont(.caption)
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
            }
            .frame(minHeight: 32)
            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
        }
    }

    /// 状态胶囊（只显示、不可点）：老列表行同款——弹更新橙、禁用红、正常灰
    private var versionChip: some View {
        let color: Color = entry.state == "soft" ? .orange : (entry.state == "banned" ? .red : .gray)
        return Text(entry.stateText)
            .appFont(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(8)
    }

    private func fieldRow(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .appFont(.body)
                .frame(width: 70, alignment: .leading)
            TextField(placeholder, text: text)
                .autocorrectionDisabled()
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    /// 侧滑改状态：version_set 只带状态（不带文案），改完用回传列表刷新整页
    private func setState(_ newState: String) async {
        do {
            let list = try await api.versionSet(build: entry.build, state: newState)
            onSaved(list)
        } catch {
            if !error.isCancelError {
                err = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func save() async {
        saving = true
        saved = false
        err = nil
        defer { saving = false }
        do {
            let list = try await api.versionSet(build: entry.build, title: title, l2: l2, l3: l3)
            onSaved(list)
            saved = true
        } catch {
            if !error.isCancelError {
                err = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
