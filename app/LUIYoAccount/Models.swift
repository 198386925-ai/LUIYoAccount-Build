import Foundation

// MARK: - 邮箱账号（user-auth-v2.php）
struct AccountUser: Decodable, Identifiable {
    let id: Int
    let email: String
    let isBanned: Bool
    let banReason: String
    let banTitle: String
    let banSubtitle: String
    let svip: Bool
    let svipExpiresAt: Int
    let ipFlagged: Bool
    let udid: String
    let allowJailbreak: Bool
    let createdAt: Int
    let lastLoginAt: Int

    enum CodingKeys: String, CodingKey {
        case id, email, svip
        case isBanned = "is_banned"
        case banReason = "ban_reason"
        case banTitle = "ban_title"
        case banSubtitle = "ban_subtitle"
        case svipExpiresAt = "svip_expires_at"
        case ipFlagged = "ip_flagged"
        case udid
        case allowJailbreak = "allow_jailbreak"
        case createdAt = "created_at"
        case lastLoginAt = "last_login_at"
    }

    /// is_banned 等字段服务端可能是 Bool / Int(0/1)，兼容解析
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        email = (try? c.decode(String.self, forKey: .email)) ?? ""
        isBanned = Self.flexBool(c, .isBanned)
        banReason = (try? c.decode(String.self, forKey: .banReason)) ?? ""
        banTitle = (try? c.decode(String.self, forKey: .banTitle)) ?? ""
        banSubtitle = (try? c.decode(String.self, forKey: .banSubtitle)) ?? ""
        svip = Self.flexBool(c, .svip)
        svipExpiresAt = (try? c.decode(Int.self, forKey: .svipExpiresAt)) ?? 0
        ipFlagged = Self.flexBool(c, .ipFlagged)
        udid = (try? c.decode(String.self, forKey: .udid)) ?? ""
        allowJailbreak = Self.flexBool(c, .allowJailbreak)
        createdAt = (try? c.decode(Int.self, forKey: .createdAt)) ?? 0
        lastLoginAt = (try? c.decode(Int.self, forKey: .lastLoginAt)) ?? 0
    }

    private static func flexBool(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) -> Bool {
        if let b = try? c.decode(Bool.self, forKey: k) { return b }
        if let i = try? c.decode(Int.self, forKey: k) { return i != 0 }
        return false
    }

    var createdText: String {
        guard createdAt > 0 else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(createdAt)))
    }

    var lastLoginText: String {
        guard lastLoginAt > 0 else { return "从未登录" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(lastLoginAt)))
    }

    var svipExpiresText: String {
        guard svipExpiresAt > 0 else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(svipExpiresAt)))
    }
}

struct AccountsResp: Decodable {
    let ok: Bool
    let error: String?
    let users: [AccountUser]?
    let total: Int?
}

struct SimpleResp: Decodable {
    let ok: Bool
    let error: String?
}

// MARK: - 应用更新（updates/latest.json + app-update.php）
struct LatestRelease: Decodable {
    let tagName: String
    let body: String?
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let size: Int
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", body, assets
    }

    var assetName: String { assets.first?.name ?? "" }
    var assetSize: Int { assets.first?.size ?? 0 }
}

struct UploadResp: Decodable {
    let ok: Bool
    let error: String?
    let name: String?
}

// MARK: - 版本管理（app-update.php versions.json 注册表）
struct VersionEntry: Decodable, Identifiable {
    let version: String
    let build: String
    let notes: String
    let publishedAt: Int
    let state: String   // normal / soft（弹更新） / banned（禁用）
    let title: String
    let l2: String
    let l3: String

    var id: String { build }

    enum CodingKeys: String, CodingKey {
        case version, build, notes, state, title, l2, l3
        case publishedAt = "published_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(String.self, forKey: .version)) ?? ""
        if let s = try? c.decode(String.self, forKey: .build) { build = s }
        else if let i = try? c.decode(Int.self, forKey: .build) { build = String(i) }
        else { build = "" }
        notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
        publishedAt = (try? c.decode(Int.self, forKey: .publishedAt)) ?? 0
        state = (try? c.decode(String.self, forKey: .state)) ?? "normal"
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        l2 = (try? c.decode(String.self, forKey: .l2)) ?? ""
        l3 = (try? c.decode(String.self, forKey: .l3)) ?? ""
    }

    var stateText: String {
        state == "soft" ? "弹更新中" : (state == "banned" ? "已禁用" : "正常")
    }

    var publishedText: String {
        guard publishedAt > 0 else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(publishedAt)))
    }
}

struct VersionsResp: Decodable {
    let ok: Bool
    let error: String?
    let versions: [VersionEntry]?
}

// MARK: - 卡密（licenses，admin_gen_cards / admin_list_cards）
struct CardItem: Decodable, Identifiable {
    let id: Int
    let code: String
    let disabled: Bool
    let days: Int
    let createdAt: Int
    let boundEmail: String
    let remark: String
    let boundUdid: String
    let boundAt: Int

    enum CodingKeys: String, CodingKey {
        case id, code, disabled, days
        case createdAt = "created_at"
        case boundEmail = "bound_email"
        case remark
        case boundUdid = "bound_udid"
        case boundAt = "bound_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        code = (try? c.decode(String.self, forKey: .code)) ?? ""
        if let b = try? c.decode(Bool.self, forKey: .disabled) { disabled = b }
        else if let i = try? c.decode(Int.self, forKey: .disabled) { disabled = i != 0 }
        else { disabled = false }
        days = (try? c.decode(Int.self, forKey: .days)) ?? 30
        createdAt = (try? c.decode(Int.self, forKey: .createdAt)) ?? 0
        boundEmail = (try? c.decode(String.self, forKey: .boundEmail)) ?? ""
        remark = (try? c.decode(String.self, forKey: .remark)) ?? ""
        boundUdid = (try? c.decode(String.self, forKey: .boundUdid)) ?? ""
        boundAt = (try? c.decode(Int.self, forKey: .boundAt)) ?? 0
    }

    var isBound: Bool { !boundEmail.isEmpty }
    var daysText: String { days >= 36500 ? "永久" : "\(days) 天" }
    var createdText: String {
        guard createdAt > 0 else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(createdAt)))
    }
    var boundAtText: String {
        guard boundAt > 0 else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(boundAt)))
    }
}

struct CardsResp: Decodable {
    let ok: Bool
    let error: String?
    let cards: [CardItem]?
    let total: Int?
}

struct GenCardsResp: Decodable {
    let ok: Bool
    let error: String?
    let codes: [String]?
    let count: Int?
    let days: Int?
}

// MARK: - 邮件发送记录（mail_log，admin_mail_log）
struct MailLogItem: Decodable, Identifiable {
    let id: Int
    let toEmail: String
    let subject: String
    let ok: Bool
    let createdAt: Int

    enum CodingKeys: String, CodingKey {
        case id, subject, ok
        case toEmail = "to_email"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        toEmail = (try? c.decode(String.self, forKey: .toEmail)) ?? ""
        subject = (try? c.decode(String.self, forKey: .subject)) ?? ""
        if let b = try? c.decode(Bool.self, forKey: .ok) { ok = b }
        else if let i = try? c.decode(Int.self, forKey: .ok) { ok = i != 0 }
        else if let t = try? c.decode(String.self, forKey: .ok) { ok = (t == "1") }
        else { ok = false }
        createdAt = (try? c.decode(Int.self, forKey: .createdAt)) ?? 0
    }

    var createdText: String {
        guard createdAt > 0 else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(createdAt)))
    }
}

struct MailLogResp: Decodable {
    let ok: Bool
    let error: String?
    let logs: [MailLogItem]?
    let total: Int?
}
