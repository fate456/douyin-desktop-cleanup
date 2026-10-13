#Requires -Version 5.1
<#
抖音会话与残留清理工具（Windows PowerShell 5.1）
双击 Start-Douyin.bat：放行网络并启动；后台主程序退出后自动拦截与清理。
Status 默认只读。Lockdown 保存当前配置后禁用自启；Unlock 恢复本工具记录的配置。
安装目录自动读取注册信息，也可使用 DOUYIN_ROOT 环境变量或 -DouyinRoot。
日志、快照和快捷方式备份位于用户本地数据目录，源码不保存机器信息。
详细用法及验收边界见 README.txt。
#>

[CmdletBinding()]
param(
    [ValidateSet('Status', 'Clean', 'Lockdown', 'Unlock', 'Watch', 'Allow', 'Block', 'Finish', 'Session', 'SessionWait')]
    [string]$Action = 'Status',

    [string]$DouyinRoot = '',
    [string]$DataRoot = '',

    [ValidateRange(-1, 300)][int]$SettleSeconds = -1,

    [ValidatePattern('^[\p{L}\p{N}_.-]{1,128}$')][string]$TaskName = 'DouyinResidualCleanup',
    [ValidatePattern('^[\p{L}\p{N}_. -]{1,128}$')][ValidateScript({ $_.Trim().Length -gt 0 })][string]$RulePrefix = 'DouyinKiller-Block',

    # 收尾任务模式：
    #   LogonOnly (默认) 只在开机 / 登录各跑一次，不轮询，日常零开销
    #   Periodic         额外按 WatchIntervalMinutes 轮询，自动感更强但持续有唤醒
    #   None             完全不要计划任务
    [ValidateSet('LogonOnly', 'Periodic', 'None')]
    [string]$WatchdogMode = 'LogonOnly',

    # 仅在 WatchdogMode=Periodic 时生效
    [ValidateRange(1, 1440)][int]$WatchIntervalMinutes = 5,

    [ValidateRange(1, 600)][int]$StartupTimeoutSeconds = 45,
    [ValidateRange(1, 60)][int]$ExitGraceSeconds = 2,
    [ValidateRange(1, 10)][int]$CleanupMaxPasses = 5,
    [ValidateRange(0, 3600)][int]$StateCacheSeconds = 60,
    [switch]$SaveStatus,
    [ValidatePattern('^(|Global\\DouyinCleanup-Ready-[a-f0-9]{32})$')][string]$ReadyEvent = '',

    [switch]$HardMode
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off
. (Join-Path $PSScriptRoot 'Douyin.Common.ps1')
. (Join-Path $PSScriptRoot 'Douyin.Restore.ps1')

# ---------------------------------------------------------------- 基础设施

$ScriptPath = $PSCommandPath
if (-not $ScriptPath) { $ScriptPath = $MyInvocation.MyCommand.Path }
$ScriptRoot = Split-Path -Parent $ScriptPath
if (-not $DataRoot) { $DataRoot = Get-DefaultDataRoot }
if (-not [IO.Path]::IsPathRooted($DataRoot)) { throw 'DataRoot 必须是绝对路径。' }
$DataRoot = [IO.Path]::GetFullPath($DataRoot).TrimEnd('\')
if ($DataRoot -eq [IO.Path]::GetPathRoot($DataRoot).TrimEnd('\')) { throw 'DataRoot 不能是磁盘根目录。' }
if ($DataRoot.TrimEnd('\') -eq $ScriptRoot.TrimEnd('\') -or (Test-PathUnderRoot $DataRoot $ScriptRoot)) { throw '运行数据目录不能位于项目源码内。' }
try { $DouyinRoot = Resolve-DouyinRoot -ConfiguredRoot $DouyinRoot -DataRoot $DataRoot }
catch { Write-Host (Protect-PrivateText $_.Exception.Message) -ForegroundColor Red; exit 1 }
$IsWatch = ($Action -eq 'Watch')
$CacheContext = $DouyinRoot + '|' + $RulePrefix
$ContextDir = Join-Path $DataRoot (Get-ContextHash $CacheContext)
$LogDir = Join-Path $ContextDir 'logs'
$LogFile = Join-Path $LogDir ('douyin-killer-{0:yyyy-MM}.log' -f (Get-Date))
$StatusFile = Join-Path $ContextDir 'last-status.txt'
$StateFile = Join-Path $ContextDir 'net-state.json'
$RecoveryFile = Join-Path $ContextDir ('recovery-' + (Get-ContextHash $TaskName) + '.json')

if ($Action -ne 'Status' -and (-not (Test-Path -LiteralPath $LogDir))) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# 日志超过 1 MB 就滚动归档，避免巡检日志无限增长
$logItem = Get-Item -LiteralPath $LogFile -ErrorAction SilentlyContinue
if ($Action -ne 'Status' -and $logItem -and $logItem.Length -gt 1MB) {
    Move-Item -LiteralPath $LogFile -Destination ($LogFile + '.old') -Force -ErrorAction SilentlyContinue
}
if ($Action -ne 'Status') {
    foreach ($oldLog in @(Get-ChildItem -LiteralPath $LogDir -Filter 'douyin-killer-*.log*' -File -ErrorAction Stop | Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip 6)) {
        if (Test-PathUnderRoot $oldLog.FullName $LogDir) { Remove-Item -LiteralPath $oldLog.FullName -Force -ErrorAction Stop }
    }
}

if ($SettleSeconds -lt 0) {
    if ($Action -eq 'Watch') { $SettleSeconds = 0 } else { $SettleSeconds = 1 }
}

$IsWatch = ($Action -eq 'Watch')

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, (Protect-PrivateText $Message)
    if ($Action -ne 'Status') { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue }
    if ($IsWatch) { return }
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        'INFO'  { Write-Host $line -ForegroundColor Gray }
        default { Write-Host $line }
    }
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    param([string]$What = '该操作')
    if (Test-IsAdmin) { return $true }
    throw "$What 需要管理员权限。请用配套 BAT 以管理员身份运行。"
}

# ---------------------------------------------------------------- 目标定义

# 抖音的「附属常驻进程」：退出主程序后这些不该还在
$SideCarNames = @(
    'douyin_guard.exe',
    'douyin_widget.exe',
    'douyin_tray.exe',
    'push_detect.exe',
    'app_guard.exe',
    'tt_crash_reporter.exe',
    'parfait_crash_handler.exe',
    'dump_reporter.exe',
    'installer_downloader.exe',
    'app_shell_updater.exe',
    'douyin_doctor.exe',
    'elevation_service.exe',
    'douyin_game_widget.exe',
    'update-driver.exe',
    'UpdateDriverDaemon.exe',
    'UpdateDriverDaemonX64.exe',
    'systeminfo.exe',
    'adjust_get_current_system_volume_vista_plus.exe'
)

# 抖音主程序名：出现即视为用户正在使用，跳过一切清理
$MainNames = @('douyin.exe', 'new_douyin.exe', 'douyin.backup')

$DouyinServices = @(
    @{ Name = 'douyin_performance_service'; Default = 'Automatic' },
    @{ Name = 'DouyinElevationService';     Default = 'Manual'    }
)

# ---------------------------------------------------------------- 进程扫描

function Get-DouyinProcessSnapshot {
    $root = $DouyinRoot.TrimEnd('\')
    $prefix = $root + '\'
    $list = New-Object System.Collections.Generic.List[object]

    foreach ($p in (Get-CimInstance Win32_Process -ErrorAction Stop)) {
        $exe = $null
        try { $exe = $p.ExecutablePath } catch { }

        $underRoot = $false
        if ($exe) {
            if ($exe.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -or
                $exe.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) {
                $underRoot = $true
            }
        }

        $name = [string]$p.Name
        $list.Add([pscustomobject]@{
            Pid       = [int]$p.ProcessId
            Name      = $name
            Path      = $exe
            PathKnown = [bool]$exe
            Created   = $p.CreationDate
            UnderRoot = $underRoot
            IsMain    = ($underRoot -and ($MainNames -contains $name))
            IsSideCar = ($underRoot -and ($SideCarNames -contains $name))
        })
    }
    return $list
}

# 选出一批「本次可以结束」的进程
function Select-RemovableProcess {
    param($Snapshot)
    $targets = New-Object System.Collections.Generic.List[object]
    foreach ($p in $Snapshot) {
        # 后台主程序已退出时，清理安装目录内的全部组件，覆盖更新后的新文件名。
        if ($p.UnderRoot -and $p.PathKnown -and (-not $p.IsMain)) { $targets.Add($p); continue }
        # 路径不可读时保留该进程，不能把其他软件的同名上报/更新组件误杀。
    }
    return $targets
}

function Test-DouyinInUse {
    param($Snapshot)
    foreach ($p in $Snapshot) {
        if (($MainNames -contains $p.Name) -and ($p.UnderRoot -or (-not $p.PathKnown))) { return $true }
    }
    return $false
}

# 轻量存活检查：按进程名查，比 Get-CimInstance 快一个数量级（用于会话等待循环）
$DouyinProcessNames = @($MainNames | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) } | Select-Object -Unique)

function Test-DouyinAliveFast {
    $hit = @(Get-Process -Name $DouyinProcessNames -ErrorAction SilentlyContinue)
    foreach ($p in $hit) {
        $path = $null
        try { $path = $p.Path } catch { }
        # 无法确认主程序路径时保守地等；已确认是其他目录的同名程序则忽略。
        if (-not $path -or $path.StartsWith($DouyinRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Stop-VerifiedResidual {
    param($Target)
    $current = Get-CimInstance Win32_Process -Filter ('ProcessId={0}' -f $Target.Pid) -ErrorAction Stop
    if (-not $current) { return $false }
    if ($current.ExecutablePath -ne $Target.Path -or $current.CreationDate -ne $Target.Created) {
        Write-Log ('PID {0} 的进程身份已变化，跳过。' -f $Target.Pid) 'WARN'
        return $false
    }
    Stop-Process -Id $Target.Pid -Force -ErrorAction Stop
    return $true
}

# ---------------------------------------------------------------- 核心清理

function Invoke-ResidualCleanup {
    param([switch]$Silent)
    $snapshot = @(Get-DouyinProcessSnapshot)
    $killed = 0
    for ($pass = 1; $pass -le $CleanupMaxPasses; $pass++) {
        if (Test-DouyinInUse -Snapshot $snapshot) {
            if ($Action -ne 'Clean') { Sync-DouyinFirewallState -Snapshot $snapshot -Force }
            if (-not $Silent) { Write-Log '后台主程序正在使用，保留所有组件。' 'INFO' }
            return @{ Killed = $killed; InUse = $true }
        }
        if ($pass -eq 1 -and $Action -ne 'Clean') {
            if ($Action -eq 'Finish') { Ensure-DouyinFirewallCoverage -Block $true | Out-Null }
            Sync-DouyinFirewallState -Snapshot $snapshot -Force:($Action -ne 'Watch')
        }
        $targets = @(Select-RemovableProcess -Snapshot $snapshot)
        if ($targets.Count -eq 0) {
            $unknown = @($snapshot | Where-Object { (-not $_.PathKnown) -and ($SideCarNames -contains $_.Name) })
            if ($unknown.Count) { throw '有同名组件路径不可读取，无法确认属于抖音；已保留，不能确认零进程。' }
            if (-not $Silent -or $killed -gt 0) { Write-Log '收尾复查：抖音安装目录内进程已归零。' 'OK' }
            return @{ Killed = $killed; InUse = $false }
        }
        $ordered = $targets | Sort-Object @{ Expression = { if ($_.Name -in @('douyin_guard.exe', 'app_guard.exe')) { 0 } else { 1 } } }, Pid -Unique
        foreach ($target in $ordered) {
            if (Test-DouyinAliveFast) {
                if ($Action -ne 'Clean') { Sync-DouyinFirewallState -Snapshot (Get-DouyinProcessSnapshot) -Force }
                return @{ Killed = $killed; InUse = $true }
            }
            try {
                if (Stop-VerifiedResidual -Target $target) {
                    $killed++
                    Write-Log ('已结束残留进程: {0} (PID {1})' -f $target.Name, $target.Pid) 'OK'
                }
            } catch { Write-Log ('残留结束失败，将复查重试: {0} -> {1}' -f $target.Name, $_.Exception.Message) 'WARN' }
        }
        if ($SettleSeconds -gt 0) { Start-Sleep -Seconds $SettleSeconds }
        else { Start-Sleep -Milliseconds 200 }
        $snapshot = @(Get-DouyinProcessSnapshot)
    }
    if (Test-DouyinInUse -Snapshot $snapshot) {
        if ($Action -ne 'Clean') { Sync-DouyinFirewallState -Snapshot $snapshot -Force }
        return @{ Killed = $killed; InUse = $true }
    }
    $remaining = @(Select-RemovableProcess -Snapshot $snapshot)
    $unknown = @($snapshot | Where-Object { (-not $_.PathKnown) -and ($SideCarNames -contains $_.Name) })
    if ($remaining.Count -or $unknown.Count) {
        throw ('收尾经过 {0} 轮仍未确认零进程；保留日志并返回失败。' -f $CleanupMaxPasses)
    }
    if (-not $Silent -or $killed -gt 0) { Write-Log '收尾复查：抖音安装目录内进程已归零。' 'OK' }
    return @{ Killed = $killed; InUse = $false }
}

# ---------------------------------------------------------------- 自启断根

function Disable-DouyinServices {
    foreach ($service in @(Get-DouyinServiceTargets)) {
        if ($service.StartMode -eq 'Disabled' -and $service.State -eq 'Stopped') { continue }
        Save-ServiceBaseline $service
        if ($service.State -ne 'Stopped') { Stop-Service -Name $service.Name -Force -ErrorAction Stop }
        Set-Service -Name $service.Name -StartupType Disabled -ErrorAction Stop
        Write-Log ('已停止并禁用服务: {0}' -f $service.Name) 'OK'
    }
}

function Get-DouyinRelatedTasks {
    $tasks = New-Object System.Collections.Generic.List[object]
    foreach ($t in (Get-ScheduledTask -ErrorAction Stop)) {
        if ($t.TaskName -eq $TaskName -and $t.TaskPath -eq '\') { continue }
        $blob = (($t.Actions | ForEach-Object { '{0} {1}' -f $_.Execute, $_.Arguments }) -join ' ')
        if ($t.TaskPath.StartsWith('\DouyinUser\', [StringComparison]::OrdinalIgnoreCase) -or
            $blob -match ('(?i)(?:^|["\s])' + [regex]::Escape($DouyinRoot + '\'))) {
            $tasks.Add($t)
        }
    }
    return $tasks
}

function Disable-DouyinTasks {
    $tasks = @(Get-DouyinRelatedTasks)

    if ($tasks.Count -eq 0) { Write-Log '没有发现抖音相关计划任务。' 'INFO'; return }

    foreach ($t in $tasks) {
        if ($t.State -eq 'Disabled') { continue }
        try {
            Save-TaskBaseline $t
            Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop | Out-Null
            Write-Log ('已禁用计划任务: {0}{1}' -f $t.TaskPath, $t.TaskName) 'OK'
        }
        catch {
            Write-Log ('计划任务禁用失败: {0}{1} -> {2}' -f $t.TaskPath, $t.TaskName, $_.Exception.Message) 'WARN'
            throw
        }
    }
}

function Get-DouyinExecutables {
    $pending = New-Object Collections.Generic.Stack[string]
    $pending.Push($DouyinRoot)
    while ($pending.Count) {
        foreach ($item in (Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
            elseif ($item.Extension -eq '.exe' -and (Test-PathUnderRoot $item.FullName $DouyinRoot)) { $item.FullName }
        }
    }
}

function Ensure-DouyinFirewallCoverage {
    param([bool]$Block)
    $exes = @(Get-DouyinExecutables | Sort-Object -Unique)
    if (-not $exes.Count) { throw '安装目录内没有 exe，不能配置隔离。' }
    $rules = @(Get-DouyinFirewallRules)
    $byPath = @{}
    $stale = @()
    $prefix = $RulePrefix + ' ('
    foreach ($rule in ($rules | Sort-Object Name)) {
        $program = $rule.DisplayName.Substring($prefix.Length, $rule.DisplayName.Length - $prefix.Length - 1)
        if ($exes -notcontains $program -or $byPath.ContainsKey($program)) { $stale += $rule.Name }
        else { $byPath[$program] = $rule }
    }
    $filters = @{}
    if ($byPath.Count) {
        foreach ($filter in (Get-NetFirewallApplicationFilter -Program @($byPath.Keys) -ErrorAction Stop)) { $filters[[string]$filter.InstanceID] = [string]$filter.Program }
    }
    $enabled = 'False'
    if ($Block) { $enabled = 'True' }
    Clear-DouyinNetState
    foreach ($exe in $exes) {
        $displayName = '{0} ({1})' -f $RulePrefix, $exe
        if ($byPath.ContainsKey($exe)) {
            $rule = $byPath[$exe]
            if ($filters[[string]$rule.InstanceID] -ne $exe -or [string]$rule.Direction -ne 'Outbound' -or
                [string]$rule.Action -ne 'Block' -or [string]$rule.Profile -ne 'Any') {
                Set-NetFirewallRule -Name $rule.Name -Program $exe -Direction Outbound -Action Block -Profile Any -Enabled $enabled -ErrorAction Stop | Out-Null
            }
        } else {
            $name = 'DouyinCleanup-' + (Get-ContextHash ($CacheContext + '|' + $exe))
            New-NetFirewallRule -Name $name -DisplayName $displayName -Group 'DouyinCleanup' -Description 'Local Douyin session isolation' `
                -Direction Outbound -Program $exe -Action Block -Profile Any -Enabled $enabled -ErrorAction Stop | Out-Null
        }
    }
    if ($stale.Count) { Remove-NetFirewallRule -Name $stale -ErrorAction Stop }
    $verified = @(Get-DouyinFirewallRules)
    if ($verified.Count -ne $exes.Count) { throw '网络规则覆盖数量复查失败。' }
    $confirmedFilters = @{}
    foreach ($filter in (Get-NetFirewallApplicationFilter -Program $exes -ErrorAction Stop)) { $confirmedFilters[[string]$filter.InstanceID] = [string]$filter.Program }
    foreach ($rule in $verified) {
        $expected = $rule.DisplayName.Substring($prefix.Length, $rule.DisplayName.Length - $prefix.Length - 1)
        if ($confirmedFilters[[string]$rule.InstanceID] -ne $expected) { throw '网络规则程序路径复查失败。' }
    }
    return $exes.Count
}

function Set-DouyinFirewallBlock {
    $coverage = Ensure-DouyinFirewallCoverage -Block $true
    Set-DouyinFirewallRules -Block $true -Force | Out-Null
    Write-Log ('出站拦截已配置并复查：覆盖 {0} 个程序。' -f $coverage) 'OK'
}



# 读取缓存状态：blocked / allowed / none（确认未配置） / $null（未知）
function Get-DouyinNetState {
    if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
    try {
        $v = Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($v.Context -ne $CacheContext) { return $null }
        $age = ([DateTime]::UtcNow - [DateTime]::Parse($v.CheckedUtc).ToUniversalTime()).TotalSeconds
        if ($age -lt 0 -or $age -ge $StateCacheSeconds) { return $null }
        if ($v.State -in @('blocked', 'allowed', 'none')) { return $v.State }
    } catch { return $null }
    return $null
}

function Clear-DouyinNetState {
    if (Test-Path -LiteralPath $StateFile) { Remove-Item -LiteralPath $StateFile -Force -ErrorAction Stop }
}

function Save-DouyinNetState {
    param([string]$State)
    Write-AtomicJson -Path $StateFile -Value @{ State = $State; Context = $CacheContext; CheckedUtc = [DateTime]::UtcNow.ToString('o') }
}

function Get-DouyinFirewallRules {
    # 只查询本工具的规则；再次用字符串前缀过滤，避免自定义前缀内的通配符扩大范围。
    $displayPrefix = $RulePrefix + ' (' + $DouyinRoot + '\'
    $displayFilter = [WildcardPattern]::Escape($displayPrefix) + '*'
    return @(Get-NetFirewallRule -DisplayName $displayFilter -ErrorAction Stop |
        Where-Object { $_.DisplayName.StartsWith($displayPrefix, [StringComparison]::OrdinalIgnoreCase) -and $_.DisplayName.EndsWith(')') })
}

# 批量开关防火墙规则并复查；Watch 可复用短期缓存，手动操作强制查实。
function Set-DouyinFirewallRules {
    param([bool]$Block, [switch]$Force)

    $want = 'allowed'
    if ($Block) { $want = 'blocked' }

    if ((-not $Force) -and ((Get-DouyinNetState) -eq $want)) { return 0 }

    Clear-DouyinNetState
    $rules = @(Get-DouyinFirewallRules)
    if ($rules.Count -eq 0) {
        # 只有管理员才可能读到全部规则。非管理员读不到时不要误记成"未配置"，
        # 否则会把状态缓存写坏，导致 SYSTEM 看门狗以后一直跳过。
        if ($Block) { throw '没有配置出站拦截规则。请先执行 Lockdown。' }
        if (Test-IsAdmin) { Save-DouyinNetState -State 'none' }
        return 0
    }

    $changed = 0
    foreach ($r in $rules) {
        if ([string]$r.Direction -ne 'Outbound' -or [string]$r.Action -ne 'Block') {
            throw ('防火墙规则配置异常，拒绝把它当成拦截规则: {0}' -f $r.DisplayName)
        }
    }
    $names = @($rules | Where-Object { ([string]$_.Enabled -eq 'True') -ne $Block } | Select-Object -ExpandProperty Name)
    if ($names.Count -gt 0) {
        $enabled = 'False'
        if ($Block) { $enabled = 'True' }
        Set-NetFirewallRule -Name $names -Enabled $enabled -ErrorAction Stop | Out-Null
        $changed = $names.Count
    }
    $verified = @(Get-DouyinFirewallRules)
    if ($verified.Count -ne $rules.Count -or @($verified | Where-Object { ([string]$_.Enabled -eq 'True') -ne $Block }).Count -gt 0) {
        throw '防火墙状态复查失败，未写入成功缓存。'
    }
    Save-DouyinNetState -State $want
    return $changed
}

function Sync-DouyinFirewallState {
    param($Snapshot, [switch]$Force)

    # 已确认这台机器没有拦截规则时直接跳过
    if ((-not $Force) -and ((Get-DouyinNetState) -eq 'none')) { return }

    if (-not $Snapshot) { $Snapshot = Get-DouyinProcessSnapshot }

    $inUse = Test-DouyinInUse -Snapshot $Snapshot
    $changed = Set-DouyinFirewallRules -Block (-not $inUse) -Force:$Force

    if ($changed -gt 0) {
        if ($inUse) {
            Write-Log ('检测到抖音正在使用 → 已临时放行 {0} 条规则，保证你能正常刷视频。' -f $changed) 'INFO'
        }
        else {
            Write-Log ('抖音未运行 → 已启用 {0} 条出站拦截规则。' -f $changed) 'OK'
        }
    }
}

# ---------------------------------------------------------------- 一键会话

# 等抖音彻底退出。返回 $true=确实起来过又退出了；$false=压根没等到它启动
function Wait-DouyinExit {
    # 阶段 1：等抖音起来（最多 180 秒）
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $started = $false
    while ($sw.Elapsed.TotalSeconds -lt $StartupTimeoutSeconds) {
        if (Test-DouyinAliveFast) { $started = $true; break }
        Start-Sleep -Milliseconds 700
    }
    if (-not $started) { return $false }

    # 阶段 2：等后台主程序彻底退出；残留组件由后续收尾负责，不影响退出判断。
    while ($true) {
        Start-Sleep -Seconds 1
        if (Test-DouyinAliveFast) { continue }
        # 短暂确认，重开后继续守护。
        Start-Sleep -Seconds $ExitGraceSeconds
        if (Test-DouyinAliveFast) { continue }
        return $true
    }
}

function Get-ChildArguments {
    param([string]$ChildAction)
    return ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Action {1} -DouyinRoot "{2}" -TaskName "{3}" -RulePrefix "{4}" -SettleSeconds {5} -StartupTimeoutSeconds {6} -ExitGraceSeconds {7} -StateCacheSeconds {8} -DataRoot "{9}" -CleanupMaxPasses {10}' -f
        $ScriptPath, $ChildAction, $DouyinRoot, $TaskName, $RulePrefix, $SettleSeconds, $StartupTimeoutSeconds, $ExitGraceSeconds, $StateCacheSeconds, $DataRoot, $CleanupMaxPasses)
}

function Get-SessionWatchers {
    return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop | Where-Object {
        $_.ProcessId -ne $PID -and $_.CommandLine -and
        $_.CommandLine.IndexOf('"' + $ScriptPath + '"', [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $_.CommandLine -match '-Action\s+SessionWait(?:\s|$)' -and
        ($_.CommandLine.IndexOf('-DouyinRoot "' + $DouyinRoot + '"', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
         ($_.CommandLine -notmatch '-DouyinRoot')) -and
        ($_.CommandLine.IndexOf('-RulePrefix "' + $RulePrefix + '"', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
         ($RulePrefix -eq 'DouyinKiller-Block' -and $_.CommandLine -notmatch '-RulePrefix'))
    })
}

function New-ContextMutex {
    param([string]$Kind)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($CacheContext.ToLowerInvariant()))).Replace('-', '') }
    finally { $hasher.Dispose() }
    return New-Object Threading.Mutex($false, ('Global\DouyinCleanup-' + $Kind + '-' + $hash))
}

function Start-DouyinAsUser {
    param([Parameter(Mandatory)][string]$Executable)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.User.Value -eq 'S-1-5-18') { throw '不能从 SYSTEM 会话启动交互式抖音。请使用桌面入口。' }
    $launchTask = 'DouyinCleanupLaunch-' + [Guid]::NewGuid().ToString('N')
    $action = New-ScheduledTaskAction -Execute $Executable -WorkingDirectory $DouyinRoot
    $principal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    $registered = $false
    try {
        Register-ScheduledTask -TaskName $launchTask -TaskPath '\' -Action $action -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
        $registered = $true
        Start-ScheduledTask -TaskName $launchTask -TaskPath '\' -ErrorAction Stop
        $wait = [Diagnostics.Stopwatch]::StartNew()
        while ($wait.Elapsed.TotalSeconds -lt 15) {
            if (Test-DouyinAliveFast) { return }
            Start-Sleep -Milliseconds 250
        }
        throw '普通用户启动超时，未确认主程序启动。'
    } finally {
        if ($registered) { Unregister-ScheduledTask -TaskName $launchTask -TaskPath '\' -Confirm:$false -ErrorAction Stop }
    }
}

function Start-SessionWatcher {
    $readyName = 'Global\DouyinCleanup-Ready-' + [Guid]::NewGuid().ToString('N')
    $event = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $readyName)
    try {
        $arguments = (Get-ChildArguments -ChildAction SessionWait) + ' -ReadyEvent "' + $readyName + '"'
        $watcher = Start-Process -FilePath "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -WindowStyle Hidden -PassThru -ErrorAction Stop
        if (-not $event.WaitOne(10000)) { throw '收尾守护未确认就绪，启动失败。' }
        if ($watcher.HasExited -and $watcher.ExitCode -ne 0) { throw '收尾守护就绪后异常退出。' }
    } finally { $event.Dispose() }
}

# 一键看抖音：放行网络 -> 启动抖音 -> 挂一个隐藏守护，关掉抖音后自动收尾
function Invoke-Session {
    if (-not (Assert-Admin '一键会话')) { return }

    $alreadyRunning = Test-DouyinAliveFast
    $exe = Join-Path $DouyinRoot 'douyin.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { $exe = Join-Path $DouyinRoot 'new_douyin.exe' }
    if (-not $alreadyRunning -and (-not (Test-Path -LiteralPath $exe -PathType Leaf))) {
        throw ('找不到抖音入口程序: {0}，未放行网络。' -f $DouyinRoot)
    }

    try {
        Ensure-DouyinFirewallCoverage -Block $false | Out-Null
        $n = Set-DouyinFirewallRules -Block $false -Force
        Write-Log ('本工具的网络拦截已放行（本次停用 {0} 条规则）。' -f $n) 'OK'
        # 先确认守护已就绪，再启动应用，避免应用运行后没有收尾守护。
        # 每次都通过就绪协议确认；重复子进程在互斥锁验证后立即退出。
        Start-SessionWatcher
        Write-Log '收尾守护已确认就绪。' 'OK'
        if ($alreadyRunning) { Write-Log '主程序已运行，继续使用并自动收尾。' 'INFO' }
        else {
            Start-DouyinAsUser -Executable $exe
            Write-Log '已通过普通用户会话启动抖音。' 'OK'
        }
    } catch {
        $failure = $_
        Write-Log '启动或挂载守护失败，尝试恢复网络拦截。' 'ERROR'
        try { Set-DouyinFirewallRules -Block $true -Force | Out-Null }
        catch { Write-Log ('恢复拦截也失败: {0}' -f $_.Exception.Message) 'ERROR' }
        if (-not (Test-DouyinAliveFast)) {
            try { Invoke-ResidualCleanup -Silent | Out-Null }
            catch { Write-Log ('启动失败后的残留清理失败: {0}' -f $_.Exception.Message) 'ERROR' }
        }
        throw $failure
    }
}

# 由上面的守护进程调用：等退出 -> 断网 -> 清残留
function Invoke-SessionWait {
    Assert-Admin '会话守护' | Out-Null
    $watchMutex = New-ContextMutex -Kind Watcher
    $ownsWatcher = $false
    $operationMutex = $null
    $ownsOperation = $false
    try {
        try { $ownsWatcher = $watchMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsWatcher = $true }
        Signal-SessionReady -Name $ReadyEvent
        if (-not $ownsWatcher) { Write-Log '已有本目录的会话守护，不重复等待。' 'INFO'; return }
        while ($true) {
            $exited = Wait-DouyinExit
            # 等待期间不持有操作锁；收尾时与 Session / Unlock / Watch 串行。
            $operationMutex = New-ContextMutex -Kind Operation
            try { $ownsOperation = $operationMutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $ownsOperation = $true }
            if (-not $ownsOperation) { throw '收尾等待操作锁超时，请手动执行 Finish。' }
            if (-not $exited) { Write-Log ('会话守护：{0} 秒内没等到主程序启动，尝试收尾。' -f $StartupTimeoutSeconds) 'WARN' }
            if (-not (Test-DouyinAliveFast)) { Ensure-DouyinFirewallCoverage -Block $true | Out-Null }
            $r = Invoke-ResidualCleanup
            if (-not $r.InUse) {
                Write-Log ('收尾完成，共结束 {0} 个残留进程。' -f $r.Killed) 'OK'
                return
            }
            $operationMutex.ReleaseMutex()
            $ownsOperation = $false
            $operationMutex.Dispose()
            $operationMutex = $null
            # 清理期间又启动了新会话，继续守护，避免新会话无人收尾。
            Start-Sleep -Seconds 3
        }
    } finally {
        if ($ownsOperation) { $operationMutex.ReleaseMutex() }
        if ($operationMutex) { $operationMutex.Dispose() }
        if ($ownsWatcher) { $watchMutex.ReleaseMutex() }
        $watchMutex.Dispose()
    }
}

function Install-CleanupTask {
    Save-CleanupTaskBaseline
    $arg = Get-ChildArguments -ChildAction Watch
    $taskAction = New-ScheduledTaskAction -Execute "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $arg

    $triggers = @()
    $triggers += New-ScheduledTaskTrigger -AtStartup
    $triggers += New-ScheduledTaskTrigger -AtLogOn

    $desc = '开机 / 登录各跑一次收尾（不含轮询）'
    if ($WatchdogMode -eq 'Periodic') {
        $triggers += New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) `
            -RepetitionInterval (New-TimeSpan -Minutes $WatchIntervalMinutes) `
            -RepetitionDuration (New-TimeSpan -Days 3650)
        $desc = ('开机 / 登录各一次，之后每 {0} 分钟轮询一次' -f $WatchIntervalMinutes)
    }

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    try {
        Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Action $taskAction -Trigger $triggers `
            -Settings $settings -Principal $principal -Description ('DouyinCleanup: ' + (Get-ContextHash $CacheContext) + '; ' + $desc) -Force -ErrorAction Stop | Out-Null
        Write-Log ('已安装收尾任务 {0}：{1}' -f $TaskName, $desc) 'OK'
    }
    catch {
        Write-Log ('收尾任务安装失败: {0}' -f $_.Exception.Message) 'WARN'
        throw
    }
}

function Invoke-Lockdown {
    if (-not (Assert-Admin '锁定抖音自启')) { return }

    Write-Log '==================== 开始锁定抖音自启与网络 ====================' 'INFO'
    Save-RecoveryState (Get-RecoveryState)
    Save-CleanupTaskBaseline

    Write-Log '[1/4] 处理系统服务…' 'INFO'
    Disable-DouyinServices

    Write-Log '[2/4] 处理计划任务…' 'INFO'
    Disable-DouyinTasks

    Write-Log '[3/4] 配置防火墙出站拦截…' 'INFO'
    Set-DouyinFirewallBlock

    Write-Log '[4/4] 配置收尾任务…' 'INFO'
    if ($WatchdogMode -eq 'None') {
        Save-CleanupTaskBaseline
        $old = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
        if ($old) {
            Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
            Write-Log ('已移除旧的收尾任务 {0}（当前模式 None）' -f $TaskName) 'OK'
        }
        else {
            Write-Log '模式 None：不创建任何计划任务。' 'INFO'
        }
    }
    else {
        Install-CleanupTask
    }

    if ($HardMode) {
        Write-Log '开启 HardMode：拒绝对守护进程的执行权限…' 'INFO'
        foreach ($f in @('douyin_guard.exe')) {
            $full = Join-Path $DouyinRoot $f
            if (Test-Path -LiteralPath $full) {
                Save-AclBaseline -RelativePath $f
                & icacls $full /deny '*S-1-1-0:(X)' | Out-Null
                if ($LASTEXITCODE -ne 0) { throw ('HardMode 权限设置失败: {0}' -f $full) }
                Write-Log ('HardMode: 已禁止执行 {0}' -f $full) 'OK'
            }
        }
    }

    Write-Log '--------------------- 立即清理当前残留 ---------------------' 'INFO'
    Invoke-ResidualCleanup | Out-Null

    Write-Log '锁定配置完成。可用 Status 检查当前进程和规则状态。' 'OK'
    if ($WatchdogMode -eq 'None') {
        Write-Log '当前为完全手动模式：看抖音前跑 -Action Allow，看完跑 -Action Finish。' 'INFO'
    }
    elseif ($WatchdogMode -eq 'LogonOnly') {
        Write-Log '当前为手动模式（开机 / 登录会自动收尾一次，平时不轮询）。' 'INFO'
        Write-Log '看抖音前跑 -Action Allow，看完跑 -Action Finish。' 'INFO'
    }
    else {
        Write-Log ('当前为自动模式：每 {0} 分钟巡检一次，退出抖音后会自动收尾。' -f $WatchIntervalMinutes) 'INFO'
    }
}

# ---------------------------------------------------------------- 还原

function Invoke-Unlock {
    if (-not (Assert-Admin '还原设置')) { return }

    foreach ($watcher in (Get-SessionWatchers)) {
        $current = Get-CimInstance Win32_Process -Filter ('ProcessId={0}' -f $watcher.ProcessId) -ErrorAction Stop
        if ($current -and $current.CreationDate -eq $watcher.CreationDate -and $current.CommandLine -eq $watcher.CommandLine) {
            Stop-Process -Id $watcher.ProcessId -Force -ErrorAction Stop
        }
    }
    Restore-RecordedConfiguration
    Clear-DouyinNetState
    $rules = @(Get-DouyinFirewallRules)
    if ($rules.Count) { Remove-NetFirewallRule -Name @($rules.Name) -ErrorAction Stop }
    if (@(Get-DouyinFirewallRules).Count) { throw '防火墙规则删除后复查失败，保留恢复快照。' }
    if (Test-Path -LiteralPath $RecoveryFile) { Remove-Item -LiteralPath $RecoveryFile -Force -ErrorAction Stop }
    Write-Log '记录的启动配置和隔离已恢复；快捷方式用安装器的 -Revert 单独恢复。' 'OK'
}

# ---------------------------------------------------------------- 体检

function Show-Status {
    $lines = New-Object System.Collections.Generic.List[string]
    $add = { param($s) $lines.Add($s) }

    $snapshot = Get-DouyinProcessSnapshot
    $running = @($snapshot | Where-Object { $_.UnderRoot -or ((-not $_.PathKnown) -and (($SideCarNames -contains $_.Name) -or ($MainNames -contains $_.Name))) })

    & $add '============================================================'
    & $add '            抖音状态体检报告'
    & $add '============================================================'
    & $add ('时间     : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    & $add ('抖音目录 : ' + $DouyinRoot)
    & $add ('管理员   : ' + (Test-IsAdmin))
    & $add ''

    & $add '--- 1. 正在运行的抖音进程 ---'
    if ($running.Count -eq 0) {
        & $add '  (无)'
    }
    else {
        foreach ($p in ($running | Sort-Object -Property Name)) {
            $kind = '相关进程'
            if ($p.IsMain) { $kind = '主程序  ' }
            elseif ($p.IsSideCar) { $kind = '残留组件' }
            $pathText = $p.Path
            if (-not $pathText) {
                if ($SideCarNames -contains $p.Name) { $kind = '残留组件' }
                $pathText = '(路径不可读，以管理员运行可见)'
            }
            & $add ('  [{0}] {1,-34} PID={2,-7} {3}' -f $kind, $p.Name, $p.Pid, $pathText)
        }
    }
    & $add ''

    & $add '--- 2. 抖音相关系统服务 ---'
    $svcFound = $false
    foreach ($svc in $DouyinServices) {
        $s = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
        if ($s) {
            $svcFound = $true
            $mode = (Get-CimInstance Win32_Service -Filter ("Name='" + $svc.Name + "'") -ErrorAction SilentlyContinue).StartMode
            & $add ('  {0,-32} 状态={1,-8} 启动={2}' -f $svc.Name, $s.Status, $mode)
        }
    }
    if (-not $svcFound) { & $add '  (未发现抖音服务)' }
    & $add ''

    & $add '--- 3. 抖音相关计划任务 ---'
    $tasks = @(Get-DouyinRelatedTasks)
    if ($tasks.Count -eq 0) { & $add '  (无)' }
    else { foreach ($t in $tasks) { & $add ('  [{0,-8}] {1}{2}' -f $t.State, $t.TaskPath, $t.TaskName) } }
    & $add ''

    & $add '--- 4. 收尾任务 ---'
    $wd = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($wd) {
        & $add ('  {0}: {1}' -f $TaskName, $wd.State)
        $rep = @($wd.Triggers | Where-Object { $_.Repetition -and $_.Repetition.Interval })
        if ($rep.Count -gt 0) { & $add '  模式: 自动轮询（Periodic）' } else { & $add '  模式: 仅开机 / 登录收尾（LogonOnly，无轮询）' }
    }
    elseif (-not (Test-IsAdmin)) {
        # 非管理员身份下，SYSTEM/最高权限注册的任务可能读不到，别误报成"未安装"
        & $add ('  {0}: 读取不到（需以管理员身份运行才能确认）' -f $TaskName)
    }
    else {
        & $add '  (未安装 —— 当前为完全手动模式)'
    }
    & $add ''

    & $add '--- 5. 防火墙出站拦截规则 ---'
    $rules = @()
    $firewallReadable = $true
    try { $rules = @(Get-DouyinFirewallRules) } catch { $firewallReadable = $false }
    if (-not $firewallReadable) {
        & $add '  无法读取防火墙规则，请以管理员身份体检；不能据此判断未配置。'
    }
    elseif ($rules.Count -eq 0) {
        & $add '  共 0 条（尚未配置网络隔离）'
    }
    else {
        $on = @($rules | Where-Object { [string]$_.Enabled -eq 'True' }).Count
        $off = $rules.Count - $on
        & $add ('  共 {0} 条：生效 {1} 条 / 临时放行 {2} 条' -f $rules.Count, $on, $off)
        if ($off -gt 0) { & $add '  存在停用规则；是否会自动恢复取决于会话守护或轮询任务是否正常运行。' }
    }
    & $add ''

    & $add '--- 6. 结论 ---'
    if (Test-DouyinInUse -Snapshot $snapshot) {
        & $add '  抖音主程序当前在运行（或仍在后台未完全退出），脚本不会动任何进程。'
    }
    elseif ($running.Count -gt 0) {
        & $add '  [有问题] 主程序已退出，但仍检测到残留进程。'
        & $add '           建议执行: .\DouyinKiller.ps1 -Action Lockdown'
    }
    else {
        & $add '  未检测到任何抖音进程，环境干净。'
    }
    & $add '============================================================'

    $text = Protect-PrivateText ($lines -join "`r`n")
    if (-not $IsWatch) { Write-Host $text }
    if ($SaveStatus) {
        New-Item -ItemType Directory -Path $ContextDir -Force -ErrorAction Stop | Out-Null
        Set-Content -LiteralPath $StatusFile -Value $text -Encoding UTF8 -ErrorAction Stop
    }
}

# ---------------------------------------------------------------- 入口

# Watch 模式稳态下零日志写入，只有真的发生动作才落盘
if (-not $IsWatch -and $Action -ne 'Status') {
    Write-Log ('DouyinKiller 启动 | Action={0} | Admin={1} | Root={2}' -f $Action, (Test-IsAdmin), $DouyinRoot) 'INFO'
}

$exitCode = 0
$entryMutex = $null
$ownsEntryMutex = $false
try {
    if ($Action -ne 'Status') { Assert-Admin $Action | Out-Null }
    if ($Action -notin @('Status', 'SessionWait')) {
        $entryMutex = New-ContextMutex -Kind Operation
        try { $ownsEntryMutex = $entryMutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $ownsEntryMutex = $true }
        if (-not $ownsEntryMutex) { throw '有其他操作尚未完成，等待超时。请稍后重试。' }
    }
    switch ($Action) {
        'Status' { Show-Status }
        'Clean' {
            if (Assert-Admin '清理残留进程') {
                $r = Invoke-ResidualCleanup
                if (-not $r.InUse) { Write-Log ('清理结束，共结束 {0} 个进程。' -f $r.Killed) 'OK' }
            }
        }
        'Lockdown' { Invoke-Lockdown }
        'Unlock' { Invoke-Unlock }
        'Watch' { Invoke-ResidualCleanup -Silent | Out-Null }
        'Allow' {
            if (Assert-Admin '放行抖音网络') {
            Ensure-DouyinFirewallCoverage -Block $false | Out-Null
                $n = Set-DouyinFirewallRules -Block $false -Force
                Write-Log ('本工具的网络拦截已放行（本次停用 {0} 条规则）。' -f $n) 'OK'
            }
        }
        'Block' {
            if (Assert-Admin '拦截抖音网络') {
            Ensure-DouyinFirewallCoverage -Block $true | Out-Null
                $n = Set-DouyinFirewallRules -Block $true -Force
                Write-Log ('本工具的出站拦截已启用（本次启用 {0} 条规则）。' -f $n) 'OK'
            }
        }
        'Finish' {
            # 清理函数先确认主程序已退出，再断网，最后结束残留。
            if (Assert-Admin '收尾') {
                $r = Invoke-ResidualCleanup
                if (-not $r.InUse) { Write-Log ('收尾完成，共结束 {0} 个残留进程。' -f $r.Killed) 'OK' }
            }
        }
        'Session' { Invoke-Session }
        'SessionWait' { Invoke-SessionWait }
    }
} catch {
    $exitCode = 1
    Write-Log $_.Exception.Message 'ERROR'
} finally {
    if ($ownsEntryMutex) { $entryMutex.ReleaseMutex() }
    if ($entryMutex) { $entryMutex.Dispose() }
}

if (-not $IsWatch -and $Action -ne 'Status') {
    Write-Host ''
    Write-Host '日志保存在本机数据目录，未写入项目。' -ForegroundColor DarkGray
}
exit $exitCode
