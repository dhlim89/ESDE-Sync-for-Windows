# v1.8 Stage 1 — _UNREGISTERED Duplicate Manager

## 범위와 개발 기준

stable v1.7.0(main e23c80a3408a001e6a8a31823aae94d948ea7230)의 runtime을 변경하지 않는다. version.json은 1.7.0이다. 구현은 tests/support의 순수 proposal, UI view model, selection plan, mock executor에 한정한다. normal sync, GUI, installer에서 이 모듈을 호출하지 않는다. 실제 삭제·병합 기능은 다음 단계 대상이다.

## 후보 및 등급

같은 GB/GBC system의 _UNREGISTERED 일반 파일, 실제 Android canonical 일반 파일, 단일 managed SHA candidate가 path/size/SHA evidence로 대응할 때 UNREGISTERED_MANAGED_DUPLICATE로 확인한다. symlink, traversal, case ambiguity, 불완전 inventory는 통과하지 않는다. _TEST 구성요소가 하나라도 있으면 먼저 완전히 제외하여 목록·count·warning을 만들지 않는다. 확인되지 않은 의심 항목은 REVIEW_ONLY이며 확인된 중복 count와 구분한다.

SAFE_DELETE는 저장 데이터가 없고 local game node가 없거나 path만 있는 경우이다. SAFE_MERGE_DELETE는 known .srm/.rtc/.state 또는 known metadata가 있고 기존 helper로 안전한 migration/merge가 가능한 경우이다. 데이터 존재 자체는 REVIEW 사유가 아니다.

destination 저장 파일은 SHA가 같아도 REVIEW_ONLY이다. slot/autostate/unknown sibling, old local media, unknown/custom element/attribute/comment/nested structure, duplicate XML, 환경 근거 부족은 REVIEW_ONLY이다. traversal은 BLOCK 예외다. canonical이 없거나 SHA가 다른 항목도 삭제할 수 없다.

현재 환경 근거는 Retroid + RetroArch + SameBoy GB/GBC에 한정한다. complete content/save/state/media inventories 및 path independence evidence가 필요하다. 다른 core로 일반화하지 않는다.

## 저장 데이터와 metadata

Get-RenameAssetPlan으로 SameBoy의 .srm/.rtc/.state mapping과 collision을 판정하고 Invoke-VerifiedRenameAssetMoveCore를 mock backend로 재사용한다. 다른 ROM이 같은 basename을 쓰거나 old==new이고 저장 파일이 있으면 소유권을 분리할 근거가 없으므로 REVIEW_ONLY다. 공유 namespace에서 파일을 삭제하거나 이동하지 않는다.

Get-PromotionMetadataSafety에 검사 projection을 전달한다. duplicate 관리에서는 canonical node 존재가 정상이라는 점만 projection에서 분리하고 원본 evidence는 그대로 묶는다. master metadata base, Android runtime tag-presence(0/empty 포함), alternativeEmulator/altemulator는 기존 Get-AndroidBoundGamelist를 재사용한다. canonical/local runtime이 동시에 있고 값이 다르면 합산·최신값 선택을 발명하지 않고 REVIEW_ONLY다. canonical custom metadata도 검사한다.

folder는 기존 generic merger가 보존한다. 개별 중복 정리 때문에 _UNREGISTERED/_TEST folder를 삭제하지 않는다. lastplayed는 기존 Android tag-presence 정책이며 최신 timestamp 계산 정책이라고 설명하지 않는다.

## Media 및 UI

Get-RenameMediaPlan을 재사용하여 old local media가 있으면 전체 REVIEW_ONLY, MediaAction=HOLD이다. 실제 media rename/adoption/delete는 없다.

UI 모델 열은 선택/시스템/미등록 ROM/관리 ROM/상태/처리 내용/이유이다. 상태는 정리 가능, 병합 후 정리, 검토 필요. 기본 선택은 전부 off, REVIEW checkbox는 disabled이다. 향후 메인 안내는 “관리 ROM과 중복된 미등록 ROM N개가 있습니다.”와 “중복 ROM 확인” 버튼을 사용한다. Stage 1에서는 실제 GUI를 변경하지 않는다.

## 선택과 transaction

selection snapshot은 명시적 ID 목록만 받으며 중복 ID, stale binding, disabled row를 차단한다. 여러 선택이 동일 canonical로 병합될 때는 배치 충돌 정책이 미정이므로 차단한다. binding에는 source/canonical/managed file fingerprints, XML evidence, staging bytes, operation plan을 포함한다.

SAFE_MERGE_DELETE 순서는 prepared → saves_moved → states_moved → xml_committed → source_deleted → completed이다. 보존 데이터 migration, XML commit, evidence 재검증을 먼저 수행하고 중복 ROM 삭제는 마지막 destructive step이다. SAFE_DELETE는 asset mutation 없이 XML/source 정리만 계획한다. 실패는 recovery-needed와 마지막 성공 phase를 보존하며 자동 reverse/resume는 없다. 실제 executor는 foreground SAFE 2회, ES-DE stop/restart, 완전한 inventory 및 recovery gate를 다시 구현·검증한 뒤 연결해야 한다.

## 미래 delete primitive 계약

exact source single file만 허용한다. _UNREGISTERED 하위이고 _TEST가 아니며 normalized path/root containment, file type/link, source SHA/size, canonical 존재/SHA/size, managed fingerprint를 실행 직전 재검증한다. 같은 이름의 경로·case collision도 차단한다. broad rm 또는 directory deletion은 허용하지 않는다. 삭제 후 source 부재 및 canonical SHA/size 불변을 확인한다. Stage 1의 Invoke-VerifiedAndroidDuplicateDeleteMock은 메모리 dictionary만 바꾸며 실제 ADB 삭제 adapter는 구현하지 않는다.

## 남은 production 작업

실제 UI 선택·snapshot 보관, Android verified exact-delete adapter, asset/XML 동시 변경 및 parent/link safety의 실기기 evidence, 전용 recovery journal, 실패 주입과 승인된 격리 실기기 검증이 필요하다. 이 단계의 READY는 설계/proposal/mock 완료를 뜻하며 사용자 데이터 정리 기능 READY가 아니다.
## Stage 2 — production-capable adapter와 별도 GUI

Stage 1 checkpoint: acbeb7ccbb723f9a49df9edc36a86f1f478b0223. version은 1.7.0 유지. Stage 2 코드의 실제 기기 삭제·저장 이동·XML 변경·sync·install은 실행하지 않는다. fake shell/memory filesystem fixture에서만 mutation을 검증한다.

proposal 함수는 sync-worker.ps1로 옮겨 단일 runtime 원본으로 사용한다. tests/support entry는 worker AST 함수만 로드하고 Stage 1 mock wrapper를 유지한다. 새 App runtime 파일은 추가하지 않는다.

worker Operation=Sync가 기본이다. DuplicateScan은 read-only inventory/XML pull 및 PC snapshot만 생성하고, DuplicateCleanup은 GUI의 명시적 selection 파일이 있어야 실행된다. duplicate-status.json/duplicate.log/duplicate-scan.json/duplicate-result.json과 duplicate-evidence는 normal sync status/log/summary와 분리된다. requestId로 이전 작업 결과가 현재 결과로 오인되지 않도록 한다.

메인 GUI의 중복 ROM 확인 버튼은 별도 검사를 시작한다. 7개 열, safe 항목만 전체 선택, 전체 해제, 상세 SHA와 저장 migration 안내, 선택 수, 취소 가능한 확인창, 결과 복사를 제공한다. REVIEW checkbox는 read-only이며 _TEST는 행 생성 전에 제외한다. 처리 중 재실행과 닫기를 막고 normal sync/update와 operation mutex를 공유한다. 기존 공식 summary 5개 필드의 의미는 바꾸지 않고 DuplicateUnregisteredCount는 별도 informational 값으로만 사용한다.

실행 직전 fresh proposal과 selection binding을 대조한다. 대상 ROM 3자 fingerprint, managed master XML, local/canonical node, asset mapping, media 및 환경 evidence를 바인딩한다. 안전 조건이 바뀐 항목은 STALE/REVIEW로 건너뛴다. 대상과 무관한 이전 항목의 정상 XML 변경은 다음 선택 항목을 잘못 stale 처리하지 않도록 per-item binding을 사용하되 실행 동안 전체 inventory/XML를 재검증한다.

cleanup XML은 기존 managed merger가 만든 canonical node를 원래 Android XML에 반영하는 scoped projection이다. 해당 old local/canonical game node 외의 game/folder/alternativeEmulator 노드는 원본 그대로 유지한다. 별도 XML merger를 만들지 않는다. 기존 verified temp push → re-pull → SHA/XML 검증 → 동시 변경 확인 → 같은 디렉터리 replacement를 재사용한다.

Invoke-VerifiedAndroidDuplicateDelete는 exact path, 동일 system root, _UNREGISTERED source, _TEST 제외, normalized path, source/canonical 일반 파일, symlink/parent/case 검사, SHA/size 3자 일치 및 동일 inode 거부를 적용한다. native shell은 source/canonical parent chain과 hash/size를 같은 command에서 다시 확인한 뒤 quoted `rm -- <exact source>`만 수행한다. directory/glob/recursive 삭제는 없다. 삭제 직후 journal에 rom_deleted를 기록하고 source 부재/canonical SHA·size·inode 불변을 확인한다.

SAFE_MERGE_DELETE는 기존 Get-RenameAssetPlan, New-RenameAssetAdbAdapter, Invoke-VerifiedRenameAssetMoveCore를 사용한다. 지원은 .srm/.rtc/.state만, destination 존재는 동일 SHA라도 REVIEW, slot/autostate/old media는 REVIEW다. 자동 media 처리 없음.

전용 State/duplicate-cleanup/<transactionId>.json은 transactionType=UNREGISTERED_DUPLICATE_CLEANUP, source/canonical/managed file evidence, selection grade/binding, XML/staging fingerprint, planned/completed asset moves, mutation intent, phase/time/error를 atomic 저장한다. phases는 prepared → assets_moved → xml_committed → rom_deleted → verified → completed다. 각 asset move의 intent/verified event를 남겨 phase 사이 crash도 추적한다. 정상 journal도 삭제하지 않는다.

기존 completed 이외 journal 또는 unreadable/malformed journal은 cleanup과 normal sync를 차단한다. Get-DuplicateRecoveryReport는 파일과 journal을 read-only 대조하며 automatic resume/rollback은 모두 false다. 정식 recovery UI/자동 resume는 구현하지 않는다. 다음 Stage 3에서는 실패 evidence의 수동 reconcile 절차를 실기기에서 검증해야 한다.

다중 선택은 항목별 transaction이다. stale/preflight 실패는 검토 필요로 기록하고 다음 safe 항목을 검사한다. journal 생성 이후 실패는 recovery-needed로 기록하여 이후 항목 처리를 중단한다. 이전 completed는 유지, 이후 항목은 untouched/unprocessed다. 결과에 SAFE_DELETE 완료/병합 후 완료/검토/실패/미처리를 각각 표시한다.

Stage 3 실기기 승인 전까지 실제 장치에서 Duplicate Manager 실행 버튼을 누르지 않는다. production-capable 구현 완료와 실제 사용자 데이터 삭제 승인·검증은 별개이다.
_TEST는 duplicate ROM/link/hash inventory에서 prune한다. 저장 basename 소유권 충돌을 막기 위한 별도 read-only namespace는 파일명만 사용하며 _TEST ROM 내용/SHA, 중복 count/UI row를 만들지 않는다. namespace 근거가 불완전하면 migration을 REVIEW로 남긴다. legacy helper의 옵션 기본값은 기존 동작을 유지한다.
복구가 필요한 journal이 있으면 별도 검사 실행은 파일/XML 대조 report를 PC State에 남기고 중단한다. 다른 source/device의 journal을 현재 기기에 적용하거나 자동 resume하지 않는다.
# Stage 3.1 REMOTE-ONLY

실기기 Stage 3은 원격 환경 전환으로 보류한다. SAFE_DELETE 첫 준비 시도는
읽어온 master XML을 같은 파일에 저장하여 기존 `Write-EsdeGamelist`의 overwrite
protection에 차단됐다. Android mutation은 없었으며 기존 evidence는 보존한다.

`tests/support/duplicate-remote-harness.ps1`는 test-only staging authority를 확인한다.
원본 master → SHA/size 검증 복사본 → 새 fixture-master.xml 순서로 저장한다.
원본/입력 덮어쓰기, staging 외부 경로, reparse point는 차단한다. production writer와
worker/GUI runtime은 수정하지 않는다. 테스트의 production-original은 합성 fixture이며
실제 설치본/Dropbox master에 쓰거나 실제 ADB transport를 호출하지 않는다.

격리 staging에는 `source`, `master`, `android-fixture`, `evidence`가 있다.
fake Android는 `storage/emulated/0/{ROMs,RetroArch,ES-DE}`를 실제 TEMP 파일로
구성한다. proposal, scoped XML merger, verified asset move core, verified duplicate
delete core, batch transaction 및 recovery gate는 production 함수를 재사용한다.
filesystem transport만 Fixture/Mock backend로 교체한다. 실제 shell transport는
기존 production fixture에서 검증하며, remote 검증은 기기의 filesystem/ADB나
SameBoy 실행 검증을 대체하지 않는다.

`tests/duplicate-remote-static.ps1`는 SAFE_DELETE, 3종 SAFE_MERGE_DELETE,
GUI selection→transaction 연결, folder/게임 metadata 보존, REVIEW/BLOCK,
prepared/assets_moved/xml_committed/rom_deleted 실패 및 read-only recovery를 검증한다.
completed 재실행은 안전하게 거부하고 자동 rollback/resume는 하지 않는다.
기존 GUI fixture가 REVIEW disabled, select all/clear all, confirmation/cancel,
copy payload, `_TEST` 행 제외를 계속 검증한다. evidence는 자동 정리하지 않는다.

remote 결과는 **v1.8 Stage 3.1 REMOTE READY**만 사용할 수 있다.
실제 GUI SAFE_DELETE와 SAFE_MERGE_DELETE 및 사용자 save/Save State load 확인은
실기기 접근이 재개된 이후 별도 Stage 3에서 수행한다. version은 1.7.0을 유지한다.

## Stage 3.3 worker CLI contract

worker 최상위 param block에 GUI가 전달하는 세 인자가 누락되어 실제 DuplicateScan이
parameter binding에서 차단됐다. 선언만 추가한다: `Operation`은 string/ValidateSet
`Sync,DuplicateScan,DuplicateCleanup`, 기본 `Sync`; `SelectionFile`과
`DuplicateRequestId`는 optional string이다. 기존 mandatory 인자 5개의 순서/타입을 유지한다.
일반 sync는 새 인자를 요구하지 않는다. duplicate operation은 기존 dispatch를 사용한다.

request id는 duplicate operation에서 기존 32자리 소문자 GUID 검사로 필수화한다.
GUI는 scan/result/status의 requestId를 현재 요청과 대조한다. cleanup의 SelectionFile은
StateDir 내부이며 schema/scanId/source-device identity/선택 행/selection binding과
실행 직전 재검증을 거친다. request id 자체는 selection 권한 토큰이 아니다.
기존 recovery gate 실패 시 DuplicateScan의 read-only recovery report 경로를 유지하며
새 recovery operation은 추가하지 않는다.

`tests/duplicate-cli-contract-static.ps1`는 실제 GUI Start-DuplicateTask가 생성한
arguments를 캡처하고 실제 worker param block을 사용하는 별도 binding probe 프로세스로
검증한다. probe 본문은 인자만 출력하여 실제 sync/cleanup을 실행하지 않는다.
Scan/Cleanup, 기존 positional sync, 공백·한글 경로, invalid operation/request/selection,
stale scan, `_TEST` 및 traversal 방어를 검증한다. 실제 기기에서는 기존 fixture의
DuplicateScan만 허용한다. GUI cleanup/일반 sync는 이 단계에서 실행하지 않는다.
