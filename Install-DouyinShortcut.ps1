#Requires -Version 5.1
<# Generate the current checkout's shortcut at install time; no personal .lnk is shipped. #>
[CmdletBinding()]
param(
    [switch]$Revert, [switch]$Verify, [string]$Path, [string]$Destination, [string]$DataRoot,
    [ValidateNotNullOrEmpty()][ValidateScript({ $_ -notmatch '[\\/:*?"<>|\x00-\x1f]' })][string]$Name = '抖音'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Off
. (Join-Path $PSScriptRoot 'Douyin.Common.ps1')
$ScriptRoot = $PSScriptRoot
$DouyinRoot = ''
if (-not $DataRoot) { $DataRoot = Get-DefaultDataRoot }
if (-not [IO.Path]::IsPathRooted($DataRoot)) { throw 'DataRoot must be absolute.' }
$DataRoot = [IO.Path]::GetFullPath($DataRoot).TrimEnd('\')
if ($DataRoot -eq [IO.Path]::GetPathRoot($DataRoot).TrimEnd('\')) { throw 'DataRoot cannot be a drive root.' }
if ($DataRoot.TrimEnd('\') -eq $ScriptRoot.TrimEnd('\') -or (Test-PathUnderRoot $DataRoot $ScriptRoot)) { throw 'Private backup directory cannot be inside the project.' }
if ($Verify -and $Revert) { throw '-Verify and -Revert cannot be combined.' }
if ($Path -and -not $Verify) { throw '-Path requires -Verify.' }
$launcher = Join-Path $PSScriptRoot 'Start-Douyin.bat'
$icon = Join-Path $PSScriptRoot 'douyin.ico'
if (-not $Destination) { $Destination = Join-Path $env:ProgramData ('Microsoft\Windows\Start Menu\Programs\' + $Name + '.lnk') }
$Destination = [IO.Path]::GetFullPath($Destination)
if ([IO.Path]::GetExtension($Destination) -ne '.lnk') { throw 'Destination must be a .lnk file.' }
$backupDirectory = Join-Path (Join-Path $DataRoot 'shortcuts') (Get-ContextHash $Destination)
$original = Join-Path $backupDirectory 'original.lnk'
$manifestPath = Join-Path $backupDirectory 'original.json'

function Get-ShortcutFields {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw 'Shortcut file not found.' }
    $shell = New-Object -ComObject WScript.Shell
    try {
        $link = $shell.CreateShortcut($File)
        try { return [pscustomobject]@{ Target = $link.TargetPath; Icon = $link.IconLocation; WorkDir = $link.WorkingDirectory; Arguments = $link.Arguments } }
        finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) | Out-Null }
    } finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
}

function Test-Shortcut {
    param([string]$File)
    try {
        $fields = Get-ShortcutFields $File
        $iconPath = ($fields.Icon -replace ',\s*-?\d+$', '').Trim('"')
        return ($fields.Target -eq $launcher -and $fields.WorkDir -eq $PSScriptRoot -and -not $fields.Arguments -and
            $iconPath -eq $icon -and (Test-Path -LiteralPath $iconPath -PathType Leaf))
    } catch { return $false }
}

function Copy-ShortcutAtomically {
    param([string]$Source, [string]$Target)
    $directory = Split-Path -Parent $Target
    New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    $temp = Join-Path $directory ('.douyin-' + [Guid]::NewGuid().ToString('N') + '.lnk')
    try {
        Copy-Item -LiteralPath $Source -Destination $temp -Force -ErrorAction Stop
        if ([IO.File]::Exists($Target)) { [IO.File]::Replace($temp, $Target, [Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temp, $Target) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

try {
    if ($Verify) {
        $probe = $Destination
        if ($Path) { $probe = [IO.Path]::GetFullPath($Path) }
        if (Test-Shortcut $probe) { Write-Host 'Shortcut verification passed.' -ForegroundColor Green; exit 0 }
        Write-Host 'Shortcut target, working directory or icon does not match.' -ForegroundColor Yellow
        exit 1
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run the companion BAT as administrator.' }
    if ($Revert) {
        $saved = Read-JsonFile $manifestPath
        if ($saved.Version -ne 1 -or $saved.Context -ne (Get-ContextHash $Destination)) { throw 'Invalid shortcut recovery record.' }
        if ($saved.Existed) {
            Copy-ShortcutAtomically -Source $original -Target $Destination
            if ((Get-FileHash -LiteralPath $original).Hash -ne (Get-FileHash -LiteralPath $Destination).Hash) { throw 'Shortcut restore verification failed.' }
        } elseif (Test-Path -LiteralPath $Destination) {
            if (-not (Test-Shortcut $Destination)) { throw 'Shortcut was replaced by another program; refusing to delete it.' }
            Remove-Item -LiteralPath $Destination -Force -ErrorAction Stop
        }
        Write-Host 'Original shortcut state restored.' -ForegroundColor Green
        exit 0
    }
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf) -or -not (Test-Path -LiteralPath $icon -PathType Leaf)) { throw 'Launcher or icon is missing.' }
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        New-Item -ItemType Directory -Path $backupDirectory -Force -ErrorAction Stop | Out-Null
        $existed = Test-Path -LiteralPath $Destination -PathType Leaf
        if ($existed) {
            if (Test-Shortcut $Destination) { throw 'Redirected shortcut has no original backup; refusing to save it as the original.' }
            Copy-Item -LiteralPath $Destination -Destination $original -Force -ErrorAction Stop
        }
        Write-AtomicJson -Path $manifestPath -Value @{ Version = 1; Context = (Get-ContextHash $Destination); Existed = [bool]$existed }
    }
    New-Item -ItemType Directory -Path $backupDirectory -Force -ErrorAction Stop | Out-Null
    $staged = Join-Path $backupDirectory ('staged-' + [Guid]::NewGuid().ToString('N') + '.lnk')
    try {
        $shell = New-Object -ComObject WScript.Shell
        try {
            $link = $shell.CreateShortcut($staged)
            try {
                $link.TargetPath = $launcher
                $link.WorkingDirectory = $PSScriptRoot
                $link.IconLocation = $icon + ',0'
                $link.Description = 'Douyin session launcher'
                $link.WindowStyle = 7
                $link.Save()
            } finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) | Out-Null }
        } finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
        if (-not (Test-Shortcut $staged)) { throw 'Generated shortcut verification failed.' }
        Copy-ShortcutAtomically -Source $staged -Target $Destination
        if (-not (Test-Shortcut $Destination)) { throw 'Installed shortcut verification failed.' }
    } catch {
        $failure = $_
        $saved = Read-JsonFile $manifestPath
        if ($saved.Existed) { Copy-ShortcutAtomically -Source $original -Target $Destination }
        elseif ((Test-Path -LiteralPath $Destination) -and (Test-Shortcut $Destination)) { Remove-Item -LiteralPath $Destination -Force }
        throw $failure
    } finally { if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue } }
    Write-Host 'Start Menu shortcut installed and verified. Use -Revert to undo.' -ForegroundColor Green
    exit 0
} catch {
    Write-Host (Protect-PrivateText $_.Exception.Message) -ForegroundColor Red
    exit 1
}
