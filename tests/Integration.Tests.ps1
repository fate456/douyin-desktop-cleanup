#Requires -Version 5.1
# Real OS integration using isolated, short-lived fixtures. Does not launch the user's application.
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$ScriptPath = Join-Path $project 'DouyinKiller.ps1'
$ScriptRoot = $project
$id = [Guid]::NewGuid().ToString('N')
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('DouyinIntegration-' + $id)
$DouyinRoot = Join-Path $sandbox 'install'
$DataRoot = Join-Path $sandbox 'data'
$CacheContext = $DouyinRoot + '|DouyinIntegration-' + $id
$RulePrefix = 'DouyinIntegration-' + $id
$TaskName = 'DouyinIntegration-' + $id
$StateFile = Join-Path $DataRoot 'state.json'
$SettleSeconds = 0
$CleanupMaxPasses = 5
$StateCacheSeconds = 0
$Action = 'Clean'
$IsWatch = $false
$watcher = $null
$ready = $null
$result = 0
$checks = New-Object Collections.Generic.List[string]
function Write-Pass { param([string]$Message); $checks.Add($Message); Write-Host ('PASS ' + $Message) }

foreach ($file in @('DouyinKiller.ps1', 'Douyin.Common.ps1', 'Douyin.Restore.ps1')) {
    $errors = $null; $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $project $file), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Source parse failed.' }
    foreach ($fn in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]}, $false)) { Invoke-Expression $fn.Extent.Text }
    if ($file -eq 'DouyinKiller.ps1') {
        $assignments = $ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst]}, $false)
        foreach ($name in @('SideCarNames', 'MainNames', 'DouyinServices', 'DouyinProcessNames')) {
            Invoke-Expression (($assignments | Where-Object { $_.Left.Extent.Text -eq ('$' + $name) } | Select-Object -First 1).Extent.Text)
        }
    }
}
function Write-Log { param($Message,$Level); Write-Host (Protect-PrivateText ('['+$Level+'] '+$Message)) }
function Assert-Integration { param($Condition,[string]$Message); if(-not $Condition){throw $Message} }

try {
    New-Item -ItemType Directory -Path $DouyinRoot,$DataRoot -Force | Out-Null
    $fixture = Join-Path $DouyinRoot 'douyin.exe'
    $code = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Security.Principal;
using System.Threading;
public class DouyinFixture {
    public static void Main() {
        if (Process.GetCurrentProcess().ProcessName == "douyin") {
            bool elevated = new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
            File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"elevation.txt"), elevated ? "elevated" : "limited");
            Thread.Sleep(5000);
        } else { Thread.Sleep(60000); }
    }
}
'@
    Add-Type -TypeDefinition $code -OutputAssembly $fixture -OutputType WindowsApplication
    $worker = Join-Path $DouyinRoot 'future_worker.exe'
    Copy-Item -LiteralPath $fixture -Destination $worker
    Start-DouyinAsUser -Executable $fixture
    Assert-Integration ((Get-Content -LiteralPath (Join-Path $DouyinRoot 'elevation.txt') -Raw) -eq 'limited') 'Application token was elevated.'
    Write-Pass 'Real limited user launch; temporary launch task removed.'
    Start-Process -FilePath $worker -WindowStyle Hidden | Out-Null
    Start-Sleep -Milliseconds 300
    $snapshot = @(Get-DouyinProcessSnapshot)
    $main = $snapshot | Where-Object IsMain | Select-Object -First 1
    Assert-Integration ([bool]$main) 'Fixture main process disappeared too early.'
    $cleanup = Invoke-ResidualCleanup
    Assert-Integration $cleanup.InUse 'Running application was not protected.'
    Assert-Integration (@(Get-DouyinProcessSnapshot | Where-Object { $_.UnderRoot -and -not $_.IsMain }).Count -gt 0) 'Worker was killed while the main was running.'
    Write-Pass 'Real running main protects its workers.'
    $mainProcess = Get-Process -Id $main.Pid -ErrorAction Stop
    Assert-Integration ($mainProcess.WaitForExit(10000)) 'Fixture main exit timed out.'
    $cleanup = Invoke-ResidualCleanup
    Assert-Integration (-not $cleanup.InUse -and @(Get-DouyinProcessSnapshot | Where-Object UnderRoot).Count -eq 0) 'Real cleanup did not reach zero.'
    Write-Pass 'Real CIM identity verification and cleanup reaches zero.'

    Start-Process -FilePath $worker -WindowStyle Hidden | Out-Null
    $readyName = 'Global\DouyinCleanup-Ready-' + [Guid]::NewGuid().ToString('N')
    $ready = [Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$readyName)
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Action SessionWait -DouyinRoot "{1}" -DataRoot "{2}" -RulePrefix "{3}" -TaskName "{4}" -StartupTimeoutSeconds 2 -ExitGraceSeconds 1 -SettleSeconds 0 -CleanupMaxPasses 3 -ReadyEvent "{5}"' -f $ScriptPath,$DouyinRoot,$DataRoot,$RulePrefix,$TaskName,$readyName
    $watcher = Start-Process -FilePath "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -WindowStyle Hidden -PassThru
    Assert-Integration ($ready.WaitOne(10000)) 'Real watcher never acknowledged readiness.'
    Assert-Integration ($watcher.WaitForExit(30000)) 'Real watcher did not finish.'
    Assert-Integration ($watcher.ExitCode -eq 0) 'Real watcher failed.'
    Assert-Integration (@(Get-DouyinProcessSnapshot | Where-Object UnderRoot).Count -eq 0) 'Startup timeout left workers alive.'
    $rules = @(Get-DouyinFirewallRules)
    Assert-Integration ($rules.Count -eq 2 -and @($rules | Where-Object { [string]$_.Enabled -ne 'True' }).Count -eq 0) 'Watcher did not block all fixture executables.'
    Write-Pass 'Real hidden watcher readiness, startup timeout, firewall coverage and cleanup.'
} catch {
    $result=1
    Write-Host ('FAIL '+(Protect-PrivateText $_.Exception.Message)) -ForegroundColor Red
} finally {
    if($ready){$ready.Dispose()}
    if($watcher -and -not $watcher.HasExited){
        $process=Get-CimInstance Win32_Process -Filter ('ProcessId={0}' -f $watcher.Id) -ErrorAction SilentlyContinue
        if($process -and $process.CommandLine -and $process.CommandLine.Contains($id)){Stop-Process -Id $watcher.Id -Force -ErrorAction SilentlyContinue}
    }
    foreach($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)){
        if(Test-PathUnderRoot $process.ExecutablePath $DouyinRoot){Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue}
    }
    $rules=@(Get-DouyinFirewallRules)
    if($rules.Count){Remove-NetFirewallRule -Name @($rules.Name) -ErrorAction Stop}
    Assert-Integration (@(Get-DouyinFirewallRules).Count -eq 0) 'Fixture firewall cleanup failed.'
    $absolute=[IO.Path]::GetFullPath($sandbox)
    $tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $absolute.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $absolute) -ne ('DouyinIntegration-'+$id)){throw 'Unsafe fixture cleanup path.'}
    if(Test-Path -LiteralPath $absolute){Remove-Item -LiteralPath $absolute -Recurse -Force -ErrorAction Stop}
    Write-Pass 'Isolated fixtures and firewall rules removed.'
}
Write-AtomicJson -Path (Join-Path $project 'artifacts\integration.json') -Value @{Version=1;ExitCode=$result;Checks=@($checks.ToArray())}
exit $result
