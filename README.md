# DH.CSManager 배포

이 저장소는 사용자 설치용 파일만 담는다. 개발 소스·Python 가상환경·서명 개인키는 없다.

## 처음 설치

Git for Windows가 설치된 PowerShell에서 배포 담당자가 제공한 저장소 주소를 사용한다.

```powershell
git clone --depth 1 --branch dh-csmanager-release https://github.com/solesence-cloud/agneskhala.git DH.CSManager-Release
cd DH.CSManager-Release
powershell -ExecutionPolicy Bypass -File .\Install-DHCSManager.ps1
```

앱은 `%LOCALAPPDATA%\DH.CSManager`에 설치한다. 업무 데이터는 기존처럼
`%USERPROFILE%\CS_Manager_Data`에 남으므로 업데이트가 데이터를 지우지 않는다.

## 업데이트

앱을 종료한 뒤, 복제한 배포 저장소에서 실행한다.

```powershell
powershell -ExecutionPolicy Bypass -File .\Update-DHCSManager.ps1
```

설치 스크립트는 ZIP의 SHA-256을 `release.json` 값과 비교하고, 압축 구조를 확인한 뒤
staging으로 풀어 기존 버전을 백업하고 교체한다. 실패하면 기존 설치를 원복한다.

이 저장소를 받은 경로와 Git 권한이 최초 신뢰 경계다. 인증서 없는 배포이므로 인터넷에서
출처가 불명확한 복제 명령이나 `irm ... | iex` 방식은 사용하지 않는다.
