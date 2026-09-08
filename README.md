# DH.CSManager 배포

이 저장소는 사용자 설치용 파일만 담는다. 개발 소스·Python 가상환경·서명 개인키는 없다.

> **컴퓨터를 새로 깐 분은 [`START-HERE.md`](START-HERE.md) 를 보세요.**
> Git 설치부터 회원가입·업데이트까지 한 줄씩 따라 하도록 적어 뒀습니다.
> 아래는 이미 익숙한 사람을 위한 요약입니다.

## 운영자 — 새 사람에게 배포할 때

안내서는 이 저장소 **안**에 있다. 저장소를 받는 법을 안내서가 적고 있으므로,
받기 전에는 못 본다. 그 고리를 끊는 것이 운영자의 몫이다 — **세 가지를 준다.**

| 순서 | 무엇 | 어디서 |
|---|---|---|
| 1 | **저장소 권한** | GitHub `solesence-cloud/agneskhala` 에 그 사람 계정을 추가 |
| 2 | **안내서 링크** | `https://github.com/solesence-cloud/agneskhala/blob/dh-csmanager-release/START-HERE.md` |
| 3 | **초대 코드** | 앱 `🌐 서버 계정` → `초대 코드` → `코드 발급` |

2번 링크는 **1번을 준 뒤에야 열린다**(private 저장소다). 순서를 지킨다.
링크 대신 `START-HERE.md` 파일을 그대로 보내도 된다 — 어느 쪽이든 **최신본은
이 저장소의 `dh-csmanager-release` 브랜치**가 정본이다.

받는 사람이 `csm-2026.com` 에 닿는지도 미리 확인하게 한다. 설치가 거기서
산출물을 받는다.

## 처음 설치

Git for Windows가 설치된 PowerShell에서 실행한다. 저장소는 private 이므로 회사 Git
계정 권한이 필요하다.

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

`Update-DHCSManager.ps1` 이 `git pull --ff-only` 를 먼저 하므로 따로 당길 필요는 없다.

설치 스크립트는 ZIP을 내려받아 SHA-256을 `release.json` 값과 비교하고, 압축 구조를
확인한 뒤 staging으로 풀어 기존 버전을 백업하고 교체한다. 실패하면 기존 설치를
원복한다. **지문이 다르면 설치하지 않는다** — 산출물이 인증 없는 URL 에
있으므로 여기가 바꿔치기를 막는 자리다.

Git 권한과 **서명·지문 대조**가 신뢰 경계다. 인증서 없는 배포이므로 인터넷에서
출처가 불명확한 복제 명령이나 `irm ... | iex` 방식은 사용하지 않는다.
