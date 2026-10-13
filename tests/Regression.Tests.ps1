#Requires -Version 5.1
# Runs production functions with mocked OS calls. Never launches Douyin or changes system settings.
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$source = Join-Path $project 'DouyinKiller.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join '; ') }
$definitions = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($module in @('Douyin.Common.ps1', 'Douyin.Restore.ps1')) {
    $moduleErrors = $null
    $moduleTokens = $null
    $moduleAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $project $module), [ref]$moduleTokens, [ref]$moduleErrors)
    if ($moduleErrors.Count) { throw ($moduleErrors.Message -join '; ') }
    $definitions += $moduleAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
}
$assignments = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] }, $false)
$passed = 0
$failed = 0

function Assert-True { param($Condition, [string]$Message = 'Assertion failed'); if (-not $Condition) { throw $Message } }
function Assert-Throws { param([scriptblock]$Body); $threw = $false; try { & $Body | Out-Null } catch { $threw = $true }; Assert-True $threw 'Expected a failure' }
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & {
            foreach ($def in $definitions) { Invoke-Expression $def.Extent.Text }
            foreach ($var in @('SideCarNames', 'MainNames', 'DouyinServices', 'DouyinProcessNames')) {
                $statement = $assignments | Where-Object { $_.Left.Extent.Text -eq ('$' + $var) } | Select-Object -First 1
                Invoke-Expression $statement.Extent.Text
            }
            $DouyinRoot = 'C:\douyin'
            $RulePrefix = 'DouyinKiller-Block'
            $TaskName = 'DouyinResidualCleanup'
            $ScriptPath = $source
            $CacheContext = $DouyinRoot + '|' + $RulePrefix
            $Action = 'Clean'
            $SettleSeconds = 0
            $StartupTimeoutSeconds = 1
            $ExitGraceSeconds = 1
            $StateCacheSeconds = 60
            $CleanupMaxPasses = 5
            $DataRoot = Join-Path ([IO.Path]::GetTempPath()) 'DouyinMockData'
            $ReadyEvent = ''
            function Write-Log { param($Message, $Level) }
            function Start-Sleep { param($Seconds, $Milliseconds) }
            function Test-IsAdmin { return $true }
            # Unmocked destructive OS calls fail closed.
            function Stop-Process { throw 'Unexpected real process termination' }
            function Start-Process { throw 'Unexpected real process launch' }
            function Set-NetFirewallRule { throw 'Unexpected real firewall mutation' }
            function New-NetFirewallRule { throw 'Unexpected real firewall creation' }
            function Remove-NetFirewallRule { throw 'Unexpected real firewall deletion' }
            function Stop-Service { throw 'Unexpected real service mutation' }
            function Set-Service { throw 'Unexpected real service mutation' }
            function Register-ScheduledTask { throw 'Unexpected real task registration' }
            function Disable-ScheduledTask { throw 'Unexpected real task mutation' }
            function Enable-ScheduledTask { throw 'Unexpected real task mutation' }
            function Unregister-ScheduledTask { throw 'Unexpected real task deletion' }
            & $Body
        }
        $script:passed++
        Write-Host ('PASS ' + $Name)
    } catch {
        $script:failed++
        Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message) -ForegroundColor Red
    }
}

Test-Case 'Sidecars do not keep the session alive' {
    function Get-Process { param($Name); if ($Name -contains 'douyin_guard') { [pscustomobject]@{ Path = 'C:\douyin\douyin_guard.exe' } } }
    Assert-True (-not (Test-DouyinAliveFast))
}
Test-Case 'Same main name outside the installation is ignored' {
    function Get-Process { [pscustomobject]@{ Path = 'C:\other\douyin.exe' } }
    Assert-True (-not (Test-DouyinAliveFast))
    Assert-True (-not (Test-DouyinInUse @([pscustomobject]@{ Name = 'douyin.exe'; PathKnown = $true; UnderRoot = $false })))
}
Test-Case 'Unreadable main path prevents cleanup' {
    function Get-Process { [pscustomobject]@{ Path = $null } }
    Assert-True (Test-DouyinAliveFast)
}
Test-Case 'Unknown or foreign crash reporter paths are never selected' {
    $items = @(
        [pscustomobject]@{ Name = 'tt_crash_reporter.exe'; PathKnown = $false; UnderRoot = $false; IsMain = $false; IsSideCar = $false },
        [pscustomobject]@{ Name = 'tt_crash_reporter.exe'; PathKnown = $true; UnderRoot = $false; IsMain = $false; IsSideCar = $false }
    )
    Assert-True (@(Select-RemovableProcess $items).Count -eq 0)
}
Test-Case 'Unlisted installation worker is cleaned after main exits' {
    $worker = [pscustomobject]@{ Name = 'future_update_worker.exe'; PathKnown = $true; UnderRoot = $true; IsMain = $false; IsSideCar = $false }
    Assert-True (-not (Test-DouyinInUse @($worker)))
    Assert-True (@(Select-RemovableProcess @($worker)).Count -eq 1)
}
Test-Case 'Remaining installation worker prevents a successful completion' {
    $script:scans = 0
    function Get-DouyinProcessSnapshot {
        $script:scans++
        [pscustomobject]@{ Pid = 42; Name = 'future_update_worker.exe'; PathKnown = $true; UnderRoot = $true; IsMain = $false; IsSideCar = $false }
    }
    function Test-DouyinAliveFast { return $false }
    function Stop-VerifiedResidual { return $true }
    $failure = ''
    try { Invoke-ResidualCleanup } catch { $failure = $_.Exception.Message }
    Assert-True ($failure -like '*5*')
    Assert-True ($script:scans -eq 6)
}
Test-Case 'Main exit is detected even while guard remains' {
    $script:checks = 0
    function Test-DouyinAliveFast { $script:checks++; return ($script:checks -eq 1) }
    Assert-True (Wait-DouyinExit)
    Assert-True ($script:checks -eq 3)
}
Test-Case 'Reopen within grace period keeps the watcher waiting' {
    $script:checks = 0
    function Test-DouyinAliveFast { $script:checks++; return ($script:checks -in @(1, 3)) }
    Assert-True (Wait-DouyinExit)
    Assert-True ($script:checks -eq 5)
}
Test-Case 'Startup timeout is reported without an infinite wait' {
    $StartupTimeoutSeconds = 0.01
    function Test-DouyinAliveFast { return $false }
    Assert-True (-not (Wait-DouyinExit))
}
Test-Case 'PID reuse is rejected before termination' {
    $old = [pscustomobject]@{ Pid = 42; Path = 'C:\douyin\douyin_guard.exe'; Created = [datetime]'2026-01-01' }
    function Get-CimInstance { [pscustomobject]@{ ExecutablePath = 'C:\other\tool.exe'; CreationDate = [datetime]'2026-01-02' } }
    Assert-True (-not (Stop-VerifiedResidual $old))
}
Test-Case 'Matching process identity can be terminated' {
    $old = [pscustomobject]@{ Pid = 42; Path = 'C:\douyin\douyin_guard.exe'; Created = [datetime]'2026-01-01' }
    $script:stops = 0
    function Get-CimInstance { [pscustomobject]@{ ExecutablePath = 'C:\douyin\douyin_guard.exe'; CreationDate = [datetime]'2026-01-01' } }
    function Stop-Process { $script:stops++ }
    Assert-True (Stop-VerifiedResidual $old)
    Assert-True ($script:stops -eq 1)
}
Test-Case 'Reopen before second cleanup preserves the new session' {
    $SettleSeconds = 1
    $script:scans = 0
    $script:stops = 0
    function Get-DouyinProcessSnapshot {
        $script:scans++
        if ($script:scans -eq 1) { [pscustomobject]@{ Pid = 42; Name = 'douyin_guard.exe'; IsSideCar = $true; UnderRoot = $true; PathKnown = $true } }
        else { [pscustomobject]@{ Pid = 43; Name = 'douyin.exe'; IsSideCar = $false; UnderRoot = $true; PathKnown = $true } }
    }
    function Test-DouyinAliveFast { return $false }
    function Stop-VerifiedResidual { $script:stops++; return $true }
    function Sync-DouyinFirewallState { throw 'Clean must not touch firewall' }
    $result = Invoke-ResidualCleanup
    Assert-True ($result.InUse -and $script:stops -eq 1)
}
Test-Case 'Firewall mutation failure invalidates cache' {
    $script:cleared = 0
    $script:saveCalled = $false
    function Clear-DouyinNetState { $script:cleared++ }
    function Get-DouyinFirewallRules { [pscustomobject]@{ Name = 'r1'; Enabled = 'False'; Direction = 'Outbound'; Action = 'Block' } }
    function Set-NetFirewallRule { throw 'Access denied' }
    function Save-DouyinNetState { $script:saveCalled = $true }
    Assert-Throws { Set-DouyinFirewallRules -Block $true -Force }
    Assert-True ($script:cleared -eq 1)
    Assert-True (-not $script:saveCalled)
}
Test-Case 'Firewall verification catches silently ignored changes' {
    $script:saveCalled = $false
    function Clear-DouyinNetState {}
    function Get-DouyinFirewallRules { [pscustomobject]@{ Name = 'r1'; Enabled = 'False'; Direction = 'Outbound'; Action = 'Block' } }
    function Set-NetFirewallRule {}
    function Save-DouyinNetState { $script:saveCalled = $true }
    Assert-Throws { Set-DouyinFirewallRules -Block $true -Force }
    Assert-True (-not $script:saveCalled)
}
Test-Case 'Firewall changes are batched and checked before caching' {
    $script:updated = $false
    $script:saved = $null
    function Clear-DouyinNetState {}
    function Get-DouyinFirewallRules {
        $enabled = 'False'; if ($script:updated) { $enabled = 'True' }
        foreach ($n in @('r1', 'r2')) { [pscustomobject]@{ Name = $n; Enabled = $enabled; Direction = 'Outbound'; Action = 'Block' } }
    }
    function Set-NetFirewallRule { param($Name, $Enabled); Assert-True ($Name.Count -eq 2 -and $Enabled -eq 'True'); $script:updated = $true }
    function Save-DouyinNetState { param($State); $script:saved = $State }
    Assert-True ((Set-DouyinFirewallRules -Block $true -Force) -eq 2)
    Assert-True ($script:saved -eq 'blocked')
}
Test-Case 'Blocking without rules cannot report success' {
    function Clear-DouyinNetState {}
    function Get-DouyinFirewallRules {}
    Assert-Throws { Set-DouyinFirewallRules -Block $true -Force }
}
Test-Case 'Lockdown enables already existing disabled rules' {
    $DouyinRoot = $project
    $RulePrefix = 'mock'
    $script:enabledExisting = $false
    function Clear-DouyinNetState {}
    function Ensure-DouyinFirewallCoverage { param($Block); Assert-True $Block; return 1 }
    function Set-DouyinFirewallRules { param($Block, [switch]$Force); $script:enabledExisting = $Block -and $Force }
    Set-DouyinFirewallBlock
    Assert-True $script:enabledExisting
}
Test-Case 'Custom configuration is forwarded to child processes' {
    $DouyinRoot = 'C:\custom app'
    $TaskName = 'CustomTask'
    $RulePrefix = 'CustomRule'
    $SettleSeconds = 2
    $arg = Get-ChildArguments SessionWait
    Assert-True ($arg.Contains('-DouyinRoot "C:\custom app"') -and $arg.Contains('-TaskName "CustomTask"') -and $arg.Contains('-RulePrefix "CustomRule"') -and $arg.Contains('-SettleSeconds 2'))
}
Test-Case 'Firewall discovery is scoped to the installation directory' {
    function Get-NetFirewallRule {
        [pscustomobject]@{ DisplayName = 'DouyinKiller-Block (C:\douyin\douyin.exe)' }
        [pscustomobject]@{ DisplayName = 'DouyinKiller-Block (C:\douyin-other\douyin.exe)' }
        [pscustomobject]@{ DisplayName = 'DouyinKiller-Block (C:\other\douyin.exe)' }
    }
    $rules = @(Get-DouyinFirewallRules)
    Assert-True ($rules.Count -eq 1 -and $rules[0].DisplayName -eq 'DouyinKiller-Block (C:\douyin\douyin.exe)')
}
Test-Case 'Missing entry executable does not open the firewall' {
    $DouyinRoot = 'C:\missing-installation-for-test'
    function Get-DouyinProcessSnapshot {}
    function Test-DouyinAliveFast { return $false }
    function Set-DouyinFirewallRules { throw 'Firewall must not be touched' }
    $message = ''
    try { Invoke-Session } catch { $message = $_.Exception.Message }
    Assert-True ($message -like '*C:\missing-installation-for-test*')
}
Test-Case 'Application launch failure restores network blocking' {
    $script:transitions = @()
    function Test-DouyinAliveFast { return $false }
    function Test-Path { return $true }
    function Ensure-DouyinFirewallCoverage { return 1 }
    function Get-SessionWatchers { [pscustomobject]@{ ProcessId=42 } }
    function Start-SessionWatcher {}
    function Start-DouyinAsUser { throw 'Launch failed' }
    function Invoke-ResidualCleanup {}
    function Set-DouyinFirewallRules { param($Block); $script:transitions += $Block; return 0 }
    function Start-Process { throw 'Launch failed' }
    Assert-Throws { Invoke-Session }
    Assert-True ($script:transitions.Count -eq 2 -and -not $script:transitions[0] -and $script:transitions[1])
}
Test-Case 'Watcher launch failure restores network blocking' {
    $script:transitions = @()
    function Test-DouyinAliveFast { return $true }
    function Test-Path { return $true }
    function Ensure-DouyinFirewallCoverage { return 1 }
    function Set-DouyinFirewallRules { param($Block); $script:transitions += $Block; return 0 }
    function Get-SessionWatchers {}
    function Start-Process { throw 'Watcher launch failed' }
    function Invoke-ResidualCleanup {}
    Assert-Throws { Invoke-Session }
    Assert-True ($script:transitions.Count -eq 2 -and -not $script:transitions[0] -and $script:transitions[1])
}
Test-Case 'Application launch uses a limited interactive task and removes it' {
    $script:removed=0
    function New-ScheduledTaskAction { param($Execute,$WorkingDirectory); Assert-True ($Execute -eq 'C:\douyin\douyin.exe'); return 'action' }
    function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel); Assert-True ($LogonType -eq 'Interactive' -and $RunLevel -eq 'Limited'); return 'principal' }
    function New-ScheduledTaskSettingsSet { return 'settings' }
    function Register-ScheduledTask {}
    function Start-ScheduledTask {}
    function Test-DouyinAliveFast { return $true }
    function Unregister-ScheduledTask { $script:removed++ }
    Start-DouyinAsUser 'C:\douyin\douyin.exe'
    Assert-True ($script:removed -eq 1)
}
Test-Case 'Task discovery ignores unrelated cleanup scripts' {
    function Get-ScheduledTask {
        [pscustomobject]@{ TaskName = 'OtherCleanup'; TaskPath = '\'; Actions = @([pscustomobject]@{ Execute = 'powershell.exe'; Arguments = '-File C:\SampleTools\cleanup\tool.ps1' }) }
        [pscustomobject]@{ TaskName = 'Guard'; TaskPath = '\DouyinUser\Guard\'; Actions = @([pscustomobject]@{ Execute = 'C:\douyin\douyin_guard.exe'; Arguments = '' }) }
    }
    $found = @(Get-DouyinRelatedTasks)
    Assert-True ($found.Count -eq 1 -and $found[0].TaskName -eq 'Guard')
}
Test-Case 'Cached state expires and is scoped to the configured root' {
    $taskTemp = Join-Path ([IO.Path]::GetTempPath()) ('DouyinRegression-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $taskTemp | Out-Null
    $StateFile = Join-Path $taskTemp 'state.txt'
    try {
        Save-DouyinNetState blocked
        Assert-True ((Get-DouyinNetState) -eq 'blocked')
        $CacheContext = 'different installation'
        Assert-True ($null -eq (Get-DouyinNetState))
        $CacheContext = $DouyinRoot + '|' + $RulePrefix
        $StateCacheSeconds = 0
        Assert-True ($null -eq (Get-DouyinNetState))
        Set-Content -LiteralPath $StateFile -Value 'blocked'
        Assert-True ($null -eq (Get-DouyinNetState))
    } finally {
        Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $taskTemp -Force
    }
}
Test-Case 'Context mutex supports exclusive ownership' {
    $CacheContext = 'Regression-' + [Guid]::NewGuid().ToString('N')
    $mutex = New-ContextMutex Operation
    $held = $false
    try { $held = $mutex.WaitOne(0); Assert-True $held } finally { if ($held) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

Test-Case 'Transient cleanup failure is retried and zero verified' {
    $script:scans = 0; $script:stops = 0
    function Get-DouyinProcessSnapshot {
        $script:scans++
        if ($script:scans -lt 3) { [pscustomobject]@{ Pid=42; Name='future_worker.exe'; UnderRoot=$true; PathKnown=$true; IsMain=$false } }
    }
    function Test-DouyinAliveFast { return $false }
    function Stop-VerifiedResidual { $script:stops++; if ($script:stops -eq 1) { throw 'Transient failure' }; return $true }
    $result = Invoke-ResidualCleanup
    Assert-True ($result.Killed -eq 1 -and -not $result.InUse -and $script:stops -eq 2)
}
Test-Case 'Unknown path cannot be reported as zero processes' {
    function Get-DouyinProcessSnapshot { [pscustomobject]@{ Name='douyin_guard.exe'; UnderRoot=$false; PathKnown=$false; IsMain=$false } }
    Assert-Throws { Invoke-ResidualCleanup }
}
Test-Case 'Guardian is terminated before workers regardless of PID' {
    $script:scans=0; $script:order=@()
    function Get-DouyinProcessSnapshot {
        $script:scans++
        if ($script:scans -eq 1) {
            [pscustomobject]@{ Pid=10; Name='worker.exe'; UnderRoot=$true; PathKnown=$true; IsMain=$false }
            [pscustomobject]@{ Pid=99; Name='douyin_guard.exe'; UnderRoot=$true; PathKnown=$true; IsMain=$false }
        }
    }
    function Test-DouyinAliveFast { return $false }
    function Stop-VerifiedResidual { param($Target); $script:order += $Target.Name; return $true }
    Invoke-ResidualCleanup | Out-Null
    Assert-True ($script:order[0] -eq 'douyin_guard.exe')
}
Test-Case 'Firewall coverage adds new files and prunes obsolete rules' {
    $script:rules = @([pscustomobject]@{ Name='old'; InstanceID='old'; DisplayName='DouyinKiller-Block (C:\douyin\old.exe)'; Direction='Outbound'; Action='Block'; Profile='Any' })
    function Get-DouyinExecutables { 'C:\douyin\douyin.exe'; 'C:\douyin\new_worker.exe' }
    function Get-DouyinFirewallRules { $script:rules }
    function Clear-DouyinNetState {}
    function New-NetFirewallRule {
        param($Name,$DisplayName,$Program,$Enabled)
        Assert-True ($Enabled -eq 'False')
        $script:rules += [pscustomobject]@{ Name=$Name; InstanceID=$Name; DisplayName=$DisplayName; Program=$Program }
    }
    function Remove-NetFirewallRule { param($Name); $script:rules=@($script:rules | Where-Object { $Name -notcontains $_.Name }) }
    function Get-NetFirewallApplicationFilter {
        foreach($rule in $script:rules) { [pscustomobject]@{ InstanceID=$rule.Name; Program=$rule.Program } }
    }
    Assert-True ((Ensure-DouyinFirewallCoverage -Block $false) -eq 2)
    Assert-True ($script:rules.Count -eq 2 -and @($script:rules | Where-Object Name -eq 'old').Count -eq 0)
}
Test-Case 'Readiness is acknowledged through the actual named event' {
    $name='Global\DouyinCleanup-Ready-'+[Guid]::NewGuid().ToString('N')
    $event=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$name)
    try { Signal-SessionReady $name; Assert-True ($event.WaitOne(0)) } finally { $event.Dispose() }
}
Test-Case 'Readiness event refuses arbitrary external names' { Assert-Throws { Signal-SessionReady 'Global\OtherApplication' } }
Test-Case 'Private diagnostics redact configured paths' {
    $ScriptRoot='C:\SampleTools\cleanup'
    $text=Protect-PrivateText ('failure '+$ScriptRoot+' '+$DouyinRoot+' '+$DataRoot)
    Assert-True ($text.Contains('[PROJECT]') -and $text.Contains('[DOUYIN]') -and $text.Contains('[LOCALDATA]'))
    Assert-True (-not $text.Contains($ScriptRoot))
}
Test-Case 'Repeated atomic writes leave complete JSON without temporary files' {
    $folder=Join-Path ([IO.Path]::GetTempPath()) ('DouyinAtomic-'+[Guid]::NewGuid().ToString('N'))
    $file=Join-Path $folder 'state.json'
    try {
        Write-AtomicJson $file @{Version=1}
        Write-AtomicJson $file @{Version=2; Nested=@{Ready=$true}}
        $saved=Read-JsonFile $file
        Assert-True ($saved.Version -eq 2 -and $saved.Nested.Ready)
        Assert-True (@(Get-ChildItem -LiteralPath $folder -File).Count -eq 1)
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $folder -Force -ErrorAction SilentlyContinue
    }
}
Test-Case 'Task baseline preserves the first enabled state across repeats' {
    $script:baseline=[pscustomobject]@{Version=1;Context=$CacheContext;Services=@();Tasks=@();Acls=@();CleanupTask=$null}
    function Get-RecoveryState { $script:baseline }
    function Save-RecoveryState { param($State); $script:baseline=$State }
    Save-TaskBaseline ([pscustomobject]@{TaskName='Guard';TaskPath='\DouyinUser\';State='Ready'})
    Save-TaskBaseline ([pscustomobject]@{TaskName='Guard';TaskPath='\DouyinUser\';State='Disabled'})
    Assert-True ($script:baseline.Tasks.Count -eq 1 -and $script:baseline.Tasks[0].Enabled)
}
Test-Case 'Unrelated same-name scheduled task cannot be overwritten' {
    function Get-RecoveryState { [pscustomobject]@{CleanupTask=$null} }
    function Get-ScheduledTask { [pscustomobject]@{Actions=@([pscustomobject]@{Arguments='-File C:\Other\tool.ps1'})} }
    Assert-Throws { Save-CleanupTaskBaseline }
}
Test-Case 'Legacy unlock without snapshots does not reset third-party settings' {
    $RecoveryFile=Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N')+'.missing')
    function Get-ScheduledTask {}
    Restore-RecordedConfiguration
}
Test-Case 'Installation boundary rejects sibling names and parent traversal' {
    Assert-True (Test-PathUnderRoot 'C:\Apps\Douyin\worker.exe' 'C:\Apps\Douyin')
    Assert-True (-not (Test-PathUnderRoot 'C:\Apps\DouyinOther\worker.exe' 'C:\Apps\Douyin'))
    Assert-True (-not (Test-PathUnderRoot 'C:\Apps\Douyin\..\Other\worker.exe' 'C:\Apps\Douyin'))
}
Test-Case 'Malformed recovery is rejected before restoring any service' {
    $folder=Join-Path ([IO.Path]::GetTempPath()) ('DouyinRecovery-'+[Guid]::NewGuid().ToString('N'))
    $RecoveryFile=Join-Path $folder 'recovery.json'
    try {
        Write-AtomicJson $RecoveryFile @{Version=1;Context=$CacheContext;Services=@(@{Name='MockService';StartMode='Auto';DelayedPresent=$false;DelayedValue=0},@{Name='BrokenService';StartMode='INVALID';DelayedPresent=$false;DelayedValue=0});Tasks=@();Acls=@();CleanupTask=$null}
        $script:modified=$false
        function Get-Service { return $true }
        function Set-Service { $script:modified=$true }
        Assert-Throws { Restore-RecordedConfiguration }
        Assert-True (-not $script:modified)
    }finally{Remove-Item -LiteralPath $RecoveryFile -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $folder -Force -ErrorAction SilentlyContinue}
}
Test-Case 'Restoration uses recorded startup and task enabled states' {
    $folder=Join-Path ([IO.Path]::GetTempPath()) ('DouyinRestore-'+[Guid]::NewGuid().ToString('N'))
    $RecoveryFile=Join-Path $folder 'recovery.json'
    try {
        Write-AtomicJson $RecoveryFile @{Version=1;Context=$CacheContext;Services=@(@{Name='MockService';StartMode='Manual';DelayedPresent=$false;DelayedValue=0});Tasks=@(@{Name='Guard';Path='\DouyinUser\';Enabled=$false});Acls=@();CleanupTask=$null}
        $script:startup='';$script:disabled=0
        function Get-Service { return $true }
        function Set-Service { param($Name,$StartupType);$script:startup=$StartupType }
        function Remove-ItemProperty {}
        function Get-ScheduledTask { return $true }
        function Disable-ScheduledTask { $script:disabled++ }
        Restore-RecordedConfiguration
        Assert-True ($script:startup -eq 'Manual' -and $script:disabled -eq 1)
    }finally{Remove-Item -LiteralPath $RecoveryFile -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $folder -Force -ErrorAction SilentlyContinue}
}
Test-Case 'Broad system directory cannot be selected as a cleanup root' {
    Assert-Throws { Resolve-DouyinRoot -ConfiguredRoot $env:windir -DataRoot $DataRoot }
    Assert-Throws { Resolve-DouyinRoot -ConfiguredRoot ([IO.Path]::GetTempPath()) -DataRoot $DataRoot }
}
Test-Case 'A directory without the application entry cannot be selected' {
    $folder=Join-Path ([IO.Path]::GetTempPath()) ('DouyinEmpty-'+[Guid]::NewGuid().ToString('N'))
    try{New-Item -ItemType Directory -Path $folder|Out-Null;Assert-Throws {Resolve-DouyinRoot -ConfiguredRoot $folder -DataRoot $DataRoot}}
    finally{Remove-Item -LiteralPath $folder -Force}
}
Test-Case 'Existing recovery does not allow overwriting a replaced task' {
    function Get-RecoveryState { [pscustomobject]@{CleanupTask=[pscustomobject]@{Name=$TaskName;Existed=$false}} }
    function Get-ScheduledTask { [pscustomobject]@{Actions=@([pscustomobject]@{Execute='other.exe';Arguments='-Action Watch'})} }
    Assert-Throws { Save-CleanupTaskBaseline }
}
Test-Case 'Marked same-context task is recognized after moving the checkout' {
    $task=[pscustomobject]@{
        Description=('DouyinCleanup: '+(Get-ContextHash $CacheContext)+'; cleanup')
        Actions=@([pscustomobject]@{Execute='powershell.exe';Arguments='-File "C:\OldTools\DouyinKiller.ps1" -Action Watch -DouyinRoot "C:\douyin" -RulePrefix "DouyinKiller-Block"'})
    }
    Assert-True (Test-CleanupTaskOwned $task)
}

Write-Host ('Results: {0} passed, {1} failed' -f $passed, $failed)
if ($failed) { exit 1 }
exit 0
