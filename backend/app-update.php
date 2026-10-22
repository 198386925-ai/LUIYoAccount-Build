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
// 重复上传同版本+同构建时自动替换旧的（IPA 文件覆盖、注册表条目顶替，不产生重复行）
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

// ---- 版本注册表（updates/versions.json：每个发布过的版本一行：状态 + 弹窗文案） ----
// 状态：normal 正常 / soft 弹更新（可无视） / banned 禁用（必须退 App）
// 非 normal 的状态会同步进 latest.json 的 version_states，主 App 直接读 latest.json 就能执行
function versions_path() { return UPD_DIR . '/versions.json'; }

function default_popup($version) {
    return [
        'title' => '请尽快更新' . $version . '版本',
        'l2'    => '如您不更新我将禁用此版本',
        'l3'    => 'LUIYo ' . $version . '版本已更新请您尽快更新',
    ];
}

function make_version_entry($version, $build, $notes, $publishedAt = null) {
    $p = default_popup($version);
    return [
        'version'      => (string)$version,
        'build'        => (string)$build,
        'notes'        => (string)$notes,
        'published_at' => $publishedAt ?? time(),
        'state'        => 'normal',
        'title'        => $p['title'],
        'l2'           => $p['l2'],
        'l3'           => $p['l3'],
    ];
}

function load_versions() {
    $f = versions_path();
    if (is_file($f)) {
        $j = json_decode(file_get_contents($f), true);
        if (is_array($j)) return $j;
    }
    // 还没有注册表：用当前 latest.json 生成一条种子记录
    $meta = UPD_DIR . '/latest.json';
    if (is_file($meta)) {
        $j = json_decode(file_get_contents($meta), true);
        if (is_array($j) && preg_match('/^v(.+)-b([0-9]+)$/', $j['tag_name'] ?? '', $m)) {
            return [make_version_entry($m[1], $m[2], $j['body'] ?? '', filemtime($meta) ?: time())];
        }
    }
    return [];
}

function save_versions($versions) {
    if (!is_dir(UPD_DIR)) mkdir(UPD_DIR, 0755, true);
    $tmp = versions_path() . '.tmp';
    file_put_contents($tmp, json_encode($versions, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT), LOCK_EX);
    rename($tmp, versions_path());
}

// 把非 normal 的版本状态同步进 latest.json 的 version_states（其余字段原样保留；没有非 normal 时删掉这个键）
function sync_version_states($versions) {
    $meta = UPD_DIR . '/latest.json';
    if (!is_file($meta)) return;
    $j = json_decode(file_get_contents($meta), true);
    if (!is_array($j)) return;
    $map = [];
    foreach ($versions as $v) {
        $st = $v['state'] ?? 'normal';
        if ($st !== 'normal' && !empty($v['build'])) {
            $map[(string)$v['build']] = [
                'state' => $st,
                'title' => $v['title'] ?? '',
                'l2'    => $v['l2'] ?? '',
                'l3'    => $v['l3'] ?? '',
            ];
        }
    }
    if ($map) $j['version_states'] = $map; else unset($j['version_states']);
    $tmp = $meta . '.tmp';
    file_put_contents($tmp, json_encode($j, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT), LOCK_EX);
    rename($tmp, $meta);
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

    // 先读版本注册表（缺失时用旧 latest.json 做种子，必须赶在 latest.json 被覆盖之前）
    $versions = load_versions();

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

    // 新版本登记进注册表（置顶，状态 normal + 默认弹窗文案），再把已有版本的状态同步回新 latest.json
    // Build 40：重复上传同 build 时自动替换——先剔除注册表里同 build 的旧
    // 条目（注册表全系统以 build 为键，version_set / version_delete 同口径；
    // 历史遗留的同 build 重复行也一并清掉），新条目顶替它，不再叠出重复行；
    // 同名 IPA 文件在上面 move_uploaded_file 时已直接覆盖为最新一份，
    // version_states 随后按新注册表重建，旧条目的状态/文案随之失效
    $versions = array_values(array_filter($versions, function ($v) use ($build) {
        return (string)($v['build'] ?? '') !== (string)$build;
    }));
    array_unshift($versions, make_version_entry($version, $build, $notes));
    save_versions($versions);
    sync_version_states($versions);

    out(['ok' => true, 'name' => $name, 'version' => $version, 'build' => $build,
         'size' => $size, 'sha256' => $sha, 'url' => $url, 'latest' => $latest]);
}

// ---- 版本管理（需管理员密码，JSON body，与账号 App 的 postUpdate 对应） ----
if ($action === 'versions_list' || $action === 'version_set' || $action === 'version_delete') {
    $raw = json_decode(file_get_contents('php://input'), true);
    $in = is_array($raw) ? $raw : $_POST;
    if (!admin_authed($in['password'] ?? '')) out(['ok' => false, 'error' => '密码验证失败'], 401);
    $versions = load_versions();
    if ($action === 'versions_list') {
        out(['ok' => true, 'versions' => $versions]);
    }
    // version_delete：按 build 删注册表记录（同 build 的重复记录一并删），同步
    // latest.json 的 version_states；只删记录，绝不删 updates/ 里已上传的 IPA 文件
    if ($action === 'version_delete') {
        $build = trim((string)($in['build'] ?? ''));
        if ($build === '') out(['ok' => false, 'error' => '缺少 build 参数']);
        $kept = [];
        foreach ($versions as $v) {
            if ((string)($v['build'] ?? '') !== $build) $kept[] = $v;
        }
        if (count($kept) === count($versions)) {
            out(['ok' => false, 'error' => '找不到构建号 ' . $build . ' 的版本记录']);
        }
        save_versions($kept);
        sync_version_states($kept);
        out(['ok' => true, 'versions' => $kept]);
    }
    // version_set：按 build 定位，只改传了的字段（状态 / 标题 / 第二行 / 第三行）
    $build = trim((string)($in['build'] ?? ''));
    if ($build === '') out(['ok' => false, 'error' => '缺少 build 参数']);
    $found = false;
    foreach ($versions as $i => $v) {
        if ((string)($v['build'] ?? '') === $build) {
            if (isset($in['state']) && in_array($in['state'], ['normal', 'soft', 'banned'], true)) {
                $versions[$i]['state'] = $in['state'];
            }
            foreach (['title', 'l2', 'l3'] as $k) {
                if (array_key_exists($k, $in)) $versions[$i][$k] = (string)$in[$k];
            }
            $found = true;
            break;
        }
    }
    if (!$found) out(['ok' => false, 'error' => '找不到构建号 ' . $build . ' 的版本记录']);
    save_versions($versions);
    sync_version_states($versions);
    out(['ok' => true, 'versions' => $versions]);
}

out(['ok' => false, 'error' => '未知 action'], 400);
