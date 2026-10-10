# Repository Guidelines

## 언어와 변경 원칙

모든 대화·분석·작업 보고는 한국어로 작성한다. 식별자, 파일명, 명령어, 로그 원문은 필요하면 영어를 유지한다. 정상 코드를 불필요하게 재작성하지 말고 변경을 작은 함수로 제한한다. 기존 사용자 데이터·설정·프로필과 RG Cube 정상 동작을 보존한다. 동작 변경 시 README와 버전 계약을 함께 검토한다.

## 구성과 실행 환경

현재 개발 기준은 **v1.5.0 Stage 3 개발** (stable 기준 v1.4.9)이며 `version.json`이 버전의 단일 원본이다. Windows 11과 Windows PowerShell 5.1 호환성을 유지하고 모든 PS1은 UTF-8 BOM으로 저장한다.

- `ESDE-Sync.ps1`: Windows Forms GUI, ADB 및 worker 실행.
- `sync-worker.ps1`: ROM mirror, foreground 검사, gamelist 병합, media ownership의 runtime 원본.
- `update-common.ps1`, `update-transaction.ps1`, `update-worker.ps1`: 패키지 검증, App 교체·백업·rollback.
- `install.ps1`/`install.cmd`, `uninstall.ps1`/`uninstall.cmd`: 설치·제거 진입점.
- `scripts/package-release.ps1`, `tests/*.ps1`: 패키징과 회귀 검증.

설치 루트는 `%LOCALAPPDATA%\ESDE-Sync`이다. `State\sync.log`, `State\status.json`을 사용하며 로그는 `FileShare.ReadWrite`를 유지한다. ADB는 `platform-tools\adb.exe`이고 실행 디렉터리는 App 밖으로 고정한다. GUI 종료 시 kill-server 결과와 서버 종료를 확인한다.

## 선택 범위와 Android 안전 검사

원본 `roms`의 첫 수준 폴더가 선택 시스템이다. 선택되지 않은 시스템은 수정하지 않는다. ROM은 strict mirror를 유지하되 `_TEST`/`_UNREGISTERED` 구성요소와 하위는 대소문자와 무관하게 비교·전송·삭제에서 제외한다. 원격 목록 실패와 빈 목록을 구분하고 삭제 전에 허용 루트 및 선택 시스템 경계를 검증한다. 불명확하면 중단한다. 실제 링크와 읽을 수 없는 Dropbox placeholder도 안전하게 차단한다.

power·keyguard, activity activities/top, window windows/displays/policy, input, HOME 증거를 수집한다. Awake·잠금 해제와 activity/window/input 합의가 안정적으로 두 번 확인된 SAFE만 통과한다. HOME 설정이나 activity 하나만으로 허용하지 않는다. 게임·제3 앱, 수면, SystemUI, 누락·모순은 차단하고 게임을 강제 종료하지 않는다. 검사 후 ES-DE 종료 → 처리 → 재실행 순서이며, 이번 worker가 종료했다면 오류에도 복구 재실행을 시도한다. 패키지/activity는 `org.es_de.frontend` / `org.es_de.frontend/.MainActivityHomeApp`이다.

## Gamelist metadata 정책

ROM 존재 여부를 XML 엔트리로 판단하거나 새 game을 자동 생성하지 않는다. 일반 metadata는 Dropbox BASE가 기준이다. 동일 managed path의 Android playcount/lastplayed/playtime를 tag 단위로 보존하고 기존 local-only 경로 노드는 전체를 병합한다. 예약 이름은 경로의 어느 구성요소에도 적용하며 정규화 key는 대소문자를 구분한다. 로컬 충돌은 Android 우선, 전체 game 노드와 알 수 없는 필드를 보존한다. XML parser와 메모리 wrapper로 `alternativeEmulator`/`gameList` sibling 구조 및 top-level 순서를 유지한다. traversal·잘못된 XML은 차단한다.

Dropbox XML 사전 검증 후 ES-DE 종료 상태에서 Android XML을 pull한다. 모든 선택 시스템의 병합 준비·검증이 완료되어야 mutation을 시작한다. Android temp push → 재-pull → XML/SHA 검증 → 기존 파일 동시 변경 확인 → 같은 디렉터리 mv로 교체한다. 원본 부재도 local-only가 있으면 보존하며, 없으면 pull/parse 이후 정확한 gamelist.xml만 제거한다. unknown 파일은 보존한다.

## Media ownership과 복구

media는 ROM mirror와 별도 처리한다. `State\media-ownership\<source-device identity SHA>.json`에 원본 정규화 경로·identity, ADB serial, schema, 경로·배포 SHA·크기·시각을 저장한다. 다른 원본/기기의 manifest를 재사용하지 않는다. 손상·중복·잘못된 경로는 자동 초기화하지 않고 중단한다.

- 최초 도입 시 기존 Android media는 모두 unmanaged이다. 동일 경로·동일 SHA도 자동 채택하지 않는다.
- Android-only unmanaged는 보존한다. 동일 경로의 다른 SHA는 변경 전에 전체 작업을 차단한다.
- 신규 파일은 SHA 검증 전송 성공 후만 managed로 기록한다.
- managed 현재 SHA가 마지막 deployed SHA와 같을 때만 원본 변경을 갱신하거나 원본 삭제에 따라 단일 파일을 삭제한다. Android 수정본은 덮어쓰기·삭제하지 않고 충돌로 차단한다.
- 소유권 판단은 timestamp가 아닌 SHA-256이다. native/toybox sha256sum과 PC pull fallback을 사용한다. unknown hash는 destructive mutation 근거가 아니다.

전체 media 계획을 검증하고 기존 managed 변경·삭제 전에 PC 백업을 확보한다. temp 전송·SHA·교체 검증 후 전체 성공 시 manifest를 atomic 저장한다. `State\media-transactions` journal로 작업을 기록하며 실패는 media 변경을 역순 rollback한다. **이미 처리한 ROM/gamelist까지 rollback하지는 않는다.** 미완료·손상 journal 또는 rollback 실패는 후속 작업을 차단하고 자료를 보존한다. 자동 crash recovery는 없으며 정상 종료·성공한 rollback의 임시 bytes만 정리하고 journal은 유지한다.

## 업데이트·검증·배포

App 교체와 rollback은 State/config.json/platform-tools를 보존한다. GUI/operation mutex, visible startup confirmation, 원래 오류와 rollback 오류 분리를 유지한다. `Get-PackageFiles`의 기존 App 8개 계약을 지켜 v1.4.8 설치 updater가 이해하지 못하는 새 runtime 파일을 추가하지 않는다. ZIP/hash/digest/manifest 검증과 **tag v1.4.8의 실제 validator** 호환 시험을 유지한다.

`powershell.exe -NoProfile -File .\tests\media-ownership-static.ps1`처럼 테스트를 실행한다. foreground·gamelist·media 및 기존 updater/안전 테스트 전체, PowerShell 5.1 구문, BOM, `git diff --check`를 확인한다. 패키지는 `scripts/package-release.ps1 -Version 1.5.0`로 생성·재검증하고 reports/dist/State/로그/개인 설정을 포함하지 않는다.

실기기 시험은 승인된 격리 범위와 백업·전후 SHA를 사용한다. 실제 사용자 라이브러리에 파괴적 시험을 하지 않으며 예상 밖 결과에는 중단하고 증거를 보존한다. Phase A/B의 Retroid 검증은 통과했지만 다른 vendor 검증과 실제 앱 내 v1.4.8→v1.4.9 업데이트는 별도 확인 사항이다. 승인 없이 commit/push/main 병합/tag/Release/설치를 수행하지 않는다.

## v1.5.0 최종 local-only 정책
현재 설계는 docs/v150-local-only-classification.md이다. docs/history는 폐기된 checkpoint 기록이다.
Dropbox는 관리 SOURCE이며 이 기능에서 쓰지 않는다. 관리 ROM list도 source에 만들지 않는다.
_TEST는 manual-only, _UNREGISTERED는 일반 Android 비관리 ROM의 자동 분류 목적지이다.
이후 두 영역은 동일하게 scan/mirror/delete/overwrite 제외 및 gamelist whole-node 보존을 적용한다.
동일 경로 SHA conflict는 ROM을 보존하고 warning을 기록하며 managed XML/media 정책을 유지한다.
다른 경로 같은 SHA는 검증된 save/state/media mapping이 없으면 REVIEW, 다중 SHA 후보는 AMBIGUOUS이다. canonical ROM 중복 전송/ROM-only rename/중복 node 자동 정리는 금지한다.
전체 계획 검증 후 Android 내부 mv/SHA → gamelist verified transfer → inventory refresh → managed mirror 순서이다.
실패는 최소 classification state를 보존하고 후속 mutation을 차단한다. 자동 reverse move/resume 없음.
local-only가 있는 system의 media는 flat naming 정책 확인 전 전체 job을 보류하고 파일/metadata를 유지한다.
Managed runtime3/alternativeEmulator subtree/GB·GBC staging mapping과 기존 안전장치를 유지한다.
실제 데이터/이전 시험 자료 변경, commit/push/main/tag/Release/설치는 별도 승인 없이 하지 않는다.