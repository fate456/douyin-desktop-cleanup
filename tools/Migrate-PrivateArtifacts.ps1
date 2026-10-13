#Requires -Version 5.1
# Relocates legacy local data without deleting recovery material.
[CmdletBinding()]
param([string]$ProjectRoot = '')
$ErrorActionPreference='Stop'
if(-not $ProjectRoot){$ProjectRoot=Split-Path -Parent $PSScriptRoot}
$root=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
if(-not (Test-Path -LiteralPath (Join-Path $root 'DouyinKiller.ps1'))){throw 'Expected project was not found.'}
. (Join-Path $root 'Douyin.Common.ps1')
$data=[IO.Path]::GetFullPath((Get-DefaultDataRoot)).TrimEnd('\')
if($data -eq $root -or (Test-PathUnderRoot $data $root)){throw 'Private storage overlaps project.'}
$originalSource=Join-Path $root 'backup\抖音.lnk'
if(Test-Path -LiteralPath $originalSource -PathType Leaf){
    $destination=Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\抖音.lnk'
    $key=Get-ContextHash $destination
    $directory=Join-Path (Join-Path $data 'shortcuts') $key
    $manifest=Join-Path $directory 'original.json'
    if(-not (Test-Path -LiteralPath $manifest)){
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $originalTarget=Join-Path $directory 'original.lnk'
        Copy-Item -LiteralPath $originalSource -Destination $originalTarget -Force
        if((Get-FileHash -LiteralPath $originalSource).Hash -ne (Get-FileHash -LiteralPath $originalTarget).Hash){throw 'Shortcut migration verification failed.'}
        Write-AtomicJson $manifest @{Version=1;Context=$key;Existed=$true}
    }
}
$targets=@('backup','logs','抖音.lnk','last-status.txt','net-state.txt')
$artifactDirectory=Join-Path $root 'artifacts'
if(Test-Path -LiteralPath $artifactDirectory){
    foreach($file in (Get-ChildItem -LiteralPath $artifactDirectory -Filter '*.patch' -File)){$targets+='artifacts\'+$file.Name}
    $oldReport=Join-Path $artifactDirectory 'verification.txt'
    if((Test-Path -LiteralPath $oldReport) -and (Get-Content -LiteralPath $oldReport -Raw).Contains($root)){$targets+='artifacts\verification.txt'}
}
$vault=Join-Path $data ('legacy-private-'+[Guid]::NewGuid().ToString('N'))
$count=0
foreach($relative in $targets){
    $source=[IO.Path]::GetFullPath((Join-Path $root $relative))
    if(-not $source.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Source escaped workspace.'}
    if(-not (Test-Path -LiteralPath $source)){continue}
    $item=Get-Item -LiteralPath $source -Force
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Source is a reparse point.'}
    if($item.PSIsContainer -and @(Get-ChildItem -LiteralPath $source -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count){throw 'Legacy folder has reparse points.'}
    $target=[IO.Path]::GetFullPath((Join-Path $vault $relative))
    if(-not $target.StartsWith($data+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Private target escaped intended data directory.'}
    $files=@();if($item.PSIsContainer){$files=@(Get-ChildItem -LiteralPath $source -Recurse -File -Force)}else{$files=@($item)}
    $hashes=@{}
    foreach($file in $files){$hashes[$file.FullName.Substring($root.Length+1)]=(Get-FileHash -LiteralPath $file.FullName).Hash}
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Move-Item -LiteralPath $source -Destination $target -ErrorAction Stop
    foreach($path in $hashes.Keys){
        if((Get-FileHash -LiteralPath (Join-Path $vault $path)).Hash -ne $hashes[$path]){throw 'Moved legacy file hash mismatch.'}
    }
    $count+=$files.Count
}
Write-Host ('Private legacy files relocated and hash-verified: '+$count)
