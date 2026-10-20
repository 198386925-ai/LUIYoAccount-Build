# LUIYo 邮箱账号授权系统

新授权方案（与老设备码系统完全独立、互不影响）：
注册邮箱 → 设密码 → 邮箱验证码 → 登录 → 绑卡密 → SVIP

## 目录
- `backend/user-auth-v2.php` — 账号系统后端 API（注册/登录/绑卡密/管理）
- `backend/user-admin.html` — 网页后台（账号列表/封禁/允许越狱/IP标红）
- `backend/auth-test-v2.html` — 接口测试页
- `backend/smtp.php` — 发信邮箱配置模板（部署时放服务器 web 根外）
- `app/` — 独立账号管理 iOS App 源码（GitHub Actions 打包）

## 部署（域名 luioe.bbroot.com）
1. `backend/` 三个文件（php + 两个 html）传到新站点根目录
2. 数据库：默认读同目录 `luiyo.db`（与老系统同库，表自动创建；绑卡密读老 `licenses` 表）。
   路径不同时设环境变量 `LUIYO_DB_PATH`
3. SMTP：把 `smtp.php` 填上 QQ 邮箱 + 新生成的 16 位授权码，
   放到 `/www/luiyo-private/smtp.php`（web 根外，安全）
4. 管理员密码：与老后台共用 `/www/luiyo-private/admin.hash`

## 安全措施（已实现）
1. 登录锁定：连错 5 次密码锁 15 分钟
2. 新设备登录：必须点邮箱确认链接，旧设备自动下线；换设备 24h 冷静期
3. IP 异常：1 小时内两个不同 IP 登录 → 后台标红，人工审核
5. 越狱检测：按账号单独开关，默认禁止，后台/App 可给指定账号放行

## 账号规则
- 一号一设备，新登录挤掉旧设备
- 注册免费；未绑卡密 = 免费用户（功能锁定）；绑卡密 = SVIP（默认 30 天，再绑累加）
- 一张卡密只能绑一个账号
