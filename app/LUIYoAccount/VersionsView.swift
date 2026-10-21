import SwiftUI

/// 版本管理（Build 32 从「应用更新」页拆出来，单独一个底栏页）：
/// 版本列表，一条版本一张卡——卡头是「版本号 · Build · 状态」，卡里三行
/// 输入框直接改弹窗文案（一级标题 / 二级文案 / 三级文案）、一行状态
/// 选择（正常 / 弹更新 / 禁用），保存按钮一次写回（version_set 带全部字段）。
/// 行高按 Build 32 的压缩口径：输入行上下内边距 7（Form 默认约 11）。
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

/// 单条版本的编辑卡：三行输入框 + 状态分段 + 保存（状态在本卡内改，
/// 不再用侧滑菜单和弹窗编辑器）
private struct VersionEditCard: View {
    @EnvironmentObject var api: AccountAPI
    let entry: VersionEntry
    let onSaved: ([VersionEntry]) -> Void
    @State private var title: String
    @State private var l2: String
    @State private var l3: String
    @State private var state: String
    @State private var saving = false
    @State private var saved = false
    @State private var err: String?

    init(entry: VersionEntry, onSaved: @escaping ([VersionEntry]) -> Void) {
        self.entry = entry
        self.onSaved = onSaved
        _title = State(initialValue: entry.title)
        _l2 = State(initialValue: entry.l2)
        _l3 = State(initialValue: entry.l3)
        _state = State(initialValue: entry.state)
    }

    var body: some View {
        Section {
            fieldRow("一级标题", placeholder: "弹窗标题", text: $title)
            fieldRow("二级文案", placeholder: "第二行文案", text: $l2)
            fieldRow("三级文案", placeholder: "第三行文案", text: $l3)
            Picker("状态", selection: $state) {
                Text("正常").tag("normal")
                Text("弹更新").tag("soft")
                Text("禁用").tag("banned")
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
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
            .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
        } header: {
            AppSectionHeader("\(entry.version) · Build \(entry.build) · \(entry.stateText)")
        }
    }

    private func fieldRow(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .appFont(.body)
                .frame(width: 70, alignment: .leading)
            TextField(placeholder, text: text)
                .autocorrectionDisabled()
        }
        .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
    }

    private func save() async {
        saving = true
        saved = false
        err = nil
        defer { saving = false }
        do {
            let list = try await api.versionSet(build: entry.build, state: state, title: title, l2: l2, l3: l3)
            onSaved(list)
            saved = true
        } catch {
            if !error.isCancelError {
                err = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
