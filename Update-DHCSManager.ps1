[CmdletBinding()]
param(
    [switch]$NoShortcuts,
    [string]$InstallRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$git = Get-Command git.exe -ErrorAction SilentlyContinue
if ($null -eq $git) {
    throw 'Git for Windows is required for updates. Install it once, then retry.'
}
& $git.Source -C $repositoryRoot pull --ff-only
if ($LASTEXITCODE -ne 0) {
    throw "git pull --ff-only failed ($LASTEXITCODE). The installed app was not changed."
}

$installer = Join-Path $repositoryRoot 'Install-DHCSManager.ps1'
$installArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer, '-Confirm:$false')
if ($NoShortcuts) { $installArguments += '-NoShortcuts' }
if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) { $installArguments += @('-InstallRoot', $InstallRoot) }
& powershell.exe @installArguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
