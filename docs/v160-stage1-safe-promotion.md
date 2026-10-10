# v1.6 Stage 1: same-name safe promotion 설계

stable v1.5.0의 ROM/mirror/REVIEW 안전 정책을 유지한다. 현재 개발 version.json은 1.6.0 / releaseTag v1.6.0이다.
초기 proposal/mock 기록은 아래에 보존한다. 현재 Stage 1.3은 제한된 production-equivalent 경로 연결 및 격리 실기기 1회 검증을 완료했다.

## 허용 후보
- Supported gb/gbc, sync 시작 inventory에 존재한 root `_UNREGISTERED/` ROM만.
- `_TEST`는 manual-only 의도를 보존하므로 자동 승격하지 않는다.
- 예약 prefix 이후 상대 경로와 단일 same-system managed candidate의 canonical 상대 경로가 Ordinal 일치.
- basename만 같은 다른 하위 경로, 이름 변경, cross-system, 다중 candidate는 REVIEW.
- 현재 source SHA=최초 Android SHA=managed SHA, canonical destination absent.
- destination의 case-insensitive 충돌도 보수적으로 REVIEW, source/gamelist 중복은 REVIEW.
- parent 안전성, path-independent save/state, media relocation 불필요, local metadata 처리 근거가 모두 검증돼야 한다.
- canonical 동일 SHA 파일이 이미 있어도 source 삭제/정리하지 않고 REVIEW.

## 순수 proposal 계약
New-SameNamePromotionProposal은 classifier row를 변경하지 않고 독립 proposal를 반환한다.
Classification=LOCAL_ONLY_MANAGED_MATCH 유지, SafePromotionEligible 및 Action만 proposal에서 구분.
검증된 fixture에서만 PROMOTE_TO_MANAGED, 실제 mapping UNKNOWN이면 PRESERVE_AND_REVIEW.
SafetyEvidence는 caller가 검증해 공급할 snapshot 근거이며 arbitrary flag를 production 승인으로 쓰지 않는다.
현재 실제 emulator evidence 등록/production caller/이동 executor 연결은 없다.
ROM/XML operation 제안만 생성한다. 실제 SHA 재조회/경계/parent 검증은 미래 executor의 필수 조건이다.

## 향후 transaction
기존 Invoke-ClassificationMoves의 검증 패턴을 공통 same-filesystem verified move helper로 추출하는 별도 구현을 검토한다.
현 함수는 destination을 _UNREGISTERED로 고정 검증하므로 promotion을 그대로 전달할 수 없다.
별도 복제 executor 대신 방향별 validated plan + 공통 mv-n/SHA 검증 primitive를 사용한다.
전체 XML/ROM 준비 후 foreground SAFE 두 번 → ES-DE stop → source 및 destination 재검증 → 동일 filesystem 확인
→ 안전 parent → mv -n → destination SHA/source absence → 기존 Sync-GamelistSystem temp/readback/XML/SHA/fingerprint/rename
→ inventory refresh → managed mirror → ES-DE restart.
ROM 성공 후 XML 실패는 recovery-needed 상태 보존 및 후속 mutation 차단, 자동 reverse move/resume 없음.
새 proposal는 production mutation 경로에 연결되지 않았으며 이 transaction 자체는 미구현이다.

## XML
기존 Android node를 clone에서 canonical path로 바꾸고 기존 Get-AndroidBoundGamelist를 사용하면
master metadata + Android runtime3(0/empty 포함) + alternativeEmulator subtree 결과를 1 node로 만들 수 있다.
기존 canonical Android node가 있으면 병합 추측 없이 REVIEW.
local node가 있고 master canonical node가 없으면 runtime 유실 위험 때문에 REVIEW.
local node가 없으면 synthetic local node를 만들지 않고 기존 master node 정책을 따른다.
unknown/preference/media/platform local metadata는 기존 managed merge가 유지하지 않는다.
이들의 폐기/보존 정책은 미확정이므로 LocalMetadataResolved 근거 없이는 자동 승격 불가.
새 XML merger를 만들지 않는다.

## save/state 및 media
v1.5 조사 기록: RetroArch saves/states root, sort_savefiles/sort_savestates true,
content-dir/by-content false는 관찰했지만 모든 core/game override와 state slot/auto naming은 UNKNOWN.
같은 basename은 안전의 충분조건이 아니다. 전체 override/실제 path-independent naming 근거 확인 전 REVIEW.
save/state 이동·rename·write 0; 실제 ROM promotion도 아직 비활성.
첫 promotion run은 GB/GBC 해당 system media hold 유지. 다음 sync에서 남은 local-only/REVIEW가 없을 때만 기존 정책 재평가.
다음 sync에도 다른 local-only가 남아 있으면 hold가 계속될 수 있다. media rename/추론/새 ownership adoption 없음.

## summary/UI 제안 (미구현)
PromotedCount 별도 축 권고. 신규 GUI는 필드 absent를 0으로 처리해 이전 status를 읽어야 한다.
구 GUI는 추가 필드를 무시할 수 있으나 formatter fixture로 검증 필요.
LocalOnlyCount는 시작 보호 수, PromotedCount는 이번 완료 승격 수. UnmanagedMoveCount와 섞지 않는다.
ReviewCount는 실행되지 않는 fallback REVIEW만 집계하는 방향으로 별도 확정 필요.
App 8-file/updater package 계약에는 status 필드 추가가 직접 영향을 주지 않는다.
이번 Stage에서 summary 및 GUI 변경 없음.

## fixtures 및 다음 gate
same relative path / nested, basename-only mismatch, different filename, multiple candidate,
canonical same/different SHA, case collision, source change, game collision,
runtime zero/empty, alternative subtree, local absent, master absent, UNKNOWN evidence,
_TEST preserve, media hold/save-state Preserve, proposal I/O0 및 runtime 미연결.
실제 save/state mapping/override, unknown metadata 정책, parent safety evidence contract가 다음 Stage blocker.
실기기 시험/설치/Dropbox write/commit/push/tag/Release는 이번 Stage에서 하지 않는다.
## Stage 1.1 실기기 근거와 Stage 1.2 (2026-10-10)
사용자 확인: Retroid 7b67d4e2 + RetroArch aarch64 + SameBoy의 V160_SAVE_TEST.gb를
_TEST에서 gb root로 옮긴 뒤 in-game save 및 savestate load 성공, duplicate save/state 없음.
.srm/.rtc/.state는 RetroArch saves/SameBoy, states/SameBoy 아래 같은 basename 사용.
이전 UNKNOWN 기록은 조사 당시 상태이며 현재 이 구성의 basename 유지/path 변경은 실기기 근거 확보.
GB 시험 sample이며 적용 범위는 동일 구성 GB/GBC로 제한. 다른 core/vendor/override 변경으로 일반화하지 않는다.
현재 Stage는 추가 실기기 조회·mutation 없이 이 사용자 확정 결과를 근거로 설계한다.

### Metadata inspector
Get-PromotionMetadataSafety: 기존 XML model/Get-EsdeGameEntries 재사용.
known managed-authoritative scrape/media tags + runtime3 + game-level altemulator를 허용한다.
unknown/preference(favorite/hidden 등), attributes, comments, 중첩 XML/비표준 node는 LOCAL-EXTRA-METADATA/REVIEW.
중복 child/path 및 canonical Android path 충돌은 INVALID/COLLISION으로 preflight 차단.
local node가 있으나 managed canonical node가 없으면 runtime merge destination 없음으로 차단.
local absent는 정상 master 정책; synthetic local node 없음.
Get-PromotionBoundGamelist는 local clone path만 변경하고 기존 Get-AndroidBoundGamelist를 호출한다.
master 및 Android 원본을 수정하지 않는다. known altemulator도 최종 staging 변환 성공이 추가 gate이다.

### Mock verified move와 transaction
Invoke-VerifiedAndroidRomMoveMock는 Mock adapter만 허용하며 실제 ADB backend가 없다.
normal→_UNREGISTERED와 _UNREGISTERED→normal 방향의 정책은 caller가 검증한다.
Stat, Parent, MoveNoClobber, Record adapter는 in-memory fixtures만 구현한다.
source/destination normalized relative path, system scope, source link/SHA, destination absence,
source/destination parent canonical equality/containment, 같은 filesystem을 검증한다.
Parent adapter는 전체 ancestor chain symlink/종류 검사와 필요한 내부 parent만 생성하는 계약이다.
생성 후 parent 및 source/destination을 다시 검증하고 no-clobber move → hash/source absence 확인.
실제 parent-chain ADB adapter 구현은 후속 Stage이며 bool Safe만 믿는 production 구현은 허용하지 않는다.
생성된 빈 parent는 실패 후 자동 삭제하지 않는다.
Invoke-SameNamePromotionMock: XML prepare/validate 및 초기 fingerprint → state prepared → verified move
→ XML fingerprint 재검증 → 기존 temp/readback/fingerprint/atomic-rename 계약의 CommitXml adapter → completed.
Mock CommitXml는 성공/실패/fingerprint race를 모사한다. 실제 temp push/readback/atomic replace는 이번에 연결하지 않는다.
실패는 recovery-needed evidence 보존, 자동 reverse move/resume 없음.
transaction evidence에는 system/relative paths/expected 및 initial SHA/destination absent/XML/media/save/state action이 있다.
전체 XML/ROM bytes는 state 기록에 넣지 않는다.
production 적용 전 모든 계획 준비 → SAFE2 → ES-DE stop → final revalidation → ROM → XML → inventory refresh
→ normal managed mirror → media HOLD → ES-DE restart → status completed 순서가 필요하다.
현재 Confirm-ClassificationInventory의 expected classification은 promotion 전후를 고려하지 않으므로 production 연결 금지.
새 inventory가 canonical MANAGED임을 검증해 기존 Send-ClassifiedManagedFile의 동일 SHA no-push 경로를 사용한다.

### Summary proposal
Get-PromotionSummaryProposal은 status writer에 연결하지 않은 내부 계약 preview이다.
ManagedCount=start managed, UnmanagedMoveCount=start unmanaged 이동, PromotedCount=completed promotion,
LocalOnlyCount=start local-only, ReviewCount=fallback review. 성공 promotion은 ReviewCount에서 제외한다.
시작 local2 / 승격1은 LocalOnlyCount2 / PromotedCount1이며 이동 count와 섞지 않는다.
구 status에 PromotedCount 부재는 향후 신규 reader에서 0 기본값 처리; 현재 GUI/formatter/production fields 변경 없음.

### Stage 1.2 남은 gate
production adapter(parent chain/same filesystem/no-clobber), 기존 move executor와 공통 primitive 실제 통합,
원본/master/XML fingerprint binding, refresh 전후 classification 검증, incomplete state gate,
수정없는 prototype count를 실제 completed state와 연결, GUI backward compatibility는 다음 Stage 검증 대상.
현 production local-only match는 여전히 PRESERVE_AND_REVIEW. _TEST 자동 승격 없음.
## Stage 1.3 production 연결 (실제 sync 미실행)
version 1.5.0 유지, 미커밋 development tree에만 연결한다. 설치본/Release bytes는 변경하지 않는다.
Get-PromotionEnvironmentEvidence는 gb/gbc + Retroid serial 7b67d4e2 + Stage1.1 config SHA
b224183630dd375291bd67c605d31ce247dc3b7fe78aa4e2361cf82fd4fae111 + SameBoy system/game label + cfg override/link 없음에 제한.
현재 config가 달라졌거나 다른 serial/core이면 REVIEW. core binary update/다른 vendor에 대한 검증은 별도 등록 필요.
_TEST, 다른 이름/하위 경로, 다중 candidate는 기존 fallback; canonical ROM 존재는 기존 중복 cleanup 없이 REVIEW.
metadata extra는 REVIEW, canonical XML collision/invalid는 mutation 이전 BLOCK.

### Native adapter
공통 Invoke-VerifiedAndroidRomMoveCore를 Mock/Adb wrapper가 공유한다.
실제 Invoke-VerifiedAndroidRomMove caller는 _UNREGISTERED→동일 reserved-relative-path canonical만 허용한다.
Invoke-PromotionShell은 모든 nonzero exit/비어있지 않은 stderr를 차단한다.
Get-VerifiedRomParent는 ROMs/system root와 각 기존 ancestor directory/symlink/realpath/stat-device 및 case 충돌을 확인한다.
missing child만 mkdir, 생성 후 동일 검증; root 생성/자동 directory 삭제 없음.
Assert-PromotionFileCase는 file leaf의 case variant도 mutation 직전에 차단한다.
source/parent SHA와 device 재검증 → guarded mv-n → destination SHA/source absence.
parent creation attempts는 state/history에 남기며 rollback cleanup하지 않는다.

### Plan/evidence/order
Prepare-ClassificationSystem에서 조건부 proposal를 Promotions에 넣고 시작 inventory Action을 PROMOTE_TO_MANAGED로 표시한다.
classification 문자열은 LOCAL_ONLY_MANAGED_MATCH 유지, XML clone만 canonicalize한다.
Android XML/master XML 및 두 node fingerprints와 staged output SHA, environment SHA를 plan에 바인딩.
Assert-PromotionEvidence는 원본 Android snapshot/현재 master/source/staging/metadata/environment를 ROM 직전/직후와 commit 전에 재검증한다.
Sync-PromotionGamelist는 기존 verified XML staging/readback/fingerprint/rename 흐름을 strict ADB wrapper로 호출한다.
commit 후 target XML SHA, master fingerprint, refresh MANAGED 검증까지 성공해야 completed.
승격이 있는 run의 mixed normal→local-only move도 같은 executor에서 처리하고 system XML을 한 번 commit한다.
아무 승격도 없으면 기존 v1.5 Invoke-ClassificationMoves 경로를 그대로 사용한다.
state prepared→rom_moved→xml_committed→completed, 실패 recovery-needed. 기존 New-ClassificationContext가 unfinished/corrupt를 차단한다.
State/android-classification-history/<transaction>.json에 별도 기록하여 active state가 다음 작업으로 갱신돼도 증거를 보존한다.
부모 생성/ROM 이동 이후 실패 자동 복구 없음. staging과 journal 유지.

### Inventory/summary
Confirm-ClassificationInventory는 성공 승격 source를 canonical MANAGED 예상 row로 변환해 실제 refresh와 비교한다.
Send-ClassifiedManagedFile은 동일 SHA canonical 존재를 읽고 USB push를 생략한다.
PromotedCount 공식 status 필드: completed promotion 수, ManagedCount/LocalOnlyCount는 시작 inventory 기준.
GUI는 absent=0, zero는 기존 화면 유지, >0이면 관리 ROM 승격 row를 표시한다. REVIEW detail에는 성공 승격을 넣지 않는다.
media는 첫 promotion run HOLD. save/state rename/move/write 없음.

### 격리 실기기 준비
Dropbox는 쓰지 않는다. 시험에는 관리 source 전체의 TEMP 사본을 쓰고 GB에 시험 ROM 사본만 추가한다.
기존 V160_SAVE_TEST canonical을 inbox에 준비하는 조작은 fixture 한정으로만 수행하고 SHA/전후 evidence를 남겨야 한다.
production 설치/GUI sync는 이 Stage에서 하지 않는다. 실제 시험 실행은 다음 승인 후 단일 run.
### Native transfer response와 fixture 준비 중단 기록
ADB file push/pull의 성공 안내는 stderr 또는 stdout에 올 수 있다.
Test-PromotionAdbResult는 exit0 + 정확한 source의 1 file/0 skipped 성공 안내 및 제한된 progress만 허용한다.
다른 stderr/stdout, 다른 source, nonzero exit는 차단하며 XML/size/SHA readback 검증은 그대로 유지한다.
Stage1.3 fixture 준비 중 최초 strict wrapper가 정상 전송 안내를 거부하여 ROM은 inbox에 있으나 XML final commit 전 중단됐다.
이는 actual promotion/sync가 아닌 canonical→inbox 시험 fixture 준비이다. ES-DE restart 성공.
기존 XML/media/save/state/Dropbox bytes는 baseline과 동일, 시험 ROM 경로 1개만 변경됐고 SHA 동일.
자동 역이동/XML 재시도는 하지 않았다. 격리 Trial State는 recovery-needed로 보존하고 다음 실행을 차단한다.
fixture NOT READY: 사용자 승인 후 시험 game path 수정과 fixture state 명시적 검토가 필요하다.
설치된 v1.5 App/RC/production State는 변경하지 않았다. 수정된 native acknowledgement handling은 mock에서 검증했다.
같은 SHA인 기존 다른 이름 local-only가 있어도 그 node/ROM을 보존한다.
승격이 승인된 canonical metadata만 기존 REVIEW master exclusion에서 제외하여 canonical node 1개/master metadata를 보장한다.
다른 REVIEW의 ROM push suppression과 local-only whole-node 보호는 그대로 유지한다.
## Stage 1 실기기 완료 checkpoint
Retroid Pocket Mini V2 / serial 7b67d4e2 / GB / RetroArch + SameBoy의 격리 시험 1회 PASS.
Evidence root: C:\esde-v160-fixture-12a6c42a
최종 증거: C:\esde-v160-fixture-12a6c42a\actual-promotion-20261010-132821\FINAL-PASS.json
fixture recovery 원본 및 history는 동일 root의 recovery-20261010-132311에 보존한다.
위 NOT READY/recovery-needed 기록은 당시 중단 상태의 역사이며, 명시적 수동 검증 후 Trial gate를 해소했다.
_UNREGISTERED/V160_SAVE_TEST.gb → V160_SAVE_TEST.gb internal move, SHA 동일, ROM USB push 0.
canonical node 1 / old _UNREGISTERED node 0, runtime3/alternativeEmulator 및 다른 node semantic 보존.
완료 summary: ManagedCount 97 / UnmanagedMoveCount 0 / PromotedCount 1 / LocalOnlyCount 3 / ReviewCount 2.
save 39/39 및 state 1/1 path·size·SHA 동일. 사용자 in-game save와 Save State 실제 load 모두 성공.
media HOLD, Source/Dropbox write 0, production State/App unchanged, final SAFE 2회 / ADB residual 0.
runner는 child ExitCode를 null로 기록했다. 성공 근거는 worker done/100%/6-6, complete marker와 completed transaction 및 전후 검증이다.
이 절대 경로는 시험 증거 위치이며 제품 실행 dependency가 아니다. 시험 자료 자동 정리 없음.
지원 범위는 검증된 기기/config의 GB/GBC + SameBoy gate로 제한하며 실제 promotion/load 검증은 GB이다.
RC에서는 package/static와 checkpoint bytes 동등성만 검증하며 production install/sync를 추가 실행하지 않는다.