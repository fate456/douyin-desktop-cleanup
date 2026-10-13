#Requires -Version 5.1
# Shared local infrastructure. Importing this file has no side effects.

function Get-DefaultDataRoot {
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = [Environment]::GetFolderPath('LocalApplicationData') }
    if (-not $base) { throw 'Local application data directory is unavailable.' }
    return Join-Path $base 'DouyinCleanup'
}

function Get-ContextHash {
    param([Parameter(Mandatory)][string]$Value)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value.ToLowerInvariant()))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Test-PathUnderRoot {
    param([string]$Path, [string]$Root)
    if (-not $Path -or -not $Root) { return $false }
    try {
        return [IO.Path]::GetFullPath($Path).StartsWith([IO.Path]::GetFullPath($Root).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Resolve-DouyinRoot {
    param([string]$ConfiguredRoot, [string]$DataRoot)
    if (-not $ConfiguredRoot) { $ConfiguredRoot = $env:DOUYIN_ROOT }
    if (-not $ConfiguredRoot -and $DataRoot) {
        $settings = Join-Path $DataRoot 'settings.json'
        if (Test-Path -LiteralPath $settings -PathType Leaf) {
            $config = Read-JsonFile -Path $settings
            $ConfiguredRoot = [string]$config.DouyinRoot
        }
    }
    if (-not $ConfiguredRoot) {
        $candidates = @()
        foreach ($registryRoot in @(
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        )) {
            foreach ($key in (Get-ChildItem -LiteralPath $registryRoot -ErrorAction SilentlyContinue)) {
                $value = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
                if (-not $value -or $value.DisplayName -notmatch '^(抖音|Douyin)(\s|$)') { continue }
                $candidate = [string]$value.InstallLocation
                if (-not $candidate -and $value.DisplayIcon) {
                    $icon = ([string]$value.DisplayIcon -replace ',\s*-?\d+$', '').Trim('"')
                    if ([IO.Path]::IsPathRooted($icon)) { $candidate = Split-Path -Parent $icon }
                }
                if ($candidate -and ((Test-Path -LiteralPath (Join-Path $candidate 'douyin.exe') -PathType Leaf) -or
                    (Test-Path -LiteralPath (Join-Path $candidate 'new_douyin.exe') -PathType Leaf))) {
                    $candidates += [IO.Path]::GetFullPath($candidate).TrimEnd('\')
                }
            }
        }
        $candidates = @($candidates | Select-Object -Unique)
        if ($candidates.Count -ne 1) { throw '无法唯一识别抖音安装目录。请设置 DOUYIN_ROOT 环境变量或传入 -DouyinRoot。' }
        $ConfiguredRoot = $candidates[0]
    }
    if (-not [IO.Path]::IsPathRooted($ConfiguredRoot)) { throw 'DouyinRoot 必须是绝对路径。' }
    $resolved = [IO.Path]::GetFullPath($ConfiguredRoot).TrimEnd('\')
    if ($resolved -eq [IO.Path]::GetPathRoot($resolved).TrimEnd('\')) { throw 'DouyinRoot 不能是磁盘或共享根目录。' }
    foreach ($broadRoot in @($env:windir,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:USERPROFILE,[IO.Path]::GetTempPath())) {
        if ($broadRoot -and $resolved -eq [IO.Path]::GetFullPath($broadRoot).TrimEnd('\')) { throw '拒绝将系统、程序或用户根目录作为抖音安装目录。' }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $resolved 'douyin.exe') -PathType Leaf) -and
        -not (Test-Path -LiteralPath (Join-Path $resolved 'new_douyin.exe') -PathType Leaf)) { throw '目录内没有抖音主入口，拒绝将它作为清理目录。' }
    return $resolved
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}

function Write-AtomicJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null }
    $temp = Join-Path $directory ('.write-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Protect-PrivateText {
    param([string]$Text)
    $replacements = @(
        @($ScriptRoot, '[PROJECT]'), @($DouyinRoot, '[DOUYIN]'),
        @($DataRoot, '[LOCALDATA]'), @($env:USERPROFILE, '[USER]')
    )
    foreach ($pair in $replacements) {
        if ($pair[0]) { $Text = [regex]::Replace($Text, [regex]::Escape([string]$pair[0]), [string]$pair[1], [Text.RegularExpressions.RegexOptions]::IgnoreCase) }
    }
    foreach ($name in @($env:COMPUTERNAME, $env:USERNAME)) {
        if ($name -and $name.Length -ge 3) { $Text = [regex]::Replace($Text, '(?i)(?<![\w])' + [regex]::Escape($name) + '(?![\w])', '[LOCAL-ID]') }
    }
    return $Text
}

function Signal-SessionReady {
    param([string]$Name)
    if (-not $Name) { return }
    if ($Name -notmatch '^Global\\DouyinCleanup-Ready-[a-f0-9]{32}$') { throw 'Invalid readiness event.' }
    $event = [Threading.EventWaitHandle]::OpenExisting($Name)
    try { $event.Set() | Out-Null } finally { $event.Dispose() }
}
