# install.ps1 — USB ブート済みの PIX-SMB400 / TU-BUHD100 に mirakc を入れて起動する。
#
#   install.bat をダブルクリック、または
#   powershell -ExecutionPolicy Bypass -File install.ps1 [デバイスのIPアドレス] [-OverwriteConfig]
#
# 何度実行してもよい（更新にも使える）。既存の config.yml は上書きしない。
# Bluetooth を無効にするか聞かれる。聞かれたくなければ -Bluetooth disable / keep

param(
    [string]$IP = "",
    [switch]$OverwriteConfig,
    [ValidateSet("ask", "disable", "keep")]
    [string]$Bluetooth = "ask"
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"   # Invoke-WebRequest が極端に遅くなるのを防ぐ
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Kit = $PSScriptRoot
$Payload = Join-Path $Kit "payload"
$Tmp = "/data/local/tmp"
$MirakcDir = "$Tmp/mirakc"
$Port = 40772

function Say($m)  { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

# ---- 1. adb を用意する --------------------------------------------------------
function Find-Adb {
    $local = Join-Path $Kit "tools\platform-tools\adb.exe"
    if (Test-Path $local) { return $local }
    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$Adb = Find-Adb
if (-not $Adb) {
    Say "adb が見つからないので、Google の公式配布 (platform-tools) をダウンロードします"
    $url = "https://dl.google.com/android/repository/platform-tools-latest-windows.zip"
    $tools = Join-Path $Kit "tools"
    New-Item -ItemType Directory -Force -Path $tools | Out-Null
    $zip = Join-Path $tools "platform-tools.zip"
    try {
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath $tools -Force
        Remove-Item $zip
    } catch {
        Die "adb のダウンロードに失敗しました: $($_.Exception.Message)"
    }
    $Adb = Find-Adb
    if (-not $Adb) { Die "adb の準備に失敗しました" }
}
Ok "adb: $Adb"

# ---- 2. 接続 ------------------------------------------------------------------
if (-not $IP) { $IP = Read-Host "デバイスの IP アドレスを入力してください (例 192.168.0.77)" }
$IP = ($IP.Trim() -split ":")[0]
if (-not $IP) { Die "IP アドレスが空です" }
$T = "${IP}:5555"

function AdbRun { & $Adb -s $T @args }
# デバイス上でシェルコマンドを実行し、出力（文字列）を返す
function Dev([string]$cmd) { (& $Adb -s $T shell $cmd 2>$null | Out-String).Trim() }
# デバイス上で test などを実行し、成否を返す
function DevTest([string]$cmd) { & $Adb -s $T shell $cmd 2>$null | Out-Null; return ($LASTEXITCODE -eq 0) }

Say "$T に接続します"
$connected = $false
for ($i = 0; $i -lt 10; $i++) {
    & $Adb connect $T 2>$null | Out-Null
    $state = (& $Adb -s $T get-state 2>$null | Out-String).Trim()
    if ($state -eq "device") { $connected = $true; break }
    Start-Sleep -Seconds 3
}
if (-not $connected) { Die "$T に接続できません。IP アドレスと、USB ブートで起動しているか（起動から 1 分ほど待ったか）を確認してください" }

# ---- 3. 状態チェック ----------------------------------------------------------
$uid = Dev "id -u"
if ($uid -ne "0") { Die "root で接続できていません (uid=$uid)。USB ブートではなく通常起動しています。USB メモリとブート手順を確認してください" }

$board = Dev "getprop pix.hw.boardname"
if ($board -ne "PIX-SMB400") { Die "対応していない機種です (pix.hw.boardname=$board)" }

if (DevTest "grep -q '^service mirakc ' /init.pixboot.rc") {
    Ok "USB ブート (mirakc 版) で起動しています"
} elseif (DevTest "grep -q mirakurun_proxy /init.pixboot.rc") {
    Die "USB メモリの中身が Mirakurun 版です。このキットの USB フォルダのファイルに差し替えて再起動してから、もう一度実行してください"
} else {
    Die "このキットの USB メモリで起動していないようです (/init.pixboot.rc に mirakc サービスが無い)"
}

# ---- 4. ACAS キー -------------------------------------------------------------
$Key = ""
$keyFile = Join-Path $Kit "acas_key.txt"
if (Test-Path $keyFile) {
    $Key = ((Get-Content $keyFile -Raw) -replace "\s", "")
    Say "acas_key.txt からキーを読みました"
} elseif (DevTest "test -s $Tmp/.acas_key") {
    Ok "ACAS キーはデバイスに設定済みです（そのまま使います）"
} else {
    Write-Host "BS4K を見るには ACAS キー（64 桁の 16 進数）が必要です。"
    Write-Host "持っていなければ空のまま Enter（地デジ・BS は見られます。後から設定もできます）。"
    $Key = ((Read-Host "ACAS キー") -replace "\s", "")
}
if ($Key) {
    if ($Key -notmatch '^[0-9a-fA-F]{64}$') { Die "ACAS キーの形式が違います（64 桁の 16 進数）" }
    Dev "umask 077; echo '$Key' > $Tmp/.acas_key; chmod 600 $Tmp/.acas_key" | Out-Null
    Ok "ACAS キーを設定しました"
} elseif (-not (DevTest "test -s $Tmp/.acas_key")) {
    Warn "ACAS キーなしで続けます（BS4K はスクランブルのまま）"
}

# ---- 5. 動いている mirakc を止める -------------------------------------------
# pkill -f は adb shell 自身にマッチして自殺するので PID を引いて kill する
Say "動作中の mirakc があれば止めます"
Dev 'stop mirakc 2>/dev/null; true' | Out-Null
# Windows PowerShell 5.1 は引数中の " を正しく渡せないので、デバイス側のコマンドでは ' だけを使う
Dev 'p=$(pgrep -f ''mirakc/mirakc$'' | head -1); [ x$p != x ] && kill -TERM $p && sleep 3; true' | Out-Null
Dev 'p=$(pgrep -f tuner_reaper | head -1); [ x$p != x ] && kill -9 $p; true' | Out-Null

# ---- 6. ファイルを送る --------------------------------------------------------
function Push($src, $dst) {
    & $Adb -s $T push $src $dst 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "転送に失敗しました: $src" }
}

Say "バイナリを送ります（30MB ほど）"
Dev "mkdir -p $MirakcDir/epg" | Out-Null
foreach ($f in "tuner-stream-ng", "tuner-stream-bs", "tuner-stream-bs-ng", "b21dec", "b61dec", "dantto4k") {
    Push (Join-Path $Payload "bin\$f") "$Tmp/$f"
}
foreach ($f in "mirakc", "mirakc-arib") {
    Push (Join-Path $Payload "bin\$f") "$MirakcDir/$f"
}
Dev "chmod 755 $Tmp/tuner-stream-ng $Tmp/tuner-stream-bs $Tmp/tuner-stream-bs-ng $Tmp/b21dec $Tmp/b61dec $Tmp/dantto4k $MirakcDir/mirakc $MirakcDir/mirakc-arib" | Out-Null

# スクリプトは毎ブート initramfs から上書きされる。中身は同じなので、
# 再起動せずにすぐ動かすためだけに送る
foreach ($f in "smb400-tuner.sh", "start_mirakc.sh", "tuner_reaper.sh", "stop_android_tv.sh", "crash_guard.sh") {
    Push (Join-Path $Payload "scripts\$f") "$Tmp/$f"
}
Dev "chmod 755 $Tmp/smb400-tuner.sh $Tmp/start_mirakc.sh $Tmp/tuner_reaper.sh $Tmp/stop_android_tv.sh $Tmp/crash_guard.sh" | Out-Null

Push (Join-Path $Payload "config\strings.yml") "$MirakcDir/strings.yml"
$hasConfig = DevTest "test -f $MirakcDir/config.yml"
if ($hasConfig -and -not $OverwriteConfig) {
    Ok "config.yml はデバイスにあるものをそのまま使います（上書きするなら -OverwriteConfig）"
} else {
    if ($hasConfig) {
        $bak = "config.yml.bak-" + (Get-Date -Format "yyyyMMddHHmmss")
        Dev "cp $MirakcDir/config.yml $MirakcDir/$bak" | Out-Null
        Say "既存の config.yml を $bak に退避しました"
    }
    Push (Join-Path $Payload "config\config.yml") "$MirakcDir/config.yml"
    Ok "config.yml を送りました（関東向け）"
}
Ok "ファイルの転送が終わりました"

# ---- 7. Bluetooth（任意） -----------------------------------------------------
# com.android.bluetooth が SIGABRT のクラッシュループを起こし、crash_dump32 が
# 溜まって本体が固まったことがある。mirakc には Bluetooth は要らない。
# pm disable は /data に記録されるので、USB を抜いた通常起動にも効く
$BtPkg = "com.android.bluetooth"
function BtDisabled { ((Dev "pm list packages -d") -split "`r?`n") -contains "package:$BtPkg" }
if (BtDisabled) {
    Ok "Bluetooth は無効化済みです"
} else {
    $choice = $Bluetooth
    if ($choice -eq "ask") {
        Write-Host ""
        Write-Host "Bluetooth を無効にしますか？（おすすめ）"
        Write-Host "  Bluetooth のクラッシュがきっかけで本体が固まることがありました。mirakc には不要です。"
        Write-Host "  ただし USB を抜いて普通の Android TV として使うときも Bluetooth（BT リモコンなど）が"
        Write-Host "  使えなくなります。戻すときは: adb -s $T shell pm enable $BtPkg"
        $ans = Read-Host "無効にする [Y/n]"
        if ($ans -match '^[nN]') { $choice = "keep" } else { $choice = "disable" }
    }
    if ($choice -eq "disable") {
        Dev "pm disable $BtPkg" | Out-Null
        if (BtDisabled) { Ok "Bluetooth を無効にしました" } else { Warn "Bluetooth を無効にできませんでした（このまま続けます）" }
    } else {
        Say "Bluetooth はそのままにします"
    }
}

# ---- 8. 起動 ------------------------------------------------------------------
if (DevTest "test -e $Tmp/mirakc.disabled") {
    Warn "自動起動が無効になっています ($Tmp/mirakc.disabled がある)"
    Warn "有効にするには: `"$Adb`" -s $T shell rm -f $Tmp/mirakc.disabled"
    exit 0
}

Say "mirakc を起動します（Android TV の画面は止まります）"
Dev "rm -f $Tmp/mirakc-start.pid; setsid sh $Tmp/start_mirakc.sh >/dev/null 2>&1 &" | Out-Null

Say "起動を待っています（最大 2 分）"
for ($i = 0; $i -lt 40; $i++) {
    try {
        $v = Invoke-RestMethod -Uri "http://${IP}:$Port/api/version" -TimeoutSec 5
        Write-Host ""
        Ok "mirakc が起動しました: $($v | ConvertTo-Json -Compress)"
        Write-Host ""
        Write-Host "  EPGStation などの Mirakurun の URL に次を設定してください:"
        Write-Host "      http://${IP}:$Port"
        Write-Host ""
        Write-Host "  番組表 (EPG) が揃うまでには数十分かかります。"
        Write-Host "  次回からは USB メモリを挿したまま電源を入れるだけで自動で起動します（起動後 2 分ほどかかります）。"
        exit 0
    } catch {
        Start-Sleep -Seconds 3
    }
}
Warn "まだ応答がありません。ログを確認してください:"
Warn "  `"$Adb`" -s $T shell tail -50 $Tmp/mirakc.log"
exit 1
