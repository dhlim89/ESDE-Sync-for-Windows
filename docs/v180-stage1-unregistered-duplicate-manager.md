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