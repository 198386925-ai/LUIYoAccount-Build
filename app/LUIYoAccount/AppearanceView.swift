import SwiftUI

/// 外观：全局字体（从设置页搬入，行为不变）+ 底栏排序（前 3 个进底栏，其余收进「更多」）
struct AppearanceView: View {
    @EnvironmentObject var fontStore: FontStore
    @EnvironmentObject var tabOrder: TabOrderStore
    @State private var showFontPicker = false
    @State private var fontError: String?
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
                            Text(f.displayName)
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
                }
                .onDelete { idx in
                    for i in idx { fontStore.delete(fontStore.fonts[i]) }
                }
                Button {
                    showFontPicker = true
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text("导入字体（ttf / otf / ttc）")
                    }
                }
                Text("选中后立即全局生效，标题和正文都会换成该字体；少数系统控件可能仍用系统字体。导入的字体向左滑可删除，存本机、重启也在。")
                    .appFont(.footnote)
                    .foregroundColor(.secondary)
            } header: {
                AppSectionHeader("全局字体")
            }

            Section {
                ForEach(Array(tabOrder.order.enumerated()), id: \.element.id) { idx, tab in
                    HStack(spacing: 10) {
                        Image(systemName: tab.icon)
                            .foregroundColor(.accentColor)
                            .frame(width: 24)
                        Text(tab.title)
                        Spacer()
                        Text(idx < 3 ? "显示中" : "在更多里")
                            .appFont(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .onMove { tabOrder.move(from: $0, to: $1) }
            } header: {
                AppSectionHeader("底栏排序")
            }
            Section {
                Text("前 3 个进底栏，其余收进「更多」；点右上角编辑后拖动排序，底栏立即更新。")
                    .appFont(.footnote)
                    .foregroundColor(.secondary)
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
    }
}
