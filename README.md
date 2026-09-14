# DH.CSManager 배포

이 저장소는 사용자 설치용 파일만 담는다. 개발 소스·Python 가상환경·서명 개인키는 없다.

> **컴퓨터를 새로 깐 분은 [`START-HERE.md`](START-HERE.md) 를 보세요.**
> 받은 폴더를 푸는 것부터 회원가입·업데이트까지 한 줄씩 따라 하도록 적어 뒀습니다.
> **Git 도 GitHub 계정도 필요 없습니다** — Git 경로는 그 문서의 부록이다.
> 아래는 이미 익숙한 사람을 위한 요약입니다.

## 운영자 — 새 사람에게 배포할 때

**받는 사람에게 저장소를 주지 않는다.** 설치기는 git 을 안 쓰고, 산출물·버전
정보·안내서가 전부 `csm-2026.com` 에서 온다. 한 번 보내면 그 뒤로는 손이 안 간다.

| 순서 | 무엇 | 어디서 |
|---|---|---|
| 1 | **안내서 링크** 하나 (또는 아래 ZIP) | 메일·메신저로 **한 번만** |
| 2 | **초대 코드** | 앱 `🌐 서버 계정` → `초대 코드` → `코드 발급` |
| 3 | **가입 승인** | 그 사람이 가입한 뒤 `🌐 서버 계정` 에서 우클릭 → 승인 |

**파일을 안 보내도 된다.** 받는 사람이 인터넷만 되면 안내서의 「빠른 길」대로
설치기와 `release.json` 을 서버에서 직접 받아 깐다. 링크 하나면 끝난다.

    https://csm-2026.com/current/START-HERE.md

파일로 주고 싶으면(인터넷이 막힌 PC 등) 아래로 묶는다. **clone 폴더를 통째로
복사하지 않는다** — `.git` 이 딸려 가고, 받는 사람 PC 에서 그게 저장소로 보인다.
아래 명령은 필요한 넷만 담는다.

```powershell
Compress-Archive -Path START-HERE.md, Install-DHCSManager.ps1, `
    Update-DHCSManager.ps1, release.json `
    -DestinationPath "$env:USERPROFILE\Desktop\DH.CSManager-Setup.zip" -Force
```

받는 사람이 `csm-2026.com` 에 닿는지 **설치 전에** 확인하게 한다.

### 릴리스마다 다시 보낼 것은 없다

`current` 가 릴리스 폴더를 가리키는 심볼릭 링크라, 배포하면 아래 셋이 한꺼번에
최신이 된다. 주소는 고정이고 내용만 바뀐다.

| 주소 | 누가 본다 |
|---|---|
| `/current/release.json` | `Update-DHCSManager.ps1` — 그래서 사용자가 스스로 업데이트한다 |
| `/current/START-HERE.md` | 아직 안 깐 사람. 링크를 한 번만 보내면 된다 |
| `/current/Install-DHCSManager.ps1` | 첫 설치를 명령 한 줄로 하고 싶을 때 |

안내서는 배포판 안(exe 옆)에도 들어간다 — 이미 깐 사람은 앱을 업데이트하면
안내서도 같이 최신이 되고, 인터넷 없이도 읽는다.

**치른 값**: 기대 해시가 산출물과 같은 서버에서 온다. 전에는 GitHub 가 그 역할이라
서버가 털려도 해시가 안 맞아 멈췄다. 되찾으려면 설치기가 `manifest.json.sig` 를
검증해야 한다(개인키는 서버에 없다). 앱은 이미 그렇게 한다.

## 저장소로 설치 — 운영자와 스스로 업데이트할 사람만

받는 사람 대부분은 위 「운영자」 절대로 폴더를 받으면 되고 이 절은 필요 없다.
이 경로는 Git for Windows 와 회사 Git 계정 권한이 필요하다. 대신 새 버전이
나와도 폴더를 다시 받지 않고 `Update-DHCSManager.ps1` 이 스스로 당겨 온다.

**저장소에는 ZIP 이 없다.** `release.json` 의 `archive_url`(https 만 허용)·
`archive_sha256` 과 서명만 들어 있고, 산출물(약 67MB)은 `csm-2026.com/releases/`
에서 받는다. 그래서 clone 이 가볍고, 11월 winget 전환 때 산출물을 또 옮기지
않는다 — winget 의 `InstallerUrl`/`InstallerSha256` 이 같은 값이다.
설치에는 **저장소 권한과 서버 접근이 둘 다** 필요하다.

```powershell
git clone --depth 1 --branch dh-csmanager-release https://github.com/solesence-cloud/agneskhala.git DH.CSManager-Release
cd DH.CSManager-Release
powershell -ExecutionPolicy Bypass -File .\Install-DHCSManager.ps1 -NonInteractive
```

앱은 `%LOCALAPPDATA%\DH.CSManager`에 설치한다. 업무 데이터는 기존처럼
`%USERPROFILE%\CS_Manager_Data`에 남으므로 업데이트가 데이터를 지우지 않는다.

설치 뒤 회원가입에는 **운영자에게 받은 초대 코드**가 필요하다. 코드 없이는
가입 자체가 되지 않고, 가입 뒤에도 운영자가 승인해야 로그인된다.
서명 인증서가 없는 배포라 첫 실행 때 Windows SmartScreen 경고가 뜬다 —
`추가 정보` → `실행` 으로 넘어간다.

## 업데이트

앱을 종료한 뒤, 복제한 배포 저장소에서 실행한다.

```powershell
powershell -ExecutionPolicy Bypass -File .\Update-DHCSManager.ps1
```

폴더가 **clone 이고 Git 이 깔려 있으면** `Update-DHCSManager.ps1` 이 먼저
`git pull --ff-only` 를 하므로 따로 당길 필요는 없다. 파일로만 받은 폴더(또는
Git 이 없는 PC)에서는 같은 스크립트가 `csm-2026.com/current/release.json` 에서
최신 정보를 받아 온다 — **받는 사람에게 Git 을 요구하지 않는다**(2026-09-14).

설치 스크립트는 ZIP을 내려받아 SHA-256을 `release.json` 값과 비교하고, 압축 구조를
확인한 뒤 staging으로 풀어 기존 버전을 백업하고 교체한다. 실패하면 기존 설치를
원복한다. **지문이 다르면 설치하지 않는다** — 산출물이 인증 없는 URL 에
있으므로 여기가 바꿔치기를 막는 자리다.

Git 권한과 **서명·지문 대조**가 신뢰 경계다. 인증서 없는 배포이므로 인터넷에서
출처가 불명확한 복제 명령이나 `irm ... | iex` 방식은 사용하지 않는다.
