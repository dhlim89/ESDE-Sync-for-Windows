# v1.8 Stage 4A 성능 계측과 진행 표시

version은 1.7.0이다. batch/selective SHA, mtime/cache, 병렬 전송은 도입하지 않는다.

## 호출 흐름

초기화·ADB 연결·선택 시스템 원본 검증 → 원본 media 복사/SHA → SAFE·ES-DE 종료 → Prepare-RomSystemSync(시스템 XML, 원본/Android ROM inventory·SHA·classification) → local-only media HOLD → 나머지 Prepare-MediaPlan → promotion 또는 unmanaged move → inventory 재검증 → XML commit → bucket별 ROM/XML/media 처리 → summary·ES-DE 재실행·done.

DuplicateScan은 별도로 Get-DuplicateProductionSnapshot(ROM content, 반복 ROM inventory, managed source, save/state, XML/media, _TEST 이름만 조회) → New-DuplicateProductionRows를 호출한다. 기존 전체 inventory 반복을 제거하지 않는다.

## 계측

phase별 UTC 시작/종료, elapsedMs, workload, ADB/SHA delta를 기록한다. 중첩 phase 시간은 inclusive이며 합산하지 않는다. Invoke-Adb 한 곳에서 process launch를 센다. shell/push/pull/stat/hash/move/delete counters는 중복 가능한 명령 분류다. AdbHashCalls는 명령 수, TotalHashCount는 local file/text SHA 및 Android가 반환한 SHA 결과 수다. native 이후 pull 재검증도 별도 SHA로 센다.

ROM root inventory는 기존 코드처럼 auxiliary file도 SHA 계산할 수 있다. raw inventory와 managed/classification count를 구분한다. SourceMediaStagingHashCount는 원본 복사본 재검증이다. MutationRevalidationHashCount는 전체 hash의 부분집합이다.

State/performance-baseline.json 및 sync.log PERF 줄에 기록한다. baseline harness는 gitCheckpoint와 worker SHA를 함께 기록한다. progress write 수/소요 ms/최대 silence/write 실패를 측정한다. 계측 보고 실패 때문에 media session cleanup을 건너뛰지 않는다.

## status와 GUI

기존 state/message/percent/current/total/summary/requestId 의미를 유지한다. phase, phaseLabel, overallPercent, phasePercent, phaseCurrent, phaseTotal, currentItem, elapsedMs, indeterminate를 추가한다. 기존 current/total은 bucket 계약이므로 파일 workload는 phaseCurrent/phaseTotal이다.

GUI는 새 필드가 없으면 기존 status를 표시한다. 새 필드가 있으면 전체 %, 단계, 처리 개수, 파일명, 경과 시간을 표시한다. 총량 미확정은 marquee, 확정 후 determinate, 완료/오류는 marquee 해제다.

임시 전체 경계: 원본 준비 0–20, ROM/XML 준비 20–50, media 계획 50–70, 기존 bucket 처리 70–95, 완료 100. 시스템별 phase 재진입은 별도 invocation이다. 각 invocation의 phasePercent와 전체 overallPercent는 감소하지 않는다.

파일 loop와 ADB 대기에서 500ms throttle로 heartbeat를 쓴다. stdout/stderr ReadToEndAsync로 pipe를 배수하며 같은 ADB process를 기다린다. 전송 병렬화는 아니다.

## baseline 범위

tests/support/performance-readonly-profile.ps1는 함수만 import한다. worker 본문·normal sync·cleanup을 실행하지 않는다. transport가 push/install/kill-server와 write shell을 차단한다. 격리 evidence State만 사용하고 ES-DE를 종료하지 않는다. SAFE 2회와 recovery gate를 먼저 검사한다.

격리 Source unchanged planning 및 DuplicateScan을 각각 측정한다. actual no-op sync 전체 시간으로 확대 해석하지 않는다. transfer/delete/rename 실제 실행 0이며 PC staging 복사/XML pull은 존재한다. small-change fixture는 동일 source inventory/classifier에서 ROM 1개 byte 변경을 측정하고 MANAGED_CONFLICT 정책을 검증한다. 실기기 전송 속도의 대용은 아니다.

## 검증과 다음 단계

schema/throttle/monotonic/Unicode/status 호환/Forms binding/fake process ADB counter/file·text·native SHA/mutation subset/small change 및 전체 회귀를 실행한다. App 8/package 13, v1.4.8 validator 계약을 유지한다.

Stage 4B 우선 조사: media per-file 상태·SHA 왕복, ROM native SHA 이후 pull 재검증, DuplicateScan 반복 전체 inventory. mutation 직전 SHA 및 reserved/review/recovery 경계를 유지한다. 수치는 evidence JSON을 기준으로 한다.

## 2026-10-12 실기기 읽기 전용 baseline

evidence 디렉터리: TEMP/ESDE-stage4a-profile-frozen-20261012-142334. 기준 checkpoint d7f17131cbc800a7e4283dafc97e6984fef1d661 위 수정 source를 측정했으며 implementationSha256으로 최종 worker와 동일함을 확인했다. 원본 JSON은 유지한다.

- unchanged planning: 135,533ms, ADB 1,470(shell 1,364 / pull 106 / push 0), hash 명령 620, SHA 2,651.
- ROM SHA: source 105 / Android 208(native+pull). source/Android raw inventory entries 105/110, classification managed 99 / local-only 5 / REVIEW 1. raw entries에는 auxiliary가 포함된다.
- media: source 909, Android 전체 909(GB 393 HOLD, GBC 516 비교), source SHA 909 + staging 복사본 SHA 909 + Android SHA 516. 변경 계획 0.
- source media 준비 16,296ms; GB ROM/XML 준비 14,437ms; GBC ROM/XML 준비 18,952ms; media 비교 83,325ms. 이 안의 XML 354ms, source ROM SHA 705ms, Android ROM SHA 23,733ms는 중첩 시간이다.
- progress 265 writes / 327.9982ms(전체의 약 0.24%), max silence 1,444ms. mutation verification SHA 0, 실제 transfer/delete/rename 0.
- DuplicateScan: 83,989ms / ADB 52(shell 50, pull 2) / SHA 1,763 / 후보 1(REVIEW_ONLY). media safety inventory 45,838ms, save/state inventory 3,152ms, ROM root inventory 두 번 30,529ms. snapshot 안의 중첩 시간이다.
- DuplicateScan progress 175 writes / 277.9626ms(약 0.33%), max silence 874ms. 이전 heartbeat 미적용 예비 측정의 26,688ms 공백과 구분한다.
- 신규 fixture 26 PASS, 전체 40 scripts ExitCode=0, PS1 52 syntax/BOM PASS, v1.4.8 validator 12 PASS, App 8/package 13 및 ZIP-source mismatch 0.

Stage 4B weight 제안: prepare/safety 5%, source media 10%, ROM/XML 25%, media 비교 50%, mutation 5%, verification/restart 5%. 읽기 전용 baseline이므로 실제 transfer/restart 비중은 변경 workload 측정 뒤 재조정해야 한다. 전체 최적화 전후 속도 개선률을 주장하지 않는다.
