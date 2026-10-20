import SwiftUI

struct LoginView: View {
    @EnvironmentObject var api: AccountAPI
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.blue)
            Text("LUIYo账号")
                .font(.title2).bold()
            Text("邮箱账号授权管理")
                .font(.subheadline)
                .foregroundColor(.secondary)
            SecureField("管理员密码", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(height: 44)
                .padding(.horizontal, 32)
            Button {
                Task { await doLogin() }
            } label: {
                if busy {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("登录")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(height: 44)
            .padding(.horizontal, 32)
            .disabled(busy || password.isEmpty)
            Spacer()
        }
        .alert("登录失败", isPresented: .constant(error != nil)) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func doLogin() async {
        busy = true
        defer { busy = false }
        do {
            try await api.login(password: password)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
