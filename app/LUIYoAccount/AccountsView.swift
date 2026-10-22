import SwiftUI
import UIKit

/// 拉伸展开容器（Build 40；Build 41 按用户录的主 App 设置页视频重做
/// 动效口径）：内容按自然高度先量出来、从一开始就按最终尺寸排版、
/// 顶对齐钉住，容器高度在 0 ↔ 自然高度之间动画，内容被容器自己的
/// 边界逐步裁剪揭示——整张卡是一面在长高，不是「内容淡入」也不是
/// 「下面另长出一块」。Build 40 的两处偏差在 41 撤掉：① 详情单独的
/// opacity 淡入淡出（视频里没有淡入，只有裁剪揭示）；② spring 欠
/// 阻尼（dampingFraction 0.86）会过冲回弹，视频是平滑无回弹——改
/// 临界阻尼（response 0.32 / dampingFraction 1.0，零过冲）+ 约
/// 0.3s 的节奏，与主 App 卡片一致。高度动画在同一事务里驱动所在
/// 行的行高，下面的行跟着一起滑。账号卡 / 封禁行 / 邮件卡 / 更新
/// 说明 / 历史版本共用同一套动效。量测靠背景 GeometryReader 读内容
/// 固有高度（内容垂直方向 fixedSize 不吃父级压缩）；展开状态只是
/// 本地 UI 状态，切换不触发任何回源
struct StretchReveal<Content: View>: View {
    let expanded: Bool
    let content: Content
    @State private var contentHeight: CGFloat = 0

    init(expanded: Bool, @ViewBuilder content: () -> Content) {
        self.expanded = expanded
        self.content = content()
    }

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: StretchHeightKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(StretchHeightKey.self) { contentHeight = $0 }
            .frame(height: expanded ? contentHeight : 0, alignment: .top)
            .clipped()
            // Build 41：去掉 Build 40 的 .opacity 淡入淡出（揭示只靠裁剪），
            // 弹簧改临界阻尼防过冲回弹（口径见本结构体头部注释）
            .animation(.spring(response: 0.32, dampingFraction: 1.0), value: expanded)
            .accessibilityHidden(!expanded)
    }
}

private struct StretchHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 邮箱账号管理：分组卡片列表（全部=已授权/未授权两张分组卡；切到分类=一个账号一张卡）
/// + 行侧滑 封禁(带理由)·解封 / 允许越狱开关 / 取消IP标红 / 复制账号
/// Build 39：分类下方的「封禁」表单（账号/标题/副标题/原因）和「已封禁」
/// 列表整块搬去底栏「封禁」页（本文件末尾的 BansView），本页只留账号行
/// 侧滑里的快捷封禁 / 解封（只带理由，和表单那套标题/副标题文案无关）
/// Build 35：账号卡可收起——收起只显示邮箱 + 右侧标识（免费/SVIP/已封禁，
/// 不加箭头），点卡展开才显示注册/最后登录/UDID/越狱允许等详情行
/// Build 40：展开/收起改成拉伸动效（StretchReveal），内容不变
struct AccountsView: View {
    @EnvironmentObject var api: AccountAPI
    @EnvironmentObject var fontStore: FontStore
    /// 列表直接读 App 级缓存（Build 38）：切 tab / 页面再出现都不整表
    /// 重拉；封禁 / 越狱 / 取消标红由 API 就地改缓存行，本页自动刷新；
    /// 只有右上「刷新」和下拉刷新才回源
    private var list: [AccountUser] { api.accountsCache ?? [] }
    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?
    @State private var banTarget: AccountUser?
    @State private var banReason = ""
    @State private var filter: AccountFilter = .all
    /// 账号卡收起/展开（Build 35）：按邮箱记展开状态，默认全收起
    @State private var expandedAccounts: Set<String> = []

    enum AccountFilter: String, CaseIterable {
        case all = "全部"
        case svip = "已授权"
        case free = "未授权"

        var key: String {
            switch self {
            case .all: return "all"
            case .svip: return "svip"
            case .free: return "free"
            }
        }
        init?(key: String) {
            switch key {
            case "all": self = .all
            case "svip": self = .svip
            case "free": self = .free
            default: return nil
            }
        }
    }

    private var filterBinding: Binding<String> {
        Binding(get: { filter.key }, set: { filter = AccountFilter(key: $0) ?? .all })
    }

    var filtered: [AccountUser] { list }

    private var svipAccounts: [AccountUser] { filtered.filter { $0.svip } }
    private var freeAccounts: [AccountUser] { filtered.filter { !$0.svip } }

    var body: some View {
        NavigationView {
            Group {
                if loading && list.isEmpty {
                    ProgressView()
                } else {
                    Form {
                        Section {
                            PillSegmented(options: [("all", "全部"), ("svip", "已授权"), ("free", "未授权")],
                                          selection: filterBinding)
                        }
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        .listRowBackground(Color.clear)

                        switch filter {
                        case .all:
                            Section {
                                if svipAccounts.isEmpty {
                                    Text("暂无已授权账号")
                                        .foregroundColor(.secondary)
                                }
                                ForEach(svipAccounts) { u in accountRow(u) }
                            } header: {
                                AppSectionHeader("已授权（\(svipAccounts.count)）")
                            }
                            Section {
                                if freeAccounts.isEmpty {
                                    Text("暂无未授权账号")
                                        .foregroundColor(.secondary)
                                }
                                ForEach(freeAccounts) { u in accountRow(u) }
                            } header: {
                                AppSectionHeader("未授权（\(freeAccounts.count)）")
                            }
                        case .svip:
                            if svipAccounts.isEmpty {
                                Section { Text("暂无已授权账号").foregroundColor(.secondary) }
                            }
                            ForEach(svipAccounts) { u in
                                Section { accountRow(u) }
                            }
                        case .free:
                            if freeAccounts.isEmpty {
                                Section { Text("暂无未授权账号").foregroundColor(.secondary) }
                            }
                            ForEach(freeAccounts) { u in
                                Section { accountRow(u) }
                            }
                        }
                    }
                    .compactSectionSpacing()
                    .refreshable { await reload(force: true) }
                }
            }
            .navigationTitle("账号管理")
            // 本页不放常驻搜索框（用户规矩：搜索框只有点开搜索才会显示）；找账号走
            // 底栏搜索圆钮打开的全局搜索——它能搜账号/卡密/邮件并点结果直达本页
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    // Build 37：右上「退出」按用户要求删掉，换成「刷新」
                    //（退出登录在设置页里，本来就有，不受影响）
                    // Build 38：这是本页唯一的整表回源入口（连同下拉刷新）
                    Button("刷新") { Task { await reload(force: true) } }
                }
            }
            .task { await reload() }
            .alert("错误", isPresented: .constant(error != nil)) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
            .alert("操作成功", isPresented: .constant(notice != nil)) {
                Button("好") { notice = nil }
            } message: { Text(notice ?? "") }
            .alert("封禁账号", isPresented: .constant(banTarget != nil)) {
                TextField("封禁理由（可空）", text: $banReason)
                Button("封禁", role: .destructive) {
                    if let u = banTarget {
                        let reason = banReason
                        banTarget = nil
                        run { try await api.accountBan(email: u.email, ban: true, reason: reason) }
                    }
                }
                Button("取消", role: .cancel) { banTarget = nil }
            } message: {
                if let u = banTarget { Text("封禁 \(u.email)？30 秒内在用户 App 生效。") }
            }
        }
    }

    // MARK: - 账号行

    private func accountRow(_ u: AccountUser) -> some View {
        let expanded = expandedAccounts.contains(u.email)
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(u.email)
                    .appFont(.headline)
                    .lineLimit(1)
                // 详情只在展开时显示（Build 35）：收起 = 邮箱 + 右侧标识，不加箭头
                // Build 40：显隐改走 StretchReveal 拉伸动效，内容一字未变
                StretchReveal(expanded: expanded) {
                    VStack(alignment: .leading, spacing: 1) {
                        if u.isBanned && !u.banReason.isEmpty {
                            Text("封禁理由：" + u.banReason)
                                .appFont(.caption)
                                .foregroundColor(.red)
                        }
                        Text("注册 \(u.createdText) · 最后登录 \(u.lastLoginText)")
                            .appFont(.caption)
                            .foregroundColor(.secondary)
                        if !u.udid.isEmpty {
                            Text("UDID " + u.udid)
                                .appFont(.caption2, design: .monospaced)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                        HStack {
                            // 今日验证（Build 38）：后端 captcha_today 在才拼
                            // 「· 今日验证 X 次」；老后端没这字段整段不显示
                            Text("越狱允许：" + (u.allowJailbreak ? "是" : "否")
                                 + (u.captchaToday.map { " · 今日验证 \($0) 次" } ?? ""))
                            Spacer()
                            if u.svip {
                                Text("SVIP 到期 " + u.svipExpiresText)
                            }
                        }
                        .appFont(.caption)
                        .foregroundColor(.secondary)
                    }
                }
            }
            Spacer(minLength: 6)
            // 状态标识成组放在右侧、对整行上下居中（不再贴在邮箱那一行）；
            // Build 38：整列左边缘对齐——免费/SVIP 和下面 IP异常 的左边缘
            // 在同一条竖线上（原来各自右对齐，左边缘参差不齐）
            VStack(alignment: .leading, spacing: 1) {
                if u.isBanned {
                    tag("已封禁", bg: Color.red.opacity(0.15), fg: .red)
                } else if u.svip {
                    tag("SVIP", bg: Color.green.opacity(0.15), fg: .green)
                } else {
                    tag("免费", bg: Color.gray.opacity(0.15), fg: .secondary)
                }
                if u.ipFlagged {
                    tag("IP异常", bg: Color.orange.opacity(0.18), fg: .orange)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // 点卡收起/展开详情（侧滑不受影响，各走各的手势）
            // Build 40：动效归 StretchReveal 的 spring 拉伸，这里只翻状态
            if expanded { expandedAccounts.remove(u.email) } else { expandedAccounts.insert(u.email) }
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 26, bottom: 2, trailing: 26))
        .swipeActions(edge: .trailing) {
            if u.isBanned {
                Button("解封") { run { try await api.accountBan(email: u.email, ban: false) } }
                    .tint(.green)
            } else {
                Button("封禁") { banTarget = u; banReason = "" }
                    .tint(.red)
            }
            if u.allowJailbreak {
                Button("禁止越狱") { run { try await api.accountJailbreak(email: u.email, allow: false) } }
                    .tint(.gray)
            } else {
                Button("允许越狱") { run { try await api.accountJailbreak(email: u.email, allow: true) } }
                    .tint(.blue)
            }
            if u.ipFlagged {
                Button("取消标红") { run { try await api.accountUnflag(email: u.email) } }
                    .tint(.orange)
            }
            Button("复制账号") {
                UIPasteboard.general.string = u.email
                notice = "已复制账号"
            }
            .tint(.indigo)
        }
    }

    private func tag(_ s: String, bg: Color, fg: Color) -> some View {
        Text(s)
            .appFont(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(bg)
            .foregroundColor(fg)
            .cornerRadius(8)
    }

    private func reload(force: Bool = false) async {
        loading = true
        defer { loading = false }
        do {
            _ = try await api.accounts(force: force)
        } catch {
            if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func run(_ op: @escaping () async throws -> Void) {
        Task {
            do {
                try await op()
                notice = "已生效"
                // Build 38：不再操作完就整表重拉——API 已就地把缓存行
                // 改好（@Published），本页跟着自动刷新
            } catch {
                if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            }
        }
    }
}

// MARK: - 封禁页（Build 39 从账号页搬出）

/// 封禁管理：封禁表单（账号 / 标题 / 副标题 / 原因，被封用户在主 App
/// 看到的就是这套文案）+「已封禁」列表。
/// Build 40：已封禁列表改版——收起只显示账号邮箱 + 箭头，点行拉伸
/// 展开就地改标题 / 副标题 / 原因并保存（见下方 BannedAccountRow，
/// 写法照版本管理卡）；侧滑解封 / 复制账号保持不变。表单不动。
/// Build 39 以前这两块挂在账号页分类切换下方，现整块搬到底栏「封禁」
/// 页单独成页，表单字段、文案与操作一字未改；数据和账号页一样直接读
/// App 级缓存（Build 38），封禁 / 解封由 API 就地改缓存行、本页自动
/// 刷新，只有右上「刷新」和下拉刷新才回源
struct BansView: View {
    @EnvironmentObject var api: AccountAPI
    @EnvironmentObject var fontStore: FontStore
    private var list: [AccountUser] { api.accountsCache ?? [] }
    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?
    // 封禁表单
    @State private var banEmail = ""
    @State private var banFormTitle = ""
    @State private var banFormSubtitle = ""
    @State private var banFormReason = ""

    private var bannedAccounts: [AccountUser] { list.filter { $0.isBanned } }

    var body: some View {
        NavigationView {
            Group {
                if loading && list.isEmpty {
                    ProgressView()
                } else {
                    Form {
                        banFormSection

                        if !bannedAccounts.isEmpty {
                            Section {
                                ForEach(bannedAccounts) { u in
                                    BannedAccountRow(user: u, run: run, notify: { notice = $0 })
                                }
                            } header: {
                                AppSectionHeader("已封禁（\(bannedAccounts.count)）")
                            }
                        }
                    }
                    .compactSectionSpacing()
                    .refreshable { await reload(force: true) }
                }
            }
            .navigationTitle("封禁")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("刷新") { Task { await reload(force: true) } }
                }
            }
            .task { await reload() }
            .alert("错误", isPresented: .constant(error != nil)) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
            .alert("操作成功", isPresented: .constant(notice != nil)) {
                Button("好") { notice = nil }
            } message: { Text(notice ?? "") }
        }
    }

    // MARK: - 封禁表单（账号 / 标题 / 副标题 / 原因）

    private var banFormSection: some View {
        Section {
            banField("账号", placeholder: "填要封禁的邮箱", text: $banEmail, keyboard: .emailAddress)
            banField("标题", placeholder: "如：账号已被封禁", text: $banFormTitle)
            banField("副标题", placeholder: "如：你的账号已被停用", text: $banFormSubtitle)
            banField("原因", placeholder: "如：多次违规使用", text: $banFormReason)
            Button {
                submitBanForm()
            } label: {
                Text("封禁")
                    .appFont(.body, weight: .semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(banEmail.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            AppSectionHeader("封禁")
        }
    }

    private func banField(_ label: String, placeholder: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .appFont(.body)
                .frame(width: 52, alignment: .leading)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        // 封禁表单行上下压紧（布局/标签不变，只收行高）
        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
    }

    private func submitBanForm() {
        let email = banEmail.trimmingCharacters(in: .whitespaces).lowercased()
        guard !email.isEmpty else { return }
        let t = banFormTitle, s = banFormSubtitle, r = banFormReason
        run {
            try await api.accountBan(email: email, ban: true, reason: r, title: t, subtitle: s)
            banEmail = ""; banFormTitle = ""; banFormSubtitle = ""; banFormReason = ""
        }
    }

    private func reload(force: Bool = false) async {
        loading = true
        defer { loading = false }
        do {
            _ = try await api.accounts(force: force)
        } catch {
            if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func run(_ op: @escaping () async throws -> Void) {
        Task {
            do {
                try await op()
                notice = "已生效"
            } catch {
                if !error.isCancelError { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            }
        }
    }
}

// MARK: - 已封禁行（Build 40 可展开编辑）

/// 已封禁列表的行：收起只显示账号邮箱 + 授权标识 + 右侧箭头；点行拉伸展开
/// （StretchReveal，与账号卡同款动效），展开后是标题 / 副标题 /
/// 原因三个输入框 + 保存——保存走账号页封禁表单同一条 admin_ban
/// 写接口（api.accountBan 带 title/subtitle），写完 API 就地改缓存
/// 行，主 App 下次状态检查就拿到新文案。保存按钮与反馈行照版本
/// 管理卡的口径：有改动才亮、保存中转圈、成功显「已保存」、失败
/// 显红字。左滑解封 / 复制账号保持 Build 39 以前的行为（解封走
/// 父页统一的 run，提示归父页弹）
private struct BannedAccountRow: View {
    @EnvironmentObject var api: AccountAPI
    @EnvironmentObject var fontStore: FontStore
    let user: AccountUser
    let run: (@escaping () async throws -> Void) -> Void
    let notify: (String) -> Void
    @State private var expanded = false
    @State private var title: String
    @State private var subtitle: String
    @State private var reason: String
    @State private var saving = false
    @State private var saved = false
    @State private var saveError: String?

    init(user: AccountUser,
         run: @escaping (@escaping () async throws -> Void) -> Void,
         notify: @escaping (String) -> Void) {
        self.user = user
        self.run = run
        self.notify = notify
        _title = State(initialValue: user.banTitle)
        _subtitle = State(initialValue: user.banSubtitle)
        _reason = State(initialValue: user.banReason)
    }

    /// 有没有没保存的改动（输入框现值 vs 缓存现值）：保存按钮亮/灰看它
    private var dirty: Bool {
        title != user.banTitle || subtitle != user.banSubtitle || reason != user.banReason
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Text(user.email)
                    .appFont(.headline)
                    .lineLimit(1)
                Spacer(minLength: 6)
                // Build 41：收起行右侧加授权标识（与账号行同数据源、同
                // 样式的胶囊：SVIP 绿 / 免费灰），在箭头左边
                statusTag
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .appFont(.caption, weight: .semibold)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
            StretchReveal(expanded: expanded) {
                VStack(spacing: 0) {
                    editField("标题", placeholder: "如：账号已被封禁", text: $title)
                    editField("副标题", placeholder: "如：你的账号已被停用", text: $subtitle)
                    editField("原因", placeholder: "如：多次违规使用", text: $reason)
                    VStack(spacing: 6) {
                        Button {
                            save()
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
                        .tint(.red)
                        .disabled(saving || !dirty)
                        if saved {
                            Text("已保存")
                                .appFont(.caption)
                                .foregroundColor(.green)
                        } else if let saveError {
                            Text(saveError)
                                .appFont(.caption)
                                .foregroundColor(.red)
                                .lineLimit(1)
                        }
                    }
                    .padding(.top, 10)
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 26, bottom: 2, trailing: 26))
        .swipeActions(edge: .trailing) {
            Button("解封") { run { try await api.accountBan(email: user.email, ban: false) } }
                .tint(.green)
            Button("复制账号") {
                UIPasteboard.general.string = user.email
                notify("已复制账号")
            }
            .tint(.indigo)
        }
        // 改了任何一格，「已保存」标记立刻撤下（按钮随 dirty 重新亮起）
        .onChange(of: title) { _ in saved = false }
        .onChange(of: subtitle) { _ in saved = false }
        .onChange(of: reason) { _ in saved = false }
    }

    /// 授权标识胶囊（Build 41）：与账号页账号行的 tag 同字号 / 同内边距 /
    /// 同圆角 / 同配色——SVIP 绿底绿字，免费灰底灰字（已封禁标识在本页
    /// 没有意义，人人都在封禁名单里，不重复显示）
    private var statusTag: some View {
        Text(user.svip ? "SVIP" : "免费")
            .appFont(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(user.svip ? Color.green.opacity(0.15) : Color.gray.opacity(0.15))
            .foregroundColor(user.svip ? Color.green : Color.secondary)
            .cornerRadius(8)
    }

    private func editField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .appFont(.body)
                .frame(width: 52, alignment: .leading)
            TextField(placeholder, text: text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.vertical, 7)
    }

    private func save() {
        let t = title, s = subtitle, r = reason
        saving = true
        saved = false
        saveError = nil
        Task {
            defer { saving = false }
            do {
                try await api.accountBan(email: user.email, ban: true, reason: r, title: t, subtitle: s)
                saved = true
            } catch {
                if !error.isCancelError {
                    saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
}
