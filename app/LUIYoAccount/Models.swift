import Foundation

// MARK: - 邮箱账号（user-auth-v2.php）
struct AccountUser: Decodable, Identifiable {
    let id: Int
    let email: String
    let isBanned: Bool
    let banReason: String
    let svip: Bool
    let svipExpiresAt: Int
    let ipFlagged: Bool
    let allowJailbreak: Bool
    let createdAt: Int
    let lastLoginAt: Int

    enum CodingKeys: String, CodingKey {
        case id, email, svip
        case isBanned = "is_banned"
        case banReason = "ban_reason"
        case svipExpiresAt = "svip_expires_at"
        case ipFlagged = "ip_flagged"
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
        svip = Self.flexBool(c, .svip)
        svipExpiresAt = (try? c.decode(Int.self, forKey: .svipExpiresAt)) ?? 0
        ipFlagged = Self.flexBool(c, .ipFlagged)
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
