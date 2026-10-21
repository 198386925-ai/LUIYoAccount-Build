import SwiftUI

/// 外观：全局字体（从设置页搬入，行为不变）+ 底栏排序（四个标签页的先后顺序）
struct AppearanceView: View {
    @EnvironmentObject var fontStore: FontStore
    @EnvironmentObject var tabOrder: TabOrderStore
    @State private var showFontPicker = false
    @State private var fontError: String?
    /// 重命名目标 + 输入框（Build 36）：改的只是显示名覆盖，字体文件不动
    @State private var renameTarget: ImportedFont?
    @State private var renameText = ""
    @State private var editMode: EditMode = .inactive

    var body: some View {
        Form {
            Section {
                Button {
                    fontStore.select("")
                } label: {
                    HStack {
                        Text("系统默认")
                            .foregroundColor(.primary)
                        Spacer()
                        if fontStore.psName.isEmpty {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                ForEach(fontStore.fonts) { f in
                    Button {
                        fontStore.select(f.psName)
                    } label: {
                        HStack {
                            Text(fontStore.displayName(for: f))
                                .font(Font.custom(f.psName, size: 17 * FontStore.computeFactor(psName: f.psName)))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Spacer()
                            if fontStore.psName == f.psName {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("删除", role: .destructive) { fontStore.delete(f) }
                        Button("重命名") {
                            renameText = fontStore.displayName(for: f)
                            renameTarget = f
                        }
                    }
                }
                Button {
                    showFontPicker = true
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text("导入字体（ttf / otf / ttc）")
                    }
                }
            } header: {
                AppSectionHeader("全局字体")
            }

            Section {
                ForEach(tabOrder.order) { tab in
                    HStack(spacing: 10) {
                        Group {
                            if let asset = tab.customIconAsset {
                                Image(asset)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 19, height: 19)
                            } else {
                                Image(systemName: tab.icon)
                            }
                        }
                        .foregroundColor(.accentColor)
                        .frame(width: 24)
                        Text(tab.title)
                        Spacer()
                    }
                }
                .onMove { tabOrder.move(from: $0, to: $1) }
            } header: {
                AppSectionHeader("底栏排序")
            }
        }
        .compactSectionSpacing()
        .navigationTitle("外观")
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(editMode.isEditing ? "完成" : "编辑") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
            }
        }
        .sheet(isPresented: $showFontPicker) {
            FontDocumentPicker { url in
                guard let url else { return }
                do {
                    fontStore.select(try fontStore.importFont(from: url))
                } catch {
                    fontError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
        .alert("导入失败", isPresented: .constant(fontError != nil)) {
            Button("好") { fontError = nil }
        } message: { Text(fontError ?? "") }
        .alert("重命名", isPresented: .constant(renameTarget != nil)) {
            TextField("字体名字", text: $renameText)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("保存") {
                if let t = renameTarget {
                    fontStore.rename(psName: t.psName, to: renameText)
                }
                renameTarget = nil
            }
        } message: {
            Text("只改显示的名字，字体文件不变；把名字清掉保存 = 恢复原名")
        }
    }
}
