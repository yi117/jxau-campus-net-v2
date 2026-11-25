<#
.SYNOPSIS
  关掉 Windows"连上需要登录的网络就自动打开浏览器"的行为。

.DESCRIPTION
  双击 no-portal-popup.cmd 即可（会自动请求管理员权限）。

  校园网每次开机都要先认证，Windows 的强制门户检测（NCSI）发现"能连上但上不了网"，
  就会自己拉起浏览器打开认证页。守护进程正常时会在几十秒内登好，
  但开机那两分钟学校的认证设备常常还不认新会话，Windows 就已经弹了。

  这里改两个策略键：
    HKLM\SOFTWARE\Policies\Microsoft\Windows\WcmSvc\GroupPolicy
        fBlockWebBrowserLaunch = 1
    HKLM\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator
        NoWebBrowserLaunch = 1

  只影响"自动打开浏览器"这一个动作：
    - 网络图标该提示"需要登录"还是提示
    - 你自己点通知、手动打开认证页，完全不受影响
    - 不会改动 NCSI 探测本身，所以 Windows 对"有没有网"的判断照旧

  用 -Revert 可以还原。
#>

param(
    [switch]$Revert
)

$ErrorActionPreference = 'Stop'

$wcmKey  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WcmSvc\GroupPolicy'
$ncsiKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator'
$valueA  = 'fBlockWebBrowserLaunch'
$valueB  = 'NoWebBrowserLaunch'

function Test-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host '需要管理员权限改策略键，正在请求 UAC...' -ForegroundColor Yellow
    Start-Sleep -Seconds 1
    $extra = if ($Revert) { ' -Revert' } else { '' }
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}"{1}' -f $PSCommandPath, $extra
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine | Out-Null
    return
}

Write-Host ''
Write-Host '================ 开机自动弹认证页 ================' -ForegroundColor Cyan

if ($Revert) {
    foreach ($pair in @(@{ Key = $wcmKey; Name = $valueA }, @{ Key = $ncsiKey; Name = $valueB })) {
        if (Test-Path -LiteralPath $pair.Key) {
            $existing = Get-ItemProperty -LiteralPath $pair.Key -Name $pair.Name -ErrorAction SilentlyContinue
            if ($null -ne $existing) {
                Remove-ItemProperty -LiteralPath $pair.Key -Name $pair.Name -ErrorAction SilentlyContinue
                Write-Host ("已删除：{0} -> {1}" -f $pair.Key, $pair.Name) -ForegroundColor Green
            } else {
                Write-Host ("本来就没有：{0} -> {1}" -f $pair.Key, $pair.Name)
            }
        }
    }
    Write-Host ''
    Write-Host '还原完成。下次连上需要认证的网络时，Windows 又会自动打开浏览器。' -ForegroundColor Cyan
    if ($Host.Name -eq 'ConsoleHost') { Read-Host '按回车关闭这个窗口' | Out-Null }
    return
}

if (-not (Test-Path -LiteralPath $wcmKey)) {
    New-Item -Path $wcmKey -Force | Out-Null
    Write-Host ("已创建：{0}" -f $wcmKey)
}
New-ItemProperty -LiteralPath $wcmKey -Name $valueA -Value 1 -PropertyType DWord -Force | Out-Null
Write-Host ("已设置：{0}\{1} = 1" -f $wcmKey, $valueA) -ForegroundColor Green

if (-not (Test-Path -LiteralPath $ncsiKey)) {
    New-Item -Path $ncsiKey -Force | Out-Null
    Write-Host ("已创建：{0}" -f $ncsiKey)
}
New-ItemProperty -LiteralPath $ncsiKey -Name $valueB -Value 1 -PropertyType DWord -Force | Out-Null
Write-Host ("已设置：{0}\{1} = 1" -f $ncsiKey, $valueB) -ForegroundColor Green

Write-Host ''
Write-Host '完成。' -ForegroundColor Cyan
Write-Host '下次开机 Windows 不会再自己弹浏览器了；网络图标该提示"需要登录"仍然会提示。'
Write-Host '真要手动登录时，自己打开浏览器访问认证页就行，和以前一样。'
Write-Host ''
Write-Host '想还原：no-portal-popup.cmd -Revert'
if ($Host.Name -eq 'ConsoleHost') { Read-Host '按回车关闭这个窗口' | Out-Null }
