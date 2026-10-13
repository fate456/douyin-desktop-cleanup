#Requires -Version 5.1
# Exercises the actual installer against isolated destinations, never the Start Menu.
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$sandbox=Join-Path ([IO.Path]::GetTempPath()) ('DouyinShortcut-'+[Guid]::NewGuid().ToString('N'))
$destination=Join-Path $sandbox 'menu\fixture.lnk'
$data=Join-Path $sandbox 'private'
$ps=Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$installer=Join-Path $project 'Install-DouyinShortcut.ps1'
$result=0
$checks=@()
function Run-Installer {
    param([string[]]$Extra=@(),[int]$Expected=0)
    & $ps -NoProfile -ExecutionPolicy Bypass -File $installer -Destination $destination -DataRoot $data @Extra | Out-Host
    if($LASTEXITCODE -ne $Expected){throw 'Unexpected installer exit code.'}
}
try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Run-Installer
    Run-Installer -Extra @('-Verify')
    Run-Installer
    Run-Installer -Extra @('-Revert')
    if(Test-Path -LiteralPath $destination){throw 'New shortcut was not removed on revert.'}
    $checks+='Install, verify, reinstall, revert restores an absent original.'
    Write-Host ('PASS '+$checks[-1])
    # Use a separate destination so its baseline is genuinely an existing shortcut.
    $destination=Join-Path $sandbox 'menu\existing.lnk'
    $shell=New-Object -ComObject WScript.Shell
    try {
        $link=$shell.CreateShortcut($destination)
        try {$link.TargetPath=Join-Path $env:windir 'System32\notepad.exe';$link.Save()}
        finally {[Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)|Out-Null}
    }finally{[Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)|Out-Null}
    $originalHash=(Get-FileHash -LiteralPath $destination).Hash
    Run-Installer -Extra @('-Verify') -Expected 1
    Run-Installer
    Run-Installer -Extra @('-Verify')
    Run-Installer -Extra @('-Revert')
    if((Get-FileHash -LiteralPath $destination).Hash -ne $originalHash){throw 'Original shortcut bytes were not restored.'}
    $checks+='Existing shortcut original bytes survive installation and restoration.'
    Write-Host ('PASS '+$checks[-1])
} catch {$result=1;Write-Host 'FAIL Shortcut integration.' -ForegroundColor Red}
finally {
    $absolute=[IO.Path]::GetFullPath($sandbox)
    $base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $absolute.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $absolute) -notlike 'DouyinShortcut-*'){throw 'Unsafe cleanup path.'}
    if(Test-Path -LiteralPath $absolute){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
. (Join-Path $project 'Douyin.Common.ps1')
Write-AtomicJson -Path (Join-Path $project 'artifacts\shortcut-integration.json') -Value @{Version=1;ExitCode=$result;Checks=$checks}
exit $result
