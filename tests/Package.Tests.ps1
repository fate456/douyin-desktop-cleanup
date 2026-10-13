#Requires -Version 5.1
# Validates extracted release payload and its actual BAT launcher with isolated fixtures.
[CmdletBinding()]
param([string]$PackageRoot='')
$ErrorActionPreference='Stop'
if(-not $PackageRoot){$PackageRoot=Split-Path -Parent $PSScriptRoot}
$PackageRoot=[IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
. (Join-Path $PackageRoot 'Douyin.Common.ps1')
$admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $admin){throw 'Package integration requires administrator privileges.'}
$id=[Guid]::NewGuid().ToString('N')
$sandbox=Join-Path ([IO.Path]::GetTempPath()) ('DouyinPackage-'+$id)
$fixtureRoot=Join-Path $sandbox 'install'
$ScriptRoot=$PackageRoot
$DouyinRoot=$fixtureRoot
$dataRoot=Get-DefaultDataRoot
$contextName=Get-ContextHash ($fixtureRoot+'|DouyinKiller-Block')
$context=Join-Path $dataRoot $contextName
$oldRoot=$env:DOUYIN_ROOT
$checks=New-Object Collections.Generic.List[string]
$payloadHashes=@{}
$failure=$null
$exitCode=0
function Pass-Package {param([string]$Message);$checks.Add($Message);Write-Host ('PASS '+$Message)}
function Assert-Package {param($Value,[string]$Message);if(-not $Value){throw $Message}}
function Get-FixtureRules {
    $prefix='DouyinKiller-Block ('+$fixtureRoot+'\'
    return @(Get-NetFirewallRule -DisplayName ([WildcardPattern]::Escape($prefix)+'*') -ErrorAction Stop | Where-Object {$_.DisplayName.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)})
}
function Get-FixtureProcesses {
    return @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {Test-PathUnderRoot $_.ExecutablePath $fixtureRoot})
}
try {
    Assert-Package ((Get-Content -LiteralPath (Join-Path $PackageRoot 'VERSION') -Raw).Trim() -eq '1.0.1') 'Unexpected package version.'
    foreach($line in (Get-Content -LiteralPath (Join-Path $PackageRoot 'artifacts/source-hashes.txt') -Encoding UTF8)){
        if(-not $line){continue}
        $parts=$line -split '  ',2
        Assert-Package ($parts.Count -eq 2 -and $parts[0] -match '^[a-f0-9]{64}$') 'Invalid source manifest.'
        $absolute=[IO.Path]::GetFullPath((Join-Path $PackageRoot $parts[1]))
        Assert-Package (Test-PathUnderRoot $absolute $PackageRoot) 'Manifest path leaves the package.'
        Assert-Package ((Get-FileHash -LiteralPath $absolute -Algorithm SHA256).Hash.ToLowerInvariant() -eq $parts[0]) 'Package source hash mismatch.'
        $payloadHashes[$parts[1]]=$parts[0]
    }
    foreach($file in @('Start-Douyin.bat','Run-DouyinKiller.bat','Install-DouyinShortcut.bat','开始使用.txt','README.txt','douyin.ico')){
        Assert-Package (Test-Path -LiteralPath (Join-Path $PackageRoot $file) -PathType Leaf) 'Required entry file is missing.'
    }
    foreach($file in (Get-ChildItem -LiteralPath $PackageRoot -Filter '*.ps1' -Recurse)){
        $tokens=$null;$errors=$null
        [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)|Out-Null
        Assert-Package ($errors.Count -eq 0) 'Packaged PowerShell source cannot be parsed.'
    }
    foreach($file in @('README.md','docs/images/README.md')){
        $path=Join-Path $PackageRoot $file
        foreach($match in [regex]::Matches((Get-Content -LiteralPath $path -Raw -Encoding UTF8),'\]\(([^)]+)\)')){
            $link=$match.Groups[1].Value
            if($link -match '^https?://|^#'){continue}
            Assert-Package (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $path) $link) -PathType Leaf) 'Offline documentation link is missing.'
        }
    }
    Pass-Package 'Manifest hashes, Windows PowerShell 5.1 parsing, entry files and offline image links.'
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
    $fixture=Join-Path $fixtureRoot 'douyin.exe'
    $code=@'
using System;
using System.IO;
using System.Diagnostics;
using System.Security.Principal;
using System.Threading;
public class DouyinPackageFixture {
    public static void Main() {
        if (Process.GetCurrentProcess().ProcessName == "douyin") {
            bool elevated = new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
            File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"elevation.txt"), elevated ? "elevated" : "limited");
            Thread.Sleep(8000);
        } else { Thread.Sleep(60000); }
    }
}
'@
    Add-Type -TypeDefinition $code -OutputAssembly $fixture -OutputType WindowsApplication
    $worker=Join-Path $fixtureRoot 'future_worker.exe'
    Copy-Item -LiteralPath $fixture -Destination $worker
    Start-Process -FilePath $worker -WindowStyle Hidden | Out-Null
    $env:DOUYIN_ROOT=$fixtureRoot
    $launcher=Join-Path $PackageRoot 'Start-Douyin.bat'
    $command='call "'+$launcher+'"'
    $cmd=Start-Process -FilePath $env:ComSpec -ArgumentList @('/d','/c',$command) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $sandbox 'stdout.txt') -RedirectStandardError (Join-Path $sandbox 'stderr.txt')
    # Keep the process handle open so Windows PowerShell can retrieve its exit code.
    $null=$cmd.Handle
    Assert-Package ($cmd.WaitForExit(40000)) 'Packaged BAT launch timed out.'
    Assert-Package ($cmd.ExitCode -eq 0) 'Packaged BAT launch failed.'
    Assert-Package ((Get-Content -LiteralPath (Join-Path $fixtureRoot 'elevation.txt') -Raw) -eq 'limited') 'Packaged launcher elevated the application.'
    Pass-Package 'Actual Start-Douyin.bat launches a limited user fixture from the extracted folder.'
    $deadline=[DateTime]::UtcNow.AddSeconds(35)
    do {
        $processes=@(Get-FixtureProcesses)
        $watchers=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop | Where-Object {$_.CommandLine -and $_.CommandLine.Contains('-Action SessionWait') -and $_.CommandLine.Contains($fixtureRoot)})
        $rules=@(Get-FixtureRules)
        $done=($processes.Count -eq 0 -and $watchers.Count -eq 0 -and $rules.Count -eq 2 -and @($rules | Where-Object {[string]$_.Enabled -ne 'True'}).Count -eq 0)
        if(-not $done){Start-Sleep -Milliseconds 500}
    }while(-not $done -and [DateTime]::UtcNow -lt $deadline)
    Assert-Package $done 'Packaged session did not clean all fixture processes and restore blocking.'
    Pass-Package 'Background fixture exit reaches zero processes and zero session watchers; both outbound rules are enabled.'
}catch {
    $exitCode=1;$failure=Protect-PrivateText $_.Exception.Message
    Write-Host ('FAIL '+$failure) -ForegroundColor Red
    foreach($name in @('stdout.txt','stderr.txt')){
        $diagnostic=Join-Path $sandbox $name
        if(Test-Path -LiteralPath $diagnostic){Write-Host (Protect-PrivateText (Get-Content -LiteralPath $diagnostic -Raw -Encoding UTF8))}
    }
}finally {
    $env:DOUYIN_ROOT=$oldRoot
    foreach($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)){
        $isFixture=Test-PathUnderRoot $process.ExecutablePath $fixtureRoot
        $isWatcher=$process.Name -eq 'powershell.exe' -and $process.CommandLine -and $process.CommandLine.Contains('-Action SessionWait') -and $process.CommandLine.Contains($fixtureRoot)
        if($isFixture -or $isWatcher){Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue}
    }
    $rules=@(Get-FixtureRules)
    if($rules.Count){Remove-NetFirewallRule -Name @($rules.Name) -ErrorAction Stop}
    foreach($target in @($sandbox,$context)){
        $absolute=[IO.Path]::GetFullPath($target)
        $safeSandbox=$absolute -eq [IO.Path]::GetFullPath($sandbox) -and (Test-PathUnderRoot $absolute ([IO.Path]::GetTempPath())) -and (Split-Path -Leaf $absolute) -eq ('DouyinPackage-'+$id)
        $safeContext=$absolute -eq [IO.Path]::GetFullPath($context) -and (Test-PathUnderRoot $absolute $dataRoot) -and (Split-Path -Leaf $absolute) -eq $contextName
        if(-not ($safeSandbox -or $safeContext)){throw 'Unsafe package fixture cleanup path.'}
        if(Test-Path -LiteralPath $absolute){
            Assert-Package (-not ((Get-Item -LiteralPath $absolute).Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Fixture cleanup cannot follow a reparse point.'
            Remove-Item -LiteralPath $absolute -Recurse -Force -ErrorAction Stop
        }
    }
    Assert-Package (@(Get-FixtureRules).Count -eq 0) 'Fixture rules were not removed.'
    Pass-Package 'Only isolated fixture processes, rules and data were removed.'
}
$report=@{Version=1;PackageVersion='1.0.1';Result='PASS';ExitCode=$exitCode;Checks=@($checks.ToArray());PayloadHashes=$payloadHashes;Failure=$failure;FixtureApplicationOnly=$true;ActualDouyinLaunched=$false}
if($exitCode){$report.Result='FAIL'}
Write-AtomicJson -Path (Join-Path $PackageRoot 'artifacts/package-validation.json') -Value $report
exit $exitCode
