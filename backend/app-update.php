<?php
// ============================================================
// LUIYo 应用更新服务（与邮箱账号系统共用管理员密码）
// ------------------------------------------------------------
// 部署：与 user-auth-v2.php 放同一目录（网站根目录）
// 接口：
//   POST ?action=current                 当前线上版本（免密码，读 updates/latest.json）
//   POST ?action=upload_ipa              上传 IPA（需管理员密码，multipart 表单）
//        表单字段: password, ipa(文件), version(可选), build(可选), notes(可选)
//        版本/构建号不填时自动识别：IPA 内 Info.plist → 文件名兜底
// 存储：同目录 updates/ 下存 IPA（规范名 LUIYo-<版本>-b<构建>.ipa）+ latest.json
// 更新源地址：https://你的域名/updates/latest.json（静态文件，App 直接读）
// latest.json 为 GitHub Releases 风格，含 draft/prerelease 字段（App 强校验）
// ============================================================

header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Headers: Content-Type');
header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
if (($_SERVER['REQUEST_METHOD'] ?? '') === 'OPTIONS') { http_response_code(204); exit; }

const UPD_DIR = __DIR__ . '/updates';

function out($arr, $code = 200) {
    http_response_code($code);
    echo json_encode($arr, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

// 与 user-auth-v2.php 完全一致的管理员验证
function admin_authed($pw) {
    if (!$pw) return false;
    $env_hash = getenv('LUIYO_ADMIN_HASH');
    if ($env_hash && password_verify($pw, $env_hash)) return true;
    $hash_file = '/www/luiyo-private/admin.hash';
    if (file_exists($hash_file) && password_verify($pw, trim(file_get_contents($hash_file)))) return true;
    return false;
}

function public_base() {
    $https = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off')
        || (($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https');
    $scheme = $https ? 'https' : 'http';
    $host = $_SERVER['HTTP_HOST'] ?? 'localhost';
    $dir = rtrim(str_replace('\\', '/', dirname($_SERVER['SCRIPT_NAME'] ?? '/')), '/');
    return $scheme . '://' . $host . $dir . '/updates';
}

// ---- 极简 bplist（二进制 plist）解析：只需从 Info.plist 取两个字符串 ----
function bplist_parse($data) {
    if (substr($data, 0, 8) !== 'bplist00') return null;
    $trailer = substr($data, -32);
    $offsetSize = ord($trailer[6]);
    $refSize = ord($trailer[7]);
    $readBig = function ($s, $pos, $len) { $v = 0; for ($i = 0; $i < $len; $i++) $v = $v * 256 + ord($s[$pos + $i]); return $v; };
    $numObjects = $readBig($trailer, 8, 8);
    $topObject = $readBig($trailer, 16, 8);
    $offsetTable = $readBig($trailer, 24, 8);
    $offsets = [];
    for ($i = 0; $i < $numObjects; $i++) $offsets[] = $readBig($data, $offsetTable + $i * $offsetSize, $offsetSize);
    $parse = null;
    $parse = function ($idx) use (&$parse, $data, $offsets, $refSize, $readBig) {
        $pos = $offsets[$idx];
        $byte = ord($data[$pos]);
        $type = $byte >> 4;
        $info = $byte & 0x0F;
        $pos++;
        if ($info === 0x0F) {
            $lenByte = ord($data[$pos]);
            $lenLen = 1 << ($lenByte & 0x0F);
            $pos++;
            $info = $readBig($data, $pos, $lenLen);
            $pos += $lenLen;
        }
        switch ($type) {
            case 0x0:
                if ($info === 0) return null;
                if ($info === 8) return false;
                if ($info === 9) return true;
                return null;
            case 0x1:
                return $readBig($data, $pos, 1 << $info);
            case 0x4:
                return substr($data, $pos, $info);
            case 0x5:
                return substr($data, $pos, $info);
            case 0x6:
                $s = substr($data, $pos, $info * 2);
                return function_exists('mb_convert_encoding') ? mb_convert_encoding($s, 'UTF-8', 'UTF-16BE') : $s;
            case 0xA:
                $arr = [];
                for ($i = 0; $i < $info; $i++) $arr[] = $parse($readBig($data, $pos + $i * $refSize, $refSize));
                return $arr;
            case 0xD:
                $dict = [];
                for ($i = 0; $i < $info; $i++) {
                    $k = $parse($readBig($data, $pos + $i * $refSize, $refSize));
                    $v = $parse($readBig($data, $pos + ($info + $i) * $refSize, $refSize));
                    if (is_string($k)) $dict[$k] = $v;
                }
                return $dict;
        }
        return null;
    };
    $root = $parse($topObject);
    return is_array($root) ? $root : null;
}

// 从 IPA 文件读 Info.plist 的版本/构建号；返回 [version, build]（取不到为 null）
function ipa_version_build($path) {
    if (!class_exists('ZipArchive')) return [null, null];
    $zip = new ZipArchive();
    if ($zip->open($path) !== true) return [null, null];
    $target = null;
    for ($i = 0; $i < $zip->numFiles; $i++) {
        $n = $zip->getNameIndex($i);
        if (preg_match('#^Payload/[^/]+\.app/Info\.plist$#', $n)) { $target = $n; break; }
    }
    if ($target === null) { $zip->close(); return [null, null]; }
    $raw = $zip->getFromName($target);
    $zip->close();
    if ($raw === false) return [null, null];
    if (substr($raw, 0, 8) === 'bplist00') {
        $p = bplist_parse($raw);
        if ($p) return [$p['CFBundleShortVersionString'] ?? null, $p['CFBundleVersion'] ?? null];
        return [null, null];
    }
    $v = $b = null;
    if (preg_match('/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]*)<\/string>/', $raw, $m)) $v = trim($m[1]);
    if (preg_match('/<key>CFBundleVersion<\/key>\s*<string>([^<]*)<\/string>/', $raw, $m)) $b = trim($m[1]);
    return [$v, $b];
}

$action = $_GET['action'] ?? '';

if ($action === 'current') {
    $meta = UPD_DIR . '/latest.json';
    if (!is_file($meta)) out(['ok' => false, 'error' => '尚未发布任何版本']);
    $j = json_decode(file_get_contents($meta), true);
    if (!is_array($j)) out(['ok' => false, 'error' => 'latest.json 损坏']);
    $j['ok'] = true;
    out($j);
}

if ($action === 'upload_ipa') {
    $pw = $_POST['password'] ?? '';
    if (!admin_authed($pw)) out(['ok' => false, 'error' => '密码验证失败'], 401);

    if (!isset($_FILES['ipa']) || $_FILES['ipa']['error'] !== UPLOAD_ERR_OK) {
        $code = $_FILES['ipa']['error'] ?? -1;
        $hint = ($code === UPLOAD_ERR_INI_SIZE || $code === UPLOAD_ERR_FORM_SIZE)
            ? '文件超过服务器上传上限（去宝塔 PHP 设置调大 upload_max_filesize）' : '没有收到文件';
        out(['ok' => false, 'error' => $hint]);
    }
    $tmp = $_FILES['ipa']['tmp_name'];
    $origName = $_FILES['ipa']['name'] ?? '';

    if (!class_exists('ZipArchive')) out(['ok' => false, 'error' => '服务器 PHP 缺少 ZipArchive 扩展']);
    $zip = new ZipArchive();
    if ($zip->open($tmp) !== true) out(['ok' => false, 'error' => '不是有效的 IPA（zip 打不开）']);
    $hasPlist = false;
    for ($i = 0; $i < $zip->numFiles; $i++) {
        if (preg_match('#^Payload/[^/]+\.app/Info\.plist$#', $zip->getNameIndex($i))) { $hasPlist = true; break; }
    }
    $zip->close();
    if (!$hasPlist) out(['ok' => false, 'error' => '不是有效的 IPA（缺 Payload/*.app/Info.plist）']);

    $version = trim($_POST['version'] ?? '');
    $build = trim($_POST['build'] ?? '');
    $notes = trim($_POST['notes'] ?? '');

    if ($version === '' || $build === '') {
        [$iv, $ib] = ipa_version_build($tmp);
        if ($version === '' && $iv) $version = trim((string)$iv);
        if ($build === '' && $ib) $build = trim((string)$ib);
    }
    if ($version === '' || $build === '') {
        if (preg_match('/^LUIYo-([0-9]+(?:\.[0-9]+){1,3})-b([1-9][0-9]*)\.ipa$/i', $origName, $m)) {
            if ($version === '') $version = $m[1];
            if ($build === '') $build = $m[2];
        } elseif (preg_match('/-([0-9]+(?:\.[0-9]+){1,3}(?:-[0-9]+)?)-Build\(([0-9]+)\)\.ipa$/i', $origName, $m)) {
            if ($version === '') $version = $m[1];
            if ($build === '') $build = $m[2];
        }
    }
    // 版本号尾巴的 -N（如 1.0.7-1）不符合检查更新格式，自动去掉
    if ($version !== '' && !preg_match('/^[0-9]+(\.[0-9]+){0,3}$/', $version) && preg_match('/^([0-9]+(\.[0-9]+){0,3})-[0-9]+$/', $version, $m)) {
        $version = $m[1];
    }
    if (!preg_match('/^[0-9]+(\.[0-9]+){0,3}$/', $version)) {
        out(['ok' => false, 'error' => '版本号「' . $version . '」格式不对（应如 1.0.7），请手动填写']);
    }
    if (!preg_match('/^[1-9][0-9]*$/', $build)) {
        out(['ok' => false, 'error' => '构建号「' . $build . '」格式不对（应为纯数字），请手动填写']);
    }

    if (!is_dir(UPD_DIR) && !mkdir(UPD_DIR, 0755, true)) out(['ok' => false, 'error' => '无法创建 updates 目录']);

    $name = 'LUIYo-' . $version . '-b' . $build . '.ipa';
    $dest = UPD_DIR . '/' . $name;
    if (!move_uploaded_file($tmp, $dest)) out(['ok' => false, 'error' => '保存文件失败']);

    $size = filesize($dest);
    $sha = hash_file('sha256', $dest);
    $url = public_base() . '/' . $name;

    $latest = [
        'tag_name' => 'v' . $version . '-b' . $build,
        'draft' => false,
        'prerelease' => false,
        'body' => $notes !== '' ? $notes : '本次更新：优化体验，修复已知问题。',
        'assets' => [[
            'name' => $name,
            'size' => $size,
            'digest' => 'sha256:' . $sha,
            'browser_download_url' => $url,
        ]],
    ];
    $json = json_encode($latest, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT);
    $metaTmp = UPD_DIR . '/latest.json.tmp';
    file_put_contents($metaTmp, $json, LOCK_EX);
    rename($metaTmp, UPD_DIR . '/latest.json');

    out(['ok' => true, 'name' => $name, 'version' => $version, 'build' => $build,
         'size' => $size, 'sha256' => $sha, 'url' => $url, 'latest' => $latest]);
}

out(['ok' => false, 'error' => '未知 action'], 400);
