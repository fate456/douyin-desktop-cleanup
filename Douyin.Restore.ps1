#Requires -Version 5.1
# Changes are recorded before applying them. Recovery files live outside the source tree.

function Get-RecoveryState {
    if (-not (Test-Path -LiteralPath $RecoveryFile -PathType Leaf)) {
        return [pscustomobject]@{ Version = 1; Context = $CacheContext; Services = @(); Tasks = @(); Acls = @(); CleanupTask = $null }
    }
    $state = Read-JsonFile -Path $RecoveryFile
    if ($state.Version -ne 1 -or $state.Context -ne $CacheContext) { throw '恢复快照版本或安装位置不匹配，拒绝继续修改。' }
    foreach ($property in @('Services', 'Tasks', 'Acls', 'CleanupTask')) {
        if (-not $state.PSObject.Properties[$property]) { throw '恢复快照不完整，拒绝继续修改。' }
    }
    foreach ($entry in @($state.Services)) {
        if ($entry.Name -notmatch '^[\w.-]+$' -or $entry.StartMode -notin @('Auto', 'Manual', 'Disabled') -or
            $entry.DelayedPresent -isnot [bool] -or $entry.DelayedValue -notin @(0, 1)) { throw '服务恢复记录无效。' }
    }
    foreach ($entry in @($state.Tasks)) {
        if (-not $entry.Name -or $entry.Name -match '[\\/*?\[\]]' -or $entry.Path -notmatch '^\\.*\\$|^\\$' -or $entry.Enabled -isnot [bool]) { throw '任务恢复记录无效。' }
    }
    foreach ($entry in @($state.Acls)) {
        if ($entry.RelativePath -ne 'douyin_guard.exe') { throw 'ACL 恢复目标无效。' }
        [Security.AccessControl.RawSecurityDescriptor]::new([string]$entry.AccessSddl) | Out-Null
    }
    if ($state.CleanupTask) {
        if ($state.CleanupTask.Name -ne $TaskName -or $state.CleanupTask.Existed -isnot [bool]) { throw '收尾任务恢复记录无效。' }
        if ($state.CleanupTask.Existed) {
            if (-not $state.CleanupTask.Xml) { throw '收尾任务 XML 恢复记录为空。' }
            $xml = [xml]$state.CleanupTask.Xml
            if (-not $xml.DocumentElement -or $xml.DocumentElement.LocalName -ne 'Task') { throw '收尾任务 XML 恢复记录无效。' }
        }
    }
    return $state
}

function Save-RecoveryState {
    param($State)
    Write-AtomicJson -Path $RecoveryFile -Value $State
}

function Get-DouyinServiceTargets {
    foreach ($service in (Get-CimInstance Win32_Service -ErrorAction Stop)) {
        $isKnown = @($DouyinServices | Where-Object { $_.Name -eq $service.Name }).Count -gt 0
        $isOwned = $service.PathName -match ('(?i)(?:^|")' + [regex]::Escape($DouyinRoot + '\'))
        if ($isKnown -and -not $isOwned) {
            $parameters = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $service.Name + '\Parameters'
            $value = Get-ItemProperty -LiteralPath $parameters -Name ServiceDll -ErrorAction SilentlyContinue
            if ($value -and $value.ServiceDll) { $isOwned = Test-PathUnderRoot -Path ([Environment]::ExpandEnvironmentVariables([string]$value.ServiceDll)) -Root $DouyinRoot }
        }
        if ($isOwned) { $service }
    }
}

function Save-ServiceBaseline {
    param($Service)
    $state = Get-RecoveryState
    if (@($state.Services | Where-Object { $_.Name -eq $Service.Name }).Count) { return }
    $registryPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $Service.Name
    $registry = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
    $delayed = $registry.PSObject.Properties['DelayedAutoStart']
    $state.Services = @($state.Services) + [pscustomobject]@{
        Name = $Service.Name; StartMode = $Service.StartMode
        DelayedPresent = [bool]$delayed; DelayedValue = $(if ($delayed) { [int]$delayed.Value } else { 0 })
    }
    Save-RecoveryState $state
}

function Save-TaskBaseline {
    param($Task)
    $state = Get-RecoveryState
    if (@($state.Tasks | Where-Object { $_.Name -eq $Task.TaskName -and $_.Path -eq $Task.TaskPath }).Count) { return }
    $state.Tasks = @($state.Tasks) + [pscustomobject]@{ Name = $Task.TaskName; Path = $Task.TaskPath; Enabled = ($Task.State -ne 'Disabled') }
    Save-RecoveryState $state
}

function Save-AclBaseline {
    param([string]$RelativePath)
    $full = [IO.Path]::GetFullPath((Join-Path $DouyinRoot $RelativePath))
    if (-not (Test-PathUnderRoot $full $DouyinRoot)) { throw 'ACL target escaped installation directory.' }
    $state = Get-RecoveryState
    if (@($state.Acls | Where-Object { $_.RelativePath -eq $RelativePath }).Count) { return }
    $acl = Get-Acl -LiteralPath $full -ErrorAction Stop
    $state.Acls = @($state.Acls) + [pscustomobject]@{ RelativePath = $RelativePath; AccessSddl = $acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access) }
    Save-RecoveryState $state
}

function Save-CleanupTaskBaseline {
    $state = Get-RecoveryState
    $existing = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($existing -and -not (Test-CleanupTaskOwned $existing)) { throw '已有同名的其他计划任务，拒绝覆盖。请使用其他 TaskName。' }
    if ($null -ne $state.CleanupTask) { return }
    $xml = $null
    if ($existing) { $xml = Export-ScheduledTask -InputObject $existing -ErrorAction Stop }
    $state.CleanupTask = [pscustomobject]@{ Name = $TaskName; Existed = [bool]$existing; Xml = $xml }
    Save-RecoveryState $state
}

function Test-CleanupTaskOwned {
    param($Task)
    $expectedExecutable = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $tag = 'DouyinCleanup: ' + (Get-ContextHash $CacheContext) + ';'
    foreach ($action in $Task.Actions) {
        if ($action.Execute -ne $expectedExecutable -and $action.Execute -ne 'powershell.exe') { continue }
        if (-not $action.Arguments -or $action.Arguments -notmatch '-Action\s+Watch(?:\s|$)') { continue }
        if ($action.Arguments.IndexOf('"' + $ScriptPath + '"', [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        if ($Task.Description -and $Task.Description.StartsWith($tag, [StringComparison]::OrdinalIgnoreCase) -and
            $action.Arguments.IndexOf('-DouyinRoot "' + $DouyinRoot + '"', [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            $action.Arguments.IndexOf('-RulePrefix "' + $RulePrefix + '"', [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

function Restore-RecordedConfiguration {
    if (-not (Test-Path -LiteralPath $RecoveryFile -PathType Leaf)) {
        Write-Log '没有修改前快照：仅移除本工具的隔离；服务和第三方任务保持现状，避免伪造原始配置。' 'WARN'
        $watchTask = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
        if ($watchTask -and (Test-CleanupTaskOwned $watchTask)) {
            Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
        }
        return
    }
    $state = Get-RecoveryState
    foreach ($entry in @($state.Services)) {
        if ($entry.Name -notmatch '^[\w.-]+$' -or $entry.StartMode -notin @('Auto', 'Manual', 'Disabled')) { throw '服务恢复快照无效。' }
        if (-not (Get-Service -Name $entry.Name -ErrorAction SilentlyContinue)) { continue }
        $startupType = @{ Auto = 'Automatic'; Manual = 'Manual'; Disabled = 'Disabled' }[$entry.StartMode]
        Set-Service -Name $entry.Name -StartupType $startupType -ErrorAction Stop
        $registryPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $entry.Name
        if ($entry.DelayedPresent) { Set-ItemProperty -LiteralPath $registryPath -Name DelayedAutoStart -Value ([int]$entry.DelayedValue) -ErrorAction Stop }
        else { Remove-ItemProperty -LiteralPath $registryPath -Name DelayedAutoStart -ErrorAction SilentlyContinue }
        Write-Log ('已恢复服务启动配置: {0}' -f $entry.Name) 'OK'
    }
    foreach ($entry in @($state.Tasks)) {
        if (-not $entry.Name -or $entry.Path -notmatch '^\\') { throw '任务恢复快照无效。' }
        $task = Get-ScheduledTask -TaskName $entry.Name -TaskPath $entry.Path -ErrorAction SilentlyContinue
        if (-not $task) { continue }
        if ($entry.Enabled) { Enable-ScheduledTask -TaskName $entry.Name -TaskPath $entry.Path -ErrorAction Stop | Out-Null }
        else { Disable-ScheduledTask -TaskName $entry.Name -TaskPath $entry.Path -ErrorAction Stop | Out-Null }
        Write-Log ('已恢复任务启用状态: {0}' -f $entry.Name) 'OK'
    }
    foreach ($entry in @($state.Acls)) {
        $full = [IO.Path]::GetFullPath((Join-Path $DouyinRoot $entry.RelativePath))
        if (-not (Test-PathUnderRoot $full $DouyinRoot)) { throw 'ACL 恢复路径越界。' }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $acl = Get-Acl -LiteralPath $full -ErrorAction Stop
        $acl.SetSecurityDescriptorSddlForm($entry.AccessSddl, [Security.AccessControl.AccessControlSections]::Access)
        Set-Acl -LiteralPath $full -AclObject $acl -ErrorAction Stop
    }
    if ($state.CleanupTask) {
        $entry = $state.CleanupTask
        if ($entry.Name -ne $TaskName) { throw '收尾任务恢复快照名称不匹配。' }
        $task = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
        if ($task -and -not (Test-CleanupTaskOwned $task)) { throw '收尾任务已被其他配置替换，拒绝覆盖。' }
        if ($entry.Existed) { Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Xml $entry.Xml -Force -ErrorAction Stop | Out-Null }
        elseif ($task) { Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' -Confirm:$false -ErrorAction Stop }
    }
}
