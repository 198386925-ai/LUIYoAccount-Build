import Foundation

enum APIError: LocalizedError {
    case server(String)
    case network(Error)
    case badResponse
    case cancelled

    var errorDescription: String? {
        switch self {
        case .server(let m): return m
        case .network(let e): return "网络错误：\(e.localizedDescription)"
        case .badResponse: return "服务器返回异常"
        case .cancelled: return "已取消"
        }
    }
}

extension Error {
    /// 请求被系统取消（页面切换/重复刷新）——不是真错误，不要弹窗打扰用户
    var isCancelError: Bool {
        if let e = self as? APIError, case .cancelled = e { return true }
        if let e = self as? URLError, e.code == .cancelled { return true }
        return false
    }
}

/// 账号系统管理接口客户端（user-auth-v2.php @ luioe.bbroot.com，密码鉴权）
@MainActor
class AccountAPI: ObservableObject {
    static let accountBase = "https://luioe.bbroot.com"

    @Published var loggedIn = false

    // MARK: - 会话级数据缓存（Build 38 性能）
    // 旧行为：每个页面自带一份 @State，切 tab / 每次出现都整表重拉，操作完
    // 又整表重拉——请求数翻倍、卡密表还没行数上限，越用越慢。
    // 现在：数据集在 App 级 store 里只拉一次，会话内切 tab 零请求；只有
    // 「刷新」胶囊 / 下拉刷新（force）和操作后的失效才重新拉。能就地改的
    // 操作（封禁 / 越狱 / 取消标红 / 卡密作废 / 删除）直接改缓存行，
    // 不再整表重拉。各页面直接读这些 @Published 缓存渲染。
    @Published private(set) var accountsCache: [AccountUser]?
    @Published private(set) var cardsCache: [CardItem]?
    @Published private(set) var versionsCache: [VersionEntry]?
    @Published private(set) var mailCache: [MailLogItem]?
    @Published private(set) var latestCache: LatestRelease?
    /// latest.json 拉过一次没拉到（还没发布）和没拉过要区分开
    private var latestLoaded = false

    // MARK: - 登录/登出（登录 = 用密码拉一次账号列表验证）

    func login(password: String) async throws {
        let r: AccountsResp = try await post(action: "admin_list", params: [:], password: password)
        guard r.ok else { throw APIError.server(r.error ?? "登录失败") }
        Keychain.save(password)
        // 登录这次 admin_list 的结果顺手种进缓存：进 App 后账号页零请求
        accountsCache = r.users ?? []
        loggedIn = true
    }

    func logout() {
        Keychain.delete()
        loggedIn = false
        accountsCache = nil
        cardsCache = nil
        versionsCache = nil
        mailCache = nil
        latestCache = nil
        latestLoaded = false
    }

    // MARK: - 账号管理

    /// 账号列表：会话内命中缓存直接返回；force 才回源整表拉
    func accounts(force: Bool = false) async throws -> [AccountUser] {
        if !force, let cached = accountsCache { return cached }
        let r: AccountsResp = try await post(action: "admin_list", params: [:])
        guard r.ok, let list = r.users else { throw APIError.server(r.error ?? "获取失败") }
        accountsCache = list
        return list
    }

    /// 就地改缓存里某个账号的字段（下标找不到就不动，等下次回源自然同步）
    private func patchAccount(email: String, _ change: (AccountUser) -> AccountUser) {
        guard var list = accountsCache, let i = list.firstIndex(where: { $0.email == email }) else { return }
        list[i] = change(list[i])
        accountsCache = list
    }

    func accountBan(email: String, ban: Bool, reason: String = "", title: String? = nil, subtitle: String? = nil) async throws {
        var p = ["email": email, "ban": ban ? "1" : "0"]
        if !reason.isEmpty { p["reason"] = reason }
        // title/subtitle 只在调用方明确给出时才带（后端按「带了才存」，行内封禁不会冲掉表单填的文案）
        if let title { p["title"] = title }
        if let subtitle { p["subtitle"] = subtitle }
        let r: SimpleResp = try await post(action: "admin_ban", params: p)
        guard r.ok else { throw APIError.server(r.error ?? "操作失败") }
        // 就地同步缓存：封禁换 is_banned + 本次带的原因/标题/副标题，
        // 没带的字段和后端一致保持原值——不再整表重拉
        patchAccount(email: email) { u in
            u.with(isBanned: ban, banReason: reason,
                   banTitle: title ?? u.banTitle,
                   banSubtitle: subtitle ?? u.banSubtitle)
        }
    }

    func accountJailbreak(email: String, allow: Bool) async throws {
        let r: SimpleResp = try await post(action: "admin_jailbreak", params: ["email": email, "allow": allow ? "1" : "0"])
        guard r.ok else { throw APIError.server(r.error ?? "操作失败") }
        patchAccount(email: email) { $0.with(allowJailbreak: allow) }
    }

    func accountUnflag(email: String) async throws {
        let r: SimpleResp = try await post(action: "admin_unflag", params: ["email": email])
        guard r.ok else { throw APIError.server(r.error ?? "操作失败") }
        patchAccount(email: email) { $0.with(ipFlagged: false) }
    }

    /// 快捷授权（Build 44，账号页侧滑）：后端 admin_svip 直接改过期时间
    /// （添加 = 永久，取消 = 清零），卡密不动；缓存就地同步
    func accountSvip(email: String, svip: Bool) async throws {
        struct SvipResp: Decodable {
            let ok: Bool
            let error: String?
            let svipExpiresAt: Int?
            enum CodingKeys: String, CodingKey {
                case ok, error
                case svipExpiresAt = "svip_expires_at"
            }
        }
        let r: SvipResp = try await post(action: "admin_svip", params: ["email": email, "svip": svip ? "1" : "0"])
        guard r.ok else { throw APIError.server(r.error ?? "操作失败") }
        patchAccount(email: email) { $0.with(svip: svip, svipExpiresAt: r.svipExpiresAt ?? (svip ? 4102444800 : 0)) }
    }

    /// 卡密授权（Build 50，授权卡 + 侧滑添加授权）：后端 admin_svip_card
    /// 卡密必填，按卡面天数开通并绑定卡密（永久卡 = 永久）；老后端没有
    /// 这个动作会直接报错，不会悄悄按永久开通；缓存就地同步
    func accountSvipCard(email: String, card: String) async throws {
        struct SvipCardResp: Decodable {
            let ok: Bool
            let error: String?
            let svipExpiresAt: Int?
            enum CodingKeys: String, CodingKey {
                case ok, error
                case svipExpiresAt = "svip_expires_at"
            }
        }
        let r: SvipCardResp = try await post(action: "admin_svip_card", params: ["email": email, "card": card])
        guard r.ok else { throw APIError.server(r.error ?? "操作失败") }
        patchAccount(email: email) { $0.with(svip: true, svipExpiresAt: r.svipExpiresAt ?? 4102444800) }
    }

    // MARK: - 卡密管理（生成 / 列表 / 作废，用户在主 App 里绑卡开通 SVIP）

    func genCards(count: Int, days: Int, remark: String) async throws -> [String] {
        let r: GenCardsResp = try await post(action: "admin_gen_cards", params: ["count": String(count), "days": String(days), "remark": remark])
        guard r.ok, let codes = r.codes else { throw APIError.server(r.error ?? "生成失败") }
        // 接口只回卡号、没有完整卡行（无 id），本地拼不出一行：只失效卡密
        // 一份缓存，页面随后只重拉卡密表，不碰别的数据集
        cardsCache = nil
        return codes
    }

    /// 卡密列表（无行数上限、最重的一份）：会话内只拉一次，force 才回源
    func cards(force: Bool = false) async throws -> [CardItem] {
        if !force, let cached = cardsCache { return cached }
        let r: CardsResp = try await post(action: "admin_list_cards", params: [:])
        guard r.ok, let list = r.cards else { throw APIError.server(r.error ?? "获取失败") }
        cardsCache = list
        return list
    }

    func cardDisable(id: Int, disabled: Bool) async throws {
        let r: SimpleResp = try await post(action: "admin_disable_card", params: ["id": String(id), "disabled": disabled ? "1" : "0"])
        guard r.ok else { throw APIError.server(r.error ?? "操作失败") }
        if var list = cardsCache, let i = list.firstIndex(where: { $0.id == id }) {
            list[i] = list[i].withDisabled(disabled)
            cardsCache = list
        }
    }

    func cardDelete(id: Int) async throws {
        let r: SimpleResp = try await post(action: "admin_delete_card", params: ["id": String(id)])
        guard r.ok else { throw APIError.server(r.error ?? "删除失败") }
        cardsCache?.removeAll { $0.id == id }
    }

    // MARK: - 邮件发送记录（注册验证码 / 换设备确认信的发送日志）

    /// 邮件记录：会话内只拉一次，force 才回源
    func mailLogs(force: Bool = false) async throws -> [MailLogItem] {
        if !force, let cached = mailCache { return cached }
        let r: MailLogResp = try await post(action: "admin_mail_log", params: [:])
        guard r.ok, let list = r.logs else { throw APIError.server(r.error ?? "获取失败") }
        mailCache = list
        return list
    }

    // MARK: - 应用更新（app-update.php，与账号管理共用密码）

    /// 线上版本：会话内只拉一次（含「拉过但为空」）；force 才回源
    func fetchLatest(force: Bool = false) async -> LatestRelease? {
        if !force && latestLoaded { return latestCache }
        guard let url = URL(string: Self.accountBase + "/updates/latest.json") else { return nil }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return latestCache }
        latestCache = try? JSONDecoder().decode(LatestRelease.self, from: data)
        latestLoaded = true
        return latestCache
    }

    nonisolated func uploadIPA(fileURL: URL, version: String, build: String, notes: String) async throws -> UploadResp {
        let pw = Keychain.load() ?? ""
        guard !pw.isEmpty else { throw APIError.server("未保存密码，请重新登录") }
        guard let url = URL(string: Self.accountBase + "/app-update.php?action=upload_ipa") else {
            throw APIError.server("服务器地址无效")
        }
        let fileData: Data
        do { fileData = try Data(contentsOf: fileURL) } catch { throw APIError.network(error) }
        let boundary = "Boundary-" + UUID().uuidString
        var body = Data()
        func addField(_ name: String, _ value: String) {
            body.append(("--" + boundary + "\r\n").data(using: .utf8)!)
            body.append(("Content-Disposition: form-data; name=\"" + name + "\"\r\n\r\n").data(using: .utf8)!)
            body.append((value + "\r\n").data(using: .utf8)!)
        }
        addField("password", pw)
        addField("version", version)
        addField("build", build)
        addField("notes", notes)
        body.append(("--" + boundary + "\r\n").data(using: .utf8)!)
        body.append(("Content-Disposition: form-data; name=\"ipa\"; filename=\"" + fileURL.lastPathComponent + "\"\r\n").data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append(("\r\n--" + boundary + "--\r\n").data(using: .utf8)!)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch let e as URLError where e.code == .cancelled { throw APIError.cancelled }
        catch { throw APIError.network(error) }
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        if http.statusCode == 401 { throw APIError.server("密码验证失败") }
        guard http.statusCode == 200 else { throw APIError.badResponse }
        let r: UploadResp
        do { r = try JSONDecoder().decode(UploadResp.self, from: data) } catch { throw APIError.badResponse }
        guard r.ok else { throw APIError.server(r.error ?? "上传失败") }
        return r
    }

    // MARK: - 版本管理（app-update.php versions_list / version_set）

    /// 版本列表：会话内只拉一次，force 才回源
    func versionsList(force: Bool = false) async throws -> [VersionEntry] {
        if !force, let cached = versionsCache { return cached }
        let r: VersionsResp = try await postUpdate(action: "versions_list", params: [:])
        guard r.ok, let list = r.versions else { throw APIError.server(r.error ?? "获取失败") }
        versionsCache = list
        return list
    }

    func versionSet(build: String, state: String? = nil, title: String? = nil, l2: String? = nil, l3: String? = nil) async throws -> [VersionEntry] {
        var p = ["build": build]
        if let state { p["state"] = state }
        if let title { p["title"] = title }
        if let l2 { p["l2"] = l2 }
        if let l3 { p["l3"] = l3 }
        let r: VersionsResp = try await postUpdate(action: "version_set", params: p)
        guard r.ok, let list = r.versions else { throw APIError.server(r.error ?? "操作失败") }
        // 接口本身就回传最新列表：直接写进缓存，页面不用再拉一次
        versionsCache = list
        return list
    }

    /// 按 build 删版本记录（Build 37 批量删除用；需新版 app-update.php 的
    /// version_delete——只删注册表记录和弹窗状态，IPA 文件保留）
    func versionDelete(build: String) async throws -> [VersionEntry] {
        let r: VersionsResp = try await postUpdate(action: "version_delete", params: ["build": build])
        guard r.ok, let list = r.versions else { throw APIError.server(r.error ?? "删除失败") }
        versionsCache = list
        return list
    }

    // MARK: - 底层（JSON POST，密码放 body，与 PHP admin_authed 对应）
    // nonisolated：这三个函数不碰任何实例状态，请求发送和 JSON 解码都
    // 不在主线程跑（卡密整表解码不卡界面）；会话走 URLSession.shared
    // （系统级 keep-alive 长连接，没有逐请求新建会话的开销）

    nonisolated private func post<T: Decodable>(action: String, params: [String: String], password: String? = nil) async throws -> T {
        try await post(file: "user-auth-v2.php", action: action, params: params, password: password)
    }

    nonisolated private func postUpdate<T: Decodable>(action: String, params: [String: String]) async throws -> T {
        try await post(file: "app-update.php", action: action, params: params, password: nil)
    }

    nonisolated private func post<T: Decodable>(file: String, action: String, params: [String: String], password: String?) async throws -> T {
        let pw = password ?? Keychain.load() ?? ""
        guard !pw.isEmpty else { throw APIError.server("未保存密码，请重新登录") }
        guard let url = URL(string: Self.accountBase + "/" + file + "?action=" + action) else {
            throw APIError.server("服务器地址无效")
        }
        var all = params
        all["password"] = pw
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: all)
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch let e as URLError where e.code == .cancelled {
            throw APIError.cancelled
        } catch {
            throw APIError.network(error)
        }
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        if http.statusCode == 401 { throw APIError.server("密码验证失败") }
        guard http.statusCode == 200 else { throw APIError.badResponse }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.badResponse
        }
    }
}
