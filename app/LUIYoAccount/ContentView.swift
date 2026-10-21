import SwiftUI
import UIKit

/// 外壳：登录后是自定义悬浮底栏——顺序前 3 个页面进胶囊底栏，第 4 个是「更多」
/// （点开在底栏上方弹出小卡，列出其余页面），胶囊右侧另有一个独立圆形搜索按钮
/// （打开全局搜索）。顺序由 TabOrderStore 管理，在「设置 → 外观 → 底栏排序」里拖动调整。
struct ContentView: View {
    @EnvironmentObject var api: AccountAPI
    @StateObject private var tabOrder = TabOrderStore()
    @State private var selection: AppTab = .accounts
    @State private var showMore = false
    @State private var showSearch = false
    @State private var autoDone = false

    var body: some View {
        Group {
            if api.loggedIn {
                mainShell
            } else if !autoDone {
                ProgressView("登录中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LoginView()
            }
        }
        .modifier(GlobalFontModifier())
        .environmentObject(tabOrder)
        .onAppear {
            FontStore.applyUIKitAppearances()
            // 自动登录：有保存的密码就直接进，不用每次输
            guard !autoDone else { return }
            if let saved = Keychain.load(), !saved.isEmpty {
                Task {
                    try? await api.login(password: saved)
                    autoDone = true
                }
            } else {
                autoDone = true
            }
        }
    }

    // MARK: - 主外壳（页面 + 悬浮底栏）

    private var mainShell: some View {
        ZStack {
            TabView(selection: $selection) {
                AccountsView()
                    .tag(AppTab.accounts)
                    .toolbar(.hidden, for: .tabBar)
                CardsView()
                    .tag(AppTab.cards)
                    .toolbar(.hidden, for: .tabBar)
                MailLogView()
                    .tag(AppTab.mail)
                    .toolbar(.hidden, for: .tabBar)
                UpdateView()
                    .tag(AppTab.update)
                    .toolbar(.hidden, for: .tabBar)
                SettingsView()
                    .tag(AppTab.settings)
                    .toolbar(.hidden, for: .tabBar)
            }
            // 给悬浮底栏 + 搜索按钮让出底部空间，内容不被压住
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 88)
            }

            // 「更多」打开时铺一层透明点击层，点别处收起（底栏在它上层，照常可点）
            if showMore {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { showMore = false } }
            }

            VStack(spacing: 0) {
                Spacer()
                if showMore {
                    HStack {
                        Spacer()
                        moreMenu
                    }
                    .padding(.trailing, 84)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                bottomBar
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .sheet(isPresented: $showSearch) {
            GlobalSearchView { tab in
                selection = tab
                showMore = false
            }
        }
    }

    // MARK: - 悬浮底栏（胶囊：前 3 页 + 更多；右侧独立圆形搜索按钮）

    private var bottomBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            HStack(spacing: 2) {
                ForEach(tabOrder.barTabs) { tab in
                    barItem(tab)
                }
                moreItem
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(Color(UIColor.systemBackground).opacity(0.94))
                    .shadow(color: .black.opacity(0.13), radius: 14, y: 4)
            }

            Button {
                showSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 60, height: 60)
                    .background {
                        Circle()
                            .fill(Color(UIColor.systemBackground).opacity(0.94))
                            .shadow(color: .black.opacity(0.13), radius: 14, y: 4)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private func barItem(_ tab: AppTab) -> some View {
        Button {
            selection = tab
            withAnimation(.easeInOut(duration: 0.18)) { showMore = false }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.icon)
                    .font(.system(size: 19))
                Text(tab.title)
                    .appFont(size: 10.5)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .foregroundColor(selection == tab ? .accentColor : .primary)
            .background {
                if selection == tab {
                    Capsule().fill(Color.gray.opacity(0.16))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 当前选中的页面在「更多」里时，「更多」呈选中态（蓝）
    private var moreHighlighted: Bool {
        showMore || !tabOrder.barTabs.contains(selection)
    }

    private var moreItem: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { showMore.toggle() }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 19, weight: .bold))
                Text("更多")
                    .appFont(size: 10.5)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .foregroundColor(moreHighlighted ? .accentColor : .primary)
            .background {
                if moreHighlighted {
                    Capsule().fill(Color.gray.opacity(0.16))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 「更多」弹出小卡（其余页面）

    private var moreMenu: some View {
        let rest = tabOrder.moreTabs
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(rest) { tab in
                Button {
                    selection = tab
                    withAnimation(.easeInOut(duration: 0.18)) { showMore = false }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.icon)
                            .frame(width: 22)
                        Text(tab.title)
                            .appFont(.body)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(selection == tab ? .accentColor : .primary)
                if tab.id != rest.last?.id {
                    Divider().padding(.leading, 46)
                }
            }
        }
        .frame(width: 176)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.systemBackground).opacity(0.97))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        }
    }
}
