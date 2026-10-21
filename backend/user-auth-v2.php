<?php
// ============================================================
// LUIYo 邮箱账号授权系统 v2（完整版）
// 流程：注册邮箱 → 设密码 → 邮箱验证码 → 登录 → 绑卡密 → SVIP
// 规则：一号一设备（新登录挤掉旧设备）；换设备 24h 冷静期
// 安全：1 登录锁定（连错5次锁15分钟）
//       2 新设备登录需点邮箱确认链接
//       3 IP 异常标红（1小时内两个不同 IP → 后台标红人工审核）
//       5 越狱检测按账号单独开关（默认禁止，后台可放行）
// 依赖：PHP 7.4+ / SQLite PDO
// 数据库：复用老系统同一 luiyo.db（users 等表独立，老系统完全不碰）
// 部署：放新站点目录（如 luioe.bbroot.com 的 web 根），
//       SMTP 配置放 web 根外：/www/luiyo-private/smtp.php
//       返回 ['user'=>'发信邮箱','pass'=>'16位授权码','name'=>'LUIYo']
// ============================================================

header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: POST, GET, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type, Authorization');
if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') exit;

// ---------- 配置 ----------
define('BASE_URL', 'https://luioe.bbroot.com');   // 邮箱确认链接域名
define('DB_PATH', getenv('LUIYO_DB_PATH') ?: __DIR__ . '/luiyo.db');
$smtp_file = '/www/luiyo-private/smtp.php';
if (file_exists($smtp_file)) {
    $SMTP = require $smtp_file;
} else {
    // 临时：直接改这里也行；正式建议用上面的外部配置文件
    $SMTP = ['user' => '在此填发信邮箱', 'pass' => '在此填16位授权码', 'name' => 'LUIYo'];
}

try {
    $db = new PDO('sqlite:' . DB_PATH);
    $db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
} catch (Exception $e) {
    echo json_encode(['ok' => false, 'error' => '数据库连接失败']);
    exit;
}

// ---------- 建表 / 补列（幂等，老库自动升级） ----------
$db->exec("CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    is_verified INTEGER DEFAULT 0,
    is_banned INTEGER DEFAULT 0,
    ban_reason TEXT DEFAULT '',
    svip_expires_at INTEGER DEFAULT 0,
    license_id INTEGER DEFAULT 0,
    current_device_id TEXT DEFAULT '',
    last_login_at INTEGER DEFAULT 0,
    device_switch_at INTEGER DEFAULT 0,
    created_at INTEGER NOT NULL
)");
$db->exec("CREATE TABLE IF NOT EXISTS email_codes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    email TEXT NOT NULL,
    code TEXT NOT NULL,
    purpose TEXT DEFAULT 'register',
    expires_at INTEGER NOT NULL,
    used INTEGER DEFAULT 0,
    created_at INTEGER NOT NULL
)");
$db->exec("CREATE INDEX IF NOT EXISTS idx_email_codes ON email_codes(email, code)");
// 卡密表（绑卡 + 后台生成共用；老库已有同名表时不覆盖，缺列在下方补）
$db->exec("CREATE TABLE IF NOT EXISTS licenses (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    code_plain TEXT UNIQUE NOT NULL,
    disabled INTEGER DEFAULT 0,
    days INTEGER DEFAULT 30,
    created_at INTEGER DEFAULT 0
)");
try { $db->exec("ALTER TABLE licenses ADD COLUMN days INTEGER DEFAULT 30"); } catch (Exception $e) {}
try { $db->exec("ALTER TABLE licenses ADD COLUMN created_at INTEGER DEFAULT 0"); } catch (Exception $e) {}
try { $db->exec("ALTER TABLE licenses ADD COLUMN remark TEXT DEFAULT ''"); } catch (Exception $e) {}
try { $db->exec("ALTER TABLE licenses ADD COLUMN bound_user_id INTEGER DEFAULT 0"); } catch (Exception $e) {}
try { $db->exec("ALTER TABLE licenses ADD COLUMN bound_email TEXT DEFAULT ''"); } catch (Exception $e) {}
try { $db->exec("ALTER TABLE licenses ADD COLUMN bound_at INTEGER DEFAULT 0"); } catch (Exception $e) {}
// v2 新表：设备确认 / 登录日志
$db->exec("CREATE TABLE IF NOT EXISTS device_confirms (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    device_id TEXT NOT NULL,
    token TEXT UNIQUE NOT NULL,
    expires_at INTEGER NOT NULL,
    used INTEGER DEFAULT 0,
    created_at INTEGER NOT NULL
)");
$db->exec("CREATE TABLE IF NOT EXISTS login_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    ip TEXT NOT NULL,
    device_id TEXT DEFAULT '',
    created_at INTEGER NOT NULL
)");
$db->exec("CREATE INDEX IF NOT EXISTS idx_login_logs ON login_logs(user_id, created_at)");
$cols = $db->query("PRAGMA table_info(users)")->fetchAll(PDO::FETCH_COLUMN, 1);
foreach ([
    'failed_count'   => "ALTER TABLE users ADD COLUMN failed_count INTEGER DEFAULT 0",
    'locked_until'   => "ALTER TABLE users ADD COLUMN locked_until INTEGER DEFAULT 0",
    'ip_flagged'     => "ALTER TABLE users ADD COLUMN ip_flagged INTEGER DEFAULT 0",
    'allow_jailbreak'=> "ALTER TABLE users ADD COLUMN allow_jailbreak INTEGER DEFAULT 0",
    'udid'           => "ALTER TABLE users ADD COLUMN udid TEXT DEFAULT ''",
] as $c => $sql) if (!in_array($c, $cols)) $db->exec($sql);
$db->exec("CREATE TABLE IF NOT EXISTS udid_enroll (
    token TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    used INTEGER DEFAULT 0,
    created_at INTEGER NOT NULL
)");
$db->exec("CREATE TABLE IF NOT EXISTS mail_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    to_email TEXT NOT NULL,
    subject TEXT DEFAULT '',
    ok INTEGER DEFAULT 0,
    created_at INTEGER DEFAULT 0
)");

// ---------- 工具 ----------
function resp($ok, $data = []) { echo json_encode(array_merge(['ok' => $ok], $data), JSON_UNESCAPED_UNICODE); exit; }
function get_input() { $d = json_decode(file_get_contents('php://input'), true); return is_array($d) ? $d : $_POST; }
function gen_code($len = 6) { $s = ''; for ($i = 0; $i < $len; $i++) $s .= (string)random_int(0, 9); return $s; }
function gen_token() { return bin2hex(random_bytes(32)); }
function client_ip() {
    if (!empty($_SERVER['HTTP_CF_CONNECTING_IP'])) return $_SERVER['HTTP_CF_CONNECTING_IP'];
    if (!empty($_SERVER['HTTP_X_FORWARDED_FOR'])) return explode(',', $_SERVER['HTTP_X_FORWARDED_FOR'])[0];
    return $_SERVER['REMOTE_ADDR'] ?? '';
}
function admin_authed($in) {
    if (session_status() !== PHP_SESSION_ACTIVE) session_start();
    if (!empty($_SESSION['luiyo_admin'])) return true;
    $pw = $in['password'] ?? '';
    $hash_file = '/www/luiyo-private/admin.hash';
    $env_hash = getenv('LUIYO_ADMIN_HASH');
    if ($env_hash && $pw && password_verify($pw, $env_hash)) return true;
    if ($pw && file_exists($hash_file) && password_verify($pw, trim(file_get_contents($hash_file)))) return true;
    return false;
}

// ---------- SMTP 发信（通道由 smtp.php 配置决定：QQ / Resend） ----------
function send_qq_email_raw($to, $subject, $body) {
    global $SMTP;
    $host = $SMTP['host'] ?? 'smtp.qq.com';
    $port = $SMTP['port'] ?? 465;
    $from = $SMTP['from'] ?? $SMTP['user'];
    $fp = @stream_socket_client("ssl://{$host}:{$port}", $errno, $errstr, 15);
    if (!$fp) return false;
    $read = function() use ($fp) { return fgets($fp, 512); };
    $send = function($s) use ($fp) { fwrite($fp, $s . "\r\n"); };
    $read(); $send("EHLO luiyo");
    while ($l = $read()) { if (strpos($l, '250 ') === 0 || strpos($l, "250\r\n") !== false) break; if (strpos($l, '250-') !== 0) break; }
    $send("AUTH LOGIN"); $read();
    $send(base64_encode($SMTP['user'])); $read();
    $send(base64_encode($SMTP['pass'])); $r = $read();
    if (strpos($r, '235') === false) { fclose($fp); return false; }
    $send("MAIL FROM:<" . $from . ">"); $read();
    $send("RCPT TO:<$to>"); $read();
    $send("DATA"); $read();
    $headers = "From: " . $SMTP['name'] . " <" . $from . ">\r\n";
    $headers .= "To: <$to>\r\n";
    $headers .= "Subject: =?UTF-8?B?" . base64_encode($subject) . "?=\r\n";
    $headers .= "Content-Type: text/plain; charset=UTF-8\r\n";
    $send($headers . "\r\n" . $body . "\r\n.");
    $r = $read();
    $send("QUIT"); fclose($fp);
    return strpos($r, '250') !== false;
}

// ---------- 发信入口：发送 + 自动记入 mail_log（后台「邮件发送记录」可查） ----------
function send_qq_email($to, $subject, $body) {
    global $db;
    $ok = send_qq_email_raw($to, $subject, $body);
    try {
        $db->prepare("INSERT INTO mail_log (to_email, subject, ok, created_at) VALUES (?,?,?,?)")
           ->execute([$to, $subject, $ok ? 1 : 0, time()]);
    } catch (Throwable $e) { /* 记日志失败不影响发信本身 */ }
    return $ok;
}

$action = $_GET['action'] ?? '';
$in = get_input();
$now = time();

// ============ 邮箱确认链接落地页（GET，浏览器打开） ============
if ($action === 'confirm_device') {
    header('Content-Type: text/html; charset=utf-8');
    $token = trim($_GET['token'] ?? '');
    $st = $db->prepare("SELECT * FROM device_confirms WHERE token=? AND used=0 AND expires_at>?");
    $st->execute([$token, $now]);
    $c = $st->fetch(PDO::FETCH_ASSOC);
    if (!$c) { echo '<h3>链接已失效或已确认过</h3><p>请回到 App 重新登录。</p>'; exit; }
    // 确认 = 允许这台新设备成为当前设备（旧设备自动挤下线）
    $db->prepare("UPDATE users SET current_device_id=?, device_switch_at=?, last_login_at=? WHERE id=?")
       ->execute([$c['device_id'], $now, $now, $c['user_id']]);
    $db->prepare("UPDATE device_confirms SET used=1 WHERE id=?")->execute([$c['id']]);
    echo '<h3>确认成功</h3><p>新设备已授权，请回到 App 点「我已确认」完成登录。旧设备将自动下线。</p>';
    exit;
}

// ============ 发送验证码 ============
// ---------- UDID 获取（描述文件方式，浏览器/设备直连） ----------
if ($action === 'udid_profile') {
    $t = trim($_GET['t'] ?? '');
    $st = $db->prepare("SELECT * FROM udid_enroll WHERE token=? AND used=0 AND expires_at>?");
    $st->execute([$t, time()]);
    if (!$st->fetch()) { http_response_code(404); echo '链接已过期，请回 App 重新获取'; exit; }
    $self = 'https://' . $_SERVER['HTTP_HOST'] . $_SERVER['SCRIPT_NAME'];
    $recv = htmlspecialchars($self . '?action=udid_receive&t=' . $t, ENT_XML1);
    $uuid = strtoupper(sprintf('%04x%04x-%04x-%04x-%04x-%04x%04x%04x',
        random_int(0,0xffff), random_int(0,0xffff), random_int(0,0xffff),
        random_int(0,0x0fff)|0x4000, random_int(0,0x3fff)|0x8000,
        random_int(0,0xffff), random_int(0,0xffff), random_int(0,0xffff)));
    header_remove('Content-Type');
    header('Content-Type: application/x-apple-aspen-config; charset=utf-8');
    header('Content-Disposition: attachment; filename="LUIYo-UDID.mobileconfig"');
    echo '<?xml version="1.0" encoding="UTF-8"?>' . "\n";
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' . "\n";
    echo '<plist version="1.0"><dict>'
        . '<key>PayloadContent</key><dict>'
        . '<key>DeviceAttributes</key><array><string>UDID</string><string>PRODUCT</string><string>VERSION</string><string>SERIAL</string></array>'
        . '<key>URL</key><string>' . $recv . '</string>'
        . '</dict>'
        . '<key>PayloadDisplayName</key><string>LUIYo 设备绑定</string>'
        . '<key>PayloadDescription</key><string>把本机 UDID 绑定到你的 LUIYo 账号，安装后自动完成</string>'
        . '<key>PayloadIdentifier</key><string>com.luiyo.udid.enroll</string>'
        . '<key>PayloadType</key><string>Profile Service</string>'
        . '<key>PayloadUUID</key><string>' . $uuid . '</string>'
        . '<key>PayloadVersion</key><integer>1</integer>'
        . '</dict></plist>';
    exit;
}

if ($action === 'udid_receive') {
    $t = trim($_GET['t'] ?? '');
    $raw = file_get_contents('php://input');
    $udid = '';
    if (preg_match('/<key>UDID<\/key>\s*<string>([^<]+)<\/string>/', $raw, $m)) $udid = trim($m[1]);
    $st = $db->prepare("SELECT * FROM udid_enroll WHERE token=? AND used=0 AND expires_at>?");
    $st->execute([$t, time()]);
    $row = $st->fetch();
    if ($row && $udid !== '') {
        $db->prepare("UPDATE users SET udid=? WHERE id=?")->execute([$udid, $row['user_id']]);
        $db->prepare("UPDATE udid_enroll SET used=1 WHERE token=?")->execute([$t]);
    }
    $self = 'https://' . $_SERVER['HTTP_HOST'] . $_SERVER['SCRIPT_NAME'];
    header('Location: ' . $self . '?action=udid_done', true, 301);
    exit;
}

if ($action === 'udid_done') {
    header_remove('Content-Type');
    header('Content-Type: text/html; charset=utf-8');
    echo '<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><body style="font-family:-apple-system;text-align:center;padding:60px 20px"><h2>✅ UDID 已绑定</h2><p>回到 LUIYo App 刷新即可看到本机 UDID。</p></body>';
    exit;
}

if ($action === 'send_code') {
    $email = strtolower(trim($in['email'] ?? ''));
    $purpose = $in['purpose'] ?? 'register';
    if (!filter_var($email, FILTER_VALIDATE_EMAIL)) resp(false, ['error' => '邮箱格式不对']);
    if ($purpose === 'reset') {
        $st = $db->prepare("SELECT id FROM users WHERE email=?");
        $st->execute([$email]);
        if (!$st->fetch()) resp(false, ['error' => '该邮箱未注册']);
    }
    $st = $db->prepare("SELECT created_at FROM email_codes WHERE email=? ORDER BY id DESC LIMIT 1");
    $st->execute([$email]);
    $last = $st->fetch(PDO::FETCH_ASSOC);
    if ($last && $now - $last['created_at'] < 60) resp(false, ['error' => '发太快了，60秒后再试']);
    $code = gen_code(6);
    $st = $db->prepare("INSERT INTO email_codes (email,code,purpose,expires_at,used,created_at) VALUES (?,?,?,?,0,?)");
    $st->execute([$email, $code, $purpose, $now + 300, $now]);
    if ($purpose === 'reset') {
        $sent = send_qq_email($email, "LUIYo 重置密码验证码", "你正在重置 LUIYo 账号密码，验证码是：" . $code . "，5分钟内有效。如非本人操作请忽略，你的密码不会被更改。");
    } else {
        $sent = send_qq_email($email, "LUIYo 注册验证码", "你的验证码是：" . $code . "，5分钟内有效。如非本人操作请忽略。");
    }
    if (!$sent) resp(false, ['error' => '邮件发送失败，稍后再试']);
    resp(true, ['msg' => '验证码已发送到邮箱']);
}

// ============ 注册 ============
if ($action === 'register') {
    $email = strtolower(trim($in['email'] ?? ''));
    $password = $in['password'] ?? '';
    $code = trim($in['code'] ?? '');
    if (!filter_var($email, FILTER_VALIDATE_EMAIL)) resp(false, ['error' => '邮箱格式不对']);
    if (strlen($password) < 6) resp(false, ['error' => '密码至少6位']);
    if (strlen($code) !== 6) resp(false, ['error' => '验证码是6位数字']);
    $st = $db->prepare("SELECT * FROM email_codes WHERE email=? AND code=? AND used=0 AND expires_at>? ORDER BY id DESC LIMIT 1");
    $st->execute([$email, $code, $now]);
    $ec = $st->fetch(PDO::FETCH_ASSOC);
    if (!$ec) resp(false, ['error' => '验证码不对或已过期']);
    $st = $db->prepare("SELECT id FROM users WHERE email=?");
    $st->execute([$email]);
    if ($st->fetch()) resp(false, ['error' => '这个邮箱注册过了，直接登录吧']);
    $hash = password_hash($password, PASSWORD_BCRYPT);
    $st = $db->prepare("INSERT INTO users (email,password_hash,is_verified,created_at) VALUES (?,?,1,?)");
    $st->execute([$email, $hash, $now]);
    $uid = $db->lastInsertId();
    $db->prepare("UPDATE email_codes SET used=1 WHERE id=?")->execute([$ec['id']]);
    resp(true, ['user_id' => (int)$uid, 'email' => $email, 'msg' => '注册成功，请登录']);
}

// ============ 找回密码（邮箱验证码重置） ============
if ($action === 'reset_password') {
    $email = strtolower(trim($in['email'] ?? ''));
    $password = $in['password'] ?? '';
    $code = trim($in['code'] ?? '');
    if (!filter_var($email, FILTER_VALIDATE_EMAIL)) resp(false, ['error' => '邮箱格式不对']);
    if (strlen($password) < 6) resp(false, ['error' => '密码至少6位']);
    if (strlen($code) !== 6) resp(false, ['error' => '验证码是6位数字']);
    $st = $db->prepare("SELECT * FROM email_codes WHERE email=? AND code=? AND purpose='reset' AND used=0 AND expires_at>? ORDER BY id DESC LIMIT 1");
    $st->execute([$email, $code, $now]);
    $ec = $st->fetch(PDO::FETCH_ASSOC);
    if (!$ec) resp(false, ['error' => '验证码不对或已过期']);
    $st = $db->prepare("SELECT id FROM users WHERE email=?");
    $st->execute([$email]);
    $u = $st->fetch(PDO::FETCH_ASSOC);
    if (!$u) resp(false, ['error' => '该邮箱未注册']);
    $hash = password_hash($password, PASSWORD_BCRYPT);
    // 改密码 + 踢掉已登录设备 + 清错误锁定；SVIP 与绑定的卡密不受影响
    $db->prepare("UPDATE users SET password_hash=?, current_device_id='', failed_count=0, locked_until=0 WHERE id=?")
       ->execute([$hash, $u['id']]);
    $db->prepare("DELETE FROM device_confirms WHERE user_id=?")->execute([$u['id']]);
    $db->prepare("UPDATE email_codes SET used=1 WHERE id=?")->execute([$ec['id']]);
    resp(true, ['msg' => '密码已重置，请用新密码重新登录']);
}

// ============ 登录（含安全 1/2/3/5） ============
if ($action === 'login') {
    $email = strtolower(trim($in['email'] ?? ''));
    $password = $in['password'] ?? '';
    $device_id = trim($in['device_id'] ?? '');
    $jailbroken = !empty($in['jailbroken']) ? 1 : 0;
    if (!$device_id) resp(false, ['error' => '缺少设备标识']);
    $st = $db->prepare("SELECT * FROM users WHERE email=?");
    $st->execute([$email]);
    $u = $st->fetch(PDO::FETCH_ASSOC);
    if (!$u) resp(false, ['error' => '账号不存在，先注册吧']);
    // 安全1：锁定中
    if ((int)$u['locked_until'] > $now) {
        $m = ceil(($u['locked_until'] - $now) / 60);
        resp(false, ['error' => "密码错误次数过多，账号已锁定，{$m}分钟后再试", 'locked' => true]);
    }
    // 密码校验 + 安全1计数
    if (!password_verify($password, $u['password_hash'])) {
        $fails = (int)$u['failed_count'] + 1;
        if ($fails >= 5) {
            $db->prepare("UPDATE users SET failed_count=0, locked_until=? WHERE id=?")->execute([$now + 900, $u['id']]);
            resp(false, ['error' => '密码错误次数过多，账号锁定15分钟', 'locked' => true]);
        }
        $db->prepare("UPDATE users SET failed_count=? WHERE id=?")->execute([$fails, $u['id']]);
        resp(false, ['error' => '密码不对（还剩' . (5 - $fails) . '次）']);
    }
    if ($u['is_banned']) resp(false, ['error' => '账号已被封禁' . ($u['ban_reason'] ? '：' . $u['ban_reason'] : '')]);
    // 安全5：越狱检测（按账号单独开关）
    if ($jailbroken && empty($u['allow_jailbreak'])) {
        resp(false, ['error' => '检测到越狱设备，该账号未开通越狱使用权限', 'jailbreak_denied' => true]);
    }
    $isNewDevice = ($u['current_device_id'] !== '' && $u['current_device_id'] !== $device_id);
    // 首次登录（还没绑定设备）：直接绑定
    if ($u['current_device_id'] === '') {
        $db->prepare("UPDATE users SET current_device_id=?, last_login_at=?, failed_count=0 WHERE id=?")
           ->execute([$device_id, $now, $u['id']]);
        log_login($db, $u['id'], $device_id, $now);
        $svip = $u['svip_expires_at'] > $now;
        resp(true, ['user_id' => (int)$u['id'], 'email' => $u['email'], 'token' => $device_id, 'svip' => $svip, 'svip_expires_at' => (int)$u['svip_expires_at']]);
    }
    // 同设备登录：直接通过
    if (!$isNewDevice) {
        $db->prepare("UPDATE users SET last_login_at=?, failed_count=0 WHERE id=?")->execute([$now, $u['id']]);
        log_login($db, $u['id'], $device_id, $now);
        $svip = $u['svip_expires_at'] > $now;
        resp(true, ['user_id' => (int)$u['id'], 'email' => $u['email'], 'token' => $device_id, 'svip' => $svip, 'svip_expires_at' => (int)$u['svip_expires_at']]);
    }
    // 新设备 + 24h 冷静期
    if ($now - (int)$u['device_switch_at'] < 86400 && (int)$u['device_switch_at'] > 0) {
        $h = ceil((86400 - ($now - $u['device_switch_at'])) / 3600);
        resp(false, ['error' => "换设备太频繁，{$h}小时后再试", 'cooldown' => true]);
    }
    // 安全2：新设备需邮箱确认
    $ctoken = gen_token();
    $db->prepare("INSERT INTO device_confirms (user_id,device_id,token,expires_at,used,created_at) VALUES (?,?,?,?,0,?)")
       ->execute([$u['id'], $device_id, $ctoken, $now + 1800, $now]);
    $link = BASE_URL . '/user-auth-v2.php?action=confirm_device&token=' . $ctoken;
    $sent = send_qq_email($u['email'], "LUIYo 新设备登录确认",
        "有人在新设备上登录你的账号。\r\n如果这是你本人操作，请在30分钟内打开下面链接确认，旧设备将自动下线：\r\n" . $link . "\r\n如果不是你本人，请忽略并修改密码。");
    if (!$sent) resp(false, ['error' => '确认邮件发送失败，稍后再试']);
    resp(true, ['need_confirm' => true, 'msg' => '新设备登录：确认邮件已发送，请去邮箱点确认链接，然后在 App 点「我已确认」']);
}

// App 点「我已确认」后轮询这个接口
if ($action === 'check_confirm') {
    $st = $db->prepare("SELECT * FROM users WHERE email=?");
    $st->execute([strtolower(trim($in['email'] ?? ''))]);
    $u = $st->fetch(PDO::FETCH_ASSOC);
    if (!$u) resp(false, ['error' => '账号不存在']);
    $device_id = trim($in['device_id'] ?? '');
    if ($u['current_device_id'] === $device_id && $device_id !== '') {
        $db->prepare("UPDATE users SET failed_count=0 WHERE id=?")->execute([$u['id']]);
        log_login($db, $u['id'], $device_id, $now);
        $svip = $u['svip_expires_at'] > $now;
        resp(true, ['confirmed' => true, 'token' => $device_id, 'svip' => $svip, 'svip_expires_at' => (int)$u['svip_expires_at']]);
    }
    resp(true, ['confirmed' => false, 'msg' => '还没确认，去邮箱点链接']);
}

// ============ 绑卡密 ============
if ($action === 'bind_card') {
    $token = trim($in['token'] ?? '');
    $card = strtoupper(trim($in['card'] ?? ''));
    if (!$token) resp(false, ['error' => '先登录']);
    $st = $db->prepare("SELECT * FROM users WHERE current_device_id=?");
    $st->execute([$token]);
    $u = $st->fetch(PDO::FETCH_ASSOC);
    if (!$u) resp(false, ['error' => '登录过期，重新登录吧']);
    if ($u['is_banned']) resp(false, ['error' => '账号已被封禁']);
    $st = $db->prepare("SELECT * FROM licenses WHERE code_plain=?");
    $st->execute([$card]);
    $lic = $st->fetch(PDO::FETCH_ASSOC);
    if (!$lic) resp(false, ['error' => '卡密不存在']);
    if (!empty($lic['disabled'])) resp(false, ['error' => '这张卡密已作废']);
    $st = $db->prepare("SELECT id FROM users WHERE license_id=? AND id!=?");
    $st->execute([$lic['id'], $u['id']]);
    if ($st->fetch(PDO::FETCH_ASSOC)) resp(false, ['error' => '这张卡密已被其他账号绑定']);
    // 记录这张卡被哪个账号绑定（卡密列表要清楚显示 账号 + UDID）
    $db->prepare("UPDATE licenses SET bound_user_id=?, bound_email=?, bound_at=? WHERE id=?")->execute([$u['id'], $u['email'], $now, $lic['id']]);
    // SVIP 时长：按卡面天数（生成卡密时设定），没有天数的旧卡默认 30 天；days>=36500 视为永久
    $days = !empty($lic['days']) ? (int)$lic['days'] : 30;
    if ($days >= 36500) { $expires = 4102444800; $db->prepare("UPDATE users SET svip_expires_at=?, license_id=? WHERE id=?")->execute([$expires, $lic['id'], $u['id']]); resp(true, ['svip' => true, 'svip_expires_at' => $expires, 'days' => $days]); }
    $expires = $now + $days * 86400;
    if ($u['svip_expires_at'] > $now) $expires = $u['svip_expires_at'] + $days * 86400;
    $db->prepare("UPDATE users SET svip_expires_at=?, license_id=? WHERE id=?")->execute([$expires, $lic['id'], $u['id']]);
    resp(true, ['svip' => true, 'svip_expires_at' => $expires, 'days' => $days]);
}

// ============ 查账号状态（App 心跳） ============
// 生成一次性 UDID 获取链接（10 分钟有效），主 App 打开后走 Safari 安装描述文件
if ($action === 'udid_enroll') {
    $token = trim($in['token'] ?? '');
    $st = $db->prepare("SELECT * FROM users WHERE current_device_id=?");
    $st->execute([$token]);
    $u = $st->fetch();
    if (!$u) resp(false, ['error' => '未登录']);
    $t = bin2hex(random_bytes(16));
    $db->prepare("INSERT INTO udid_enroll (token,user_id,expires_at,used,created_at) VALUES (?,?,?,0,?)")
       ->execute([$t, $u['id'], time() + 600, time()]);
    $self = 'https://' . $_SERVER['HTTP_HOST'] . $_SERVER['SCRIPT_NAME'];
    resp(true, ['profile_url' => $self . '?action=udid_profile&t=' . $t, 'expires_in' => 600]);
}

// 主 App 直接上报 UDID（签名描述文件里能读到时用）
if ($action === 'report_udid') {
    $token = trim($in['token'] ?? '');
    $udid = trim($in['udid'] ?? '');
    if (!preg_match('/^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16})$/', $udid)) resp(false, ['error' => 'UDID 格式不正确']);
    $st = $db->prepare("SELECT * FROM users WHERE current_device_id=?");
    $st->execute([$token]);
    $u = $st->fetch();
    if (!$u) resp(false, ['error' => '未登录']);
    $db->prepare("UPDATE users SET udid=? WHERE id=?")->execute([$udid, $u['id']]);
    resp(true, ['ok' => true, 'udid' => $udid]);
}

if ($action === 'status') {
    $token = trim($in['token'] ?? $_GET['token'] ?? '');
    $st = $db->prepare("SELECT * FROM users WHERE current_device_id=?");
    $st->execute([$token]);
    $u = $st->fetch(PDO::FETCH_ASSOC);
    if (!$u) resp(false, ['error' => '未登录', 'logged_out' => true]);
    if ($u['is_banned']) resp(true, ['banned' => true, 'reason' => $u['ban_reason']]);
    $svip = $u['svip_expires_at'] > $now;
    resp(true, ['email' => $u['email'], 'svip' => $svip, 'svip_expires_at' => (int)$u['svip_expires_at'], 'banned' => false, 'udid' => $u['udid'] ?? '']);
}

// ============ 管理员接口 ============
if (in_array($action, ['admin_list', 'admin_ban', 'admin_jailbreak', 'admin_unflag', 'admin_gen_cards', 'admin_list_cards', 'admin_disable_card', 'admin_delete_card', 'admin_mail_log'], true)) {
    if (!admin_authed($in)) { http_response_code(401); resp(false, ['error' => '未授权']); }
    if ($action === 'admin_list') {
        $st = $db->query("SELECT id,email,is_verified,is_banned,ban_reason,svip_expires_at,ip_flagged,allow_jailbreak,udid,created_at,last_login_at FROM users ORDER BY id DESC LIMIT 200");
        $list = [];
        while ($r = $st->fetch(PDO::FETCH_ASSOC)) { $r['svip'] = $r['svip_expires_at'] > $now; $list[] = $r; }
        resp(true, ['users' => $list, 'total' => count($list)]);
    }
    if ($action === 'admin_mail_log') {
        $st = $db->query("SELECT id, to_email, subject, ok, created_at FROM mail_log ORDER BY id DESC LIMIT 300");
        $logs = [];
        while ($r = $st->fetch(PDO::FETCH_ASSOC)) $logs[] = $r;
        resp(true, ['logs' => $logs, 'total' => count($logs)]);
    }
    $email = strtolower(trim($in['email'] ?? ''));
    if ($action === 'admin_ban') {
        $ban = (int)($in['ban'] ?? 1); $reason = trim($in['reason'] ?? '');
        $db->prepare("UPDATE users SET is_banned=?, ban_reason=? WHERE email=?")->execute([$ban, $reason, $email]);
        resp(true, ['msg' => $ban ? '已封禁' : '已解封']);
    }
    if ($action === 'admin_jailbreak') {
        $allow = (int)($in['allow'] ?? 0);
        $db->prepare("UPDATE users SET allow_jailbreak=? WHERE email=?")->execute([$allow, $email]);
        resp(true, ['msg' => $allow ? '已允许该账号使用越狱设备' : '已禁止该账号使用越狱设备']);
    }
    if ($action === 'admin_unflag') {
        $db->prepare("UPDATE users SET ip_flagged=0 WHERE email=?")->execute([$email]);
        resp(true, ['msg' => '已取消 IP 标红']);
    }
    // ---------- 卡密管理（生成 / 列表 / 作废） ----------
    if ($action === 'admin_gen_cards') {
        $count = max(1, min(100, (int)($in['count'] ?? 1)));
        $days = max(1, min(36500, (int)($in['days'] ?? 30)));
        $remark = trim((string)($in['remark'] ?? ''));
        $remark = preg_replace('/\s+/u', '', $remark);
        $remark = str_replace(['/', '\\', '"', "'"], '', $remark);
        $remark = strtoupper($remark);
        if (mb_strlen($remark) > 20) $remark = mb_substr($remark, 0, 20);
        $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
        $codes = [];
        $ins = $db->prepare("INSERT INTO licenses (code_hash, code_plain, disabled, days, created_at, remark) VALUES (?, ?, 0, ?, ?, ?)");
        $guard = 0; $lastErr = '';
        while (count($codes) < $count && $guard < $count * 30) {
            $guard++;
            $parts = [];
            for ($p = 0; $p < 4; $p++) {
                $seg = '';
                for ($i = 0; $i < 5; $i++) $seg .= $alphabet[random_int(0, strlen($alphabet) - 1)];
                $parts[] = $seg;
            }
            $rand = implode('-', $parts);
            $code = $remark !== '' ? ('LUI-' . $remark . '-' . $rand) : ('LUI-' . $rand);
            try { $ins->execute([hash('sha256', $code), $code, $days, $now, $remark]); $codes[] = $code; } catch (Exception $e) { $lastErr = $e->getMessage(); /* 撞码重试 */ }
        }
        if (count($codes) === 0) resp(false, ['error' => '生成失败：' . ($lastErr !== '' ? $lastErr : '未知错误')]);
        resp(true, ['codes' => $codes, 'count' => count($codes), 'days' => $days, 'remark' => $remark]);
    }
    if ($action === 'admin_list_cards') {
        $st = $db->query("SELECT l.id, l.code_plain, l.disabled, l.days, l.created_at, l.remark, l.bound_user_id, l.bound_email, l.bound_at, (SELECT email FROM users WHERE license_id=l.id LIMIT 1) AS fb_email, (SELECT udid FROM users WHERE id=l.bound_user_id) AS udid1, (SELECT udid FROM users WHERE license_id=l.id LIMIT 1) AS udid2 FROM licenses l WHERE l.code_plain <> '' ORDER BY l.id DESC");
        $cards = [];
        while ($r = $st->fetch(PDO::FETCH_ASSOC)) {
            $be = !empty($r['bound_email']) ? $r['bound_email'] : ($r['fb_email'] ?? '');
            $bu = !empty($r['udid1']) ? $r['udid1'] : ($r['udid2'] ?? '');
            $cards[] = ['id' => (int)$r['id'], 'code' => $r['code_plain'], 'disabled' => (int)$r['disabled'],
                        'days' => (int)($r['days'] ?? 30), 'created_at' => (int)($r['created_at'] ?? 0),
                        'remark' => $r['remark'] ?? '', 'bound_email' => $be,
                        'bound_udid' => $bu, 'bound_at' => (int)($r['bound_at'] ?? 0)];
        }
        resp(true, ['cards' => $cards, 'total' => count($cards)]);
    }
    if ($action === 'admin_delete_card') {
        $cid = (int)($in['id'] ?? 0);
        $db->prepare("DELETE FROM licenses WHERE id=?")->execute([$cid]);
        resp(true, ['msg' => '已删除']);
    }
    if ($action === 'admin_disable_card') {
        $cid = (int)($in['id'] ?? 0); $dis = (int)($in['disabled'] ?? 1);
        $db->prepare("UPDATE licenses SET disabled=? WHERE id=?")->execute([$dis, $cid]);
        resp(true, ['msg' => $dis ? '已作废' : '已恢复']);
    }
}

resp(false, ['error' => '未知 action']);

// ---------- 登录日志 + 安全3：IP 异常标红 ----------
function log_login($db, $uid, $device_id, $now) {
    $ip = client_ip();
    $db->prepare("INSERT INTO login_logs (user_id,ip,device_id,created_at) VALUES (?,?,?,?)")
       ->execute([$uid, $ip, $device_id, $now]);
    // 1 小时内出现过另一个不同 IP → 标红（人工审核）
    $st = $db->prepare("SELECT COUNT(DISTINCT ip) FROM login_logs WHERE user_id=? AND created_at>?");
    $st->execute([$uid, $now - 3600]);
    if ((int)$st->fetchColumn() >= 2) {
        $db->prepare("UPDATE users SET ip_flagged=1 WHERE id=?")->execute([$uid]);
    }
    // 只留最近 30 天日志
    $db->prepare("DELETE FROM login_logs WHERE created_at<?")->execute([$now - 30 * 86400]);
}
