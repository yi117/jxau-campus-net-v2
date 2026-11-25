<#
.SYNOPSIS
  卸载校园网自动认证守护，顺带把网卡的省电设置还原。

.DESCRIPTION
  双击 uninstall.cmd 即可（会自动请求管理员权限）。做的事：

    1. 停止并删除计划任务 CampusNetGuard
    2. 如果之前跑过 tune-wifi.cmd，按备份还原网卡设置
    3. 删掉 %LOCALAPPDATA%\CampusNetGuard（凭据、日志、状态）

  删完之后上网就回到原来的样子，需要自己打开认证页登录。
#>

param(
    [string]$Owner = '',
    [string]$RuntimeDir = '',
    [switch]$KeepData
)

$ErrorActionPreference = 'Stop'

$here    = $PSScriptRoot
$runtime = if ($RuntimeDir) { $RuntimeDir } else { Join-Path $env:LOCALAPPDATA 'CampusNetGuard' }
$taskName = 'CampusNetGuard'
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

function Test-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host '需要管理员权限来删除计划任务，正在请求 UAC...' -ForegroundColor Yellow
    Start-Sleep -Seconds 1
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Owner "{1}" -RuntimeDir "{2}"' -f $PSCommandPath, $currentUser, $runtime
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine | Out-Null
    return
}

Write-Host ''
Write-Host '================ 卸载校园网自动认证 ================' -ForegroundColor Cyan

# ---- 停任务、删任务
try {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    if ($task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Write-Host '已停止守护进程。'
    }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
    Write-Host ("已删除计划任务：{0}" -f $taskName) -ForegroundColor Green
} catch {
    Write-Host ("没有找到计划任务 {0}（可能已经删过了）" -f $taskName)
}

# ---- 还原"禁止开机自动弹认证页"的策略
$wcmKey  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WcmSvc\GroupPolicy'
$ncsiKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator'
$policyReverted = $false
foreach ($pair in @(
        @{ Key = $wcmKey;  Name = 'fBlockWebBrowserLaunch' },
        @{ Key = $ncsiKey; Name = 'NoWebBrowserLaunch' })) {
    if (Test-Path -LiteralPath $pair.Key) {
        $existing = Get-ItemProperty -LiteralPath $pair.Key -Name $pair.Name -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            Remove-ItemProperty -LiteralPath $pair.Key -Name $pair.Name -ErrorAction SilentlyContinue
            $policyReverted = $true
        }
    }
}
if ($policyReverted) {
    Write-Host '已还原：Windows 会恢复"连上需要登录的网络就自动打开浏览器"。' -ForegroundColor Green
}

# ---- 还原网卡设置
$tuneScript = Join-Path $here 'tune-wifi.ps1'
$backup = Join-Path $runtime 'wifi-backup.json'
if ((Test-Path -LiteralPath $tuneScript) -and (Test-Path -LiteralPath $backup)) {
    Write-Host ''
    Write-Host '发现网卡调优备份，正在还原...'
    try {
        & $tuneScript -Revert -RuntimeDir $runtime
    } catch {
        Write-Host ("还原网卡设置出错：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
        Write-Host '可以稍后手动运行 tune-wifi.cmd -Revert。'
    }
}

# ---- 清数据
Write-Host ''
if (-not $KeepData) {
    $answer = 'Y'
    if ($Host.Name -eq 'ConsoleHost') {
        $answer = Read-Host '要一并删除保存的账号和日志吗？(Y/n)'
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = 'Y' }
    }
    if ($answer -match '^[Yy]') {
        if (Test-Path -LiteralPath $runtime) {
            Remove-Item -LiteralPath $runtime -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host ("已删除：{0}" -f $runtime) -ForegroundColor Green
        }
    } else {
        Write-Host ("保留数据：{0}" -f $runtime)
        Write-Host '注意：凭据还留在里面，重新安装会直接沿用。'
    }
}

Write-Host ''
Write-Host '卸载完成。以后上网需要自己打开认证页登录。'
if ($Host.Name -eq 'ConsoleHost') {
    Read-Host '按回车关闭这个窗口' | Out-Null
}
