#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'Douyin.Common.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$sourceFiles=@(
    'DouyinKiller.ps1','Douyin.Common.ps1','Douyin.Restore.ps1',
    'Start-Douyin.bat','Run-DouyinKiller.bat',
    'Install-DouyinShortcut.ps1','Install-DouyinShortcut.bat',
    'douyin.ico','README.txt','README.md','LICENSE','.gitignore','.gitattributes',
    '.github/workflows/checks.yml',
    'tests/Regression.Tests.ps1','tests/Integration.Tests.ps1','tests/Shortcut.Tests.ps1',
    'tools/Review-Project.ps1','tools/Migrate-PrivateArtifacts.ps1','tools/Build-Release.ps1'
)
$evidenceFiles=@(
    'artifacts/code-review.txt','artifacts/regression.txt','artifacts/integration.json',
    'artifacts/shortcut-integration.json','artifacts/live-acceptance.json',
    'artifacts/privacy-review.json','artifacts/source-hashes.txt'
)
$files=@($sourceFiles)+@($evidenceFiles)
foreach($relative in $files){
    $path=Join-Path $root $relative
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw "Missing release file: $relative"}
    if((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Release file cannot be a reparse point: $relative"}
}
$hashes=@($sourceFiles | ForEach-Object {
    '{0}  {1}' -f (Get-FileHash -LiteralPath (Join-Path $root $_) -Algorithm SHA256).Hash.ToLowerInvariant(),$_
})
[IO.File]::WriteAllLines((Join-Path $root 'artifacts/source-hashes.txt'),[string[]]$hashes,(New-Object Text.UTF8Encoding($false)))
$target=Join-Path $root 'artifacts/DouyinCleanup.zip'
$temporary=$target+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
$stream=$null;$archive=$null
try{
    $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew)
    $archive=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    foreach($relative in $files){
        $entry=$archive.CreateEntry('DouyinCleanup/'+$relative,[IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime=[DateTimeOffset]::new(2000,1,1,0,0,0,[TimeSpan]::Zero)
        $inputStream=[IO.File]::OpenRead((Join-Path $root $relative))
        $outputStream=$entry.Open()
        try{$inputStream.CopyTo($outputStream)}finally{$inputStream.Dispose();$outputStream.Dispose()}
    }
    $archive.Dispose();$archive=$null
    $stream.Dispose();$stream=$null
    if(Test-Path -LiteralPath $target){
        [IO.File]::Replace($temporary,$target,[Management.Automation.Language.NullString]::Value)
    }else{[IO.File]::Move($temporary,$target)}
}finally{
    if($archive){$archive.Dispose()};if($stream){$stream.Dispose()}
    if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}
}
Write-Host ('Release archive built: {0} allowlisted files.' -f $files.Count)
