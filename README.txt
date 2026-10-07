ES-DE Sync for Android v1.4.8 Development
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
- 실제 설치 폴더/Windows Forms/Android/실제 GitHub Release 업데이트는 아직 검증하지 않았습니다.
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
