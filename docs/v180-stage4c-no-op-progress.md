# v1.8 Stage 4C no-op sync 및 GUI 진행 계측

버전은 1.7.0을 유지한다. 실제 Android 작업은 격리 trial GUI에서 사용자가 시작하며, stable 설치본과 Dropbox는 수정하지 않는다.

## 작은 변경

- `Sync-GamelistSystem`: 현재 XML과 준비 XML의 semantic token이 같으면 `Assert-GamelistSnapshot`을 수행한 뒤 전송을 생략한다. whitespace, game/folder 순서와 고유 필드 순서 차이는 무시하고 값·속성·comment·custom 구조·top-level sibling 순서는 보존한다. duplicate 필드나 comment가 있으면 순서를 무시하지 않는다.
- `Send-ClassifiedManagedFile`: existing ROM의 fresh native SHA 확인 뒤 no-op을 반환한다. source SHA 확인, 경로/symlink 검증, native 미지원 pull fallback과 실제 push 뒤 binary pull/SHA 검증은 유지한다.
- source hash 계산, memo guard eligibility와 file identity 조회의 elapsed microseconds를 별도 counter로 기록한다. guard 시간은 eligibility 검사와 handle/identity 확인을 포함하며 identity 시간과 합산하면 중복이다.
- ROM 분류 비교, 원본 snapshot 검증, 최종 inventory 확인, ES-DE 종료/재시작 phase를 계측한다. nested phase elapsed는 합산하지 않는다.
- GUI `gui-performance-Sync.json` / `gui-performance-DuplicateScan.json`: 클릭부터 완료 감지/목록 준비까지 wall-clock과 UTC timestamp를 기록한다. worker startup까지의 GUI validation 시간도 포함한다. GUI polling interval은 기존 600ms다.

## 안전성

자동 cleanup, persistent cache, parallel ADB/SHA, mtime-only 판단은 추가하지 않는다. mutation 후 검증과 recovery/REVIEW/_TEST/media HOLD 정책은 유지한다. normal summary 필드는 바꾸지 않는다.

## 검증

`tests/no-op-sync-static.ps1`: 순서/직렬화 차이, empty/zero/Unicode, 값·folder·속성·comment·custom 변경 감지, no-op XML snapshot/stale gate, no-op native SHA, push 후 binary 검증, 늦은 canonical 충돌, GUI wall-clock schema.

실제 GUI 검증과 최종 수치는 아래 재검증 기록과 evidence에 기록한다.
## 실제 GUI 측정 및 발견 사항

2026-10-12 격리 trial GUI normal sync 1회: 클릭→완료 45,308ms, worker 44,581ms. worker initialization→media plan 완료 구간은 약 20,567ms이며 이후 GUI 완료까지 약 24,741ms다. Stage 4B read-only 18,144ms와 GUI total의 차이는 27,164ms다.

- 원본 media 준비 8,761ms, GB/GBC ROM/XML 준비 1,708/2,076ms, media compare 2,769ms.
- 최종 inventory 확인 1,093/1,397ms, XML no-op finalize 1,320/1,694ms, ROM no-op 송신 판단 7,499/10,655ms, media finalize 41ms, ES-DE restart 142ms.
- restart 138/142ms 두 phase는 같은 실행에 중첩 계측된 것이며 합산하지 않는다. 중복 wrapper를 제거했다.
- ADB 275(shell270/pull4/push0), hash commands110, SHA1957. `MutationRevalidationHashCount=204`는 실제 mutation 수가 아니라 no-op 송신 판단을 포함하는 기존 context counter다. transfer/delete/rename은 모두 0이다.
- source media SHA 실행 1,615.203ms/909회; 전체 local hash guard eligibility 3,831.622ms; identity 조회 258.725ms(guard에 포함). source memo hit105. 분류 비교 4회 합계277ms이므로 새 index를 추가하지 않았다.
- progress writes150/340.8703ms, worker max silence2,840ms, 외부 관측2,842ms, percent backward0.
- ROM/XML/media/save45/state4/Dropbox 14 inventory가 모두 byte fingerprint 동일. stable App8/State21, staging source1016도 동일. SAFE2 및 duplicate recovery gate PASS.
- Duplicate Manager GUI open13,757ms, worker12,628ms; ADB65(shell62/pull2), hashcommands12, SHA1371, maxsilence2,595ms. REVIEW_ONLY1, _TEST0, cleanup0.

실제 GUI에서는 두 blocker를 발견했다. 완료창은 timer의 이전 restarting frame을 사용해 summary 숫자를 누락했다. worker exit 후 최종 status를 다시 읽고 terminal 상태를 검증하도록 수정했다. DuplicateScan progress bar는 사용자가 보이지 않는다고 보고했다. GUI 초기화의 visual styles 활성화, scan 시작 시 visible marquee 초기화와 완료 값100을 추가했다. marquee에는 visual styles가 필요하다: https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.progressbarstyle

신규 no-op/GUI fixture21 PASS. 최초 sync 뒤 사용자 승인으로 수정 GUI의 추가 no-op sync 1회와 DuplicateScan 1회를 수행했다. cleanup은 실행하지 않았다.
## 수정 GUI 실기기 재검증

사용자가 완료 summary 99/0/0/5/1, progress bar, phase/status, current/total, currentItem, elapsed, done/100%/6/6을 실제 확인했다. normal sync 45,990ms(worker45,162ms), 최대 진행 갱신 간격2,836ms, percent 역행0. ADB275(shell270/pull4/push0), hash commands110, SHA1959. progress write312.102ms이며 best-effort progress write 실패7회가 기록됐으나 이후 갱신과 최종 status는 정상이다. 실패의 개별 예외는 현재 계측에 보존되지 않아 원인을 단정하지 않는다.

DuplicateScan GUI12,751ms(worker12,171ms), worker max silence2,117ms. 사용자 확인: progress bar, 초기 marquee, 완료 determinate 전환, 목록 표시 정상; REVIEW_ONLY1/_TEST0, 창 멈춤 없음. 외부 DuplicateScan watcher는 event0으로 status 갱신 간격을 측정하지 못했으므로 worker 계측을 사용한다.

최종 SAFE2회 PASS, recovery gate 정상. ROM/XML/media/save45/state4/Dropbox14 inventory 동일, stable App8/State21 및 staging source1016 동일. trial App8/source 동일. transfer/delete/rename0, cleanup0. source/version1.7.0, main/tag/Release 변경 없음.

Evidence: C:\Users\dhlim\AppData\Local\Temp\esde4c-gui-retest-20261012-200840

최종 판정: v1.8 Stage 4C REAL-SYNC READY.
