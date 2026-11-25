<#
.SYNOPSIS
  关掉 Wi-Fi 网卡的省电断开，减少"莫名其妙掉线"。

.DESCRIPTION
  双击 tune-wifi.cmd 即可（会自动请求管理员权限）。会做三件事：

    1. 取消"允许计算机关闭此设备以节约电源"
    2. 电源计划里的"无线适配器节能模式"设为最高性能（交流/电池都设）
    3. 尝试把网卡高级设置里省电/漫游相关的项调到性能优先

  第 3 步只认已知的安全取值，认不出来就原样不动并提示手动设置。
  所有改动前的原值会存到 %LOCALAPPDATA%\CampusNetGuard\wifi-backup.json，
  用 tune-wifi.cmd -Revert（或卸载脚本）可以还原。

  注意：这里改的是本机网卡，不涉及学校设备。
#>

param(
    [switch]$Revert,
    [string]$RuntimeDir = ''
)

$ErrorActionPreference = 'Stop'

$here      = $PSScriptRoot
$runtime   = if ($RuntimeDir) { $RuntimeDir } else { Join-Path $env:LOCALAPPDATA 'CampusNetGuard' }
$backupPath = Join-Path $runtime 'wifi-backup.json'
$subGuid   = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'   # 无线适配器设置
$setGuid   = '12bbebe6-58d6-4636-95bb-3217ef867c1a'   # 节能模式
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

function Test-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host '需要管理员权限改网卡设置，正在请求 UAC...' -ForegroundColor Yellow
    Start-Sleep -Seconds 1
    $extra = if ($Revert) { ' -Revert' } else { '' }
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}"{1} -RuntimeDir "{2}"' -f $PSCommandPath, $extra, $runtime
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine | Out-Null
    return
}

if (-not (Test-Path -LiteralPath $runtime)) {
    New-Item -ItemType Directory -Force -Path $runtime | Out-Null
}

function Get-WifiAdapter {
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN' -or $_.Name -eq 'WLAN' } |
        Sort-Object @{ Expression = { if ($_.Status -eq 'Up') { 0 } else { 1 } } } |
        Select-Object -First 1
}

function Get-PowerCfgWirelessIndex {
    $text = powercfg /query SCHEME_CURRENT $subGuid 2>&1 | Out-String
    $result = [ordered]@{ ac = $null; dc = $null; raw = $text }
    $m = [regex]::Match($text, '(?:当前交流电源设置索引|Current AC Power Setting Index)\s*[:：]\s*0x([0-9a-fA-F]+)')
    if ($m.Success) { $result.ac = [Convert]::ToInt32($m.Groups[1].Value, 16) }
    $m = [regex]::Match($text, '(?:当前直流电源设置索引|Current DC Power Setting Index)\s*[:：]\s*0x([0-9a-fA-F]+)')
    if ($m.Success) { $result.dc = [Convert]::ToInt32($m.Groups[1].Value, 16) }
    return $result
}

function Set-PowerCfgWirelessIndex {
    param([int]$Ac, [int]$Dc)
    powercfg /setacvalueindex SCHEME_CURRENT $subGuid $setGuid $Ac | Out-Null
    powercfg /setdcvalueindex SCHEME_CURRENT $subGuid $setGuid $Dc | Out-Null
    powercfg /setactive SCHEME_CURRENT | Out-Null
}

Write-Host ''
Write-Host '================ 校园网：网卡省电调优 ================' -ForegroundColor Cyan

$adapter = Get-WifiAdapter
if (-not $adapter) {
    Write-Host '没找到无线网卡，可能被禁用了。' -ForegroundColor Red
    if ($Host.Name -eq 'ConsoleHost') { Read-Host '按回车关闭' | Out-Null }
    return
}
Write-Host ("网卡：{0}  状态：{1}" -f $adapter.InterfaceDescription, $adapter.Status)
Write-Host ''

# ================================================================ 还原
if ($Revert) {
    if (-not (Test-Path -LiteralPath $backupPath)) {
        Write-Host '没有找到调优备份，说明没改过，不需要还原。'
        if ($Host.Name -eq 'ConsoleHost') { Read-Host '按回车关闭' | Out-Null }
        return
    }
    $backup = Get-Content -LiteralPath $backupPath -Raw -Encoding UTF8 | ConvertFrom-Json

    if ($backup.allowComputerToTurnOff) {
        try {
            Set-NetAdapterPowerManagement -Name $adapter.Name -AllowComputerToTurnOffDevice $backup.allowComputerToTurnOff -ErrorAction Stop
            Write-Host ("已还原：允许关闭设备以节约电源 = {0}" -f $backup.allowComputerToTurnOff) -ForegroundColor Green
        } catch {
            Write-Host ("还原电源管理失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    if ($backup.powercfgWireless -and $null -ne $backup.powercfgWireless.ac -and $null -ne $backup.powercfgWireless.dc) {
        try {
            Set-PowerCfgWirelessIndex -Ac ([int]$backup.powercfgWireless.ac) -Dc ([int]$backup.powercfgWireless.dc)
            Write-Host ("已还原：无线适配器节能模式 = 交流 {0} / 电池 {1}" -f $backup.powercfgWireless.ac, $backup.powercfgWireless.dc) -ForegroundColor Green
        } catch {
            Write-Host ("还原电源计划失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    foreach ($item in @($backup.advanced)) {
        if (-not $item -or -not $item.name) { continue }
        try {
            Set-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName $item.name -DisplayValue $item.displayValue -ErrorAction Stop
            Write-Host ("已还原高级设置：{0} = {1}" -f $item.name, $item.displayValue) -ForegroundColor Green
        } catch {
            Write-Host ("还原高级设置 {0} 失败：{1}" -f $item.name, $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host '还原完成。' -ForegroundColor Cyan
    if ($Host.Name -eq 'ConsoleHost') { Read-Host '按回车关闭' | Out-Null }
    return
}

# ================================================================ 应用
$backup = [ordered]@{
    adapter                = $adapter.Name
    allowComputerToTurnOff = $null
    powercfgWireless       = $null
    advanced               = @()
}

# --- 1. 取消网卡"允许关闭以节约电源"
try {
    $pm = Get-NetAdapterPowerManagement -Name $adapter.Name -ErrorAction Stop
    $backup.allowComputerToTurnOff = "$($pm.AllowComputerToTurnOffDevice)"
    if ("$($pm.AllowComputerToTurnOffDevice)" -ne 'Disabled') {
        Set-NetAdapterPowerManagement -Name $adapter.Name -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop
        Write-Host '已关闭：允许计算机关闭此设备以节约电源' -ForegroundColor Green
    } else {
        Write-Host '已经是关闭状态：允许计算机关闭此设备以节约电源'
    }
} catch {
    Write-Host ("设置电源管理失败（网卡驱动可能不支持）：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
}

# --- 2. 电源计划里的无线节能
try {
    $cur = Get-PowerCfgWirelessIndex
    $backup.powercfgWireless = @{ ac = $cur.ac; dc = $cur.dc }
    if ($cur.ac -ne 0 -or $cur.dc -ne 0) {
        Set-PowerCfgWirelessIndex -Ac 0 -Dc 0
        Write-Host ("已设置：无线适配器节能模式 = 最高性能（原来 交流 {0} / 电池 {1}）" -f $cur.ac, $cur.dc) -ForegroundColor Green
    } else {
        Write-Host '已经是最高性能：无线适配器节能模式'
    }
} catch {
    Write-Host ("设置电源计划失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
}

# --- 3. 网卡高级设置（只改认得出的安全值）
$maxPattern = '^(最高性能|最高性能\(0\)|最大性能|Maximum Performance|Highest Performance|Disabled|关闭|不省电)$'
try {
    $props = Get-NetAdapterAdvancedProperty -Name $adapter.Name -ErrorAction Stop
    $touched = 0
    foreach ($p in $props) {
        if ($p.DisplayName -notmatch 'Power Save|省电|节能|U-APSD|Roaming|漫游') { continue }
        $current = "$($p.DisplayValue)"
        $candidates = @()
        if ($p.PSObject.Properties['ValidDisplayValues']) { $candidates = @($p.ValidDisplayValues) }
        $pick = $candidates | Where-Object { $_ -match $maxPattern } | Select-Object -First 1
        if (-not $pick) {
            Write-Host ("跳过高级设置 {0}：取值列表认不出哪个是性能优先（当前 {1}）" -f $p.DisplayName, $current) -ForegroundColor Yellow
            continue
        }
        if ($pick -eq $current) {
            Write-Host ("已经是性能优先：{0} = {1}" -f $p.DisplayName, $current)
            continue
        }
        try {
            Set-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName $p.DisplayName -DisplayValue $pick -ErrorAction Stop
            $backup.advanced += @{ name = $p.DisplayName; displayValue = $current }
            $touched++
            Write-Host ("已调整：{0}  {1} -> {2}" -f $p.DisplayName, $current, $pick) -ForegroundColor Green
        } catch {
            Write-Host ("调整 {0} 失败：{1}" -f $p.DisplayName, $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    if ($touched -eq 0) { Write-Host '高级设置没有需要改动的项。' }
} catch {
    Write-Host ("读取网卡高级设置失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
}

if ($null -ne $backup.allowComputerToTurnOff -or $null -ne $backup.powercfgWireless -or @($backup.advanced).Count -gt 0) {
    $backup | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $backupPath -Encoding UTF8
    Write-Host ''
    Write-Host ("原值已备份：{0}" -f $backupPath)
    Write-Host '想撤销就双击 tune-wifi.cmd -Revert，或者直接卸载。'
}

# --- 顺手看一眼信号
Write-Host ''
Write-Host '--- 当前无线状态 ---' -ForegroundColor Cyan
try {
    $wlan = netsh wlan show interfaces 2>&1 | Out-String
    ($wlan -split "`r?`n" | Where-Object { $_ -match 'SSID|信号|Signal|接收速率|Receive rate|发送速率|Transmit rate|状态|State|通道|Channel' } ) |
        ForEach-Object { '  ' + $_.Trim() }
} catch { }

Write-Host ''
Write-Host '调优完成。' -ForegroundColor Cyan
if ($Host.Name -eq 'ConsoleHost') { Read-Host '按回车关闭这个窗口' | Out-Null }
