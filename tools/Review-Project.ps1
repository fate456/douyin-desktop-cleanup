#Requires -Version 5.1
[CmdletBinding()]
param([string]$ProjectRoot = '', [string]$OutFile)
$ErrorActionPreference='Stop'
if(-not $ProjectRoot){$ProjectRoot=Split-Path -Parent $PSScriptRoot}
$root=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
. (Join-Path $root 'Douyin.Common.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$privatePaths=@($root,$env:USERPROFILE)
try {$privatePaths += Resolve-DouyinRoot -DataRoot (Get-DefaultDataRoot)} catch {}
$privateNames=@($env:USERNAME,$env:COMPUTERNAME) | Where-Object { $_ -and $_.Length -ge 3 -and $_ -notin @('Administrator','SYSTEM','LocalService','NetworkService','Guest') }
$issues=New-Object Collections.Generic.List[object]
$fileCount=0
$entryCount=0
$patterns=@{
    'Private key'='-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
    'API credential'='(?:sk-(?:proj-)?[A-Za-z0-9_-]{24,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[A-Z0-9]{16}|AIza[A-Za-z0-9_-]{30,})'
    'Email address'='(?i)[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
    'Phone number'='(?<!\w)1[3-9]\d{9}(?!\w)'
    'Local user path'='(?i)[A-Z]:[\\/]Users[\\/](?!Public(?:[\\/]|$)|Default(?:[\\/]|$))[^\\/\s"''][^\\/\r\n"'']*'
}
$assignment=@'
(?im)\b(?:api[_-]?key|password|passwd|client[_-]?secret|access[_-]?token|refresh[_-]?token|cookie|authorization)\b\s*[:=]\s*["']([^"'\r\n]{8,})["']
'@
$patterns['Credential literal']=$assignment.Trim()

function Inspect-Bytes {
    param([byte[]]$Bytes,[string]$Label)
    foreach($text in @([Text.Encoding]::UTF8.GetString($Bytes),[Text.Encoding]::Unicode.GetString($Bytes))){
        foreach($privatePath in $privatePaths){
            if($privatePath -and $text.IndexOf($privatePath,[StringComparison]::OrdinalIgnoreCase) -ge 0){
                $issues.Add([pscustomobject]@{File=$Label;Category='Machine-specific path'})
                break
            }
        }
        foreach($name in $privateNames){
            if($text -match ('(?i)(?<![\w])'+[regex]::Escape($name)+'(?![\w])')){$issues.Add([pscustomobject]@{File=$Label;Category='Local account or host identifier'})}
        }
        foreach($category in $patterns.Keys){
            if([regex]::IsMatch($text,$patterns[$category])){$issues.Add([pscustomobject]@{File=$Label;Category=$category})}
        }
    }
}

$pending=New-Object Collections.Generic.Stack[string]
$pending.Push($root)
while($pending.Count){
    foreach($item in (Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop)){
        $relative=$item.FullName.Substring($root.Length+1).Replace('\','/')
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){$issues.Add([pscustomobject]@{File=$relative;Category='Unreviewed reparse point'});continue}
        # Local Git metadata is not shipped; audit the source tree and release archives.
        if($relative -eq '.git'){continue}
        if($item.PSIsContainer){$pending.Push($item.FullName);continue}
        $fileCount++
        if($item.Extension -in @('.lnk','.log') -or $relative -match '^(backup|logs|\.private)/' -or $item.Name -in @('last-status.txt','net-state.txt','settings.json')){
            $issues.Add([pscustomobject]@{File=$relative;Category='Private runtime artifact inside project'})
        }
        if($item.Extension -eq '.zip'){
            $archive=[IO.Compression.ZipFile]::OpenRead($item.FullName)
            try{
                foreach($entry in $archive.Entries){
                    if(-not $entry.Name){continue}
                    $entryCount++
                    $stream=$entry.Open();$memory=New-Object IO.MemoryStream
                    try{$stream.CopyTo($memory);Inspect-Bytes -Bytes $memory.ToArray() -Label ($relative+'::'+$entry.FullName)}finally{$stream.Dispose();$memory.Dispose()}
                }
            }finally{$archive.Dispose()}
        }else{Inspect-Bytes -Bytes ([IO.File]::ReadAllBytes($item.FullName)) -Label $relative}
    }
}
$distinct=@($issues | Sort-Object File,Category -Unique)
$report=[pscustomobject]@{Version=1;FilesChecked=$fileCount;ArchiveEntriesChecked=$entryCount;IssueCount=$distinct.Count;Issues=$distinct}
if($OutFile){Write-AtomicJson -Path ([IO.Path]::GetFullPath($OutFile)) -Value $report}
Write-Host ('Privacy review: {0} files, {1} archive entries, {2} findings.' -f $fileCount,$entryCount,$distinct.Count)
if($distinct.Count){$distinct | Format-Table -AutoSize;exit 1}
exit 0
