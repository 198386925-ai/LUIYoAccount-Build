import SwiftUI

/// 版本管理（Build 32 从「应用更新」页拆出来；Build 39 起不再是底栏
/// 页——和应用更新一起进设置页「版本管理」入口的分类切换，本页是其中
/// 的「版本管理」段；不再自带 NavigationView（借设置页导航栈，和
/// UpdateView 同款），页标题由入口页统一给「版本管理」）：
/// 版本列表，一条版本一张可收起的卡（Build 35）：收起时只显示标题行
/// （版本号 · Build + 右侧状态胶囊，只显示、不加箭头），点标题行展开——
/// 展开后是三行输入框直接改弹窗文案（提示 / 标题 / 原因——Build 36
/// 改的只是输入框标签，后台字段 title/l2/l3 不变；输入框和之前完全
/// 一样，不删不移），保存按钮写回（version_set 只带文案、
/// 不带状态，后端保持当前状态）；保存下面另起一张独立卡放发布信息
/// （发布于 / 本次更新——Build 33 时在卡顶的信息块，Build 35 按用户
/// 要求挪到保存下面的独立卡里）。状态不在卡里改：对着标题行左滑出
/// 侧滑按钮（弹更新 / 禁用 / 恢复正常，按当前状态只显示适用的——和
/// Build 32 以前版本行的侧滑同一套）。
/// 行高按 Build 33 的压缩口径：输入行上下内边距 4（Build 32 是 7）。
/// Build 37：右上「刷新」左边加「编辑」——进入批量删除模式：卡片左侧出
/// 勾选圈、点卡只勾选（不展开不侧滑），底部操作条显示已选个数 + 删除，
/// 确认后按 build 逐个调后端 version_delete（只删记录，不删 IPA 文件）。
struct VersionsView: View {
    @EnvironmentObject var api: AccountAPI
    @EnvironmentObject var fontStore: FontStore
    /// 版本列表直接读 App 级缓存（Build 38）：version_set / version_delete
    /// 的回传列表由 API 直接写进缓存，本页自动刷新、不再多拉一次；
    /// 只有右上「刷新」才回源
    private var versions: [VersionEntry] { api.versionsCache ?? [] }
    @State private var loaded = false
    @State private var errorText: String?
    /// 批量删除（Build 37）：编辑模式 + 已选 build 集（版本以 build 为键，
    /// 与 version_set / 后端注册表同一口径）+ 删除确认 + 删除中
    @State private var editing = false
    @State private var selectedBuilds: Set<String> = []
    @State private var confirmDelete = false
    @State private var deleting = false

    var body: some View {
        Form {
            if versions.isEmpty {
                Section {
                    Text(loaded ? "暂无版本记录（在「应用更新」里发布一个新版本后自动生成；需新版 app-update.php）" : "读取中…")
                        .foregroundColor(.secondary)
                }
            }
            ForEach(versions) { v in
                VersionEditCard(entry: v,
                                editing: editing,
                                selected: selectedBuilds.contains(v.build),
                                onSaved: { _ in /* Build 38：回传列表已由 API 写进缓存 */ },
                                onToggleSelect: {
                                    if selectedBuilds.contains(v.build) {
                                        selectedBuilds.remove(v.build)
                                    } else {
                                        selectedBuilds.insert(v.build)
                                    }
                                })
            }
        }
        .compactSectionSpacing()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(editing ? "完成" : "编辑") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        editing.toggle()
                        if !editing { selectedBuilds.removeAll() }
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("刷新") { Task { await load(force: true) } }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if editing {
                HStack(spacing: 12) {
                    Text("已选 \(selectedBuilds.count) 个")
                        .appFont(.body)
                    Spacer()
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        HStack(spacing: 6) {
                            Text("删除")
                                .appFont(.body, weight: .semibold)
                            if deleting { ProgressView() }
                        }
                    }
                    .disabled(selectedBuilds.isEmpty || deleting)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
        .task { await load() }
        .alert("删除选中的 \(selectedBuilds.count) 个版本？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { Task { await deleteSelected() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后版本列表里不再有它们，弹窗状态同步清掉；已上传的 IPA 文件保留。")
        }
        .alert("版本管理", isPresented: .constant(errorText != nil)) {
            Button("好") { errorText = nil }
        } message: { Text(errorText ?? "") }
    }

    /// 批量删除：按 build 逐个调后端 version_delete（每个回传最新列表，
    /// 用最后一个为准），删完退出编辑模式
    private func deleteSelected() async {
        deleting = true
        defer { deleting = false }
        do {
            // 回传的最新列表已由 API 写进缓存（以最后一次删除的为准）
            for b in selectedBuilds.sorted() {
                _ = try await api.versionDelete(build: b)
            }
            selectedBuilds.removeAll()
            editing = false
        } catch {
            if !error.isCancelError {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func load(force: Bool = false) async {
        // 后端没升级时报错提示，列表保持空
        do {
            _ = try await api.versionsList(force: force)
            loaded = true
        } catch {
            loaded = true
            if !error.isCancelError {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// 单条版本的可收起编辑卡：标题行（只显示版本 + 状态胶囊）+ 展开后的
/// 三行文案输入框、保存，保存下面一张独立信息卡；
/// 状态不在卡里改——标题行左滑出侧滑按钮改状态（见文件头注释）
private struct VersionEditCard: View {
    @EnvironmentObject var api: AccountAPI
    let entry: VersionEntry
    /// 批量删除编辑模式（Build 37）：editing 时点卡只勾选；selected 是勾选态
    let editing: Bool
    let selected: Bool
    let onSaved: ([VersionEntry]) -> Void
    let onToggleSelect: () -> Void
    @State private var title: String
    @State private var l2: String
    @State private var l3: String
    @State private var saving = false
    @State private var saved = false
    @State private var err: String?
    /// 收起/展开（Build 35）：默认收起，只显示标题行
    @State private var expanded = false

    init(entry: VersionEntry, editing: Bool, selected: Bool,
         onSaved: @escaping ([VersionEntry]) -> Void,
         onToggleSelect: @escaping () -> Void) {
        self.entry = entry
        self.editing = editing
        self.selected = selected
        self.onSaved = onSaved
        self.onToggleSelect = onToggleSelect
        _title = State(initialValue: entry.title)
        _l2 = State(initialValue: entry.l2)
        _l3 = State(initialValue: entry.l3)
    }

    /// 发布信息行（保存下面独立卡的内容）：存的更新说明自带「本次更新：」
    /// 前缀时先剥掉再拼标签，不然会显示成「本次更新： 本次更新：…」（Build 35 修）
    private var publishedLine: String? {
        entry.publishedAt > 0 ? "发布于 " + entry.publishedText : nil
    }
    private var notesLine: String? {
        guard !entry.notes.isEmpty else { return nil }
        var n = entry.notes
        for p in ["本次更新：", "本次更新:"] where n.hasPrefix(p) {
            n = String(n.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return "本次更新：" + n
    }
    private var hasInfo: Bool { publishedLine != nil || notesLine != nil }

    /// 有没有没保存的改动（拿输入框现值和服务器现值比）：保存按钮亮/灰看它
    private var dirty: Bool {
        title != entry.title || l2 != entry.l2 || l3 != entry.l3
    }

    var body: some View {
        Group {
            Section {
                // 标题行：版本号 · Build + 右侧状态胶囊（只显示，不加箭头）。
                // 点它收起/展开；改状态的侧滑也挂在这一行上（弹更新 / 禁用 /
                // 恢复正常，按当前状态只显示适用的；点了直接 version_set
                // 只带状态，文案不动）
                HStack(alignment: .center, spacing: 10) {
                    if editing {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .appFont(.title3)
                            .foregroundColor(selected ? .accentColor : .secondary)
                    }
                    Text("\(entry.version) · Build \(entry.build)")
                        .appFont(.headline)
                    Spacer(minLength: 6)
                    versionChip
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if editing {
                        onToggleSelect()
                    } else {
                        withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .swipeActions(edge: .trailing) {
                    if !editing {
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
                }
                if expanded && !editing {
                    fieldRow("提示", placeholder: "弹窗标题", text: $title)
                    fieldRow("标题", placeholder: "第二行文案", text: $l2)
                    fieldRow("原因", placeholder: "第三行文案", text: $l3)
                    // 保存按钮 = 账号页封禁按钮同款（Build 36）：整宽胶囊
                    // 按钮（.borderedProminent）；有未保存改动时亮起，没改动 /
                    // 已保存时置灰不可点（disabled 的系统灰，同封禁按钮口径）。
                    // 已保存 / 报错反馈移到按钮下方一行（行为沿用之前）
                    VStack(spacing: 6) {
                        Button {
                            Task { await save() }
                        } label: {
                            HStack(spacing: 6) {
                                Text("保存")
                                if saving { ProgressView() }
                            }
                            .appFont(.body, weight: .semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(saving || !dirty)
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
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                }
            }
            // 发布信息独立卡（Build 35）：展开后才在保存下面出现，自己一张卡，
            // 只放发布于 / 本次更新两行只读小字（值空的那行不显示，两行都空整卡不出）
            if expanded && !editing && hasInfo {
                Section {
                    VStack(alignment: .leading, spacing: 3) {
                        if let publishedLine {
                            Text(publishedLine)
                                .appFont(.caption)
                                .foregroundColor(.secondary)
                        }
                        if let notesLine {
                            Text(notesLine)
                                .appFont(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }
        }
        // 改了任何一格，「已保存」标记立刻撤下（按钮随 dirty 重新亮起）
        .onChange(of: title) { _ in saved = false }
        .onChange(of: l2) { _ in saved = false }
        .onChange(of: l3) { _ in saved = false }
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
