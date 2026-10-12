# v1.7.0: 안전한 RENAME_ONLY 자동 승격

현재 개발 버전은 1.7.0 / v1.7.0이며 stable은 v1.6.0이다. Stage 3 production 연결과 실기기 자동 승격·실제 save/Save State load 검증까지 완료했다. 아래 Stage 1/3 준비 설명은 단계별 이력이며, 현재 활성 계약과 최종 증거는 마지막 절을 따른다.

stable은 v1.6.0이다. version.json 및 production worker/GUI는 변경하지 않는다.
새 구현은 tests/support/rename-promotion-proposal.ps1이며 tests에서만 로드한다.
실제 ADB backend를 거부하고 production loader에 연결하지 않는다. App 8개 계약 유지.

## 후보와 변화 유형

- SAME_NAME: 예약 prefix 제거 후 상대 경로가 Ordinal 동일. 기존 v1.6 전용 경로 유지.
- RENAME_ONLY: 예약 prefix 제거 후 parent가 동일하고 파일명만 변경. GB/GBC + SameBoy mapping 근거를 입력으로 요구하는 mock 후보.
- PATH_ONLY / RENAME_AND_PATH / CASE_ONLY: Stage 1에서는 전체 REVIEW.
- _TEST 제외, root _UNREGISTERED만. 단일 same-system managed SHA 후보, 동일 SHA, 유효 canonical path, extension 동일, destination 부재가 필수.
- Android 전체와 managed GB/GBC의 SameBoy basename inventory를 함께 검사한다. 다른 content가 old/new basename을 공유하면 저장 파일 소유권이 불명확하므로 REVIEW.
- 최초 SHA와 XML/master/node fingerprints, staging bytes 및 operation binding을 보존한다. 변경/충돌은 mutation 전에 차단한다.

## Save/state

관측된 자료는 C:/esde-v160-live-b42cde1f/before/android-save-before.json 및 android-state-before.json이다.
현재 SameBoy root: /storage/emulated/0/RetroArch/saves/SameBoy, /storage/emulated/0/RetroArch/states/SameBoy.
검증된 실기기 예는 V160_SAVE_TEST.srm/.rtc/.state이다. v1.6 실험은 basename을 유지한 parent 이동과 load를 증명했으며 basename rename 후 load를 증명하지 않았다.

mock은 .srm/.rtc/.state만 old stem → new stem으로 계획한다. source hash/size 및 완전한 inventory가 필요하다.
source 없음은 완전한 inventory evidence가 있어야 인정한다. destination만 있는 경우도 ownership unknown으로 REVIEW.
old/new 둘 다 존재하면 같은 SHA라도 자동 삭제/merge하지 않는다. 다른 SHA도 REVIEW, data 보존.
.state1/.state2/auto/예상 밖 extension/다른 core directory/case variant/symlink/traversal/중복 경로는 REVIEW.
slot은 suffix를 그대로 옮길 수 있는 구조적 가능성만 있다. 실제 naming/runtime load 근거가 없으므로 실행 계획에서 제외한다.
다른 core/vendor로 일반화하지 않는다. 입력의 Verified는 mock fixture 신뢰 계약이며 실제 환경을 자동 승인하는 증거가 아니다.

## Gamelist

Get-PromotionMetadataSafety, Get-PromotionBoundGamelist, Get-PromotionXmlEvidence를 그대로 재사용한다.
master canonical node가 필요하며 master metadata + Android runtime3 tag-presence 보존, alternativeEmulator 기존 정책을 적용한다.
0/empty runtime도 보존. canonical 1 node, old local 0 node, synthetic local/duplicate 없음.
unknown/custom element/attribute/comment는 REVIEW, duplicate/collision/malformed XML은 BLOCK.
현재 XML model/parser를 재사용하며 새 XML merger를 만들지 않는다.

## 실제 media 관측 및 정책

읽기 전용으로 기존 GB/GBC evidence manifest를 조사했다. GB 393 / GBC 516 파일, 모든 category/파일 깊이 2의 flat 구조.

| 관측 category | 관측 extension |
|---|---|
| 3dboxes | .png |
| backcovers, covers | .jpg, .png |
| fanart | .jpg |
| manuals | .pdf |
| marquees, miximages, physicalmedia | .png |
| screenshots, titlescreens | .jpg, .png |
| videos | .mp4 |

이 목록은 저장된 실기기 manifest의 관측 범위이며 모든 ES-DE layout의 보편 계약이 아니다.
NO_LOCAL_MEDIA: 완전한 inventory와 관측 layout일 때만 SAFE 후보. first run HOLD, 다음 sync는 기존 ownership-aware mirror를 적용할 수 있다.
LOCAL_MEDIA_RENAMEABLE: old stem 파일과 비어 있는 new destination의 1:1 diagnostic 후보만 기록한다. ownership/naming/load 근거가 없으므로 전체 proposal은 REVIEW, executable operations 없음.
MEDIA_COLLISION_OR_UNKNOWN: old/new 존재, 관리 canonical media + local old media, 같은 SHA 중복, custom category, nested layout, case, symlink/hash unknown은 REVIEW.
managed와 local media 중 한쪽을 삭제하거나 자동 채택하지 않는다. media mapping이 애매하면 ROM/save/state/XML promotion 전체를 보류한다.

HOLD만으로 이후 run의 orphan 문제를 해결할 수는 없다. 기존 media ownership은 마지막 deployed SHA가 같은 원본 삭제 항목을 삭제할 수 있으며, rename된 local media를 자동 채택하지 않는다.
따라서 old local media가 있는 경우 승격을 막아 linkage를 유지한다. 향후 media 지원에는 원본/기기 identity, ownership manifest 및 deployed SHA binding과 명시적 resolution이 필요하다.

## Transaction와 primitive

prepared → rom_moved → saves_moved → states_moved → xml_committed → media_completed_or_held → completed.
전체 ROM/asset/parent/filesystem/XML evidence를 선검증하고 각 operation 직전 SHA를 재확인한다.
ROM은 기존 Invoke-VerifiedAndroidRomMoveCore를 Mock adapter로 재사용한다. v1.6 stable primitive를 refactor하지 않는다.
save/state는 별도 tests-only Invoke-VerifiedRenameAssetMoveMock wrapper: 허용 root, SameBoy relative path, source/file/link/SHA/size, parent containment/filesystem, destination absent, no-clobber move, final SHA/source absence를 검증한다.
Stage 1은 모든 parent가 이미 존재해야 한다. 새 실제 generic file-move/ADB adapter와 mkdir 구현은 보류한다.
실패는 recovery-needed + 마지막 성공 phase/시도 여부/error evidence. ROM moved 후 save 실패 또는 saves moved 후 state/XML 실패를 구분한다.
자동 reverse/rollback/resume 없음. 실제 연결 시 unfinished gate와 per-operation 완료 기록, atomic durable state 및 post-commit XML evidence를 추가 검증해야 한다.
mock에서는 inventory refresh가 MANAGED임을 확인하고 기존 Send-ClassifiedManagedFile의 duplicate USB push 0을 증명한다.

## Summary와 production 비활성

향후 SAME_NAME/RENAME 성공 모두 PromotedCount +1, 별도 UI counter 없음. 내부 PromotionType=RENAME 및 ChangeType으로 구분한다.
현재 GUI/status writer는 변경하지 않는다. 기존 Get-PromotionSummaryProposal의 rename Action 연결과 REVIEW 제외 처리는 향후 production 연결 단계의 과제이다.
production은 동일 이름 safe → 기존 v1.6 자동 승격, 다른 이름 동일 SHA → 기존 REVIEW 그대로다.

## 남은 blocker

- 실제 basename rename 후 .srm/.rtc/.state load 및 naming 충돌/slot/auto state 검증.
- 실제 rename 환경 evidence 등록과 root/parent/native adapter, durable multi-asset journal 및 XML 동시 변경 검증.
- local media ownership 및 rename/adoption mapping 증거. 현재 전체 REVIEW가 안전한 fallback.
- save가 없다고 판단하려면 full inventory의 시점/fingerprint를 runtime transaction에 바인딩해야 한다.

실제 Android/Dropbox mutation, install/sync, commit/push, main/tag/Release 변경 없음. 기존 fixture/evidence를 수정하거나 정리하지 않는다.

## Stage 3 production 연결 (미커밋, version 1.6.0 유지)

Stage 2 RENAME_ONLY 실기기 결과는 사용자 game save/Save State load 확인까지 PASS했다.
Evidence: <로컬 격리 evidence 경로 비공개>
이 JSON은 static 증거이며 실제 load 성공은 후속 사용자 보고에 근거한다. 원본 evidence는 수정하지 않는다.

자동 허용은 기존 SAME_NAME과 새 RENAME_ONLY만이다. _UNREGISTERED prefix를 제거한 상대 경로의 parent가 case-sensitive 동일하고, filename 및 basename은 달라야 한다. 확장자는 그대로 유지한다. PATH_ONLY/RENAME_AND_PATH/case-only/_TEST는 REVIEW이다.
환경은 기존 Retroid <검증 기기 serial 비공개> + GB/GBC + SameBoy 정확한 config fingerprint/override 없음/RetroArch 종료 증거를 재사용한다. rename에서는 실제 OLD local node의 altemulator도 검증한다. Stage 2 runtime load 증거는 Retroid SameBoy GB 시험이며 다른 vendor/core의 증거가 아니다.

Get-RenameProductionSnapshot은 전체 saves/states, Android GB/GBC content 및 기타 시스템의 .gb/.gbc basename, source content, 선택 system media를 읽는다. directory/root canonicalization, links, SHA/size, case duplicate를 fail-closed로 검사한다. 읽기 실패/불확실한 inventory는 REVIEW로 fallback한다. source/master/Android metadata collision은 기존 BLOCK을 유지한다.
Get-RenameAssetPlan은 .srm/.rtc/.state만 계획한다. source 없음은 no-op; destination 존재는 동일 SHA여도 REVIEW. OLD/NEW basename + '.' sibling의 unknown suffix, slot/autostate, 다른 core/subdirectory/case variant는 REVIEW. 비슷한 접두사만 가진 다른 ROM의 state는 포함하지 않는다. 전체 SameBoy basename inventory로 다른 content와 save namespace를 공유하면 REVIEW.
Get-RenameRemoteInventory는 새 저장소의 absent root를 빈 inventory로 간주하지 않는다. save/state/SameBoy parent를 만들지 않는다. 기존 directory와 filesystem evidence가 없으면 REVIEW이다.

New-RenameProductionProposal -> PROMOTE_WITH_RENAME -> Invoke-ClassificationPromotions.
ROM은 안정된 Invoke-VerifiedAndroidRomMoveCore/Adb adapter를 그대로 재사용한다. rename direction wrapper만 추가했다.
Save/state는 Invoke-VerifiedRenameAssetMoveCore(Mock/Adb 공통), New-RenameAssetAdbAdapter를 사용한다. allowed root/SameBoy 경계, file/link, case, destination absent, SHA/size/filesystem, parent chain, mv -n, destination SHA/source absence를 검증한다. native shell은 exit/stderr fail-closed, source SHA를 shell의 mv 직전에도 검증한다.

모든 plan의 source/master/XML/staging 및 ROM/asset 증거를 mutation 전에 검증한다. ROM/save/state 각 move 전후에 XML/node/환경, 전체 save/state snapshot, media snapshot, managed basename 증거를 재검증한다. 완료한 asset의 source->destination 변환만 expected snapshot에 반영하여 no-op/늦은 신규 파일도 검출한다. proposal operations와 snapshot은 fingerprint에 바인딩한다.

transaction: prepared -> rom_moved -> saves_moved -> states_moved -> xml_committed -> media_completed_or_held -> completed.
asset-attempt와 verified operation, completedAssets, lastSuccessfulPhase, PromotionType=RENAME, XML evidence, parent attempts를 journal/history에 보존한다. 실패는 recovery-needed, 다음 sync BLOCK. 자동 reverse/rollback/resume 없음. phase 사이의 부분 성공도 operation evidence로 기록한다.

기존 managed merger를 재사용한다. master metadata/name을 기준으로 하고 runtime 3종/tag presence/alternativeEmulator를 유지한다. canonical game 1개/old game 0개. rename run에서 Android folder node는 whole-node 보존하여 folder lastplayed 기록의 손실을 막는다. 중복/traversal folder는 BLOCK. SAME_NAME/일반 mirror에는 이 folder 확장을 적용하지 않는다.

old local media가 있거나 media layout/ownership가 불명확하면 전체 rename은 REVIEW. media rename/adoption 없음. managed canonical media만 있더라도 첫 rename run은 system HOLD. save/state 이외 이름 이동은 없음.

XML verified temp push/re-pull/SHA/concurrent source check/same-directory replacement 후 inventory를 재수집하여 MANAGED를 검증한다. 기존 Send-ClassifiedManagedFile의 same-path/same-SHA guard로 같은 sync 내 canonical duplicate push를 막는다. 중간에 XML/master/media/asset 변동을 발견하면 recovery-needed로 중단한다.

Summary 계약은 5필드 그대로: ManagedCount / UnmanagedMoveCount / PromotedCount / LocalOnlyCount / ReviewCount.
SAME_NAME과 RENAME 성공 모두 PromotedCount에 포함한다. 시작 local-only 수는 그대로 유지하고 승인된 promotion만 REVIEW에서 제외한다. 별도 RenameCount/GUI 변경 없음.

Stage 3 1차는 코드/PC mock 및 시험 준비 단계이다. install/sync/실제 rename promotion/production State 수정/Dropbox write/commit/push/main/tag/release 없음. 다음 실기기 자동 rename 1회는 별도 승인 후 진행한다. slot/autostate와 local media가 있는 경우는 계속 REVIEW이며 자동화 범위 밖이다.
동일 canonical destination을 여러 local-only 후보가 요구하면 rename 후보끼리는 모두 REVIEW로 되돌린다. 정확히 하나의 SAME_NAME 후보가 있으면 기존 v1.6 SAME_NAME만 유지하고 rename 후보는 REVIEW이다. 계획 충돌을 파일 이동 실패 시점으로 미루지 않는다.

Stage 3.1: Get-RenameContentPathEvidence는 정규화/traversal 검증 후 기존 Get-ClassificationExtensions(gb/gbc)를 사용해 non-ROM 파일을 제외한다. .nomedia/systems.txt/readme.txt는 root에서도 ignore한다. ROM 후보는 system directory 및 Supported capability가 필수이며 root Game.gb와 unknown/Game.gb는 REVIEW fail-safe이다. Android/source 양쪽에서 동일 helper를 쓴다. SAME_NAME과 legacy mirror 정책은 변경하지 않는다.

## v1.7.0 checkpoint / RC 기준과 실기기 최종 근거

현재 활성 production 정책은 SAME_NAME(v1.6 경로 유지) 및 제한된 RENAME_ONLY이다. `_UNREGISTERED`만 대상이며 `_TEST`, PATH_ONLY, RENAME_AND_PATH, case-only, multiple candidate, unknown/custom metadata, ROM/save/state destination collision, slot/autostate, old local media, unsupported core/system, uncertain SameBoy environment는 REVIEW이다. XML malformed/collision, late evidence 변경은 기존 fail-closed BLOCK/recovery-needed 정책을 유지한다.

RENAME_ONLY는 예약 prefix 이후 parent relative path가 case-sensitive 동일해야 한다. 동일 SHA·단일 same-system managed candidate·검증된 Retroid <검증 기기 serial 비공개>/SameBoy config·metadata SAFE·canonical destination 부재·완전한 content/save/state/media evidence가 필수다. `.srm`, `.rtc`, `.state`만 basename rename하며 첫 run media HOLD, Source/Dropbox write 0, completed 뒤 MANAGED 확인과 중복 push 억제를 적용한다. 별도 RenameCount 없이 PromotedCount에 포함한다.

- Stage 2 manual rename evidence: `<로컬 격리 evidence 경로 비공개>`
- Stage 3 auto fixture evidence: `<로컬 격리 evidence 경로 비공개>`
- Actual auto result: `<로컬 격리 evidence 경로 비공개>`
- Static comparison: 위 actual 디렉터리의 `POST-STATIC-COMPARISON.json`, `XML-EXACT-STAGING-PROOF.json`, `POST-INVENTORY-PUSH-GUARD.json`
- Final SAFE / gate evidence: `FINAL-AUTO-RENAME-STATIC-PASS.json`. 이 원본은 사용자 load 이전에 작성되어 UserLoadPending=true이며 수정하지 않는다.
- 후속 사용자 확정(2026-10-11): 기존 게임 내 save 정상 인식, Save State 목록 정상, 실제 Save State load 성공. 이 문서에 사용자 확인을 기록하며 원본 evidence는 덮어쓰지 않는다.

실제 dev production worker는 격리 Source/App/State를 사용하여 정확히 1회, ExitCode=0으로 실행했다. Transaction은 prepared → rom_moved → saves_moved → states_moved → xml_committed → media_completed_or_held → completed. `V170_AUTO_OLD.gb` → `V170 AUTO RENAME NEW.gb`, ROM SHA `63a43a6a7ed74f4fab52aa58c7c666fa889e9263766e5efb475872179191b0b3` 유지. save/rtc/state도 basename만 변경하고 각 size/SHA 유지했다.

canonical NEW node 1 / OLD node 0, runtime3·alternativeEmulator·display metadata 보존, post MANAGED/SYNC, duplicate push 0, media HOLD/변화 0, 기존 REVIEW 1건 유지. summary 97/0/1/5/1. 다른 데이터 변화 0, Source/Dropbox write 0, production State/App untouched, recovery/incomplete 0, final SAFE 2회, ADB residual 0.

실제 runtime 근거는 Retroid Pocket Mini V2 + RetroArch/SameBoy GB 시험이며 다른 vendor/core로 일반화하지 않는다. slot/autostate와 local media rename/adoption은 지원 범위 밖이며 REVIEW가 정상이다. 새 v1.7.0 RC install/sync는 이번 checkpoint/package 단계에서 수행하지 않는다.

진단 제한: 승격 후보의 기존 공통 LOCAL_ONLY_MANAGED_MATCH notice에는 보존/이름 변경 보류 문구가 남아 있다. 실제 PROMOTE_WITH_RENAME action과 transaction/completion 결과를 우선 확인한다. 성공 summary/GUI의 PromotedCount는 정확하다. 이 문구는 데이터 경로 결함의 증거가 아니며 이번 checkpoint 작업에서 동작을 변경하지 않는다.

## Stage 3.2: 일반 Android-bound folder metadata 보존

Release preflight evidence: `<로컬 격리 evidence 경로 비공개>`. 기존 RC SHA `2b8e13b2e324739e28ea945807d1f92b522d9705406d4432ae04c9fbeb0cde11`는 blocked RC이며 정식 검증에 재사용하지 않는다. 원본 RC/evidence는 삭제하거나 덮어쓰지 않는다.

원인은 master를 복제하는 `Merge-EsdeGamelist`가 Android folder를 이식하지 않고, `Preserve-RenameFolderEvidence`가 RENAME promotion에만 적용된 것이었다. 현재는 그 전용 helper와 두 call site를 제거하고 공통 merger의 `Get-EsdeFolderEntries` / `Merge-EsdeFolderMetadata`로 통합한다. `Get-AndroidBoundGamelist`, SAME_NAME, RENAME, UNMANAGED/REVIEW, 기존 legacy merger가 같은 folder 보존 정책을 사용한다. game merger/runtime/ROM policy는 유지한다.

- 모든 Android-only folder는 whole-node로 보존한다. `_TEST`, `_UNREGISTERED`의 path/runtime/custom fields/attributes/comments도 포함한다. folder만 있는 XML도 보존하며 synthetic game이나 managed ROM을 생성하지 않는다.
- 같은 normalized folder path는 master node가 base이다. 관측된 일반 metadata `path/name/desc`는 master가 기준이고, Android `playcount/playtime/lastplayed`는 기존 runtime tag-presence helper로 이식한다. empty/0도 그대로 보존한다.
- Android-only custom children/attributes/comments는 병합한다. 양쪽에 충돌하는 unknown/custom data나 complex known field가 있으면 임의 삭제·선택 대신 BLOCK한다. master-only folder는 기존 bytes/policy를 유지한다.
- 기존 case-sensitive relative path helper를 재사용한다. folder에만 선택적인 마지막 `/` 하나를 제거하여 `./_UNREGISTERED`, `_UNREGISTERED`, `./_UNREGISTERED/`가 같은 key를 갖게 한다. raw path를 일괄 재작성하지 않는다. game/file/traversal contract는 완화하지 않는다.
- malformed XML, path 누락/중복/element path, traversal/absolute path, normalized duplicate 또는 case collision, duplicate known field는 fail-closed.
- BASE 부재의 기존 일반 game metadata 미승격 정책은 유지한다. 과거 BASE 부재 folder 제거 테스트는 이번 명시적인 folder retention 정책에 맞게 갱신한다. folder metadata 보존은 ROM/game 자동 승격이 아니다.

실제 blocked scenario는 RENAME 0 / SAME_NAME 0 / UNMANAGED move 1 / REVIEW 1, folder `./_UNREGISTERED`, lastplayed `20261011T093913`이다. 신규 fixture와 production read-only preview에서 folder 1→1 및 game semantic 동일 여부를 확인한다. 실제 install/sync나 Android/Dropbox mutation 없이 checkpoint/RC2를 준비한다. version/releaseTag는 1.7.0/v1.7.0 유지.
