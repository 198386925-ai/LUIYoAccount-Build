import Foundation

enum APIError: LocalizedError {
    case server(String)
    case network(Error)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .server(let m): return m
        case .network(let e): return "网络错误：\(e.localizedDescription)"
        case .badResponse: return "服务器返回异常"
        }
    }
}

/// 账号系统管理接口客户端（user-auth-v2.php @ luioe.bbroot.com，密码鉴权）
@MainActor
class AccountAPI: ObservableObject {
    static let accountBase = "https://luioe.bbroot.com"

    @Published var loggedIn = false

    // MARK: - 登录/登出（登录 = 用密码拉一次账号列表验证）

    func login(password: String) async throws {
        let r: AccountsResp = try await post(action: "admin_list", params: [:], password: password)
        guard r.ok else { throw APIError.server(r.error ?? "登录失败") }
        Keychain.save(password)
        loggedIn = true
    }

    func logout() {
        Keychain.delete()
        loggedIn = false
    }

    // MARK: - 账号管理

    func accounts() async throws -> [AccountUser] {
        let r: AccountsResp = try await post(action: "admin_list", params: [:])
        guard r.ok, let list = r.users else { throw APIError.server(r.error ?? "获取失败") }
        return list
    }

    func accountBan(email: String, ban: Bool, reason: String = "") async throws {
        var p = ["email": email, "ban": ban ? "1" : "0"]
        if !reason.isEmpty { p["reason"] = reason }
        let r: SimpleResp = try await post(action: "admin_ban", params: p)
        guard r.ok else { throw APIError.server(r.error ?? "操作失败") }
    }

    func accountJailbreak(email: String, allow: Bool) async throws {
        let r: SimpleResp = try await post(action: "admin_jailbreak", params: ["email": email, "allow": allow ? "1" : "0"])
        guard r.ok else { throw APIError.server(r.error ?? "操作失败") }
    }

    func accountUnflag(email: String) async throws {
        let r: SimpleResp = try await post(action: "admin_unflag", params: ["email": email])
        guard r.ok else { throw APIError.server(r.error ?? "操作失败") }
    }

    // MARK: - 应用更新（app-update.php，与账号管理共用密码）

    func fetchLatest() async -> LatestRelease? {
        guard let url = URL(string: Self.accountBase + "/updates/latest.json") else { return nil }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(LatestRelease.self, from: data)
    }

    func uploadIPA(fileURL: URL, version: String, build: String, notes: String) async throws -> UploadResp {
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
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch { throw APIError.network(error) }
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        if http.statusCode == 401 { throw APIError.server("密码验证失败") }
        guard http.statusCode == 200 else { throw APIError.badResponse }
        let r: UploadResp
        do { r = try JSONDecoder().decode(UploadResp.self, from: data) } catch { throw APIError.badResponse }
        guard r.ok else { throw APIError.server(r.error ?? "上传失败") }
        return r
    }

    // MARK: - 底层（JSON POST，密码放 body，与 PHP admin_authed 对应）

    private func post<T: Decodable>(action: String, params: [String: String], password: String? = nil) async throws -> T {
        let pw = password ?? Keychain.load() ?? ""
        guard !pw.isEmpty else { throw APIError.server("未保存密码，请重新登录") }
        guard let url = URL(string: Self.accountBase + "/user-auth-v2.php?action=" + action) else {
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
