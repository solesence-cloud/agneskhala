[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'DH.CSManager'),
    [switch]$NoShortcuts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$metadataPath = Join-Path $repositoryRoot 'release.json'
$requiredFiles = @('CS_Manager.exe', 'README.md', 'installed_release.json')

function Read-ReleaseMetadata {
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw "release.json is missing: $metadataPath"
    }
    try {
        $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8 | ConvertFrom-Json
    }
    catch {
        throw "release.json cannot be read: $($_.Exception.Message)"
    }
    foreach ($property in @('schema_version', 'app_id', 'release_id', 'archive', 'archive_sha256')) {
        if ([string]::IsNullOrWhiteSpace([string]$metadata.$property)) {
            throw "release.json is missing required property: $property"
        }
    }
    if ($metadata.schema_version -ne 1 -or $metadata.app_id -ne 'DH.CSManager') {
        throw 'release.json is not a DH.CSManager schema version 1 release.'
    }
    if ($metadata.release_id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$') {
        throw "Unsafe release id: $($metadata.release_id)"
    }
    if ($metadata.archive -match '(^[\\/]|^[A-Za-z]:|\.\.)') {
        throw "Unsafe archive path: $($metadata.archive)"
    }
    if ($metadata.archive_sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'release.json archive_sha256 must be a SHA-256 value.'
    }
    return $metadata
}

function Assert-Descendant {
    param([Parameter(Mandatory = $true)][string]$Candidate,
          [Parameter(Mandatory = $true)][string]$Parent)
    $root = [IO.Path]::GetFullPath($Parent)
    $path = [IO.Path]::GetFullPath($Candidate)
    $prefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe path outside $root`: $path"
    }
    return $path
}

function Test-AppRunning {
    param([Parameter(Mandatory = $true)][string]$Root)
    $prefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    return @(Get-CimInstance Win32_Process -Filter "Name='CS_Manager.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
}

function Assert-SafeArchive {
    param([Parameter(Mandatory = $true)][string]$Archive,
          [Parameter(Mandatory = $true)][string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $names = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\\', '/') })
        foreach ($name in $requiredFiles) {
            if ($names -notcontains $name) {
                throw "Release archive is missing required root file: $name"
            }
        }
        foreach ($entry in $zip.Entries) {
            if ([string]::IsNullOrWhiteSpace($entry.Name)) { continue }
            [void](Assert-Descendant -Candidate (Join-Path $Destination $entry.FullName) -Parent $Destination)
        }
    }
    finally {
        $zip.Dispose()
    }
}

function New-Shortcut {
    param([Parameter(Mandatory = $true)][string]$Path,
          [Parameter(Mandatory = $true)][string]$Target)
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $Target
    $shortcut.WorkingDirectory = Split-Path -Parent $Target
    $shortcut.IconLocation = "$Target,0"
    $shortcut.Save()
}

$release = Read-ReleaseMetadata
$archive = Assert-Descendant -Candidate (Join-Path $repositoryRoot $release.archive) -Parent $repositoryRoot
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
    throw "Release archive is missing: $archive. Run git pull --ff-only and retry."
}
$actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if (-not $actualHash.Equals($release.archive_sha256.ToLowerInvariant(), [StringComparison]::Ordinal)) {
    throw "Release archive SHA-256 mismatch. Expected $($release.archive_sha256), got $actualHash."
}

$installRoot = [IO.Path]::GetFullPath($InstallRoot)
$installParent = Split-Path -Parent $installRoot
if ([string]::IsNullOrWhiteSpace($installParent) -or $installRoot -eq $installParent) {
    throw "Unsafe install root: $installRoot"
}
$safeInstall = Assert-Descendant -Candidate $installRoot -Parent $installParent
$running = Test-AppRunning -Root $safeInstall
if ($running.Count -gt 0) {
    $ids = ($running | Select-Object -ExpandProperty ProcessId) -join ', '
    throw "DH.CSManager is running (PID: $ids). Close it and retry."
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$safeId = $release.release_id -replace '[^A-Za-z0-9._-]', '_'
$staging = Assert-Descendant -Candidate (Join-Path $installParent ('.DH.CSManager.staging.' + $safeId)) -Parent $installParent
$backupRoot = Join-Path $installParent 'DH.CSManager_Backups'
$backup = Assert-Descendant -Candidate (Join-Path $backupRoot ('DH.CSManager.' + $stamp)) -Parent $backupRoot
if (Test-Path -LiteralPath $staging) { throw "Staging path already exists: $staging" }
if (Test-Path -LiteralPath $backup) { throw "Backup path already exists: $backup" }

if (-not $PSCmdlet.ShouldProcess($safeInstall, "install DH.CSManager $($release.release_id); preserve previous version at $backup")) {
    exit 0
}

New-Item -ItemType Directory -Path $staging | Out-Null
$movedOld = $false
try {
    Assert-SafeArchive -Archive $archive -Destination $staging
    Expand-Archive -LiteralPath $archive -DestinationPath $staging -Force
    foreach ($name in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $staging $name) -PathType Leaf)) {
            throw "Extracted package is missing required file: $name"
        }
    }
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    if (Test-Path -LiteralPath $safeInstall) {
        Move-Item -LiteralPath $safeInstall -Destination $backup
        $movedOld = $true
    }
    Move-Item -LiteralPath $staging -Destination $safeInstall
}
catch {
    $failed = Assert-Descendant -Candidate (Join-Path $installParent ('DH.CSManager.failed.' + $stamp)) -Parent $installParent
    if (Test-Path -LiteralPath $safeInstall) { Move-Item -LiteralPath $safeInstall -Destination $failed }
    if ($movedOld -and (Test-Path -LiteralPath $backup)) { Move-Item -LiteralPath $backup -Destination $safeInstall }
    throw
}

$executable = Join-Path $safeInstall 'CS_Manager.exe'
if (-not $NoShortcuts) {
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'DH.CSManager'
        New-Item -ItemType Directory -Path $startMenu -Force | Out-Null
        New-Shortcut -Path (Join-Path $desktop 'DH.CSManager.lnk') -Target $executable
        New-Shortcut -Path (Join-Path $startMenu 'DH.CSManager.lnk') -Target $executable
    }
    catch {
        Write-Warning "Installed, but shortcuts could not be created: $($_.Exception.Message)"
    }
}

Write-Host "Installed DH.CSManager $($release.release_id) at $safeInstall"
if ($movedOld) { Write-Host "Previous version kept at $backup" }
Write-Host "Run: $executable"
