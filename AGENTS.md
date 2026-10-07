# Repository Guidelines

## 언어 및 작업 원칙

- 모든 사용자 대화, 분석, 설명, 작업 보고는 한국어로 작성한다.
- 코드 식별자, 함수명, 파일명, 명령어, 로그 원문은 필요한 경우 영어 그대로 유지한다.
- 정상 동작하는 코드를 불필요하게 재작성하지 않는다. 변경은 최소 범위로 수행하고 새 로직은 작은 함수로 나눈다.
- 기존 RG Cube 정상 동작을 보존한다. 변경 후 `README.txt`와 버전 정보를 갱신한다.

## 프로젝트 구성 및 실행 환경

Windows PowerShell 기반 GUI 앱 **ES-DE Sync**는 Dropbox의 ES-DE 라이브러리를 ADB로 Android 기기에 동기화한다. 현재 기준 버전은 **v1.4.4 Final**이다.

- `ESDE-Sync.ps1`: GUI 애플리케이션.
- `sync-worker.ps1`: 동기화 작업자.
- `install.ps1`, `install.cmd`: 설치 스크립트 및 실행 진입점.
- `uninstall.ps1`, `uninstall.cmd`: 제거 스크립트 및 실행 진입점.
- `README.txt`: 사용 및 변경 안내.

설치 경로는 `%LOCALAPPDATA%\ESDE-Sync`이다. 로그는 `%LOCALAPPDATA%\ESDE-Sync\State\sync.log`, 상태는 `%LOCALAPPDATA%\ESDE-Sync\State\status.json`에 저장한다. ADB 경로는 `%LOCALAPPDATA%\ESDE-Sync\platform-tools\adb.exe`이다.

Windows PowerShell 5.1 호환성을 유지하고 PowerShell 파일은 UTF-8 BOM을 유지한다. GUI 읽기와 작업자 쓰기가 동시에 가능하도록 로그 접근에 `FileShare.ReadWrite`를 유지한다.

## 동기화 및 삭제 안전 규칙

- `Dropbox\ES-DE Sync\roms`의 첫 번째 수준 폴더에서 선택된 시스템을 감지한다.
- 선택된 시스템의 `roms`, `gamelists`, `downloaded_media`만 동기화한다. 선택되지 않은 시스템은 절대 삭제하거나 수정하지 않는다.
- 삭제 로직을 수정하기 전에 원격 경로가 선택된 시스템 범위 안에 있는지 반드시 검증한다. 안전하게 판단할 수 없으면 삭제하지 않고 중단한다.
- `_UNREGISTERED`, `_TEST`는 Android 로컬 전용 예약 폴더이다. 폴더와 모든 하위 항목을 일반 동기화에서 항상 제외하며 삭제, 덮어쓰기, Dropbox 비교 및 미러링을 금지한다.

## Android 실행 상태 검사

- 동기화 전에 foreground 앱을 확인한다. 게임, 에뮬레이터 또는 다른 앱이 실행 중이면 동기화를 차단하고 해당 앱을 강제 종료하지 않는다.
- foreground 감지 실패 또는 불확실한 결과는 안전을 위해 동기화를 차단한다.
- 검사 통과 후 **ES-DE 종료 → 동기화 → ES-DE 재실행** 순서를 지킨다.
- ES-DE 패키지는 `org.es_de.frontend`, activity는 `org.es_de.frontend/.MainActivityHomeApp`이다.
- GUI 종료 시 `adb kill-server`를 실행한다.
- Pocket Air Mini에서는 `dumpsys activity`만으로 foreground를 신뢰하지 않는다. `dumpsys activity activities`, `dumpsys activity top`, `dumpsys window displays`, `dumpsys window windows`, `dumpsys input`을 함께 조사하고 기기별 진단 로그를 남긴다. HOME 패키지가 ES-DE라는 이유만으로 동기화를 허용하지 않는다.

## 예정 기능: 기존 ROM 채택 및 gamelist 보존

- 신규 기기 또는 시스템 최초 채택 시 일반 미러링 전에 기존 Android ROM과 Dropbox ROM을 SHA-256으로 비교한다.
- 해시가 일치하면 동일 ROM으로 간주하고 Dropbox가 관리하는 정상 복사본만 유지한다. 일치하는 Dropbox ROM이 없으면 기존 Android ROM을 `_UNREGISTERED`로 이동한다.
- 예약 폴더 내부는 검사하거나 이동하지 않는다. 기기별·시스템별 채택 상태를 저장하여 반복 실행에도 안전하게 동작하고 매 동기화마다 파괴적 이관을 반복하지 않는다.
- 정상 게임은 Dropbox `gamelist.xml`을 기준으로 한다. Android의 `<path>`가 `./_UNREGISTERED/` 또는 `./_TEST/`로 시작하는 `<game>` 항목은 향후 병합하여 보존한다.
- gamelist 병합에는 정규식 대신 XML 파싱을 사용하고 중복 `<path>`를 만들지 않는다. 이후 Dropbox 업데이트에도 로컬 항목을 유지한다.

## 변경 검증

변경 후 선택 범위 제한, 예약 폴더 보존, foreground 차단, ES-DE 재실행, 동시 로그 접근을 확인한다. foreground 변경은 RG Cube와 Pocket Air Mini의 진단 결과를 비교한다. 테스트 결과와 미검증 사항은 한국어로 보고한다.
