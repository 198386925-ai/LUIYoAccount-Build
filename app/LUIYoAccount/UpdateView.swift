import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 应用更新：查看线上版本 + 上传主 App 的 IPA（走 app-update.php，与账号管理同一密码）。
/// Build 34 起不是底栏页：从设置页推送打开，不再自带 NavigationView（借设置页的导航栈，和外观同款）
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

    var body: some View {
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
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                if pickedURL != nil {
                    LabeledContent("文件", value: pickedName)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    LabeledContent("大小", value: sizeText(pickedSize))
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
                TextField("版本号（留空自动识别）", text: $version)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                TextField("构建号（留空自动识别）", text: $build)
                    .keyboardType(.numberPad)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                TextField("更新说明（可空）", text: $notes)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                Button {
                    Task { await doUpload() }
                } label: {
                    HStack {
                        if uploading { ProgressView() }
                        Text(uploading ? "上传中…" : "上传并发布")
                    }
                }
                .disabled(pickedURL == nil || uploading)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                if let m = resultMsg {
                    Text(m).appFont(.footnote)
                        .foregroundColor(resultOK ? .green : .red)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            } header: {
                AppSectionHeader("上传新 IPA")
            }

        }
        .compactSectionSpacing()
        .navigationTitle("应用更新")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                // Build 37：刷新改到右上角胶囊按钮（和版本管理页同款），
                // 卡内的蓝色文字按钮已删
                Button("刷新") { Task { await loadLatest() } }
            }
        }
        .sheet(isPresented: $showPicker) {
            IPADocumentPicker { url in
                if let url = url { adopt(url) }
            }
        }
        .task {
            await loadLatest()
        }
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
