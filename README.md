# DH.CSManager 배포

이 저장소는 사용자 설치용 파일만 담는다. 개발 소스·Python 가상환경·서명 개인키는 없다.

> **컴퓨터를 새로 깐 분은 [`START-HERE.md`](START-HERE.md) 를 보세요.**
> Git 설치부터 회원가입·업데이트까지 한 줄씩 따라 하도록 적어 뒀습니다.
> 아래는 이미 익숙한 사람을 위한 요약입니다.

## 처음 설치

Git for Windows가 설치된 PowerShell에서 실행한다. 저장소는 private 이므로 회사 Git
계정 권한이 필요하다 — 그 권한이 최초 신뢰 경계다.

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

설치 스크립트는 ZIP의 SHA-256을 `release.json` 값과 비교하고, 압축 구조를 확인한 뒤
staging으로 풀어 기존 버전을 백업하고 교체한다. 실패하면 기존 설치를 원복한다.

이 저장소를 받은 경로와 Git 권한이 최초 신뢰 경계다. 인증서 없는 배포이므로 인터넷에서
출처가 불명확한 복제 명령이나 `irm ... | iex` 방식은 사용하지 않는다.
