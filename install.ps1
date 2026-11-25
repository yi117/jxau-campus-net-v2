<#
.SYNOPSIS
  安装校园网自动认证守护：录入账号、注册计划任务。

.DESCRIPTION
  双击 install.cmd 即可。分两步：

    第一步（普通权限）：在本窗口输入校园网账号和密码，
      密码用 Windows 的 DPAPI 加密后存到
      %LOCALAPPDATA%\CampusNetGuard\credential.dat，明文不落盘。

    第二步（提权）：注册名为 CampusNetGuard 的计划任务，
      登录 Windows 时自动启动 guard.ps1。

  账号只存在本机，只发给学校自己的认证服务器（10.255.240.8）。
#>

param(
    [switch]$Phase2,
    [string]$Owner = '',
    [string]$RuntimeDir = '',
    [switch]$SkipPrompt,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'

$here      = $PSScriptRoot
$guardPath = Join-Path $here 'guard.ps1'
$launcherPath = Join-Path $here 'launch.vbs'
$runtime   = if ($RuntimeDir) { $RuntimeDir } else { Join-Path $env:LOCALAPPDATA 'CampusNetGuard' }
$credPath  = Join-Path $runtime 'credential.dat'
$cfgPath   = Join-Path $runtime 'config.json'
$taskName  = 'CampusNetGuard'
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

function Test-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PlainText {
    param([System.Security.SecureString]$Secure)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

# ================================================================ 第一步：录凭据

if (-not $Phase2) {
    if (-not (Test-Path -LiteralPath $guardPath)) {
        throw "找不到 guard.ps1，请确认它在 $here 里。"
    }
    if (-not (Test-Path -LiteralPath $runtime)) {
        New-Item -ItemType Directory -Force -Path $runtime | Out-Null
    }

    $needInput = -not $SkipPrompt
    if ($SkipPrompt -and -not (Test-Path -LiteralPath $credPath)) {
        $needInput = $true
    }
    if ($needInput -and (Test-Path -LiteralPath $credPath)) {
        Write-Host ''
        Write-Host '发现已经保存过账号。' -ForegroundColor Yellow
        $again = Read-Host '要重新录入账号密码吗？(y/N，直接回车=沿用旧账号)'
        if ($again -notmatch '^[Yy]') { $needInput = $false }
    }

    $account = ''
    $secure  = $null

    if ($needInput) {
        Write-Host ''
        Write-Host '================ 校园网自动认证 安装 ================' -ForegroundColor Cyan
        Write-Host '先录入校园网上网账号（就是认证页上那个用户名和密码）。'
        Write-Host '密码用当前 Windows 账户加密保存，不会明文写到磁盘。'
        Write-Host ''
        $account = (Read-Host '校园网账号（学号）').Trim()
        if ([string]::IsNullOrWhiteSpace($account)) {
            throw '账号不能为空。'
        }
        $secure = Read-Host '校园网密码（输入时不显示）' -AsSecureString
        if ($secure.Length -eq 0) {
            throw '密码不能为空。'
        }
        $confirm = Read-Host '再输一次确认' -AsSecureString
        if ((Get-PlainText $secure) -ne (Get-PlainText $confirm)) {
            throw '两次输入的密码不一样，请重新运行 install.cmd。'
        }

        # SecureString -> 明文，拼成 "账号\n密码"，再整体用 DPAPI 加密
        $plain = Get-PlainText $secure
        $payload = ("{0}`n{1}" -f $account, $plain) | ConvertTo-SecureString -AsPlainText -Force
        $encrypted = $payload | ConvertFrom-SecureString
        [System.IO.File]::WriteAllText($credPath, $encrypted, (New-Object System.Text.UTF8Encoding($false)))
        $plain = $null
        Write-Host ''
        Write-Host ("账号已保存：{0}" -f $account) -ForegroundColor Green
        Write-Host ("凭据文件：{0}" -f $credPath)
    } else {
        Write-Host '已有凭据，沿用上次录入的账号。'
    }

    # 写默认配置（已存在就不动，保留用户改过的参数）
    if (-not (Test-Path -LiteralPath $cfgPath)) {
        $cfg = [ordered]@{
            ssid                     = 'JXAU'
            probeUrls                = @(
                'http://www.msftconnecttest.com/connecttest.txt',
                'http://connect.rom.miui.com/generate_204'
            )
            pollIntervalSec          = 30
            httpTimeoutSec           = 8
            backoffSec               = @(0, 5, 15, 30, 60, 120)
            maxLoginPer10Min         = 6
            loginPauseSec            = 600
            wifiReconnectCooldownSec = 300
            keepaliveFallbackMin     = 5
            portalHost               = '10.255.240.8'
            portalPort               = 80
        }
        $cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cfgPath -Encoding UTF8
    }

    # 注册计划任务需要管理员，换一个提权进程继续
    if (-not (Test-Admin)) {
        Write-Host ''
        Write-Host '接下来会弹出 UAC 确认框，用于注册开机自动启动的计划任务。' -ForegroundColor Yellow
        Write-Host '授权的是你自己这台电脑，不需要再输一次密码。'
        Start-Sleep -Seconds 2
        $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Phase2 -Owner "{1}" -RuntimeDir "{2}"' -f $PSCommandPath, $currentUser, $runtime
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine | Out-Null
        Write-Host ''
        Write-Host '已在新的管理员窗口继续。注册完成后，那个窗口会显示状态。'
        return
    }
}

# ================================================================ 第二步：注册任务

if ($Owner -and $Owner -ne $currentUser) {
    Write-Host ''
    Write-Host ("当前是以 {0} 身份运行的，和目标用户 {1} 不一致。" -f $currentUser, $Owner) -ForegroundColor Red
    Write-Host '多半是 UAC 里用别的管理员账号授权了。请用当前登录账户亲自完成 UAC 确认后重试。'
    if ($Host.Name -eq 'ConsoleHost' -and -not $NonInteractive) { Read-Host '按回车关闭' | Out-Null }
    return
}

if (-not (Test-Path -LiteralPath $guardPath)) {
    throw "找不到 guard.ps1：$guardPath"
}
if (-not (Test-Path -LiteralPath $credPath)) {
    throw "没有找到凭据文件：$credPath。请先正常运行一次 install.cmd。"
}

$owner = if ($Owner) { $Owner } else { $currentUser }

# 优先用 wscript 启动（完全没有控制台窗口）；没有 launch.vbs 时退回 powershell
if (Test-Path -LiteralPath $launcherPath) {
    $actionCommand = 'wscript.exe'
    $actionArgs    = '//B //Nologo "' + $launcherPath + '"'
} else {
    $actionCommand = 'powershell.exe'
    $actionArgs    = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $guardPath + '"'
}

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>校园网自动认证守护：掉线自动重连、按服务器要求发送心跳。</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Repetition>
        <Interval>PT5M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <Enabled>true</Enabled>
      <UserId>$owner</UserId>
      <Delay>PT10S</Delay>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$owner</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>10</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$actionCommand</Command>
      <Arguments>$actionArgs</Arguments>
    </Exec>
  </Actions>
</Task>
"@

Write-Host ''
Write-Host '正在注册计划任务...'
$xmlFallback = $xml -replace '(?s)<Repetition>.*?</Repetition>', ''
$registered = $false
try {
    Register-ScheduledTask -TaskName $taskName -Xml $xml -Force | Out-Null
    $registered = $true
    Write-Host '计划任务已注册（每 5 分钟自检一次，进程被结束会自动拉起）' -ForegroundColor Green
} catch {
    Write-Host ("带自愈的计划任务注册失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
    Write-Host '改用基础版本重试...'
    Register-ScheduledTask -TaskName $taskName -Xml $xmlFallback -Force | Out-Null
    $registered = $true
    Write-Host '计划任务已注册（基础版本，没有定时自检）' -ForegroundColor Green
}
if ($registered) {
    Write-Host ("守护脚本：{0}" -f $guardPath)
}

Start-ScheduledTask -TaskName $taskName
if ($NonInteractive) {
    # 界面调用时不要挂着等，给守护进程两秒把 state.json 写出来就够
    Start-Sleep -Seconds 2
} else {
    Write-Host '已启动守护进程，等它跑一轮...'
    Start-Sleep -Seconds 10
}

# 打印状态
$statusScript = Join-Path $here 'status.ps1'
if (Test-Path -LiteralPath $statusScript) {
    & $statusScript
} else {
    $statePath = Join-Path $runtime 'state.json'
    if (Test-Path -LiteralPath $statePath) {
        Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
    }
}

Write-Host ''
Write-Host '安装完成。' -ForegroundColor Cyan
Write-Host '以后开机登录会自动在后台运行，不需要再打开认证页面。'
Write-Host '查看状态：双击 status.cmd'
Write-Host '卸载：双击 uninstall.cmd'
Write-Host ''
Write-Host '建议顺手做一步：双击 tune-wifi.cmd，关掉网卡的省电断开（需要 UAC）。'
if ($Host.Name -eq 'ConsoleHost' -and -not $NonInteractive) {
    Read-Host '按回车关闭这个窗口' | Out-Null
}
