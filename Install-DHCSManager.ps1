[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param([string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'DH.CSManager'), [switch]$NoShortcuts, [switch]$NonInteractive)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
# A working directory inside the install folder would block the move below - start from the repository.
[Environment]::CurrentDirectory = $repositoryRoot
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
# Reads another process's working directory (PEB -> ProcessParameters -> CurrentDirectory).
# 2026-09-16: a VNC viewer started by the app outlived it with the install folder as its
# working directory. No file was open, so the folder simply could not be moved and the
# update failed four times with "used by another process". Only 64-bit targets are read.
$processDirectorySource = @"
using System; using System.Runtime.InteropServices; using System.Text;
namespace DHCSManager { public static class ProcessDirectory {
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll")] static extern bool IsWow64Process(IntPtr h, out bool wow);
  [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr h, IntPtr at, byte[] buffer, int size, out IntPtr read);
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int kind, byte[] info, int size, out int written);
  static byte[] Read(IntPtr h, long at, int size) { var b = new byte[size]; IntPtr n; return ReadProcessMemory(h, (IntPtr)at, b, size, out n) ? b : null; }
  public static string Get(int pid) {
    if (IntPtr.Size != 8) return null;
    IntPtr h = OpenProcess(0x0410, false, pid); if (h == IntPtr.Zero) return null;
    try {
      bool wow; if (!IsWow64Process(h, out wow) || wow) return null;
      var basic = new byte[48]; int written; if (NtQueryInformationProcess(h, 0, basic, 48, out written) != 0) return null;
      var parameters = Read(h, BitConverter.ToInt64(basic, 8) + 0x20, 8); if (parameters == null) return null;
      var text = Read(h, BitConverter.ToInt64(parameters, 0) + 0x38, 16); if (text == null) return null;
      var chars = Read(h, BitConverter.ToInt64(text, 8), BitConverter.ToUInt16(text, 0)); if (chars == null) return null;
      return Encoding.Unicode.GetString(chars);
    } finally { CloseHandle(h); } } } }
"@
function Get-ProcessDirectory {
    param([Parameter(Mandatory)][int]$ProcessId)
    # Best effort: a locked-down PC may refuse Add-Type. Then only the executable check below runs.
    try {
        if (-not ('DHCSManager.ProcessDirectory' -as [type])) { Add-Type -TypeDefinition $processDirectorySource -ErrorAction Stop }
        [DHCSManager.ProcessDirectory]::Get($ProcessId)
    } catch { $null }
}
function Get-FolderProcesses {
    param([Parameter(Mandatory)][string]$Root)
    $prefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        if ($process.ProcessId -eq $PID) { continue }
        if ($process.ExecutablePath -and $process.ExecutablePath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
            [pscustomobject]@{ Name = $process.Name; ProcessId = $process.ProcessId; RunsFromFolder = $true }; continue
        }
        $directory = Get-ProcessDirectory -ProcessId ([int]$process.ProcessId)
        if ($directory -and ($directory.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
            [pscustomobject]@{ Name = $process.Name; ProcessId = $process.ProcessId; RunsFromFolder = $false }
        }
    }
}
function Test-AppRunning {
    param([Parameter(Mandatory)][string]$Root)
    # A program started from the folder (CS_Manager.exe, but also QtWebEngineProcess.exe) has its
    # files open, so nothing can be replaced until it exits.
    @(Get-FolderProcesses -Root $Root | Where-Object { $_.RunsFromFolder })
}
function Move-Children {
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)
    New-Item -ItemType Directory -Path $To -Force | Out-Null
    foreach ($child in @(Get-ChildItem -LiteralPath $From -Force)) { Move-Item -LiteralPath $child.FullName -Destination (Join-Path $To $child.Name) }
}
function Format-Holders {
    param([object[]]$Processes)
    ($Processes | ForEach-Object { "$($_.Name) (PID $($_.ProcessId))" }) -join ', '
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
function Remove-InstallerLeftovers {
    param([Parameter(Mandatory)][string]$Parent, [Parameter(Mandatory)][string]$BackupRoot)
    # Runs after every successful install - installs are the only thing that creates these, so
    # this is the natural schedule. Only names this installer itself creates are touched, and
    # links are never followed (deleting through a junction would delete someone else's files).
    # 2026-09-16: one PC had 5 failed copies (518MB each) and 12 backups piled up.
    $cutoff = (Get-Date).AddHours(-1)
    $targets = @()
    $targets += @(Get-ChildItem -LiteralPath $Parent -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^DH\.CSManager\.failed\.\d{8}_\d{6}$' -or
        ($_.Name -match '^\.DH\.CSManager\.(staging|stale-staging)\.' -and $_.LastWriteTime -lt $cutoff)
    })
    if (Test-Path -LiteralPath $BackupRoot) {
        # Keep the newest backup for rollback; the stamp in the name sorts by time.
        $targets += @(Get-ChildItem -LiteralPath $BackupRoot -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^DH\.CSManager\.\d{8}_\d{6}$' } | Sort-Object Name -Descending | Select-Object -Skip 1)
    }
    $targets += @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^DH\.CSManager-\d{4}\.\d{2}\.\d{2}-r\d+\.zip$' })
    $removed = 0
    foreach ($item in $targets) {
        # Not proven by a test: PowerShell 5.1.26100 did not follow junctions here (top-level or nested,
        # measured 2026-09-16). Kept for older builds; a link named like a leftover is simply skipped.
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        try { Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop; $removed++ }
        catch { Write-Warning "Could not remove leftover $($item.FullName): $($_.Exception.Message)" }
    }
    if ($removed -gt 0) { Write-Host "Removed $removed leftover item(s) from earlier updates." }
}
function New-Shortcut {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Target)
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
    $shortcut.TargetPath = $Target; $shortcut.WorkingDirectory = Split-Path -Parent $Target; $shortcut.IconLocation = "$Target,0"; $shortcut.Save()
}

$release = Read-ReleaseMetadata
$installRoot = [IO.Path]::GetFullPath($InstallRoot); $installParent = Split-Path -Parent $installRoot
if ([string]::IsNullOrWhiteSpace($installParent) -or $installRoot -eq $installParent) { throw "Unsafe install root: $installRoot" }
$safeInstall = Assert-Descendant $installRoot $installParent
# Checked before downloading: files of a running app cannot be replaced, so there is no point fetching the archive.
$running = @(Test-AppRunning -Root $safeInstall)
if ($running.Count -gt 0) { throw "DH.CSManager is running: $(Format-Holders $running). Close it and run the update again." }
# A program that only has the folder as its working directory (2026-09-16: a VNC viewer that must
# stay open) blocks moving the folder itself, but not the files inside it. Then the contents are
# swapped and the folder stays where it is.
$parked = @(Get-FolderProcesses -Root $safeInstall | Where-Object { -not $_.RunsFromFolder })
if ($parked.Count -gt 0) { Write-Host "The folder is kept open by $(Format-Holders $parked); it stays open and the files inside are replaced." }
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'; $safeId = $release.release_id -replace '[^A-Za-z0-9._-]','_'
# A timestamp makes failed attempts non-blocking; never delete an unknown old staging folder.
$staging = Assert-Descendant (Join-Path $installParent ".DH.CSManager.staging.$safeId.$stamp") $installParent
$backupRoot = Join-Path $installParent 'DH.CSManager_Backups'; $backup = Assert-Descendant (Join-Path $backupRoot "DH.CSManager.$stamp") $installParent
$failed = Assert-Descendant (Join-Path $installParent "DH.CSManager.failed.$stamp") $installParent
if (-not $NonInteractive -and -not $PSCmdlet.ShouldProcess($safeInstall,"install DH.CSManager $($release.release_id); preserve previous version at $backup")) { exit 0 }

# Delta update (2026-09-16): the installed app assembles the new version from the files that
# changed; everything else is copied from this install. PowerShell 5.1 cannot verify Ed25519,
# the app can - so the app does the trusting and this script only swaps folders.
# Only an app whose stamp says it knows `--stage-update` is asked: an older exe given an unknown
# argument simply opens its window.
$deltaStaged = $false
$releaseUrl = if ($release.PSObject.Properties.Name -contains 'release_url') { [string]$release.release_url } else { '' }
$objectsUrl = if ($release.PSObject.Properties.Name -contains 'objects_url') { [string]$release.objects_url } else { '' }
$installedExe = Join-Path $safeInstall 'CS_Manager.exe'
$capabilities = @()
try { $capabilities = @((Get-Content -LiteralPath (Join-Path $safeInstall 'installed_release.json') -Raw -Encoding utf8 | ConvertFrom-Json).capabilities) } catch { $capabilities = @() }
if ($releaseUrl.StartsWith('https://',[StringComparison]::OrdinalIgnoreCase) -and $objectsUrl.StartsWith('https://',[StringComparison]::OrdinalIgnoreCase) -and ($capabilities -contains 'stage-update') -and (Test-Path -LiteralPath $installedExe -PathType Leaf)) {
    Write-Host "Downloading only the files that changed..."
    $stageLog = Join-Path ([IO.Path]::GetTempPath()) "DH.CSManager-stage-$safeId.$stamp.log"
    $stageArguments = @('--stage-update', '--staging', ('"{0}"' -f $staging), '--release-url', ('"{0}"' -f $releaseUrl), '--objects-url', ('"{0}"' -f $objectsUrl), '--release-id', ('"{0}"' -f $release.release_id))
    $stager = Start-Process -FilePath $installedExe -ArgumentList $stageArguments -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stageLog
    $said = if (Test-Path -LiteralPath $stageLog) { (Get-Content -LiteralPath $stageLog -Raw -Encoding utf8) } else { '' }
    Remove-Item -LiteralPath $stageLog -Force -ErrorAction SilentlyContinue
    if ($null -ne $said) { $said = $said.Trim() }
    if ($stager.ExitCode -eq 0) { $deltaStaged = $true; Write-Host $said }
    elseif ($stager.ExitCode -eq 3) { Write-Host "$said`nFalling back to the full download." }
    # Only exit code left is 1 (FAILED, see update_apply.py): something arrived that did not
    # match what it was signed to be. A connection that merely dropped becomes exit 3 above,
    # but once mismatched bytes have been seen the app keeps exit 1 even if the next attempt
    # then fails on the network - so the log below may well mention a network error too, and
    # that does not soften what happened. Nothing was changed; never fall back to the ZIP.
    else { throw "A downloaded piece did not match what it was signed to be - the update was stopped because this is what tampering looks like. Nothing was changed: $said (exit $($stager.ExitCode))" }
}

$downloadedArchive = $null
if (-not $deltaStaged) {
    $archiveUrl = if ($release.PSObject.Properties.Name -contains 'archive_url') { [string]$release.archive_url } else { '' }
    $localArchive = Assert-Descendant (Join-Path $repositoryRoot $release.archive) $repositoryRoot
    if (Test-Path -LiteralPath $localArchive -PathType Leaf) { $archive = $localArchive }
    elseif (-not [string]::IsNullOrWhiteSpace($archiveUrl)) {
        $downloadedArchive = Join-Path ([IO.Path]::GetTempPath()) "DH.CSManager-$safeId.zip"
        Write-Host "Downloading $archiveUrl"
        try { Invoke-WebRequest -Uri $archiveUrl -OutFile $downloadedArchive -UseBasicParsing } catch { throw "Could not download the release: $($_.Exception.Message)" }
        $archive = $downloadedArchive
    } else { throw "Release archive is missing: $localArchive" }
    if (-not ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant().Equals($release.archive_sha256.ToLowerInvariant(),[StringComparison]::Ordinal))) {
        if ($null -ne $downloadedArchive) { Remove-Item -LiteralPath $downloadedArchive -Force -ErrorAction SilentlyContinue }
        throw 'Release archive SHA-256 mismatch.'
    }
}

$movedOld = $false; $inPlace = $false; $placingNew = $false
try {
    if (-not $deltaStaged) {
        Assert-SafeArchive $archive $staging
        # Expand-Archive terminates this host after a network download; this .NET path is verified.
        [IO.Compression.ZipFile]::ExtractToDirectory($archive,$staging)
    }
    foreach ($name in $requiredFiles) { if (-not (Test-Path -LiteralPath (Join-Path $staging $name) -PathType Leaf)) { throw "Extracted package is missing required file: $name" } }
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    if (Test-Path -LiteralPath $safeInstall) {
        $inPlace = $parked.Count -gt 0
        if (-not $inPlace) {
            try { Move-Item -LiteralPath $safeInstall -Destination $backup; $movedOld = $true }
            catch [IO.IOException] { $inPlace = $true; Write-Host "The folder itself is in use; replacing the files inside it instead." }
        }
        if ($inPlace) {
            $movedOld = $true; Move-Children -From $safeInstall -To $backup
            $placingNew = $true; Move-Children -From $staging -To $safeInstall
            Remove-Item -LiteralPath $staging -Force
        } else {
            Move-Item -LiteralPath $staging -Destination $safeInstall
        }
    } else {
        Move-Item -LiteralPath $staging -Destination $safeInstall
    }
} catch {
    if ($inPlace) {
        # Undo in reverse: new files go back to staging, then the old files come home.
        if ($placingNew -and (Test-Path -LiteralPath $safeInstall)) { Move-Children -From $safeInstall -To $staging }
        if ($movedOld -and (Test-Path -LiteralPath $backup)) { Move-Children -From $backup -To $safeInstall; Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
    } elseif ($movedOld -and (Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $safeInstall)) { Move-Item -LiteralPath $backup -Destination $safeInstall }
    if (Test-Path -LiteralPath $staging) { Move-Item -LiteralPath $staging -Destination $failed }
    throw
}
$executable = Join-Path $safeInstall 'CS_Manager.exe'
if (-not $NoShortcuts) { try { $desktop=[Environment]::GetFolderPath('Desktop'); $startMenu=Join-Path ([Environment]::GetFolderPath('Programs')) 'DH.CSManager'; New-Item -ItemType Directory -Path $startMenu -Force|Out-Null; New-Shortcut (Join-Path $desktop 'DH.CSManager.lnk') $executable; New-Shortcut (Join-Path $startMenu 'DH.CSManager.lnk') $executable } catch { Write-Warning "Installed, but shortcuts could not be created: $($_.Exception.Message)" } }
if ($null -ne $downloadedArchive) { Remove-Item -LiteralPath $downloadedArchive -Force -ErrorAction SilentlyContinue }
try { Remove-InstallerLeftovers -Parent $installParent -BackupRoot $backupRoot } catch { Write-Warning "Installed, but leftovers could not be cleaned: $($_.Exception.Message)" }
Write-Host "Installed DH.CSManager $($release.release_id) at $safeInstall"
if ($movedOld) { Write-Host "Previous version kept at $backup" }
Write-Host "Run: $executable"
