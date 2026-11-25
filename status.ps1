<#
.SYNOPSIS
  看一眼校园网自动认证现在是什么状态。

.DESCRIPTION
  双击 status.cmd 即可，不需要管理员权限。会显示：

    - 计划任务是否在运行
    - 当前是否在线（现场探一次，不是读缓存）
    - 认证会话开始时间、今天自动重登了几次
    - 最近 15 行日志，排错时看这里
#>

$ErrorActionPreference = 'SilentlyContinue'

$runtime  = Join-Path $env:LOCALAPPDATA 'CampusNetGuard'
$statePath = Join-Path $runtime 'state.json'
$logPath   = Join-Path $runtime 'guard.log'
$taskName  = 'CampusNetGuard'

function Get-StateValue {
    param($State, [string]$Name, $Default = '')
    if (-not $State) { return $Default }
    $prop = $State.PSObject.Properties[$Name]
    if ($prop -and $null -ne $prop.Value) { return $prop.Value }
    return $Default
}

function Format-Time {
    param([string]$Text)
    if (-not $Text) { return '—' }
    try {
        $dt = [datetime]::Parse($Text)
        return $dt.ToString('MM-dd HH:mm:ss')
    } catch {
        return '—'
    }
}

Write-Host ''
Write-Host '================ 校园网自动认证 状态 ================' -ForegroundColor Cyan

# ---- 计划任务
$taskState = '未注册'
try {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $info = $task | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
    $taskState = "$($task.State)"
    if ($info -and $info.LastRunTime) {
        $taskState += "（上次启动 " + $info.LastRunTime.ToString('MM-dd HH:mm') + "）"
    }
} catch {
    try {
        $q = schtasks /query /tn $taskName /fo LIST 2>$null | Out-String
        if ($q -match 'Ready|就绪|Running|正在运行') { $taskState = '已注册' }
    } catch { }
}
Write-Host ("计划任务：{0}" -f $taskState)

# ---- 状态文件
$state = $null
if (Test-Path -LiteralPath $statePath) {
    try { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}
$phaseNames = @{
    'online'         = '在线'
    'init'           = '刚启动'
    'waiting'        = '等待重试'
    'login-failed'   = '登录失败，重试中'
    'gave-up'        = '已停止自动重连，等待手动登录'
    'rate-limited'   = '尝试太频繁，暂停中'
    'no-gateway'     = '没有默认网关'
    'link-down'      = '链路不通'
    'http-suspect'   = '探测异常'
    'need-captcha'   = '需要验证码'
    'bad-credential' = '账号或密码被拒'
    'unsupported'    = '认证页配置不支持'
    'no-credential'  = '还没录入账号'
    'foreign-portal' = '非校园网认证页'
}

if (-not $state) {
    Write-Host '状态文件：还没有（守护进程没跑过？）' -ForegroundColor Yellow
} else {
    $phaseRaw = "$(Get-StateValue $state 'phase' '未知')"
    $phaseText = if ($phaseNames.ContainsKey($phaseRaw)) { $phaseNames[$phaseRaw] } else { $phaseRaw }
    Write-Host ("守护阶段：{0}" -f $phaseText)
    if ($phaseRaw -eq 'gave-up') {
        Write-Host '  自动重连已经停手：手动打开认证页登录一次，登上去它会接着保活。' -ForegroundColor Yellow
    }

    # 重连预算还剩多少
    $winSec = 300
    $cfgPath = Join-Path $runtime 'config.json'
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $cfgWin = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $cfgWin.reconnectWindowSec) { $winSec = [int]$cfgWin.reconnectWindowSec }
        } catch { }
    }
    $reconnectSince = Get-StateValue $state 'reconnectSince'
    if ($reconnectSince) {
        try {
            $used = [int]((Get-Date) - [datetime]::Parse($reconnectSince)).TotalSeconds
            $left = $winSec - $used
            if ($left -lt 0) { $left = 0 }
            Write-Host ("重连预算：剩 {0} 秒（共 {1} 秒）" -f $left, $winSec)
        } catch { }
    }

    Write-Host ("上次登录：{0}" -f (Format-Time (Get-StateValue $state 'lastLoginAt')))
    Write-Host ("上次心跳：{0}" -f (Format-Time (Get-StateValue $state 'lastKeepaliveAt')))
    Write-Host ("心跳间隔：{0} 分钟" -f (Get-StateValue $state 'keepaliveInterval' 0))
    Write-Host ("今日重登：{0} 次" -f (Get-StateValue $state 'todayLoginCount' 0))
    $msg = Get-StateValue $state 'lastMessage'
    if ($msg) { Write-Host ("最近说明：{0}" -f $msg) }
}

# ---- 现场探测
$configPath = Join-Path $runtime 'config.json'
$probeUrl = 'http://www.msftconnecttest.com/connecttest.txt'
if (Test-Path -LiteralPath $configPath) {
    try {
        $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.probeUrls -and @($cfg.probeUrls).Count -gt 0) { $probeUrl = @($cfg.probeUrls)[0] }
    } catch { }
}

$online = $null
$portal = ''
try {
    $req = [System.Net.HttpWebRequest]::Create($probeUrl)
    $req.Proxy = $null
    $req.AllowAutoRedirect = $false
    $req.Timeout = 5000
    $req.ReadWriteTimeout = 5000
    $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    $resp = $req.GetResponse()
    $code = [int]$resp.StatusCode
    $loc = $resp.Headers['Location']
    $resp.Close()
    if ($code -ge 300 -and $code -lt 400 -and $loc) {
        $online = $false
        $portal = $loc
    } else {
        $online = $true
    }
} catch {
    $online = $null
}

if ($online -eq $true) {
    Write-Host '当前网络：在线' -ForegroundColor Green
} elseif ($online -eq $false) {
    Write-Host '当前网络：被拦到认证页（没登录或会话掉了）' -ForegroundColor Red
    if ($portal) { Write-Host ("认证页：{0}" -f ($portal -split '\?')[0]) }
} else {
    Write-Host '当前网络：探测无响应（Wi-Fi 没连上或出口异常）' -ForegroundColor Yellow
}

# ---- 本机网络
try {
    $gw = $null
    $ip = $null
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne 'Up') { continue }
        if ($nic.NetworkInterfaceType -eq 'Loopback') { continue }
        $props = $nic.GetIPProperties()
        foreach ($a in $props.UnicastAddresses) {
            if ($a.Address.AddressFamily -eq 'InterNetwork') { $ip = $a.Address.IPAddressToString }
        }
        foreach ($g in $props.GatewayAddresses) {
            if ($g.Address -and $g.Address.AddressFamily -eq 'InterNetwork') { $gw = $g.Address.IPAddressToString }
        }
    }
    Write-Host ("本机地址：{0}   网关：{1}" -f $(if ($ip) { $ip } else { '—' }), $(if ($gw) { $gw } else { '—' }))
} catch { }

# ---- 日志尾巴
Write-Host ''
Write-Host '--- 最近日志 ---' -ForegroundColor Cyan
if (Test-Path -LiteralPath $logPath) {
    Get-Content -LiteralPath $logPath -Tail 15 -Encoding UTF8
} else {
    Write-Host '（还没有日志）'
}

Write-Host ''
Write-Host ("日志文件：{0}" -f $logPath)
Write-Host '想立刻手动跑一轮：在本目录执行 .\guard.ps1 -Once（或双击 selftest.cmd）'
