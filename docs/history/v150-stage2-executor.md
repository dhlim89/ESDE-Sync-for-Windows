# v1.5.0 Stage 2 executor 경계

Stage 1 checkpoint: 3cb64cb7b8435c725d3669d6ff5df68369e0550b.
Stage 2는 미커밋이며 실제 Android/Dropbox mutation 없이 TEMP filesystem + mock ADB만 검증한다.

## Worker 순서

전체 source path/XML 검증 → media/adoption/ROM State 검증 → foreground preflight → ES-DE stop →
실제 Android ROM 목록 기반 unmanaged 분류 → 모든 Android XML pull/병합 →
모든 선택 시스템 inbox/metadata 계획 → 전체 media 계획 검증 →
adoption transaction → 기존 ROM mirror(보존 wrapper) → 미처리 gamelist → media transaction →
ES-DE restart.

미완료 adoption journal은 ES-DE stop/어떤 원격 mutation보다 먼저 차단한다.
완료 journal은 감사 기록으로 보존하고 자동 resume하지 않는다.
실기기에서 위 흐름을 이번 Stage에 실행하지 않았다.

## Metadata

관리본 whole game + Android playcount/playtime/lastplayed tag-level override.
0/empty도 존재하는 tag이고 absence일 때만 관리본 값을 사용한다.
일반 Android-only metadata를 관리본에 자동 추가하지 않는다.
실제 unmanaged ROM 경로 목록과 일치하는 기존 Android game만 whole-node 보존한다.
예약 node는 기존처럼 whole-node 보존한다.

system-level alternativeEmulator는 Android element가 있으면 subtree 전체를 사용한다.
element가 없어야 관리본을 사용하며 empty도 존재로 취급한다.
공통 parity fixture의 semantic 비교는 whitespace serialization만 무시하고
element/attribute/comment/text/계층과 runtime tag 존재를 검사한다.

game-level 변환은 Android-bound 복사본에서만 한다.
GB SameBoy (Standalone), GBC Sameboy (Standalone)의 정확한 대소문자를 기준으로 한다.
확인된 Android target은 idempotent 유지. 미확정 Standalone은 warning/block.
arcade 목록은 Stage 1에서 APK platform=arcade로 확인한 목록이다.
neogeo/neogeocd/neogeocdjp는 미확정 정책 로그 후 game-level 변환 생략.
예약/unmanaged whole-node는 emulator 변환 대상에서 제외한다.

## 일반 unmanaged와 inbox

ROM 존재/소유 범위는 gamelist로 판단하지 않는다.
처음 도입 시 현재 관리본과 무관한 Android-only ROM은 unmanaged로 보존한다.
State/managed-rom-paths/<source-device SHA>.json은 성공한 관리 경로를 기록한다.
이후 관리본에서 사라진 이전 관리 경로에는 기존 strict mirror 의미를 유지한다.
이 기록은 ownership hash에 기반한 media manifest와 다른 ROM 경로 범위 기록이다.
기존 Mirror-SystemFolder/Get-RemoteEntries/삭제 함수 본문은 바꾸지 않는다.
wrapper의 함수 scope 안에서만 managed remote listing을 제공한다.

root _UNREGISTERED만 adoption inbox. nested 상대 구조 유지.
_TEST/절대경로/traversal/control/Windows device names/invalid filename/links/
case-insensitive collision/non-ROM/미선택 system을 차단한다.
현재 확인된 extension catalog는 GB/GBC만 지원하며 다른 system은 inbox가 있으면 차단한다.
Android SHA는 native/toybox sha256sum이 있으면 pull SHA와 비교하고, 없으면 PC pull SHA fallback을 사용한다. commit 직전/교체 이후에도 재확인한다.
목적지 동일 SHA는 기존 canonical 대소문자를 사용하여 재사용하고 다른 SHA는 차단한다.

## XML 승격

기존 inbox game이 있으면 canonical path로 승격한다.
기존 Dropbox canonical game이 있으면 일반 metadata는 기존 관리본을 사용한다.
새 shared game은 Android node 기반이지만 runtime 3개 tag를 제거한다.
Android-bound 승격 game은 현재 기기의 runtime을 유지한다.
기존 game이 없으면 ROM만 채택하며 빈/synthetic game을 만들지 않는다.
preference/platform/media 및 device-local 경로 공유가 필요하면 unresolved policy gate.
unknown 공용 metadata는 whole-node 보존하되 device-local 절대 경로는 gate 대상이다.
Shared XML을 Dropbox에도 반영하므로 다른 기기가 ROM/공용 metadata를 받을 수 있다.

## Transaction / journal

State/adoption-transactions/<full source-device SHA>/<transaction id>.json.
schemaVersion, identity, transactionId, createdAt/updatedAt, state/completed,
originalError/sourceRestoreErrors, stage history, stagingPath와 각 entry의
system/inbox/canonical/SHA/Dropbox/Android/staged path를 기록한다.
전체 XML 내용은 journal에 기록하지 않는다.

staged → source-verified → dropbox-installed → gamelist-prepared →
dropbox-gamelist-installed → android-rom-installed →
android-gamelist-installed → android-source-removed → completed.

PC ROM은 동일 directory의 검증 temp를 Move, XML은 검증 temp를 Replace/Move.
Android ROM은 temp push/re-pull/SHA/no-clobber mv/final SHA.
Android XML은 기존 gamelist verified transfer/CAS/mv를 사용한다.
Dropbox XML fingerprint는 source read 시점 bytes 기준이며 Android XML은 pull snapshot 기준이다.
mutation 직전 다시 검사하여 concurrent modification을 차단한다.
모든 최종 ROM/XML 검증이 끝나야 inbox 삭제한다.

성공한 canonical/XML을 자동 되돌리거나 삭제하지 않는다.
미완료 journal은 이후 새 mutation을 차단하며 자동 rollback/resume가 없다.
실행 중 마지막 cleanup 또는 완료 journal 저장 실패에는 inbox 복사본만 보상한다.
보상은 absent inbox에만 SHA 검증 temp + no-clobber mv를 사용하며 수정본을 덮어쓰지 않는다.
다중 삭제는 원자적이지 않으므로 먼저 삭제한 원본도 보상 대상으로 한다.
보상 중 USB/ADB/디스크 오류까지 발생하면 원본 위치 복원은 보장할 수 없다.
이때 PC staging/canonical/journal을 보존하고 fatal 및 sourceRestoreErrors를 기록한다.
강제 종료의 동일한 cross-filesystem window도 자동 복구하지 않으며 수동 SHA 검토가 필요하다.

## Stage 3 실환경 검증 전제

- 전체 회귀/syntax/BOM/패키지 검사 통과 후 코드 리뷰.
- 사용자 승인과 Android/Dropbox 원본 전체 백업, 충분한 PC 공간.
- 선택 system과 확정 extension/mapping, preference/media 없는 최소 fixture.
- 초기 시험은 격리된 단일 GB inbox와 별도 State로 한정.
- 새 SourceRoot는 실제 사용자 Dropbox 전체와 격리하고 시스템 선택을 최소화.
- PC source/Android canonical/XML/inbox 전후 SHA 및 비선택 시스템 스냅샷.
- ADB 단절/강제 종료/cleanup 보상 실패는 별도의 승인된 fault 시험.
- preference 공유, 추가 emulator mapping, neogeo family, 실제 monitor DPI는 미확정 유지.
- Dropbox cloud upload 완료를 local SHA 검증으로 보증하지 않는다.
- 이 문서는 실제 동기화 실행 승인이 아니다.