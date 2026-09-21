[CmdletBinding()]
param(
    [switch]$NoShortcuts,
    [string]$InstallRoot,

    # 저장소 없이 받은 폴더가 최신 버전 정보를 묻는 곳. `current` 가 심볼릭
    # 링크라 주소는 고정이고 내용만 바뀐다. 11월 winget 전환에서 이 값이
    # 그대로 쓰인다.
    [string]$ReleaseInfoUrl = 'https://csm-2026.com/current/release.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 이 파일은 BOM 붙은 UTF-8 이다. PowerShell 5.1 은 BOM 없는 .ps1 을 cp949 로
# 읽어 한글을 깨뜨린다 - 안내문을 한글로 쓰려면 BOM 이 있어야 한다.

# 사람에게 보일 실패는 예외로 내지 않는다. PowerShell 이 메시지 뒤에
# "위치 ...:41 문자:9" 같은 스택을 붙이는데, 그걸 본 사람은 안내문까지
# 오류로 읽고 손을 못 쓴다. 그 화면을 실제로 받아 본 뒤에 바꿨다.
function Stop-WithMessage {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ''
    Write-Host $Message
    Write-Host ''
    exit 1
}

$repositoryRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$installer = Join-Path $repositoryRoot 'Install-DHCSManager.ps1'
$metadata = Join-Path $repositoryRoot 'release.json'

# 앱 본체만 새 것이면 다음 설치 때 다시 옛 설치기 오류를 밟는다. 따라서 한 번의
# 업데이트는 실행 파일과 아래 세 배포 도구를 같은 `current` 릴리스에서 함께 받는다.
# 모두 임시 파일로 받은 뒤 검증하고 한꺼번에 교체한다. 하나라도 실패하면 기존 묶음은
# 그대로 남는다. HTTPS 전송 보호와 PowerShell 파서는 'HTML 오류 페이지를 ps1로 저장'
# 하는 실수를 막는 장치이며, 앱 ZIP의 서명 검증을 대체하는 보안 경계는 아니다.
function Refresh-BootstrapBundle {
    param([Parameter(Mandatory = $true)][string]$BaseUrl)

    $names = @('Install-DHCSManager.ps1', 'Update-DHCSManager.ps1', 'START-HERE.md')
    $pending = @()
    try {
        foreach ($name in $names) {
            $temporary = Join-Path ([IO.Path]::GetTempPath()) (
                'DH.CSManager-bootstrap.' + [Guid]::NewGuid().ToString('N') + '.' + $name)
            Invoke-WebRequest -Uri ($BaseUrl.TrimEnd('/') + '/' + $name) `
                -OutFile $temporary -UseBasicParsing
            if ((Get-Item -LiteralPath $temporary).Length -eq 0) {
                throw "$name is empty"
            }
            if ($name.EndsWith('.ps1')) {
                $tokens = $null
                $parseErrors = $null
                [Management.Automation.Language.Parser]::ParseFile(
                    $temporary, [ref]$tokens, [ref]$parseErrors) | Out-Null
                if ($parseErrors.Count -gt 0) {
                    throw "$name is not valid PowerShell"
                }
            }
            $pending += [PSCustomObject]@{ Name = $name; Temporary = $temporary }
        }

        foreach ($entry in $pending) {
            Move-Item -LiteralPath $entry.Temporary `
                -Destination (Join-Path $repositoryRoot $entry.Name) -Force
        }
    }
    catch {
        foreach ($entry in $pending) {
            Remove-Item -LiteralPath $entry.Temporary -Force -ErrorAction SilentlyContinue
        }
        Stop-WithMessage @"
배포 도구 묶음을 최신화하지 못했습니다.
$($_.Exception.Message)

설치본과 기존 안내문은 그대로입니다. 인터넷 연결을 확인한 뒤 다시 실행하세요.
"@
    }
}

if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    Stop-WithMessage "설치 스크립트가 없습니다: $installer`n이 파일과 같은 폴더에 Install-DHCSManager.ps1 과 release.json 이 있어야 합니다."
}

# Git 저장소로 받았으면 최신 release.json 을 당겨 온다. 파일만 받은 사람은
# 저장소가 없다 - 그때는 옆에 있는 release.json 그대로 설치한다. 저장소를
# 요구하면 받는 사람마다 GitHub 계정과 권한이 필요해진다.
$isRepository = Test-Path -LiteralPath (Join-Path $repositoryRoot '.git')

# **`.git` 이 있다고 Git 을 요구하지 않는다** (2026-09-14 사용자 신고).
#
# 운영자가 자기 clone 폴더를 그대로 복사해 보내면 `.git` 이 딸려 간다. 받는
# 사람은 "파일을 받았는데도" 이 스크립트가 Git 설치를 요구하는 화면을 봤다 -
# 바로 아래 `else` 에 서버에서 받는 길이 멀쩡히 있는데도. 파일로 받은 사람에게
# Git 을 깔게 하는 것은 배포를 막는 것이지 지키는 것이 아니다.
#
# 그래서 Git 이 **없으면** 저장소가 아닌 것처럼 서버 경로로 간다. Git 이 있으면
# 예전대로 `pull --ff-only` 를 쓴다 - 진짜 clone 을 쓰는 운영자의 경로는 그대로다.
if ($isRepository) {
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        Write-Host 'Git 이 없어 서버에서 최신 버전 정보를 받습니다. (이 폴더는 복사본입니다)'
        $isRepository = $false
    }
}

if ($isRepository) {

    # 먼저 더러운 파일이 있는지 본다. 그냥 pull 하면 git 이 영어로 거절하는데,
    # 안내서 파일 하나가 수정됐다는 이유로 앱 업데이트가 막히는 것이라
    # 받는 사람이 그 메시지만 보고는 손을 못 쓴다.
    # 추적 중인 파일의 수정만 센다. 아래 안내의 `checkout -- .` 은 추적 파일만
    # 되돌리므로, 추적 안 되는 파일(??)까지 세면 안내대로 해도 영원히 막힌다
    # (2026-09-11 실사용: 시험용 사본 하나와 손으로 넣은 ZIP 하나로 멈췄다).
    # 추적 안 되는 파일은 pull --ff-only 를 막지 않는다 - 들어올 파일과 이름이
    # 겹칠 때만 막고, 그때는 아래 pull 실패 안내로 간다.
    $dirty = & $git.Source -C $repositoryRoot status --porcelain --untracked-files=no
    if ($LASTEXITCODE -ne 0) {
        Stop-WithMessage "git status 가 실패했습니다 ($LASTEXITCODE). 설치본은 그대로입니다."
    }
    if (-not [string]::IsNullOrWhiteSpace(($dirty | Out-String))) {
        # `status` 가 M 이라고 적어도 **내용은 같을 수 있다** (2026-09-18 Round 11 U-8).
        # `core.autocrlf` 가 켜진 Windows PC 에서 어떤 도구가 파일을 LF 로
        # 덮어쓰면, git 은 그 파일을 영원히 수정된 것으로 적는다 - 블롭 해시가 양쪽
        # 같아도 그렇다. 체크아웃하면 CRLF 가 될 파일인데 작업트리가 LF 라서
        # stat 캐시를 못 갱신하기 때문이다. 그때 `git diff` 는 **빈 출력**이다.
        #
        # 그래서 "사용자가 고쳤는가" 를 `status` 가 아니라 **내용**으로 판단한다.
        # `diff --quiet HEAD` 는 스테이지된 것까지 함께 보고, 줄바꿈 유령에는
        # 0(차이 없음)을 낸다.
        #
        # 2026-09-11 에 같은 계열을 한 번 닫았다(추적 안 되는 파일). 이번은
        # 추적되는데 내용이 같은 파일이라 그 수정의 사정거리 밖이었다.
        # `2>$null` 을 붙이지 마라. PowerShell 은 네이티브 exe 의 stderr 를 리다이렉트할 때
        # 줄마다 ErrorRecord(NativeCommandError)로 감싸고, 그러면 이 스크립트가 거기서
        # 끊긴다 - git 이 바로 이 상황에서 "LF will be replaced by CRLF" 를 stderr 로
        # 낸다. 대신 `core.safecrlf=false` 로 그 경고를 **안 만들게** 한다.
        & $git.Source -C $repositoryRoot -c core.safecrlf=false diff --quiet HEAD
        if ($LASTEXITCODE -eq 0) {
            # 되돌릴 내용이 없다 - 여기서 `checkout -- .` 은 아무것도 버리지 않는다.
            # 그냥 두면 `pull` 이 "local changes would be overwritten" 로 막는다.
            Write-Host '줄바꿈만 다른 파일을 정리합니다. (고친 내용은 없습니다)'
            & $git.Source -C $repositoryRoot -c core.safecrlf=false checkout -- .
            $dirty = & $git.Source -C $repositoryRoot -c core.safecrlf=false `
                        status --porcelain --untracked-files=no
        }
    }
    if (-not [string]::IsNullOrWhiteSpace(($dirty | Out-String))) {
        $names = ($dirty | ForEach-Object { $_.Substring(3) }) -join ', '
        Stop-WithMessage @"
이 폴더의 파일이 수정돼 있어서 최신 버전을 받아올 수 없습니다.
수정된 파일: $names

이 폴더는 배포용이라 직접 고칠 일이 없습니다. 아래를 그대로 쳐서 되돌린 뒤
이 스크립트를 다시 실행하세요. 업무 자료와는 무관하며 지워지지 않습니다.

    git -C "$repositoryRoot" checkout -- .

설치본은 그대로입니다. 바뀐 것이 없습니다.
"@
    }

    & $git.Source -C $repositoryRoot pull --ff-only
    if ($LASTEXITCODE -ne 0) {
        Stop-WithMessage @"
최신 버전 정보를 받아오지 못했습니다 (git pull --ff-only, 코드 $LASTEXITCODE).

인터넷이 안 되거나, 회사 Git 계정 권한이 만료됐을 수 있습니다.
연결을 확인하고 다시 해 보시고, 그래도 안 되면 운영자에게 알려 주세요.

설치본은 그대로입니다. 바뀐 것이 없습니다.
"@
    }
}
else {
    # 저장소 없이 받은 폴더다. 최신 버전 정보를 **서버에서** 받아 온다.
    # 이게 없으면 새 버전이 나올 때마다 운영자가 폴더를 다시 보내야 하고,
    # 그러면 자동 업데이트라고 할 수가 없다(사용자 지적, 2026-09-08).
    Write-Host "최신 버전 정보를 확인합니다..."
    $fresh = Join-Path ([IO.Path]::GetTempPath()) 'DH.CSManager-release.json'
    try {
        Invoke-WebRequest -Uri $ReleaseInfoUrl -OutFile $fresh -UseBasicParsing
    }
    catch {
        if (Test-Path -LiteralPath $metadata -PathType Leaf) {
            Stop-WithMessage @"
최신 버전 정보를 받아오지 못했습니다.
$($_.Exception.Message)

인터넷이 안 되거나 사내 방화벽이 csm-2026.com 을 막고 있을 수 있습니다.
연결을 확인하고 다시 해 보세요. 설치본은 그대로입니다.
"@
        }
        Stop-WithMessage "release.json 이 없고 서버에도 닿지 못했습니다.`n운영자에게 알려 주세요."
    }

    # 받은 것이 진짜 release.json 인지 보고 나서야 덮어쓴다. 깨진 응답
    # (사내 프록시의 로그인 페이지 같은 것)으로 멀쩡한 파일을 잃으면 안 된다.
    try {
        $probe = Get-Content -LiteralPath $fresh -Raw -Encoding utf8 | ConvertFrom-Json
        if ($probe.app_id -ne 'DH.CSManager' -or [string]::IsNullOrWhiteSpace([string]$probe.release_id)) {
            throw 'not a DH.CSManager release.json'
        }
    }
    catch {
        Remove-Item -LiteralPath $fresh -Force -ErrorAction SilentlyContinue
        Stop-WithMessage @"
서버에서 받은 정보를 읽을 수 없습니다. 사내 프록시가 가로챘을 수 있습니다.
브라우저로 $ReleaseInfoUrl 이 열리는지 확인하고, 안 되면 운영자에게 알려 주세요.

설치본은 그대로입니다.
"@
    }
    Move-Item -LiteralPath $fresh -Destination $metadata -Force
    Write-Host "최신 버전: $($probe.release_id)"
}

# `ReleaseInfoUrl`을 바꾸어 사내 시험 서버를 쓰는 경우에도 같은 current 묶음을
# 받도록, 주소를 따로 하드코딩하지 않는다.
if ($ReleaseInfoUrl -notmatch '/release\.json$') {
    Stop-WithMessage "ReleaseInfoUrl 은 /release.json 으로 끝나야 합니다: $ReleaseInfoUrl"
}
$bootstrapBaseUrl = $ReleaseInfoUrl -replace '/release\.json$', ''
Write-Host '설치기·업데이터·안내문을 최신 묶음으로 갱신합니다...'
Refresh-BootstrapBundle -BaseUrl $bootstrapBaseUrl

# 이미 그 버전이면 아무것도 받지 않는다 (2026-09-16). 전에는 매번 전체를 다시
# 설치했다 - 220MB 를 받아 같은 파일로 바꿔 끼웠다.
$installedRoot = if ([string]::IsNullOrWhiteSpace($InstallRoot)) { Join-Path $env:LOCALAPPDATA 'DH.CSManager' } else { $InstallRoot }
$installedStamp = Join-Path $installedRoot 'installed_release.json'
try {
    $wanted = [string](Get-Content -LiteralPath $metadata -Raw -Encoding utf8 | ConvertFrom-Json).release_id
    $have = if (Test-Path -LiteralPath $installedStamp -PathType Leaf) {
        [string](Get-Content -LiteralPath $installedStamp -Raw -Encoding utf8 | ConvertFrom-Json).release_id
    } else { '' }
}
catch { $wanted = ''; $have = '' }
if (-not [string]::IsNullOrWhiteSpace($wanted) -and $wanted -eq $have) {
    Write-Host ''
    Write-Host "이미 최신 버전입니다 ($have). 받을 것이 없습니다."
    Write-Host ''
    exit 0
}

Write-Host "설치를 시작합니다. 바뀐 파일만 받으므로 보통 금방 끝납니다."

$installArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer, '-NonInteractive')
if ($NoShortcuts) { $installArguments += '-NoShortcuts' }
if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) { $installArguments += @('-InstallRoot', $InstallRoot) }
& powershell.exe @installArguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
