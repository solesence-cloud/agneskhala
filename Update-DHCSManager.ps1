[CmdletBinding()]
param([switch]$NoShortcuts)

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

& (Join-Path $repositoryRoot 'Install-DHCSManager.ps1') -NoShortcuts:$NoShortcuts -Confirm:$false
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
