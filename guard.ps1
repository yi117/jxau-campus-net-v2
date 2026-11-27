<#
.SYNOPSIS
  校园网（JXAU / ePortal）自动认证与断线自愈守护进程。

.DESCRIPTION
  本脚本代替浏览器保持上网认证会话：

    1. 每 30 秒探测一次网络（204 探测 + 网关 ping）
    2. 掉线时自动从认证页跳转参数里取 queryString，重新登录
    3. 按认证服务器下发的间隔发送 keepalive，避免会话超时被踢
    4. 登录失败按退避重试；遇到验证码、密码错误、账号锁定立刻停下并记录

  参数：
    -Once       只跑一轮，打印结果后退出（排查用）
    -SelfTest   先注销当前会话再自动登录，验证整条链路（会短暂断网约 5 到 10 秒）
    -Quiet      不输出到控制台

  凭据保存在 %LOCALAPPDATA%\CampusNetGuard\credential.dat（DPAPI 当前用户加密）。
#>

param(
    [switch]$Once,
    [switch]$SelfTest,
    [switch]$Logout,
    [switch]$TryLogin,
    [switch]$FreshPortalUrl,
    [switch]$LoginAttempt,
    [string]$PortalUrl = '',
    [switch]$Quiet,
    [switch]$NoHide
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- 隐身

function Hide-ConsoleWindow {
    # powershell.exe -WindowStyle Hidden 对计划任务不生效，窗口会留在桌面上。
    # 进程自己拿到控制台句柄再隐藏一次，比靠启动参数可靠。
    try {
        if (-not ('CampusNet.Win32' -as [type])) {
            Add-Type -Namespace CampusNet -Name Win32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop
        }
        $handle = [CampusNet.Win32]::GetConsoleWindow()
        if ($handle -ne [System.IntPtr]::Zero) {
            [void][CampusNet.Win32]::ShowWindow($handle, 0)
        }
    } catch {
        # 隐藏失败不影响功能，最多就是桌面上多个窗口
    }
}

# ---------------------------------------------------------------- 常量与目录

$script:AppName    = 'CampusNetGuard'
$script:RuntimeDir = Join-Path $env:LOCALAPPDATA $script:AppName
$script:LogPath    = Join-Path $script:RuntimeDir 'guard.log'
$script:StatePath  = Join-Path $script:RuntimeDir 'state.json'
$script:ConfigPath = Join-Path $script:RuntimeDir 'config.json'
$script:CredPath   = Join-Path $script:RuntimeDir 'credential.dat'
$script:UserAgent  = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36'

if (-not (Test-Path -LiteralPath $script:RuntimeDir)) {
    New-Item -ItemType Directory -Force -Path $script:RuntimeDir -ErrorAction SilentlyContinue | Out-Null
}

# 没有数据目录就写不了日志和状态，也没法存凭据。
# 这时候继续跑只会变成一个看不见、什么也做不了的僵尸进程，所以直接退出。
if (-not (Test-Path -LiteralPath $script:RuntimeDir)) {
    Write-Host "无法创建数据目录：$script:RuntimeDir" -ForegroundColor Red
    Write-Host "请检查该路径的权限，或手动创建后重试。" -ForegroundColor Red
    exit 1
}

# 只有常驻模式才隐身；手动跑 -Once / -SelfTest 时要看得见输出
if (-not ($Once -or $SelfTest -or $NoHide)) {
    Hide-ConsoleWindow
}

# ---------------------------------------------------------------- 日志

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if (-not $Quiet) { Write-Host $line }
    try {
        if ((Test-Path -LiteralPath $script:LogPath) -and
            ((Get-Item -LiteralPath $script:LogPath -ErrorAction SilentlyContinue).Length -gt 2MB)) {
            Move-Item -LiteralPath $script:LogPath -Destination ($script:LogPath + '.1') -Force -ErrorAction SilentlyContinue
        }
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # 日志写不进去也不能让守护进程挂掉
    }
}

# ---------------------------------------------------------------- 配置

$script:DefaultConfig = [ordered]@{
    ssid                    = 'JXAU'
    probeUrls               = @(
        'http://www.msftconnecttest.com/connecttest.txt',
        'http://connect.rom.miui.com/generate_204'
    )
    pollIntervalSec         = 30
    httpTimeoutSec          = 8
    backoffSec              = @(0, 5, 15, 30, 60, 120)
    maxLoginPer10Min        = 6
    loginPauseSec           = 600
    wifiReconnectCooldownSec = 300
    keepaliveFallbackMin    = 5
    keepaliveSec            = 30
    reconnectWindowSec      = 300
    # 认证页要验证码时，先刷新会话再重试几次（0 = 不刷新，直接等人工）
    captchaRefreshTries     = 2
    portalHost              = '10.255.240.8'
    portalPort              = 80
}

function Load-Config {
    $cfg = $null
    if (Test-Path -LiteralPath $script:ConfigPath) {
        try {
            $cfg = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Write-Log "config.json 读不出来，改用默认配置：$($_.Exception.Message)" 'WARN'
        }
    }
    if (-not $cfg) {
        $cfg = [pscustomobject]$script:DefaultConfig
        try {
            $cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
        } catch {}
        return $cfg
    }
    # 补齐缺失项
    foreach ($key in $script:DefaultConfig.Keys) {
        if ($null -eq $cfg.PSObject.Properties[$key]) {
            $cfg | Add-Member -NotePropertyName $key -NotePropertyValue $script:DefaultConfig[$key] -Force
        }
    }
    return $cfg
}

# ---------------------------------------------------------------- 凭据

function Get-CredentialPair {
    if (-not (Test-Path -LiteralPath $script:CredPath)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $script:CredPath -Raw -ErrorAction Stop
        $sec = $raw.Trim() | ConvertTo-SecureString -ErrorAction Stop
    } catch {
        Write-Log "凭据文件解不开（可能换了 Windows 账户），请重新运行 install.cmd：$($_.Exception.Message)" 'ERROR'
        return $null
    }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    $sep = $plain.IndexOf("`n")
    if ($sep -lt 0) {
        Write-Log '凭据文件格式不对，请重新运行 install.cmd' 'ERROR'
        return $null
    }
    return [pscustomobject]@{
        User = $plain.Substring(0, $sep).Trim()
        Pass = $plain.Substring($sep + 1)
    }
}

# ---------------------------------------------------------------- 状态

$script:DefaultState = [ordered]@{
    phase               = 'init'
    pid                 = $null
    portalBase          = $null
    lastNasIp           = $null
    lastQueryString     = $null
    lastUnownedTryAt    = $null
    unownedAttempts     = 0
    reconnectSince      = $null
    onlineSince         = $null
    userIndex           = $null
    keepaliveInterval   = 0
    lastLoginAt         = $null
    lastKeepaliveAt     = $null
    lastOnlineAt        = $null
    lastWifiAttemptAt   = $null
    consecutiveFailures = 0
    keepaliveFailures   = 0
    nextAttemptAt       = $null
    loginTimes          = @()
    todayDate           = ''
    todayLoginCount     = 0
    lastMessage         = ''
    lastPhaseLogAt      = $null
    lastHeartbeatLogAt  = $null
}

function Load-State {
    $state = $null
    if (Test-Path -LiteralPath $script:StatePath) {
        try {
            $state = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch { }
    }
    if (-not $state) {
        $state = [pscustomobject]$script:DefaultState
        return $state
    }
    foreach ($key in $script:DefaultState.Keys) {
        if ($null -eq $state.PSObject.Properties[$key]) {
            $state | Add-Member -NotePropertyName $key -NotePropertyValue $script:DefaultState[$key] -Force
        }
    }
    return $state
}

function Save-State {
    param($State)
    try {
        $tmp = $script:StatePath + '.tmp'
        $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $script:StatePath -Force -ErrorAction Stop
    } catch {
        Write-Log "状态写不进去：$($_.Exception.Message)" 'WARN'
    }
}

function Add-LoginStat {
    param($State, [bool]$Success)
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ($State.todayDate -ne $today) {
        $State.todayDate = $today
        $State.todayLoginCount = 0
    }
    if ($Success) { $State.todayLoginCount = [int]$State.todayLoginCount + 1 }
    $now = Get-Date
    $kept = @()
    foreach ($t in @($State.loginTimes)) {
        try {
            if (($now - [datetime]::Parse($t)).TotalMinutes -lt 10) { $kept += $t }
        } catch { }
    }
    $kept += $now.ToString('o')
    $State.loginTimes = $kept
}

# ---------------------------------------------------------------- HTTP

function New-PortalRequest {
    param(
        [string]$Url,
        [string]$Method = 'GET',
        [string]$Body = $null,
        $Cookies = $null,
        [string]$Referer = $null
    )
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.Proxy = $null                      # 绕开系统代理（本机残留 127.0.0.1:10808 配置）
    $req.AllowAutoRedirect = $false         # 必须自己看 302 的 Location
    $req.Timeout = [int]$script:Config.httpTimeoutSec * 1000
    $req.ReadWriteTimeout = [int]$script:Config.httpTimeoutSec * 1000
    $req.UserAgent = $script:UserAgent
    $req.Accept = '*/*'
    $req.CachePolicy = [System.Net.Cache.RequestCachePolicy]::new([System.Net.Cache.RequestCacheLevel]::NoCacheNoStore)
    if ($Cookies) { $req.CookieContainer = $Cookies }
    if ($Referer) { $req.Referer = $Referer }
    if ($Body -and $Method -ne 'GET') {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentType = 'application/x-www-form-urlencoded; charset=UTF-8'
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
    }
    return $req
}

function ConvertFrom-HttpBody {
    # 认证服务器返回的中文是 GBK，而且不是每次都在头里写对 charset。
    # 先按 UTF-8 严格解码，失败再按 GBK(936) 解，避免消息变成乱码。
    param([byte[]]$Bytes, [string]$Charset)
    if (-not $Bytes -or $Bytes.Length -eq 0) { return '' }
    if ($Charset) {
        try {
            $name = $Charset.Trim().Trim('"')
            # .NET 在响应头没写 charset 时会给 ISO-8859-1，那是默认值不是真实编码
            if ($name -and $name -notmatch '^(iso-8859-1|us-ascii|ascii)$') {
                $enc = [System.Text.Encoding]::GetEncoding($name)
                if ($enc.CodePage -ne 65001) { return $enc.GetString($Bytes) }
            }
        } catch { }
    }
    $strict = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        return $strict.GetString($Bytes)
    } catch {
        return [System.Text.Encoding]::GetEncoding(936).GetString($Bytes)
    }
}

function Get-ResponseCharset {
    param($Response)
    $charset = $Response.CharacterSet
    if (-not $charset -and $Response.ContentType -match 'charset\s*=\s*([^;\s]+)') { $charset = $Matches[1] }
    return $charset
}

function Read-HttpResult {
    param($Request)
    $result = [ordered]@{
        Status   = 0
        Location = ''
        Content  = ''
        Error    = $null
    }
    try {
        $resp = $Request.GetResponse()
        $result.Status = [int]$resp.StatusCode
        $loc = $resp.Headers['Location']
        if ($loc) { $result.Location = $loc }
        $ms = New-Object System.IO.MemoryStream
        $resp.GetResponseStream().CopyTo($ms)
        $bytes = $ms.ToArray()
        $ms.Close()
        $result.Content = ConvertFrom-HttpBody -Bytes $bytes -Charset (Get-ResponseCharset -Response $resp)
        $resp.Close()
    } catch [System.Net.WebException] {
        $we = $_.Exception
        if ($we.Response) {
            $resp = $we.Response
            $result.Status = [int]$resp.StatusCode
            $loc = $resp.Headers['Location']
            if ($loc) { $result.Location = $loc }
            try {
                $ms = New-Object System.IO.MemoryStream
                $resp.GetResponseStream().CopyTo($ms)
                $bytes = $ms.ToArray()
                $ms.Close()
                $result.Content = ConvertFrom-HttpBody -Bytes $bytes -Charset (Get-ResponseCharset -Response $resp)
            } catch { }
            $resp.Close()
        } else {
            $result.Error = $we.Message
        }
    } catch {
        $result.Error = $_.Exception.Message
    }
    return [pscustomobject]$result
}

function Invoke-PortalPost {
    param(
        [string]$Base,
        [string]$Method,
        [string]$Body,
        $Cookies = $null,
        [string]$Referer = $null
    )
    $url = "$Base/eportal/InterFace.do?method=$Method"
    $req = New-PortalRequest -Url $url -Method 'POST' -Body $Body -Cookies $Cookies -Referer $Referer
    $r = Read-HttpResult $req
    $json = $null
    if ($r.Content) {
        try { $json = $r.Content | ConvertFrom-Json } catch { }
    }
    return [pscustomobject]@{
        Status = $r.Status
        Json   = $json
        Raw    = $r.Content
        Error  = $r.Error
    }
}

# ---------------------------------------------------------------- 网络探测

function Get-DefaultGateway {
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
        if ($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
        try { $props = $nic.GetIPProperties() } catch { continue }
        foreach ($gw in $props.GatewayAddresses) {
            if ($gw.Address -and $gw.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                return [pscustomobject]@{
                    Address   = $gw.Address.IPAddressToString
                    Interface = $nic.Name
                    Type      = $nic.NetworkInterfaceType
                }
            }
        }
    }
    return $null
}

function Get-LocalIPv4 {
    param([string]$InterfaceName)
    $target = $InterfaceName
    if (-not $target) {
        $gw = Get-DefaultGateway
        if ($gw) { $target = $gw.Interface }
    }
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
        if ($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
        if ($target -and $nic.Name -ne $target) { continue }
        try { $props = $nic.GetIPProperties() } catch { continue }
        foreach ($a in $props.UnicastAddresses) {
            if ($a.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                return $a.Address.IPAddressToString
            }
        }
    }
    return $null
}

function New-UserIndex {
    # ePortal 的 userIndex 是 <nasip>_<客户端IP>_<账号> 的十六进制
    # 登录响应超时拿不到它时，可以按这个规则自己拼出来
    param([string]$NasIp, [string]$ClientIp, [string]$Account)
    if (-not $NasIp -or -not $ClientIp -or -not $Account) { return $null }
    $plain = '{0}_{1}_{2}' -f $NasIp, $ClientIp, $Account
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($plain)
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Test-TcpPort {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 1500)
    if (-not $HostName) { return $false }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch { }
    }
}

function Get-NetworkState {
    foreach ($u in @($script:Config.probeUrls)) {
        $req = New-PortalRequest -Url $u
        $r = Read-HttpResult $req
        if ($r.Error) { continue }
        if ($r.Status -eq 204) {
            return [pscustomobject]@{ State = 'Online'; Url = $null; Detail = $u }
        }
        if ($r.Location -and $r.Location -match '^https?://') {
            return [pscustomobject]@{ State = 'Portal'; Url = $r.Location; Detail = $u }
        }
        if ($r.Status -eq 200) {
            if ($r.Content -and $r.Content -match '(https?://[^"''<> ]+/eportal/index\.jsp\?[^"''<> ]+)') {
                return [pscustomobject]@{ State = 'Portal'; Url = $Matches[1]; Detail = $u }
            }
            if ($u -match 'connecttest' -and $r.Content -match 'Microsoft Connect Test') {
                return [pscustomobject]@{ State = 'Online'; Url = $null; Detail = $u }
            }
            # 能拿到 200 就当通，避免误判后反复登录
            return [pscustomobject]@{ State = 'Online'; Url = $null; Detail = $u }
        }
    }
    return [pscustomobject]@{ State = 'Broken'; Url = $null; Detail = '探测无响应' }
}

function Test-CampusPortalUrl {
    param([string]$Url)
    try {
        $hostName = ([uri]$Url).Host
    } catch {
        return $false
    }
    return ($hostName -match '^10\.' -or
            $hostName -match '^192\.168\.' -or
            $hostName -match '^172\.(1[6-9]|2[0-9]|3[01])\.')
}

function Get-PortalContext {
    param([string]$PortalUrl)
    $uri = [uri]$PortalUrl
    $qs = ''
    if ($uri.Query) { $qs = $uri.Query.TrimStart('?') }
    return [pscustomobject]@{
        Base        = ('{0}://{1}' -f $uri.Scheme, $uri.Authority)
        QueryString = $qs
        Url         = $PortalUrl
    }
}

# ---------------------------------------------------------------- 认证动作

function Get-FreshPortalUrl {
    <#
        重新打开认证入口，换一个"新会话"的地址——等价于在浏览器里按一下 F5。

        背景：ePortal 连续失败多次后，会把验证码绑在当前这个认证会话上；
        重新打开认证页会拿到新的 queryString / JSESSIONID，验证码要求往往就消失了。
        这里不识别、也不绕过验证码，只是重新走一遍"打开认证页"这个正常动作。
    #>
    $hostName = [string]$script:Config.portalHost
    $port = [int]$script:Config.portalPort
    if (-not $hostName) { return $null }

    $candidates = @(
        ('http://{0}:{1}/eportal/index.jsp' -f $hostName, $port),
        ('http://{0}/eportal/index.jsp' -f $hostName)
    ) | Select-Object -Unique

    foreach ($u in $candidates) {
        try {
            $req = New-PortalRequest -Url $u -Method 'GET'
            $res = Read-HttpResult $req
            if ($res.Error) { continue }

            if ($res.Location) {
                $loc = [string]$res.Location
                if ($loc -match '^(?i)http') { return $loc }
                if ($loc.StartsWith('/')) { return ('http://{0}{1}' -f $hostName, $loc) }
            }

            # 有的入口是 JS 跳转，从返回的 HTML 里再找一次
            if ($res.Content) {
                $m = [regex]::Match($res.Content, '(?i)(?:location\.(?:href|replace)\s*[=(]\s*|window\.open\s*\(\s*)["'']([^"'']*eportal[^"'']*)["'']')
                if ($m.Success) {
                    $val = $m.Groups[1].Value
                    if ($val -match '^(?i)http') { return $val }
                }
            }
        } catch { }
    }
    return $null
}

function Invoke-PortalLogin {
    param(
        [string]$PortalUrl,
        [string]$User,
        [string]$Pass
    )
    $ctx = Get-PortalContext -PortalUrl $PortalUrl
    $cookies = New-Object System.Net.CookieContainer

    # 先按浏览器的方式打开认证页，拿 JSESSIONID
    $warm = New-PortalRequest -Url $PortalUrl -Cookies $cookies
    $warmResult = Read-HttpResult $warm
    if ($warmResult.Status -eq 0) {
        return [pscustomobject]@{ Result = 'Transport'; Message = "认证页打不开：$($warmResult.Error)"; Json = $null }
    }

    $encQS = [uri]::EscapeDataString([uri]::EscapeDataString($ctx.QueryString))

    # pageInfo 用来确认认证页有没有改成密码加密 / 需要前缀
    $info = Invoke-PortalPost -Base $ctx.Base -Method 'pageInfo' -Body "queryString=$encQS" -Cookies $cookies -Referer $PortalUrl
    if ($info.Json) {
        if ("$($info.Json.passwordEncrypt)" -eq 'true') {
            return [pscustomobject]@{ Result = 'NeedRsa'; Message = '认证页启用了密码加密，当前版本不处理'; Json = $info.Json }
        }
    }

    $encUser = [uri]::EscapeDataString([uri]::EscapeDataString($User))
    $encPass = [uri]::EscapeDataString([uri]::EscapeDataString($Pass))
    $body = "userId=$encUser&password=$encPass&service=&queryString=$encQS&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false"

    $lr = Invoke-PortalPost -Base $ctx.Base -Method 'login' -Body $body -Cookies $cookies -Referer $PortalUrl
    if ($lr.Error) {
        return [pscustomobject]@{ Result = 'Transport'; Message = "登录请求失败：$($lr.Error)"; Json = $null }
    }

    $json = $lr.Json
    if ($json -and "$($json.result)" -eq 'success') {
        $interval = 0
        try { $interval = [double]("$($json.keepaliveInterval)") } catch { $interval = 0 }
        if ($interval -le 0) { $interval = [double]$script:Config.keepaliveFallbackMin }
        return [pscustomobject]@{
            Result          = 'Success'
            Message         = "$($json.message)"
            UserIndex       = "$($json.userIndex)"
            KeepaliveMin    = $interval
            Base            = $ctx.Base
            Json            = $json
        }
    }

    $message = ''
    if ($json) { $message = "$($json.message)" }
    if (-not $message) { $message = ($lr.Raw -replace '\s+', ' ') }
    if ($message.Length -gt 200) { $message = $message.Substring(0, 200) }

    if ($json -and "$($json.validCodeUrl)" -ne '') {
        return [pscustomobject]@{ Result = 'NeedCaptcha'; Message = $message; Json = $json }
    }
    if ($message -match '验证码') {
        return [pscustomobject]@{ Result = 'NeedCaptcha'; Message = $message; Json = $json }
    }
    if ($message -match '已在线|已经在线|在线用户|已登录|绑定|冲突|占用|Too many access') {
        return [pscustomobject]@{ Result = 'Conflict'; Message = $message; Json = $json }
    }
    if ($message -match '(密码|口令|账号|帐户).*(错|不正确|不匹配|不存在|锁定|冻结|欠费)|(错|不正确).*(密码|口令)') {
        return [pscustomobject]@{ Result = 'BadCredential'; Message = $message; Json = $json }
    }
    return [pscustomobject]@{ Result = 'Unknown'; Message = $message; Json = $json }
}

function Clear-PortalSession {
    param(
        [string]$PortalUrl,
        [string]$User,
        [string]$Pass,
        [string]$UserIndex
    )
    $ctx = Get-PortalContext -PortalUrl $PortalUrl
    if ($UserIndex) {
        $r = Invoke-PortalPost -Base $ctx.Base -Method 'logout' -Body "userIndex=$UserIndex"
        if ($r.Json -and "$($r.Json.result)" -eq 'success') {
            Write-Log '已注销旧会话（按 userIndex）' 'INFO'
            return $true
        }
    }
    # 注意：login 接口的参数按页面 JS 是双重编码，这个注销接口是单重编码
    $encUser = [uri]::EscapeDataString($User)
    $encPass = [uri]::EscapeDataString($Pass)
    $r2 = Invoke-PortalPost -Base $ctx.Base -Method 'logoutByUserIdAndPass' -Body "userId=$encUser&pass=$encPass"
    if ($r2.Json -and "$($r2.Json.result)" -eq 'success') {
        Write-Log '已注销旧会话（按账号密码）' 'INFO'
        return $true
    }
    Write-Log "注销旧会话没成功：$(($r2.Raw -replace '\s+',' '))" 'WARN'
    return $false
}

function Send-Keepalive {
    param($State)
    if (-not $State.userIndex -or -not $State.portalBase) { return $false }
    $r = Invoke-PortalPost -Base $State.portalBase -Method 'keepalive' -Body "userIndex=$($State.userIndex)"
    if ($r.Json -and "$($r.Json.result)" -eq 'success') {
        return $true
    }
    if ($r.Error) {
        Write-Log "心跳请求失败：$($r.Error)" 'WARN'
        return $false
    }
    Write-Log "心跳返回异常：$(($r.Raw -replace '\s+',' '))" 'WARN'
    return $false
}

# ---------------------------------------------------------------- Wi-Fi 重连

function Invoke-NativeText {
    <#
        捕获原生命令输出并正确解码。

        踩过的坑：netsh 在中文 Windows 上**固定输出 UTF-8**，跟控制台代码页无关
        （chcp 936 / chcp 65001 都一样）。而 PowerShell 5.1 用 `& netsh 2>&1` 捕获时
        是按 [Console]::OutputEncoding（通常是 936）解码，于是日志里就出现
        「宸叉壋鍒╂岃緋」这种乱码。

        这里把输出重定向到临时文件，拿到**原始字节**，先按 UTF-8 严格解码；
        失败的机器（netsh 真发 GBK 的那种）再退回 OEM 代码页。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$Arguments = ''
    )

    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()

    try {
        Start-Process -FilePath $FilePath -ArgumentList $Arguments `
            -WindowStyle Hidden -PassThru -Wait `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile | Out-Null

        $bytes = @()
        $bytes += [System.IO.File]::ReadAllBytes($outFile)
        $bytes += [System.IO.File]::ReadAllBytes($errFile)

        if ($bytes.Length -eq 0) { return '' }

        $text = $null

        # 1) 严格 UTF-8（非法字节会抛异常）
        try {
            $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
            $text = $strictUtf8.GetString($bytes)
        } catch {
            $text = $null
        }

        # 2) 回退到系统 OEM 代码页
        if ($null -eq $text) {
            $oem = [System.Text.Encoding]::GetEncoding(
                [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
            $text = $oem.GetString($bytes)
        }

        $text = $text -replace [string][char]0xFEFF, ''
        return (($text -replace '\s+', ' ').Trim())
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-WifiInterface {
    $up = $null
    $physical = $null
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.NetworkInterfaceType -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Wireless80211) { continue }
        if ($nic.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up) {
            if (-not $up) { $up = $nic }
        }
        # 虚拟/重复实例的描述里带 "#2" "#4" 这种后缀，优先选没有后缀的物理网卡
        if (-not $physical -and $nic.Description -notmatch '#\d+') { $physical = $nic }
    }
    if ($up) { return $up }
    return $physical
}

function Try-WifiReconnect {
    param($State)
    $wifi = Get-WifiInterface
    if (-not $wifi) { return $false }
    if ($wifi.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up) { return $false }

    $cooldown = [int]$script:Config.wifiReconnectCooldownSec
    if ($State.lastWifiAttemptAt) {
        try {
            if (((Get-Date) - [datetime]::Parse($State.lastWifiAttemptAt)).TotalSeconds -lt $cooldown) {
                return $false
            }
        } catch { }
    }
    $State.lastWifiAttemptAt = (Get-Date).ToString('o')

    $ssid = [string]$script:Config.ssid
    Write-Log "Wi-Fi 不在线，尝试重新连接 $ssid" 'WARN'
    try {
        $text = Invoke-NativeText -FilePath 'netsh.exe' -Arguments ('wlan connect name="' + $ssid + '"')
        if ($text.Length -gt 160) { $text = $text.Substring(0, 160) }
        Write-Log "netsh wlan connect：$text" 'INFO'
    } catch {
        Write-Log "重连 Wi-Fi 出错：$($_.Exception.Message)" 'ERROR'
    }
    return $true
}

# ---------------------------------------------------------------- 主流程

function Write-PhaseLog {
    # 同一个故障状态别每 30 秒刷一条日志：阶段变了，或者距上次记录超过 5 分钟，才写
    param($State, [string]$Phase, [string]$Message, [string]$Level = 'WARN')
    $now = Get-Date
    $changed = ("$($State.phase)" -ne $Phase)
    $due = $true
    if ($State.lastPhaseLogAt) {
        try {
            $due = (($now - [datetime]::Parse($State.lastPhaseLogAt)).TotalMinutes -ge 5)
        } catch { }
    }
    if ($changed -or $due) {
        Write-Log $Message $Level
        $State.lastPhaseLogAt = $now.ToString('o')
    }
    $State.phase = $Phase
}

function Get-NextBackoff {
    param($State)
    $arr = @($script:Config.backoffSec)
    $i = [int]$State.consecutiveFailures
    if ($i -ge $arr.Count) { $i = $arr.Count - 1 }
    if ($i -lt 0) { $i = 0 }
    return [double]$arr[$i]
}

function Invoke-LoginOnce {
    param($State, $Cred, [string]$PortalUrl)

    $v = Invoke-PortalLogin -PortalUrl $PortalUrl -User $Cred.User -Pass $Cred.Pass
    if ($v.Result -eq 'Conflict') {
        Write-Log "认证服务器说会话冲突：$($v.Message)，先清旧会话再试一次" 'WARN'
        $conflictIndex = $State.userIndex
        if (-not $conflictIndex -and $State.lastNasIp) {
            # 没有 userIndex 也能按规则拼一个，专门用来注销掉上次残留的会话
            $conflictIndex = New-UserIndex -NasIp $State.lastNasIp -ClientIp (Get-LocalIPv4) -Account $Cred.User
        }
        Clear-PortalSession -PortalUrl $PortalUrl -User $Cred.User -Pass $Cred.Pass -UserIndex $conflictIndex | Out-Null
        Start-Sleep -Seconds 2
        $v = Invoke-PortalLogin -PortalUrl $PortalUrl -User $Cred.User -Pass $Cred.Pass
    }
    return $v
}

function Invoke-LoginAttempt {
    param($State, $Cred, [string]$PortalUrl)

    $url = $PortalUrl
    $verdict = Invoke-LoginOnce -State $State -Cred $Cred -PortalUrl $url

    # 认证页要验证码时，先按"刷新页面"的办法换一个干净会话再试。
    # 实测：连续失败几次后出现的验证码，重新打开认证页往往就不再要求了。
    $tries = 0
    $maxTries = 2
    try { $maxTries = [int]$script:Config.captchaRefreshTries } catch { }
    if ($maxTries -lt 0) { $maxTries = 0 }

    while ($verdict.Result -eq 'NeedCaptcha' -and $tries -lt $maxTries) {
        $tries++
        Write-Log ("认证页要求验证码，刷新认证页换新会话再试（第 {0}/{1} 次）" -f $tries, $maxTries) 'WARN'

        $fresh = Get-FreshPortalUrl
        if (-not $fresh) {
            Write-Log '刷新认证页没拿到新地址，放弃这次自动重试' 'WARN'
            break
        }

        $freshCtx = Get-PortalContext -PortalUrl $fresh
        if ($freshCtx.QueryString) { $State.lastQueryString = $freshCtx.QueryString }
        if ($freshCtx.QueryString -match '(?:^|&)nasip=([^&]+)') { $State.lastNasIp = $Matches[1] }
        $State.portalBase = $freshCtx.Base
        $url = $fresh

        Start-Sleep -Seconds 2
        Add-LoginStat -State $State -Success $false   # 这也是真实的一次登录请求，要进频率限制
        $verdict = Invoke-LoginOnce -State $State -Cred $Cred -PortalUrl $url
    }

    if ($verdict.Result -eq 'Success') {
        $State.userIndex = $verdict.UserIndex
        $State.keepaliveInterval = $verdict.KeepaliveMin
        $State.portalBase = $verdict.Base
        $State.lastLoginAt = (Get-Date).ToString('o')
        $State.lastKeepaliveAt = (Get-Date).ToString('o')
        $State.lastOnlineAt = (Get-Date).ToString('o')
        $State.consecutiveFailures = 0
        $State.keepaliveFailures = 0
        $State.nextAttemptAt = $null
        $State.phase = 'online'
        $State.lastMessage = '登录成功'
        Add-LoginStat -State $State -Success $true
        Write-Log ("登录成功，心跳间隔 {0} 分钟，userIndex={1}" -f $verdict.KeepaliveMin, $verdict.UserIndex) 'OK'
        return $true
    }

    $State.consecutiveFailures = [int]$State.consecutiveFailures + 1
    $State.lastMessage = $verdict.Message
    Add-LoginStat -State $State -Success $false

    switch ($verdict.Result) {
        'NeedCaptcha' {
            $State.phase = 'need-captcha'
            $State.nextAttemptAt = (Get-Date).AddSeconds([int]$script:Config.loginPauseSec).ToString('o')
            $extra = if ($tries -gt 0) { "（已刷新会话 $tries 次仍然要验证码）" } else { "" }
            Write-Log "认证页要求验证码$extra，自动登录暂停。请手动打开认证页登录一次。原文：$($verdict.Message)" 'ERROR'
        }
        'BadCredential' {
            $State.phase = 'bad-credential'
            $State.nextAttemptAt = (Get-Date).AddSeconds([int]$script:Config.loginPauseSec).ToString('o')
            Write-Log "账号或密码被拒，请重新运行 install.cmd 录入。原文：$($verdict.Message)" 'ERROR'
        }
        'NeedRsa' {
            $State.phase = 'unsupported'
            $State.nextAttemptAt = (Get-Date).AddSeconds([int]$script:Config.loginPauseSec).ToString('o')
            Write-Log "认证页启用了密码加密，本脚本暂不支持：$($verdict.Message)" 'ERROR'
        }
        default {
            $delay = Get-NextBackoff -State $State
            $State.phase = 'login-failed'
            $State.nextAttemptAt = (Get-Date).AddSeconds($delay).ToString('o')
            Write-Log ("登录失败（第 {0} 次），{1} 秒后重试。原文：{2}" -f $State.consecutiveFailures, $delay, $verdict.Message) 'WARN'
        }
    }
    return $false
}

function Invoke-Cycle {
    param($Cred)

    $state = Load-State
    $script:Config = Load-Config

    # 界面暂停：只放一个标志文件，不动计划任务，也不需要管理员权限
    if (Test-Path -LiteralPath (Join-Path $script:RuntimeDir 'paused.flag')) {
        if ("$($state.phase)" -ne 'paused') { Write-Log '被界面暂停，从现在起不登录、不保活' 'INFO' }
        $state.phase = 'paused'
        $state.lastMessage = '已暂停（界面控制）'
        Save-State -State $state
        return 'paused'
    }

    # 自动重连的总时间预算：从第一次发现认证页开始算，用完就停手等人工
    # reconnectWindowSec 单位是秒；0 = 不限制（一直重试，直到连上或手动暂停）
    $winSec = 300
    try { $winSec = [int]$script:Config.reconnectWindowSec } catch { }
    if ($winSec -lt 0) { $winSec = 0 }

    $gw = Get-DefaultGateway
    if (-not $gw) {
        $state.lastMessage = '没有默认网关'
        Write-PhaseLog -State $state -Phase 'no-gateway' -Message '没有默认网关（Wi-Fi 没连上？）'
        Try-WifiReconnect -State $state | Out-Null
        Save-State -State $state
        return 'no-gateway'
    }

    # 注：校园网和很多环境会过滤 ICMP，这里不用 ping 判断链路，
    # 网关是否存在 + 门户端口能不能连上，比 ping 可靠。
    $net = Get-NetworkState
    switch ($net.State) {
        'Online' {
            $prevPhase = "$($state.phase)"
            if ($prevPhase -eq 'init' -or $prevPhase -eq '') {
                Write-Log '启动检查：当前在线，不需要登录' 'INFO'
            } elseif ($prevPhase -ne 'online') {
                Write-Log '网络已恢复到在线' 'OK'
            }
            $state.phase = 'online'
            $state.lastOnlineAt = (Get-Date).ToString('o')
            $state.consecutiveFailures = 0
            $state.nextAttemptAt = $null
            $state.lastMessage = '在线'

            # 连续在线满一个预算周期，才认为真的稳定了，把重连预算清零
            $nowStable = Get-Date
            if (-not $state.onlineSince) { $state.onlineSince = $nowStable.ToString('o') }
            $stableSec = 0
            try { $stableSec = ($nowStable - [datetime]::Parse($state.onlineSince)).TotalSeconds } catch { }
            $gaveUp = $false
            if ($state.reconnectSince) {
                $reElapsedOnline = 0
                try { $reElapsedOnline = ($nowStable - [datetime]::Parse($state.reconnectSince)).TotalSeconds } catch { }
                $gaveUp = ($reElapsedOnline -ge $winSec)
                if ($stableSec -ge $winSec) {
                    $state.reconnectSince = $null
                    if ($gaveUp) { Write-Log '连续稳定在线，恢复自动重连能力' 'OK' }
                }
            }

            $intervalMin = [double]$state.keepaliveInterval
            if ($intervalMin -le 0) { $intervalMin = [double]$script:Config.keepaliveFallbackMin }

            # 在线但没有 userIndex：说明这次认证没拿到真正的成功响应。
            # 这种"半截会话"通常活不过两分钟，所以先补登，再退而求其次认领会话。
            if (-not $state.userIndex -and $Cred -and $state.portalBase) {
                $nowOwn = Get-Date
                $unowned = [int]$state.unownedAttempts
                $canRetryLogin = $false
                if (-not $gaveUp -and $state.lastQueryString -and $unowned -lt 6) {
                    $lastTry = $null
                    if ($state.lastUnownedTryAt) {
                        try { $lastTry = [datetime]::Parse($state.lastUnownedTryAt) } catch { }
                    }
                    if (-not $lastTry -or ($nowOwn - $lastTry).TotalSeconds -ge 45) { $canRetryLogin = $true }
                }
                if ($canRetryLogin) {
                    $state.lastUnownedTryAt = $nowOwn.ToString('o')
                    $state.unownedAttempts = $unowned + 1
                    $retryUrl = '{0}/eportal/index.jsp?{1}' -f $state.portalBase, $state.lastQueryString
                    Write-Log '在线但会话没拿到 userIndex，用缓存参数补登一次' 'INFO'
                    $retryVerdict = Invoke-PortalLogin -PortalUrl $retryUrl -User $Cred.User -Pass $Cred.Pass
                    if ($retryVerdict.Result -eq 'Success') {
                        $state.userIndex = $retryVerdict.UserIndex
                        $state.portalBase = $retryVerdict.Base
                        $state.keepaliveInterval = $retryVerdict.KeepaliveMin
                        $state.lastLoginAt = $nowOwn.ToString('o')
                        $state.lastKeepaliveAt = $nowOwn.ToString('o')
                        $state.unownedAttempts = 0
                        Add-LoginStat -State $state -Success $true
                        Write-Log '补登成功，会话归守护进程管了' 'OK'
                    } else {
                        Write-Log ("补登没成功：{0}" -f $retryVerdict.Message) 'WARN'
                    }
                }

                # 补登也不行，就按规则拼一个 userIndex，用保活试探这个会话能不能用
                if (-not $state.userIndex -and $state.lastNasIp) {
                    $adoptIp = Get-LocalIPv4
                    $candidate = New-UserIndex -NasIp $state.lastNasIp -ClientIp $adoptIp -Account $Cred.User
                    if ($candidate) {
                        $state.userIndex = $candidate
                        if (Send-Keepalive -State $state) {
                            $state.lastKeepaliveAt = (Get-Date).ToString('o')
                            $state.keepaliveFailures = 0
                            $state.lastMessage = '已接管在线会话'
                            Write-Log '接管在线会话成功（userIndex 是按规则拼的，保活可用）' 'OK'
                        } else {
                            $state.userIndex = $null
                            $state.lastMessage = '在线但会话不可用'
                            Write-Log '这个在线会话不认这个账号，先放着' 'INFO'
                        }
                    }
                }
            }

            # 心跳节奏：默认 30 秒；认证设备空闲 2 分钟就踢，30 秒留足余量
            $kaSec = 30
            try { $kaSec = [int]$script:Config.keepaliveSec } catch { }
            if ($kaSec -lt 20) { $kaSec = 20 }
            if ($intervalMin -gt 0) {
                $halfSec = [int]($intervalMin * 30)
                if ($halfSec -ge 20 -and $halfSec -lt $kaSec) { $kaSec = $halfSec }
            }

            $needKeepalive = $false
            if ($state.userIndex) {
                if (-not $state.lastKeepaliveAt) {
                    $needKeepalive = $true
                } else {
                    try {
                        if (((Get-Date) - [datetime]::Parse($state.lastKeepaliveAt)).TotalSeconds -ge $kaSec) {
                            $needKeepalive = $true
                        }
                    } catch { $needKeepalive = $true }
                }
            }
            if ($needKeepalive) {
                if (Send-Keepalive -State $state) {
                    $state.lastKeepaliveAt = (Get-Date).ToString('o')
                    $state.keepaliveFailures = 0
                } else {
                    $state.keepaliveFailures = [int]$state.keepaliveFailures + 1
                    if ($state.keepaliveFailures -ge 2) {
                        Write-Log '心跳连续两次没被认可，丢掉会话信息，等下一次重新登录' 'WARN'
                        $state.userIndex = $null
                        $state.keepaliveFailures = 0
                    } else {
                        Write-Log '心跳没被认可，再试一次' 'WARN'
                    }
                }
            }

            # 每 30 分钟留一条"我还活着"的记录，便于事后判断守护进程有没有被意外结束
            $hbDue = $true
            if ($state.lastHeartbeatLogAt) {
                try { $hbDue = ((Get-Date) - [datetime]::Parse($state.lastHeartbeatLogAt)).TotalMinutes -ge 30 } catch { $hbDue = $true }
            }
            if ($hbDue) {
                Write-Log ("在线巡检正常（今天自动登录 {0} 次）" -f [int]$state.todayLoginCount) 'INFO'
                $state.lastHeartbeatLogAt = (Get-Date).ToString('o')
            }
            Save-State -State $state
            return 'online'
        }

        'Portal' {
            if (-not (Test-CampusPortalUrl -Url $net.Url)) {
                $state.phase = 'foreign-portal'
                $state.lastMessage = "跳到了非校园网认证页：$($net.Url)"
                Save-State -State $state
                Write-Log "跳转目标不是校园网，跳过：$($net.Url)" 'WARN'
                return 'foreign-portal'
            }
            if (-not $Cred) {
                $state.phase = 'no-credential'
                $state.lastMessage = '还没录入账号'
                Save-State -State $state
                Write-Log '还没录入账号密码，请运行 install.cmd' 'ERROR'
                return 'no-credential'
            }

            # 记下这次跳转里的 nasip 和认证服务器地址：登录响应有可能超时，
            # 但有了 nasip + 本机 IP + 账号，照样能拼出 userIndex 去接管会话。
            $ctx = Get-PortalContext -PortalUrl $net.Url
            $state.portalBase = $ctx.Base
            if ($ctx.QueryString) { $state.lastQueryString = $ctx.QueryString }
            if ($ctx.QueryString -match '(?:^|&)nasip=([^&]+)') { $state.lastNasIp = $Matches[1] }
            $state.unownedAttempts = 0
            if ($state.userIndex) {
                Write-Log '会话已经掉了，清掉旧的 userIndex 重新来' 'INFO'
                $state.userIndex = $null
                $state.keepaliveFailures = 0
            }

            # 重连预算：从这一轮第一次发现认证页开始计时，超过 reconnectWindowSec 就停手
            $nowWin = Get-Date
            if (-not $state.reconnectSince) {
                $state.reconnectSince = $nowWin.ToString('o')
                if ($winSec -gt 0) {
                    Write-Log ("开始自动重连，预算 {0:N0} 秒" -f $winSec) 'INFO'
                } else {
                    Write-Log '开始自动重连，预算不限制（会一直尝试）' 'INFO'
                }
            }
            $state.onlineSince = $null
            $reElapsed = 0
            try { $reElapsed = ($nowWin - [datetime]::Parse($state.reconnectSince)).TotalSeconds } catch { }
            if ($winSec -gt 0 -and $reElapsed -ge $winSec) {
                $state.lastMessage = '自动重连已停止，请手动登录一次'
                Write-PhaseLog -State $state -Phase 'gave-up' -Level 'ERROR' -Message (
                    '已经试了 {0:N0} 秒还没连上，按规则停止自动重连。请手动打开认证页登录一次，登上去之后我会接着保活。' -f $winSec)
                Save-State -State $state
                return 'gave-up'
            }

            # 退避与频率限制
            if ($state.nextAttemptAt) {
                try {
                    if ((Get-Date) -lt [datetime]::Parse($state.nextAttemptAt)) {
                        Save-State -State $state
                        return 'waiting'
                    }
                } catch { }
            }
            $recent = 0
            $now = Get-Date
            foreach ($t in @($state.loginTimes)) {
                try { if (($now - [datetime]::Parse($t)).TotalMinutes -lt 10) { $recent++ } } catch { }
            }
            if ($recent -ge [int]$script:Config.maxLoginPer10Min) {
                $state.phase = 'rate-limited'
                $state.nextAttemptAt = $now.AddSeconds([int]$script:Config.loginPauseSec).ToString('o')
                Save-State -State $state
                Write-Log "10 分钟内已尝试 $recent 次，暂停 $($script:Config.loginPauseSec) 秒，防止账号被风控" 'ERROR'
                return 'rate-limited'
            }

            Write-Log "检测到认证页，开始登录（账号 $($Cred.User)）" 'INFO'
            $ok = Invoke-LoginAttempt -State $state -Cred $Cred -PortalUrl $net.Url
            Save-State -State $state
            if ($ok) { return 'online' }
            return 'login-failed'
        }

        default {
            # HTTP 探测没响应：分清是链路断了还是认证层的问题
            $reachable = Test-TcpPort -HostName $script:Config.portalHost -Port ([int]$script:Config.portalPort) -TimeoutMs 2000
            if (-not $reachable) {
                $state.lastMessage = "探测无响应，门户 $($script:Config.portalHost) 也连不上"
                Write-PhaseLog -State $state -Phase 'link-down' -Message 'HTTP 探测无响应，门户端口也连不上（链路问题）'
                Try-WifiReconnect -State $state | Out-Null
                Save-State -State $state
                return 'link-down'
            }
            $state.lastMessage = '门户可达但探测无响应'
            Write-PhaseLog -State $state -Phase 'http-suspect' -Message '门户端口能连上，但 204 探测无响应（出口/DNS 抖动），下轮再试'
            Save-State -State $state
            return 'http-suspect'
        }
    }
}

# ---------------------------------------------------------------- 单实例

$mutex = $null
if (-not ($Once -or $Logout -or $TryLogin -or $FreshPortalUrl -or $LoginAttempt -or $SelfTest)) {
    $mutex = New-Object System.Threading.Mutex($false, 'CampusNetGuard-Instance')
    if (-not $mutex.WaitOne(0)) {
        Write-Log '已经有一个守护进程在跑，本次退出' 'WARN'
        return
    }
}

try {
    $script:Config = Load-Config
    $cred = Get-CredentialPair

    # 守护进程重启时：上一次的重连预算如果还没过期就接着算，避免靠重启绕过限制
    if (-not ($Once -or $SelfTest -or $TryLogin -or $Logout -or $FreshPortalUrl -or $LoginAttempt)) {
        try {
            $bootState = Load-State
            if ($bootState.reconnectSince) {
                $bootAge = ((Get-Date) - [datetime]::Parse($bootState.reconnectSince)).TotalSeconds
                $bootWin = 0
                try { $bootWin = [int]$script:Config.reconnectWindowSec } catch { }
                if ($bootWin -gt 0 -and $bootAge -ge $bootWin) {
                    $bootState.reconnectSince = $null
                    $bootState.onlineSince = $null
                    Save-State -State $bootState
                }
            }
        } catch { }
    }

    if (-not $cred) {
        Write-Log '没找到可用凭据，只做探测不登录。请运行 install.cmd 录入账号。' 'ERROR'
        if ($Once) {
            $gw = Get-DefaultGateway
            $net = Get-NetworkState
            Write-Host ''
            Write-Host ("网关：{0}" -f $(if ($gw) { $gw.Address } else { '无' }))
            Write-Host ("网络状态：{0} {1}" -f $net.State, $net.Detail)
            return
        }
    }

    if ($FreshPortalUrl) {
        # 排查用：看看"刷新认证页"能拿到什么样的新地址（不发登录请求）
        $fresh = Get-FreshPortalUrl
        if ($fresh) {
            Write-Host '刷新后的认证页地址：'
            Write-Host ("  {0}" -f ($fresh -split '\?')[0])
            $ctx = Get-PortalContext -PortalUrl $fresh
            Write-Host ("  queryString 长度：{0}" -f ($ctx.QueryString.Length))
            if ($ctx.QueryString -match '(?:^|&)nasip=([^&]+)') { Write-Host ("  nasip：{0}" -f $Matches[1]) }
        } else {
            Write-Host '没拿到新地址（可能已经在线，或认证入口不通）。'
        }
        return
    }

    if ($LoginAttempt) {
        # 排查用：完整跑一遍"登录 + 验证码刷新会话"的流程（会真的发登录请求）
        if (-not $cred) {
            Write-Host '还没有可用凭据，先运行 install.cmd。'
            return
        }
        if (-not $PortalUrl) {
            Write-Host '用法：guard.ps1 -LoginAttempt -PortalUrl "http://10.255.240.8/eportal/index.jsp?..."'
            return
        }
        $st = Load-State
        Write-Host ("认证页：{0}" -f ($PortalUrl -split '\?')[0])
        Write-Host ("账号：{0}" -f $cred.User)
        $ok = Invoke-LoginAttempt -State $st -Cred $cred -PortalUrl $PortalUrl
        Write-Host ("结果：{0}" -f $(if ($ok) { '成功' } else { '失败' }))
        Write-Host ("阶段：{0}" -f $st.phase)
        Write-Host ("消息：{0}" -f $st.lastMessage)
        if ($st.userIndex) { Write-Host ("userIndex：{0}" -f $st.userIndex) }
        return
    }

    if ($TryLogin) {
        # 排查用：拿指定的认证页地址，跑一遍真实登录，再试一次心跳
        if (-not $cred) {
            Write-Host '还没有可用凭据，先运行 install.cmd。'
            return
        }
        if (-not $PortalUrl) {
            Write-Host '用法：guard.ps1 -TryLogin -PortalUrl "http://10.255.240.8/eportal/index.jsp?..."'
            return
        }
        Write-Host ("认证页：{0}" -f ($PortalUrl -split '\?')[0])
        Write-Host ("账号：{0}" -f $cred.User)
        $verdict = Invoke-PortalLogin -PortalUrl $PortalUrl -User $cred.User -Pass $cred.Pass
        Write-Host ("登录结果：{0}" -f $verdict.Result)
        Write-Host ("服务器消息：{0}" -f $verdict.Message)
        if ($verdict.Result -eq 'Success') {
            Write-Host ("userIndex：{0}" -f $verdict.UserIndex)
            Write-Host ("心跳间隔：{0} 分钟" -f $verdict.KeepaliveMin)
            $ka = Invoke-PortalPost -Base $verdict.Base -Method 'keepalive' -Body "userIndex=$($verdict.UserIndex)"
            Write-Host ("心跳测试：{0}" -f $ka.Raw)
        }
        return
    }

    if ($Logout) {
        # 排查用：直接调注销接口，把服务器原文打出来
        if (-not $cred) {
            Write-Host '还没有可用凭据，先运行 install.cmd。'
            return
        }
        $logoutState = Load-State
        $logoutBase = if ($logoutState.portalBase) { $logoutState.portalBase } else { 'http://10.255.240.8' }
        $logoutUrl = "$logoutBase/eportal/index.jsp"
        $logoutCtx = Get-PortalContext -PortalUrl $logoutUrl
        Write-Host ("认证服务器：{0}" -f $logoutCtx.Base)
        Write-Host ("账号：{0}" -f $cred.User)
        $encUserLogout = [uri]::EscapeDataString($cred.User)
        $encPassLogout = [uri]::EscapeDataString($cred.Pass)
        $logoutResult = Invoke-PortalPost -Base $logoutCtx.Base -Method 'logoutByUserIdAndPass' -Body "userId=$encUserLogout&pass=$encPassLogout"
        Write-Host ("HTTP 状态：{0}" -f $logoutResult.Status)
        Write-Host ("服务器返回：{0}" -f $logoutResult.Raw)
        return
    }

    if ($SelfTest) {
        Write-Log '开始自检：先注销当前会话，看能不能自己登回来' 'INFO'
        $state = Load-State
        $net = Get-NetworkState
        if ($net.State -eq 'Portal' -and $cred) {
            Write-Log '当前本来就没登录，直接走登录流程' 'INFO'
        } elseif ($cred) {
            Clear-PortalSession -PortalUrl "http://10.255.240.8/eportal/index.jsp" -User $cred.User -Pass $cred.Pass -UserIndex $state.userIndex | Out-Null
            $state.userIndex = $null
            Save-State -State $state
            $becameOffline = $false
            for ($i = 1; $i -le 7; $i++) {
                Start-Sleep -Seconds 3
                if ((Get-NetworkState).State -eq 'Portal') { $becameOffline = $true; break }
                Write-Log ("还没断开，再等 3 秒（{0}/7）" -f $i) 'INFO'
            }
            if ($becameOffline) {
                Write-Log '会话已断开，交给登录流程' 'INFO'
            } else {
                Write-Log '注销后探测还是通的，认证服务器可能没马上断开，这次自检说服力有限' 'WARN'
            }
        }
    }

    if ($Once) {
        $phase = Invoke-Cycle -Cred $cred
        $state = Load-State
        $gw = Get-DefaultGateway
        Write-Host ''
        if ($SelfTest) { Write-Host '自检模式：刚才主动注销了会话，下面这次是守护进程自己登回来的。' }
        Write-Host ("阶段：{0}" -f $phase)
        Write-Host ("网关：{0}" -f $(if ($gw) { $gw.Address } else { '无' }))
        Write-Host ("认证：{0}" -f $(if ($state.userIndex) { '已登录 userIndex=' + $state.userIndex } else { '未登录' }))
        Write-Host ("心跳间隔：{0} 分钟" -f $state.keepaliveInterval)
        Write-Host ("说明：{0}" -f $state.lastMessage)
        Write-Host ("日志：{0}" -f $script:LogPath)
        return
    }

    Write-Log ("守护进程启动，轮询间隔 {0} 秒" -f $script:Config.pollIntervalSec) 'INFO'
    try {
        $bootStateForUi = Load-State
        $bootStateForUi.pid = $PID
        Save-State -State $bootStateForUi
    } catch { }
    try {
        $me = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
        $parentName = ''
        try {
            $parentName = (Get-Process -Id $me.ParentProcessId -ErrorAction Stop).ProcessName
        } catch { $parentName = '?' }
        Write-Log ("进程 PID={0}，父进程 {1}({2})" -f $PID, $me.ParentProcessId, $parentName) 'INFO'
    } catch { }
    $prevCycleEnd = Get-Date
    while ($true) {
        $gap = ((Get-Date) - $prevCycleEnd).TotalSeconds
        if ($gap -gt ([int]$script:Config.pollIntervalSec * 3 + 120)) {
            Write-Log ('检测到休眠恢复（间隔 {0:N0} 秒），等 5 秒让网络就绪' -f $gap) 'INFO'
            Start-Sleep -Seconds 5
        }

        $cycleStart = Get-Date
        try {
            $phase = Invoke-Cycle -Cred $cred
        } catch {
            Write-Log "本轮异常：$($_.Exception.Message)" 'ERROR'
            $phase = 'error'
        }

        $cost = ((Get-Date) - $cycleStart).TotalSeconds
        $sleep = [int]$script:Config.pollIntervalSec - [int]$cost
        if ($sleep -lt 5) { $sleep = 5 }

        # 刚登录失败时要按退避节奏早点重试，别死等一个完整轮询周期。
        # 认证设备经常是"第一次超时、隔几秒就通了"，30 秒一轮太慢。
        if ($phase -eq 'login-failed' -or $phase -eq 'waiting') {
            $pending = Load-State
            if ($pending.nextAttemptAt) {
                try {
                    $wait = ([datetime]::Parse($pending.nextAttemptAt) - (Get-Date)).TotalSeconds
                    if ($wait -lt 3) { $wait = 3 }
                    if ($wait -lt $sleep) { $sleep = [int][Math]::Ceiling($wait) }
                } catch { }
            }
        }
        if ($sleep -lt 3) { $sleep = 3 }
        Start-Sleep -Seconds $sleep
        $prevCycleEnd = Get-Date
    }
}
catch {
    Write-Log ("守护进程异常退出：{0}" -f $_.Exception.Message) 'ERROR'
    try {
        @($_.ScriptStackTrace -split "`n" | Select-Object -First 6) | ForEach-Object {
            Write-Log ("  at " + $_.Trim()) 'ERROR'
        }
    } catch { }
}
finally {
    if (-not $Once) { Write-Log '守护进程退出' 'INFO' }
    if ($mutex) {
        try {
            $mutex.ReleaseMutex()
            $mutex.Dispose()
        } catch { }
    }
}
