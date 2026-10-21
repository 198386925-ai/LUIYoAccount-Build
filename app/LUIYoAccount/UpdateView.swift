import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 应用更新：查看线上版本 + 上传主 App 的 IPA（走 app-update.php，与账号管理同一密码）
struct UpdateView: View {
    @EnvironmentObject var api: AccountAPI
    @EnvironmentObject var fontStore: FontStore
    @State private var latest: LatestRelease?
    @State private var latestLoaded = false
    @State private var showPicker = false
    @State private var pickedURL: URL?
    @State private var pickedName = ""
    @State private var pickedSize: Int = 0
    @State private var version = ""
    @State private var build = ""
    @State private var notes = ""
    @State private var uploading = false
    @State private var resultMsg: String?
    @State private var resultOK = false
    @State private var versions: [VersionEntry] = []
    @State private var editTarget: VersionEntry?
    @State private var verMsg: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    if let l = latest {
                        LabeledContent("最新版本", value: l.tagName)
                        LabeledContent("安装包", value: l.assetName)
                        LabeledContent("大小", value: sizeText(l.assetSize))
                        if let b = l.body, !b.isEmpty {
                            Text(b).appFont(.footnote).foregroundColor(.secondary)
                        }
                    } else {
                        Text(latestLoaded ? "尚未发布任何版本" : "读取中…")
                            .foregroundColor(.secondary)
                    }
                    Button("刷新") { Task { await loadLatest() } }
                } header: {
                    AppSectionHeader("线上版本（主 App 更新源）")
                }

                Section {
                    Button {
                        showPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "doc.badge.plus")
                            Text(pickedURL == nil ? "选择 IPA 文件" : "重新选择")
                        }
                    }
                    if pickedURL != nil {
                        LabeledContent("文件", value: pickedName)
                        LabeledContent("大小", value: sizeText(pickedSize))
                    }
                    TextField("版本号（留空自动识别）", text: $version)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                    TextField("构建号（留空自动识别）", text: $build)
                        .keyboardType(.numberPad)
                    TextField("更新说明（可空）", text: $notes)
                    Button {
                        Task { await doUpload() }
                    } label: {
                        HStack {
                            if uploading { ProgressView() }
                            Text(uploading ? "上传中…" : "上传并发布")
                        }
                    }
                    .disabled(pickedURL == nil || uploading)
                    if let m = resultMsg {
                        Text(m).appFont(.footnote)
                            .foregroundColor(resultOK ? .green : .red)
                    }
                } header: {
                    AppSectionHeader("上传新 IPA")
                }

                Section {
                    if versions.isEmpty {
                        Text("暂无版本记录（发布一个新版本后自动生成；需新版 app-update.php）")
                            .foregroundColor(.secondary)
                    }
                    ForEach(versions) { v in
                        versionRow(v)
                    }
                } header: {
                    AppSectionHeader("版本管理")
                }

                Section {
                    Text("上传后包会改名为 LUIYo-版本-b构建.ipa 并更新 latest.json，主 App 检查更新即可发现。更新源：https://luioe.bbroot.com/updates/latest.json")
                        .appFont(.footnote).foregroundColor(.secondary)
                }
            }
            .compactSectionSpacing()
            .navigationTitle("应用更新")
            .sheet(isPresented: $showPicker) {
                IPADocumentPicker { url in
                    if let url = url { adopt(url) }
                }
            }
            .sheet(item: $editTarget) { entry in
                VersionTextEditor(entry: entry) { newList in versions = newList }
            }
            .alert("版本管理", isPresented: .constant(verMsg != nil)) {
                Button("好") { verMsg = nil }
            } message: { Text(verMsg ?? "") }
            .task {
                await loadLatest()
                await loadVersions()
            }
        }
    }

    // MARK: - 版本管理（状态侧滑 + 文案编辑）

    private func versionRow(_ v: VersionEntry) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(v.version) · Build \(v.build)")
                    .appFont(.headline)
                Text("发布于 " + v.publishedText)
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                if !v.notes.isEmpty {
                    Text(v.notes)
                        .appFont(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            // 状态标识对整行上下居中（不再贴在标题那一行）
            versionChip(v)
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
        .swipeActions(edge: .trailing) {
            Button("弹更新") { Task { await setVersionState(v, "soft") } }
                .tint(.orange)
            Button("禁用") { Task { await setVersionState(v, "banned") } }
                .tint(.red)
            Button("恢复正常") { Task { await setVersionState(v, "normal") } }
                .tint(.gray)
            Button("改内容") { editTarget = v }
                .tint(.blue)
        }
    }

    private func versionChip(_ v: VersionEntry) -> some View {
        let color: Color = v.state == "soft" ? .orange : (v.state == "banned" ? .red : .gray)
        return Text(v.stateText)
            .appFont(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(8)
    }

    private func setVersionState(_ v: VersionEntry, _ state: String) async {
        do {
            versions = try await api.versionSet(build: v.build, state: state)
            verMsg = state == "soft" ? "已设为弹更新" : (state == "banned" ? "已禁用该版本" : "已恢复正常")
        } catch {
            if !error.isCancelError { verMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func loadVersions() async {
        // 后端没升级时静默失败，版本管理区保持空
        if let list = try? await api.versionsList() { versions = list }
    }

    private func sizeText(_ n: Int) -> String {
        if n <= 0 { return "—" }
        return String(format: "%.1f MB", Double(n) / 1024 / 1024)
    }

    private func loadLatest() async {
        latest = await api.fetchLatest()
        latestLoaded = true
    }

    private func adopt(_ url: URL) {
        pickedURL = url
        pickedName = url.lastPathComponent
        pickedSize = (try? Data(contentsOf: url).count) ?? 0
        // 从文件名自动识别版本/构建（两种命名都支持）
        let patterns = [
            #"^LUIYo-([0-9]+(?:\.[0-9]+){1,3})-b([1-9][0-9]*)\.ipa$"#,
            #"-([0-9]+(?:\.[0-9]+){1,3}(?:-[0-9]+)?)-Build\(([0-9]+)\)\.ipa$"#
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
               let m = re.firstMatch(in: pickedName, range: NSRange(pickedName.startIndex..., in: pickedName)),
               m.numberOfRanges == 3 {
                var v = (pickedName as NSString).substring(with: m.range(at: 1))
                if let r = v.range(of: #"-[0-9]+$"#, options: .regularExpression) { v.removeSubrange(r) }
                version = v
                build = (pickedName as NSString).substring(with: m.range(at: 2))
                break
            }
        }
        resultMsg = nil
    }

    private func doUpload() async {
        guard let url = pickedURL else { return }
        uploading = true
        resultMsg = nil
        defer { uploading = false }
        do {
            let r = try await api.uploadIPA(fileURL: url, version: version, build: build, notes: notes)
            resultOK = true
            resultMsg = "✅ 已发布：\(r.name ?? "")"
            await loadLatest()
            await loadVersions()
        } catch {
            if !error.isCancelError {
                resultOK = false
                resultMsg = "❌ " + error.localizedDescription
            }
        }
    }
}

/// UIKit 文件选择器（asCopy 直接拿到本地副本，免权限作用域处理）
struct IPADocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.item], asCopy: true)
        vc.delegate = context.coordinator
        vc.allowsMultipleSelection = false
        return vc
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void
        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls.first)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick(nil)
        }
    }
}

/// 版本弹窗文案编辑：标题 / 第二行 / 第三行 + 简单预览块（弹更新蓝、禁用红）
struct VersionTextEditor: View {
    @EnvironmentObject var api: AccountAPI
    @EnvironmentObject var fontStore: FontStore
    @Environment(\.dismiss) private var dismiss
    let entry: VersionEntry
    let onSaved: ([VersionEntry]) -> Void
    @State private var title: String
    @State private var l2: String
    @State private var l3: String
    @State private var saving = false
    @State private var err: String?

    init(entry: VersionEntry, onSaved: @escaping ([VersionEntry]) -> Void) {
        self.entry = entry
        self.onSaved = onSaved
        _title = State(initialValue: entry.title)
        _l2 = State(initialValue: entry.l2)
        _l3 = State(initialValue: entry.l3)
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("标题", text: $title)
                    TextField("第二行", text: $l2)
                    TextField("第三行", text: $l3)
                } header: {
                    AppSectionHeader("弹窗文案（\(entry.version) · Build \(entry.build)）")
                }
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title.isEmpty ? "（标题）" : title)
                            .appFont(.headline, weight: .bold)
                        Text(l2.isEmpty ? "（第二行）" : l2)
                            .appFont(.subheadline)
                        Text(l3.isEmpty ? "（第三行）" : l3)
                            .appFont(.subheadline)
                    }
                    .foregroundColor(.white)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(entry.state == "banned" ? Color.red : Color.blue)
                    .cornerRadius(14)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                } header: {
                    AppSectionHeader("预览（\(entry.stateText)）")
                }
                if let err {
                    Text(err).appFont(.footnote).foregroundColor(.red)
                }
            }
            .compactSectionSpacing()
            .navigationTitle("编辑弹窗内容")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(saving)
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let list = try await api.versionSet(build: entry.build, title: title, l2: l2, l3: l3)
            onSaved(list)
            dismiss()
        } catch {
            if !error.isCancelError { err = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }
}
