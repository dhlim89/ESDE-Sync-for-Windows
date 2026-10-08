ES-DE Sync for Android v1.4.9 Development
======================================

프로그램
--------
ES-DE Sync

대상
----
USB ADB로 연결한 Android 기기

원본
----
Dropbox의 ES-DE Sync 폴더

선택된 시스템
-------------
Dropbox ES-DE Sync\roms 아래에 존재하는 1단계 시스템 폴더입니다.

예:
  roms\gb
  roms\gbc

이면 gb, gbc가 선택된 시스템입니다.

완전 미러 범위
--------------
선택된 시스템에 한해서 다음 영역을 Dropbox와 동일하게 맞춥니다.

- roms
- gamelists
- downloaded_media

단, 각 시스템의 _TEST / _UNREGISTERED 폴더와 그 하위 내용은 완전히 제외합니다.

예:
  /storage/emulated/0/ROMs/gb/_TEST
  /storage/emulated/0/ROMs/gb/_UNREGISTERED
  /storage/emulated/0/ROMs/gbc/_TEST
  /storage/emulated/0/ROMs/gbc/_UNREGISTERED

_TEST / _UNREGISTERED 규칙
----------
- Android의 _TEST / _UNREGISTERED는 삭제하지 않음
- Android의 _TEST / _UNREGISTERED 내부 파일도 삭제하지 않음
- Dropbox의 _TEST / _UNREGISTERED는 복사하지 않음
- Dropbox와 Android의 완전 미러 비교 대상에서 _TEST / _UNREGISTERED 전체 제외

_TEST는 테스트 ROM용, _UNREGISTERED는 로컬 ROM 보관용 예약 공간입니다. 이번 버전은 자동 ROM 이관을 수행하지 않습니다.

권장
----
Dropbox에는 _TEST / _UNREGISTERED 폴더를 만들지 않는 것을 권장합니다.

정식 라이브러리:
  Dropbox ES-DE Sync

테스트 ROM:
  Android 기기의 각 시스템/_TEST

이렇게 역할을 분리하면 가장 깔끔합니다.

동기화 전 안전 동작
-------------------
1. 포그라운드 앱 검사
2. ES-DE / Android 홈 / System UI이면 진행
3. 게임/에뮬레이터/다른 앱이 실행 중이면 동기화 차단
4. 사전 검사 통과 후 ES-DE 종료
5. 선택된 시스템 완전 미러링 (_TEST / _UNREGISTERED 제외)
6. 완료 후 ES-DE 자동 재실행

설치
----
install.cmd

제거
----
uninstall.cmd

설치 위치
---------
%LOCALAPPDATA%\ESDE-Sync

로그
----
%LOCALAPPDATA%\ESDE-Sync\State\sync.log


v1.4.3 수정
-----------
- sync.log를 GUI와 동기화 작업이 동시에 읽고 쓸 때 발생하던 파일 잠금 오류 수정
- 로그 읽기/쓰기에 FileShare.ReadWrite 적용
- 짧은 재시도 로직 추가
- Dropbox 쪽에 _TEST가 없을 때 시스템 전체를 한 번의 adb push --sync로 처리하도록 성능 복원
- Dropbox에 _TEST가 실수로 존재하면 해당 폴더만 제외하고 안전하게 동기화

_TEST 보존 규칙은 그대로 유지됩니다.


v1.4.4 수정
-----------
- ES-DE Sync 프로그램 창을 닫을 때 adb kill-server를 실행하도록 추가
- 프로그램 종료 후 adb.exe 프로세스가 남지 않도록 정리
- ADB 종료 실패가 있어도 프로그램 종료 자체는 막지 않음

주의:
동시에 다른 프로그램이 같은 ADB 서버를 사용 중이라면 그 연결도 끊길 수 있습니다.

v1.4.5 개발 버전
----------------
- 두 예약 폴더와 하위를 비교/삭제/전송에서 제외하며 내부를 탐색하지 않습니다.
- ROM 원본 시스템 폴더가 사라지면 예약 폴더를 남기고 일반 파일과 빈 폴더만 정리합니다.
- 삭제 전 허용 Android 루트와 현재 선택 시스템 범위를 검증합니다.
- 원격 파일/폴더 목록 조회가 모두 성공한 뒤 삭제하며 조회 오류 시 중단합니다.
- v1.4.5에서는 ReparsePoint 원본을 모두 차단했습니다. v1.4.6에서 아래 방식으로 개선했습니다.
- SHA-256 ROM 채택, gamelist.xml 병합, Pocket Air Mini foreground 개선은 아직 없습니다.
- Android에만 있는 일반 ROM은 기존처럼 삭제됩니다. 예약 ROM의 gamelist 항목은 아직 보존되지 않습니다.
- 실제 기기 검증 전 개발 버전입니다.
정적 모의 검증:
  powershell.exe -NoProfile -File .\tests\safety-static.ps1
실제 ADB를 호출하지 않고 임시 폴더의 모의 파일만 사용합니다.

v1.4.6 개발 버전
----------------
- Windows reparse tag의 이름 대체 비트를 검사하여 symbolic link/junction/mount point를 차단합니다.
- 루트와 상위 폴더도 검사하며, 핸들의 실제 최종 경로가 원본과 일치해야 합니다.
- 일반 파일과 로컬 읽기가 가능한 비링크 reparse 파일을 허용합니다. Dropbox 전용 이름 판정은 없습니다.
- Offline/Recall 속성의 placeholder와 읽기 실패 파일은 삭제 전에 차단합니다. 다운로드/수정은 요청하지 않습니다.
- 모든 선택 원본을 먼저 검증하며 파일 전체를 읽어 읽기 실패를 확인합니다. 대용량 원본에서는 검사 시간이 늘어납니다.
- worker가 ES-DE를 종료한 경우 finally에서 성공/실패와 관계없이 재실행을 한 번 시도합니다.
- preflight 실패 시 재실행하지 않으며, 재실행 실패로 원래 동기화 오류를 덮지 않습니다.
- 예약 폴더, 삭제 범위, 원격 조회 실패 안전장치는 유지합니다.
- SHA-256 채택, gamelist 병합, Pocket Air Mini foreground 개선은 아직 없습니다.
- 실제 Android 검증 전 개발 버전입니다.

추가 모의 검증:
  powershell.exe -NoProfile -File .\tests\local-recovery-static.ps1
v1.4.7 개발 버전
----------------
- 원격 find 식에서 -mindepth를 제거하고 예약 이름 prune와 파일/폴더 종류만 판정합니다.
- 폴더 조회 결과의 정확한 시스템 시작점만 제외합니다. 다른 범위 오류는 계속 차단합니다.
- -print0/NUL 구분으로 공백, 괄호, 따옴표 등을 포함한 이름을 분리합니다.
- 제어문자/줄바꿈이 있는 경로, 예약 경로 출력, NUL 종료가 없는 결과는 안전을 위해 차단합니다.
- ADB 실패와 stderr 오류는 빈 목록으로 취급하지 않습니다.
- Dropbox 처리, ES-DE 복구, foreground 및 예약 정책은 변경하지 않습니다.
- 실제 Android 검증 전 개발 버전입니다.

원격 열거 모의 검증:
  powershell.exe -NoProfile -File .\tests\remote-entries-static.ps1
v1.4.8 1차 개발
----------------
- version.json을 GUI/worker/설치의 단일 버전 기준으로 사용합니다.
- 시작 후 비동기로 GitHub 최신 stable Release를 조회합니다. 조회 실패는 동기화를 막지 않습니다.
- 사용자 버튼 승인 후 ZIP/checksum 다운로드와 digest/manifest/ZIP 검증만 수행합니다.
- 검증된 ZIP은 .Updates 아래에 보관하며 App/State/config/platform-tools에는 적용하지 않습니다.
- 동기화 중 다운로드는 차단하고 업데이트 확인 중에는 동기화를 허용합니다.
- App 교체, GUI 종료, 롤백, 업데이트 후 재실행은 아직 구현하지 않았습니다.
- 배포 ZIP은 App 파일 6개와 설치/제거/README 5개, package-manifest.json만 포함합니다.
- 패키지 검사는 README 첫 줄과 version.json 버전의 일치를 확인합니다.
- 정적 검증: powershell.exe -NoProfile -File .\tests\update-static.ps1
- 개발 패키징: powershell.exe -NoProfile -File .\scripts\package-release.ps1 -Version 1.4.8
- tag 검증 패키징: powershell.exe -NoProfile -File .\scripts\package-release.ps1 -GitPath <git.exe>
v1.4.8 2차 개발 — 안전한 App 적용
--------------------------------
- 검증된 패키지의 설치 버튼을 누르고 승인하면 App 밖의 .Updates/<sessionId>에서 worker를 실행합니다.
- GUI 종료, sync worker 부재, staged 파일/버전/해시를 확인한 뒤 App 디렉터리를 이동합니다.
- 기존 App은 backup/App으로 보관하고 staged/App을 설치 App으로 이동합니다.
- 새 GUI가 sessionId/버전/PID/프로세스 시작 시각을 확인 파일에 기록해야 completed가 됩니다.
- 실패하면 새 App을 격리하고 백업의 검증된 복원 사본을 이동해 이전 GUI를 실행합니다.
- completed 및 롤백 후에도 원본 backup/App은 보존합니다. 자동 백업 삭제는 없습니다.
- State/config.json/platform-tools는 App 교체 및 롤백 대상에서 제외합니다.
- GUI 인스턴스와 sync/update 작업에는 사용자 SID·설치 루트별 Global named mutex를 사용합니다.
- 미완료 세션/rollback_failed가 있으면 새로운 동기화를 차단합니다.
- backing_up/replacing/launching/rolling_back에서 중단된 세션은 재실행 시 보수적으로 롤백합니다.
- 상태는 임시 JSON 작성 후 원자 교체하고 원래 오류와 롤백 오류를 따로 기록합니다.
- v1.4.7 또는 1차 GUI에는 시작 확인 기능이 없어 롤백 시 파일 해시와 가시적인 메인 창으로 복원을 확인합니다.
- 새 GUI 시작 확인 제한은 기본 30초입니다. 이전 GUI를 강제로 종료하지 않습니다.
- 최초 v1.4.7 업그레이드: 동기화/GUI를 종료한 후 패키지의 install.cmd를 실행하세요.
- 수동 설치도 동일한 디렉터리 교체/복구 절차를 사용하고 완료 후 GUI를 실행합니다.
- 미완료 세션 복구 명령(기존 GUI/sync가 종료된 상태에서 실행):
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<AppRoot>\.Updates\<sessionId>\update-worker.ps1" -AppRoot "<AppRoot>" -SessionPath "<AppRoot>\.Updates\<sessionId>"
- rollback_failed에서는 backup/App과 update.log를 보존하고 경로/잠금 원인을 확인한 뒤 재시도합니다.
- 위 미검증 범위는 stage 2 당시 기록입니다. 이후 설치/GUI/rollback과 Android 회귀를 검증했으며 실제 GitHub Release 업데이트는 별도 확인 사항입니다.
- 로컬 트랜잭션 검증: powershell.exe -NoProfile -File .\tests\update-transaction.ps1
- 2차 패키지에는 App 파일 8개와 설치/제거/README 5개, package-manifest.json을 포함합니다.
- GUI 종료의 ADB 경로를 선택된 script:Adb로 연결해 kill-server 동작을 유지합니다(가짜 실행 파일로 검증).

GUI 가시성 안전 수정
--------------------
- GUI 실행에는 Normal 시작 옵션을 사용하고 PowerShell 콘솔만 별도로 숨깁니다.
- 시작 확인은 PID 소유의 top-level 창, IsWindowVisible=True, 정확한 버전 제목까지 검사합니다.
- 프로세스가 살아 있어도 가시적인 메인 창이 없으면 시간 초과 후 기존 롤백을 수행합니다.
- 이전 GUI 복원도 가시적인 창을 확인합니다. 실제 설치본 재시험은 별도로 수행합니다.

ADB 디렉터리 잠금 안전 수정
---------------------------
- GUI의 ADB 호출은 실행 파일 디렉터리를 WorkingDirectory로 지정합니다.
- sync worker는 진입/종료 부분에서 기본 프로세스 디렉터리를 App 밖에 고정/복원합니다. 동기화 함수는 변경하지 않습니다.
- GUI 종료는 kill-server 결과와 서버 종료를 확인하고 State/adb-lifecycle.log에 기록합니다.
- 업데이트는 GUI/sync/App PowerShell 부재와 ADB 종료 및 App CurrentDirectory 보유 여부를 확인한 뒤 이동합니다.
- 종료/잠금 확인은 제한 시간 내 수행하며 이동 재시도나 무관한 프로세스 강제 종료는 없습니다.
- 실제 서버 확인 실패 또는 외부 잠금 오류에서는 원래 오류를 보존하고 기존 복구 절차를 사용합니다.
- 임시 환경 검증: powershell.exe -NoProfile -File .\tests\adb-lock-static.ps1

v1.4.9 개발: 범용 Android preflight
---------------------------------
전원·잠금, activity activities/top, window windows/displays/policy, input과 HOME을 수집합니다.
Awake/잠금 해제 및 activity/current window/input application/window의 합의가 두 번
동일하게 확인되는 경우만 허용합니다. HOME 설정만으로 허용하지 않습니다.
ES-DE 이외 HOME은 실제 HOME component까지 합의해야 합니다.
제3 앱, 수면/Dozing은 차단하며 누락/실패/모순/SystemUI/NotificationShade도 차단합니다.
과거 ANR/FocusRequests와 background activity는 현재 focus와 구분합니다.
각 신호 원문과 판정 이유를 기록합니다. vendor별 미지원 출력은 차단될 수 있습니다.
동기화/삭제/예약 폴더/gamelist/updater 동작은 유지합니다.
모의 검증: powershell.exe -NoProfile -File .\tests\foreground-static.ps1

v1.4.9 stage 2: gamelist metadata 병합 기반
------------------------------------------
stage 2 당시 gamelist-common.ps1은 독립 모듈이었습니다. 현재는 아래 호환 보정대로 worker 내부에 통합했습니다.
ROM 파일과 metadata를 분리합니다. 엔트리 없는 ROM에 새 game을 만들지 않습니다.
Dropbox 일반 metadata를 유지하고 Android의 기존 _TEST/_UNREGISTERED game
전체 노드만 병합합니다. 예약 폴더는 경로의 어느 구성요소에 있어도 로컬 전용입니다.
예약 이름은 기존 worker처럼 대소문자를 무시하며, Android 파일 경로 key는
대소문자를 구분합니다. 동일 로컬 key는 Android 우선, 중복은 첫 항목을 보존하고
Dropbox 예약 경로/충돌은 warning으로 기록합니다. invalid path는 전체 병합을 중단합니다.
alternativeEmulator와 gameList가 나란한 구조를 메모리 wrapper로 파싱하고,
출력에서 wrapper를 제거합니다. Dropbox top-level 순서와 알 수 없는 필드를 유지합니다.
Dropbox가 없으면 기존 Android 로컬 엔트리가 있을 때만 파일을 만들 수 있습니다.
이 경우 Android top-level 구조를 사용하되 일반 game은 승격하지 않습니다.
출력은 재파싱한 새 PC staging 파일만 허용하며 원본/기존 파일 덮어쓰기를 거부합니다.
stage 2 당시 ROM 채택/이동, 미디어 보호, Android 연결은 미구현이었습니다. 이후 gamelist 연결은 stage 3, media ownership 보호는 stage 5에 구현했습니다. ROM 자동 채택/이동은 아직 없습니다.
검증: powershell.exe -NoProfile -File .\tests\gamelist-merge-static.ps1

v1.4.9 stage 3: gamelist worker 연결
----------------------------------
gamelist bucket은 이제 전용 처리이며 앞 절의 미연결 설명은 stage 2 당시 기준입니다.
Dropbox XML은 전체 원본 검증에서 먼저 파싱합니다. ES-DE 종료 후 모든 선택
시스템의 Android XML을 pull/병합/PC staging 재검증해야 원격 변경을 시작합니다.
병합 결과는 Android 동일 폴더의 고유 임시 파일에 push하고 size를 확인한 뒤
임시 파일을 다시 pull하여 XML과 SHA-256을 확인한 뒤 mv로 gamelist.xml을 교체합니다.
기존 최종 파일을 먼저 삭제하거나 직접 push하지 않습니다.
Dropbox 부재 시 local-only가 있으면 보존하고, 없으면 pull/parse 이후 정확한
gamelist.xml만 삭제합니다. unknown 파일 및 시스템 폴더는 보존합니다.
PC/Android 임시 파일은 정리를 시도하고 실패하면 로그를 남깁니다.
mv 응답 중 연결이 끊기면 교체 완료 여부가 불명확할 수 있으므로 로그/파일 확인이 필요합니다.
ROM/media/foreground/예약 폴더 동작은 변경하지 않았습니다. emulator 변환은 없습니다.
배포 호환 보정으로 gamelist runtime은 sync-worker.ps1 내부에 통합했습니다.
gamelist-common.ps1은 제거했으며 테스트도 worker 함수 정의만 로드합니다.
패키지는 v1.4.8과 같은 App 파일 집합을 유지하고 updater 트랜잭션은 변경하지 않습니다.
tag v1.4.8의 실제 validator로 v1.4.9 ZIP/manifest/asset/SHA 계약을 검증합니다.
검증: powershell.exe -NoProfile -File .\tests\update-v148-compat-static.ps1
모의 검증: powershell.exe -NoProfile -File .\tests\gamelist-worker-static.ps1

v1.4.9 stage 5: media ownership 안전 정책
---------------------------------------
media는 ROM strict mirror와 분리했습니다. 기존 Android media는 전부 unmanaged이며
동일 경로/동일 SHA여도 자동 채택하지 않습니다. unmanaged Android-only는 보존하고,
같은 경로의 다른 SHA 및 managed Android 수정은 원격 변경 전에 충돌로 차단합니다.
managed 파일만 마지막 deployed SHA와 현재 Android SHA가 같을 때 갱신/삭제합니다.
원본 시스템 media 폴더가 없어도 전체 폴더 삭제는 하지 않습니다.
manifest: State/media-ownership/<source-device identity SHA>.json
schemaVersion/sourceRoot/sourceIdentity/deviceSerial/createdAt/updatedAt/entries를 기록하며
entry는 system/relativePath/sourceSha256/deployedSha256/sourceSize/deployedAt/lastVerifiedAt입니다.
기기/원본 identity, schema, 필수 필드, 중복 key, 경로가 잘못되면 초기화하지 않고 중단합니다.
source SHA는 ES-DE 종료 전 준비하고, Android SHA/전체 media 계획은 종료 후 검증합니다.
모든 계획이 검증되어야 ROM/gamelist/media 변경을 시작합니다. 이후 media 적용 실패는
media만 rollback하며 앞서 완료된 ROM/gamelist까지 전체 rollback하는 기능은 아닙니다.
SHA 확인은 sha256sum -> toybox sha256sum -> PC pull 순서로 수행합니다.
기존 managed 변경/삭제 전 검증된 PC 백업을 확보하고, temp 전송/SHA/rename 후 확인합니다.
전체 성공 때만 manifest를 atomic 저장합니다. 실패는 역순 rollback하며 원래 오류를 유지합니다.
State/media-transactions에 durable journal과 백업을 기록합니다. 강제 중단/rollback 실패는
다음 작업을 차단하고 백업을 남깁니다. 자동 crash recovery는 아직 없습니다.
정상 종료 또는 성공한 rollback은 source/backup/hash 임시 파일을 정리하고 journal은 유지합니다.
전체 source hash/staging 준비는 시간과 State 여유 공간이 필요합니다.
ROM/gamelist/foreground/공통 삭제/updater 실행 로직 및 App 8개 패키지 계약은 유지합니다.
stage 5 구현 직후에는 실제 Android 적용이 미검증이었으며 아래 Phase A/B에서 확인했습니다.
모의 검증: powershell.exe -NoProfile -File .\tests\media-ownership-static.ps1

v1.4.9 Release Candidate 검증 현황
---------------------------------
Retroid Pocket Mini V2에서 media Phase A와 전체 worker Phase B를 통과했습니다.
Phase A: unmanaged 보존/동일 SHA 자동 채택 금지/충돌 차단, managed 배포·갱신·삭제,
Android 수정본 보호, 전송 및 manifest 저장 실패 시 역순 rollback을 확인했습니다.
Phase B: 격리된 uzebox만 선택해 production worker 진입점으로 ROM/gamelist/media를
검증했습니다. ExitCode=0/status=done/journal=completed, ES-DE 종료·복귀와 SAFE,
동일 원본 재실행의 ROM/media 재전송 없음 및 metadata/ownership 중복 없음을 확인했습니다.
시험 후 생성한 파일과 ownership만 정리해 원래 스냅샷으로 복원했고,
비선택 GB와 production State는 변경되지 않았습니다. 설치본은 v1.4.8을 유지했습니다.
초기 중단은 임시 시험 스크립트의 객체 Count/반환 필드/ExitCode/경로 배열 문제였으며
production 수정 없이 보정하고 모든 시험 및 최종 정리를 완료했습니다.
전체 회귀 테스트와 tag v1.4.8 실제 validator를 통한 RC 패키지 검증을 유지합니다.
v1.4.8에서 v1.4.9로 실제 앱 내 업데이트는 아직 실행하지 않았습니다.
다른 vendor, USB 단절/강제 종료 후 수동 복구, 대규모 hash/staging 비용은 남은 확인 사항입니다.
media rollback 범위는 media 전용이며 ROM/gamelist 전체 transaction 복원은 아닙니다.
RC 준비는 정식 Release 게시가 아니며 승인 없이 main/tag/Release를 변경하지 않습니다.
