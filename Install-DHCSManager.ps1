[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param([string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'DH.CSManager'), [switch]$NoShortcuts, [switch]$NonInteractive)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$metadataPath = Join-Path $repositoryRoot 'release.json'
$requiredFiles = @('CS_Manager.exe', 'README.md', 'installed_release.json')

function Assert-Descendant {
    param([Parameter(Mandatory)][string]$Candidate, [Parameter(Mandatory)][string]$Parent)
    $root = [IO.Path]::GetFullPath($Parent); $path = [IO.Path]::GetFullPath($Candidate)
    if (-not $path.StartsWith($root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe path outside $root`: $path" }
    $path
}
function Read-ReleaseMetadata {
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { throw "release.json is missing: $metadataPath" }
    try { $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8 | ConvertFrom-Json } catch { throw "release.json cannot be read: $($_.Exception.Message)" }
    foreach ($property in @('schema_version','app_id','release_id','archive','archive_sha256')) { if ([string]::IsNullOrWhiteSpace([string]$metadata.$property)) { throw "release.json is missing required property: $property" } }
    if ($metadata.schema_version -ne 1 -or $metadata.app_id -ne 'DH.CSManager') { throw 'release.json is not a DH.CSManager schema version 1 release.' }
    if ($metadata.release_id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$') { throw "Unsafe release id: $($metadata.release_id)" }
    if ($metadata.archive -match '(^[\\/]|^[A-Za-z]:|\.\.)') { throw "Unsafe archive path: $($metadata.archive)" }
    if ($metadata.archive_sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'archive_sha256 must be SHA-256.' }
    if ($metadata.PSObject.Properties.Name -contains 'archive_url') { $url = [string]$metadata.archive_url; if (-not [string]::IsNullOrWhiteSpace($url) -and -not $url.StartsWith('https://',[StringComparison]::OrdinalIgnoreCase)) { throw "archive_url must be https: $url" } }
    $metadata
}
function Test-AppRunning {
    param([Parameter(Mandatory)][string]$Root)
    $prefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    @(Get-CimInstance Win32_Process -Filter "Name='CS_Manager.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) })
}
function Assert-SafeArchive {
    param([Parameter(Mandatory)][string]$Archive, [Parameter(Mandatory)][string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $names = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\\','/') })
        foreach ($name in $requiredFiles) { if ($names -notcontains $name) { throw "Release archive is missing required root file: $name" } }
        foreach ($entry in $zip.Entries) { if (-not [string]::IsNullOrWhiteSpace($entry.Name)) { [void](Assert-Descendant (Join-Path $Destination $entry.FullName) $Destination) } }
    } finally { $zip.Dispose() }
}
function New-Shortcut {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Target)
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
    $shortcut.TargetPath = $Target; $shortcut.WorkingDirectory = Split-Path -Parent $Target; $shortcut.IconLocation = "$Target,0"; $shortcut.Save()
}

$release = Read-ReleaseMetadata
$archiveUrl = if ($release.PSObject.Properties.Name -contains 'archive_url') { [string]$release.archive_url } else { '' }
$localArchive = Assert-Descendant (Join-Path $repositoryRoot $release.archive) $repositoryRoot
$downloadedArchive = $null
if (Test-Path -LiteralPath $localArchive -PathType Leaf) { $archive = $localArchive }
elseif (-not [string]::IsNullOrWhiteSpace($archiveUrl)) {
    $safeId = $release.release_id -replace '[^A-Za-z0-9._-]','_'
    $downloadedArchive = Join-Path ([IO.Path]::GetTempPath()) "DH.CSManager-$safeId.zip"
    Write-Host "Downloading $archiveUrl"
    try { Invoke-WebRequest -Uri $archiveUrl -OutFile $downloadedArchive -UseBasicParsing } catch { throw "Could not download the release: $($_.Exception.Message)" }
    $archive = $downloadedArchive
} else { throw "Release archive is missing: $localArchive" }
if (-not ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant().Equals($release.archive_sha256.ToLowerInvariant(),[StringComparison]::Ordinal))) {
    if ($null -ne $downloadedArchive) { Remove-Item -LiteralPath $downloadedArchive -Force -ErrorAction SilentlyContinue }
    throw 'Release archive SHA-256 mismatch.'
}

$installRoot = [IO.Path]::GetFullPath($InstallRoot); $installParent = Split-Path -Parent $installRoot
if ([string]::IsNullOrWhiteSpace($installParent) -or $installRoot -eq $installParent) { throw "Unsafe install root: $installRoot" }
$safeInstall = Assert-Descendant $installRoot $installParent
$running = @(Test-AppRunning -Root $safeInstall)
if ($running.Count -gt 0) { throw "DH.CSManager is running (PID: $(($running | Select-Object -ExpandProperty ProcessId) -join ', ')). Close it and retry." }
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'; $safeId = $release.release_id -replace '[^A-Za-z0-9._-]','_'
# A timestamp makes failed attempts non-blocking; never delete an unknown old staging folder.
$staging = Assert-Descendant (Join-Path $installParent ".DH.CSManager.staging.$safeId.$stamp") $installParent
$backupRoot = Join-Path $installParent 'DH.CSManager_Backups'; $backup = Assert-Descendant (Join-Path $backupRoot "DH.CSManager.$stamp") $installParent
$failed = Assert-Descendant (Join-Path $installParent "DH.CSManager.failed.$stamp") $installParent
if (-not $NonInteractive -and -not $PSCmdlet.ShouldProcess($safeInstall,"install DH.CSManager $($release.release_id); preserve previous version at $backup")) { exit 0 }

$movedOld = $false
try {
    Assert-SafeArchive $archive $staging
    # Expand-Archive terminates this host after a network download; this .NET path is verified.
    [IO.Compression.ZipFile]::ExtractToDirectory($archive,$staging)
    foreach ($name in $requiredFiles) { if (-not (Test-Path -LiteralPath (Join-Path $staging $name) -PathType Leaf)) { throw "Extracted package is missing required file: $name" } }
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    if (Test-Path -LiteralPath $safeInstall) { Move-Item -LiteralPath $safeInstall -Destination $backup; $movedOld = $true }
    Move-Item -LiteralPath $staging -Destination $safeInstall
} catch {
    if ($movedOld -and (Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $safeInstall)) { Move-Item -LiteralPath $backup -Destination $safeInstall }
    if (Test-Path -LiteralPath $staging) { Move-Item -LiteralPath $staging -Destination $failed }
    throw
}
$executable = Join-Path $safeInstall 'CS_Manager.exe'
if (-not $NoShortcuts) { try { $desktop=[Environment]::GetFolderPath('Desktop'); $startMenu=Join-Path ([Environment]::GetFolderPath('Programs')) 'DH.CSManager'; New-Item -ItemType Directory -Path $startMenu -Force|Out-Null; New-Shortcut (Join-Path $desktop 'DH.CSManager.lnk') $executable; New-Shortcut (Join-Path $startMenu 'DH.CSManager.lnk') $executable } catch { Write-Warning "Installed, but shortcuts could not be created: $($_.Exception.Message)" } }
if ($null -ne $downloadedArchive) { Remove-Item -LiteralPath $downloadedArchive -Force -ErrorAction SilentlyContinue }
Write-Host "Installed DH.CSManager $($release.release_id) at $safeInstall"
if ($movedOld) { Write-Host "Previous version kept at $backup" }
Write-Host "Run: $executable"
