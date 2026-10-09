# v1.5.0 Stage 3 — Android local-only 분류

시작 HEAD: 5cd0ca72e7ea3a54795b4a4203d4700584f093cd.
Dropbox는 Windows의 managed source of truth이며 이 기능은 Dropbox에 쓰지 않는다.
이전 공유 라이브러리 채택 설계는 폐기됐다. 기록은 docs/history에 보존한다.

## 경계와 용어

_TEST는 manual-only 유입, _UNREGISTERED는 app-classified 유입이다.
두 경로 구성요소와 하위는 동일한 local-only 보호 대상이며 일반 inventory/mirror에서 제외한다.
기존 local-only ROM은 다시 검사·이동하거나 managed로 승격하지 않는다.
관리 여부는 source ROM 경로/SHA로 판단한다. gamelist는 optional metadata이다.

## 분류

선택 system의 일반 Android ROM만 검사한다. 현재 검증된 GB/GBC extension만 사용한다.
source/Android case collision, traversal/절대경로/control/Windows 예약명/invalid segment,
symlink 및 불확실한 hash/listing을 차단한다.
metadata.txt/systeminfo.txt는 기존 ES-DE sidecar로 구분하여 분류하지 않는다.
.sav/.srm/.rtc 및 state sidecar는 ROM SHA index/자동 분류/전송에서 제외하여 기존 데이터를 보존한다. 이는 basename/location mapping을 검증했다는 의미가 아니다.
그 외 미확정 non-ROM은 보호를 위해 차단한다.

- canonical same path + same SHA: Managed, move 없음.
- same path + different SHA: MANAGED_CONFLICT, ROM overwrite/delete/move 없음. 관리본 XML/media와 Android runtime 보존 정책은 적용 가능.
- different path + same-system source SHA 하나: MANAGED_PATH_MISMATCH, 실제 save/state/media mapping unknown이면 REVIEW. canonical ROM 중복 전송 없음.
- same-system SHA 후보 여러 개: AMBIGUOUS. 정확한 경로가 있어도 안전 규칙 5번을 우선해 REVIEW. 자동 mutation 없음.
- source 경로/동일 SHA 없음: Unmanaged → _UNREGISTERED/<relative structure>.
- destination 존재: same SHA도 DUPLICATE_BLOCK, 다른 SHA는 COLLISION.
- destination metadata node 존재: 추측 병합/중복 삭제 없이 BLOCK.

## XML

parser DOM clone의 기존 whole game에서 path만 변경한다.
runtime/preference/altemulator/media/unknown/comment/attribute 전체를 유지한다.
game node가 없으면 ROM만 이동하며 synthetic game을 만들지 않는다.
ROM이 없는 Android-only stale node는 whole-node 그대로 유지하며 cleanup하지 않는다.
실제 source ROM으로 관리되지 않는 기존 Android node는 metadata BASE에 같은 stale path가 있어도 보호한다.
Managed metadata/runtime3, system-level alternativeEmulator subtree와 확정 GB/GBC mapping은 독립적으로 유지한다.
원본 Dropbox XML은 변경하지 않는다.

## 순서 / 실패 안전

전체 source 검증/hash → classification State guard → foreground SAFE 두 번 →
ES-DE stop → normal ROM inventory/link/SHA → Android XML pull/parse →
전체 classification/XML preview 및 media 계획 → source/XML/ROM 재검증 →
same-filesystem no-clobber mv → destination SHA 및 source absent 확인 →
기존 verified gamelist temp push/read-back/XML/SHA/CAS/mv → final verify →
remote inventory refresh → managed mirror → ES-DE restart.

같은 source 경로의 SHA conflict는 warning을 기록하고 ROM 전송에서 제외한다. 일반 metadata/runtime 변환과 media engine은 유지한다.
일반 mirror의 디렉터리 fast push는 wrapper에서 파일별로 제한한다. 전송 직전 source/Android SHA를 재확인하며 늦게 발생한 conflict도 보존한다.
PATH_MISMATCH/AMBIGUOUS가 있으면 안전한 file-level media 관계를 입증할 수 없어 해당 system의 ROM/XML/media job 전체를 REVIEW로 보류한다.
정규화 executor는 연결하지 않았다. 검증된 explicit save/state/media binding fixture에만 공동 canonicalization proposal을 만들며 ROM-only proposal은 금지한다.
기존 Mirror-SystemFolder/remote listing/공통 delete safety 본문은 바꾸지 않는다.
wrapper는 관리본 file set만 remote 비교 대상으로 제공하여 새 extra ROM 삭제 경쟁을 방지한다.
refresh에서 새 unmanaged/충돌이 발견되면 mirror 전에 차단한다.

State/android-classification/<source-device identity>.json은 App 밖 최소 상태 기록이다.
prepared/moving/roms-moved/completed 또는 recovery-needed, 경로/SHA/error/PC staging 위치만 기록한다.
ROM 이동 후 XML 실패/강제 종료 시 자동 reverse move/삭제/복구를 하지 않는다.
추가 mutation을 차단하고 PC snapshot/backup 및 현재 경로를 사용자가 검토해야 한다.
다중 move는 원자적이지 않으며 일부 성공은 이동된 위치와 원본 XML의 불일치를 남길 수 있다.
ES-DE 복귀는 기존 lifecycle finally가 담당한다.

## Media

reserved 경로 구성요소는 기존 media 제외 정책으로 보호한다.
local-only 존재 또는 분류 대상이 있는 system은 미확정 flat media 관계 때문에 media job 전체를 보류한다.
metadata의 기존 media references는 유지하고 실제 media file relocation은 하지 않는다.
이 보수적 보호는 해당 system의 managed media 갱신도 지연한다.
정밀한 per-file local-only media ownership 판정은 후속 정책 결정 사항이다.
그 외 system의 기존 media ownership/journal/rollback은 유지한다.

## 검증 / 실환경 전제

모든 I/O는 mock ADB 및 TEMP fixture에 한정한다. 실제 기기/Dropbox/설치에 적용하지 않는다.
기존 Stage 3 시험 ROM, failed transaction, backup/session을 읽거나 정리하지 않는다.
채택 전용 4개 테스트는 제거하고 classification/move 테스트로 대체한다.
App 8개 및 tag v1.4.8 validator 계약을 유지한다.
실환경 전: 코드 리뷰, 명시 승인, 선택 system 전체 백업/전후 SHA, 단일 최소 fixture,
SAFE/잠금 해제, source path/hash 및 destination/XML collision gate 확인.
추가 extension catalog, media 정밀 정책, 다른 모니터/vendor 및 fault recovery는 미검증/미확정이다.
## 분류 결과와 SHA index
Classification: MANAGED / MANAGED_CONFLICT / MANAGED_PATH_MISMATCH / UNMANAGED / AMBIGUOUS / LOCAL_ONLY / INVALID.
RelativePath/AndroidRelativePath, Sha256/AndroidSha256, MatchedDropboxPaths, MatchedShaPaths, Reason, Action을 반환한다.
관리본 ROM을 경로 dictionary와 SHA → paths[] index로 한 번 모은다. 비교는 전달된 hash index를 사용하며 ROM마다 source를 다시 hash하지 않는다.
commit 직전 source 재hash는 cache 최적화보다 concurrent-change 검증을 우선하기 위한 별도 검사이다.
source의 잘못된 경로/hash/case collision은 전체 source 검증 실패이다. Android INVALID는 진단 결과로 남고 executor 전에 차단된다.
MANAGED는 warning 없음. CONFLICT는 ROM version/revision/patch 확인 warning과 PRESERVE_AND_WARN 처리이다.
LOCAL_ONLY/UNMANAGED는 whole-node 정책, REVIEW는 원본 그대로 보존한다.

## 실제 Retroid 읽기 전용 조사 (2026-10-09)
serial 7b67d4e2. GB managed 40/local-only 1, GBC managed 57. 나머지 classification은 모두 0.
관리본 GB/GBC duplicate SHA group 0. 전후 source 및 Android ROM 경로/SHA 동일.
GB local-only 1개는 이전 Stage 3 시험 자료이며 이동/삭제/정리하지 않았다.
GBC source/Android에 .sav 2개가 있어 ROM count와 별도로 보존했다.
RetroArch savefile_directory=/storage/emulated/0/RetroArch/saves, savestate_directory=/storage/emulated/0/RetroArch/states.
sort_savefiles_enable/sort_savestates_enable=true, content-dir/by-content=false.
SameBoy .srm/.rtc 실파일은 관찰했으나 state/slot/auto state 실파일 및 모든 override 증거가 없어 mapping은 UNKNOWN이다.
fixture의 known mapping은 가상 검증 자료이며 실제 emulator 지원 등록이 아니다.

## 실환경 검증 checkpoint
Stage 3.2 단일 UNMANAGED → LOCAL_ONLY 흐름은 PASS했다. 범위와 한계는 [실환경 검증](v150-stage3-runtime-validation.md)을 참조한다.

## REVIEW/action 계약
Classification은 콘텐츠/경로 판정이고 Action은 실행 의도이다.
MANAGED → SYNC, MANAGED_CONFLICT → PRESERVE_AND_WARN,
MANAGED_PATH_MISMATCH/AMBIGUOUS → REVIEW,
UNMANAGED → MOVE_TO_UNREGISTERED, LOCAL_ONLY → PRESERVE, INVALID → BLOCK.
UNMANAGED라도 destination collision 등 실행 gate 실패 시 Action은 BLOCK이다.

Conflict는 파일 단위 ROM 전송/삭제/이동에서 제외한다.
directory fast-push도 파일별 wrapper를 통하므로 conflict를 덮어쓰지 않는다.
같은 system의 다른 managed ROM은 계속 처리한다.
관리본 metadata/media와 Android runtime3/alternativeEmulator/altemulator 정책은 유지한다.
local-only media 보호 때문에 system media를 보류하는 독립 조건은 그대로이다.

PATH_MISMATCH는 동일 managed content의 존재 증거이다.
현재 mapping UNKNOWN이므로 system review ROM/candidate와 기존 game별 보존, media system REVIEW로 보류하여
canonical 추가 push/ROM-only rename/추측 save/state/media 변경을 막는다.
AMBIGUOUS도 ROM은 후보 경로 group만 보류하며 gamelist 기존 node를 보존하고 media만 system 전체를 보류한다.
이는 안전한 per-file media 연결을 입증하지 못한 현재 architecture의 보수적 경계이다.

Get-RomClassificationNotice/Write-RomClassificationNotice는 한국어 안내와
system/path/managed SHA/Android SHA/action/canonical 및 SHA 후보 경로만 기록한다.
ROM bytes는 기록하지 않는다.
Get-RomReviewSummary는 ManagedCount/UnmanagedMoveCount/ReviewCount,
NoMutationReviewCount 및 classification+reason별 집계와 항목 안내를 반환한다.
Conflict warning도 ReviewCount에 포함하지만 no-mutation REVIEW와 구분한다.
summary는 성공 완료 status.json과 기존 GUI 완료 MessageBox에 연결한다.
현재 GUI는 worker status message와 sync.log를 읽으므로 이후 연결 가능하다.
[파일 단위 REVIEW 및 완료 요약]
ROM REVIEW pair/group은 Android path + managed 후보 전체를 함께 제외한다.
다른 SHA의 managed ROM은 계속 sync한다. 원본에서 사라진 일반 ROM은 삭제 근거가 없으므로
기존 UNMANAGED 이동 정책을 따른다. review 때문에 새 삭제 정책을 만들지 않는다.
gamelist master의 review 후보는 Android-bound copy에서 제외하고 기존 Android game만 whole-node 보존한다.
후보에 기존 Android node가 없으면 canonical game을 추가하지 않는다.
media의 game↔file 대응은 미확정이므로 review가 있는 system 전체를 보류한다.
ReviewIsolation에는 Sha256/AndroidPaths/ManagedCandidatePaths 및 RomAction/GamelistAction/MediaAction을 기록한다.
성공 후 summary를 status.json에 추가하고 기존 GUI 완료 MessageBox가 한국어 counts/reasons를 표시한다.
ReviewCount=0이면 상세 확인 영역을 생략하며 SHA/enum은 UI에 표시하지 않는다.
dialog는 최대 5개 항목을 표시하고 나머지는 상세 로그로 안내한다. 기존 별도 결과 복사 기능은 없다.
오류 종료는 기존 실패 창을 유지한다. summary는 성공한 작업 및 ES-DE 재실행 후에만 완료 status에 포함된다.
## Classification capability / legacy managed sync
자동 classification과 기존 managed sync의 지원 범위는 별개이다.
Get-RomClassificationCapability는 gb/gbc에 Supported, 그 외 정상 source system 이름에는
Unsupported, 잘못된 경로/예약 이름에는 Unknown을 반환한다.
등록된 ES-DE 전체 system catalog를 추측해서 확장하지 않는다.
Unsupported는 정상 상태로 action=legacy-managed-sync를 로그에 기록한다.
Get-ClassificationExtensions는 Unsupported에 빈 배열을 반환하며 caller는 분류 자체를 건너뛴다.
직접 classification planner에 미지원 system을 전달하여 빈 extension을 허용 목록으로 쓰는 것은 금지한다.

Prepare-RomSystemSync는 Supported에서 기존 snapshot/classification pipeline을 호출한다.
Unsupported에서는 Prepare-GamelistSystem -LegacyManagedSync를 호출하며 분류 plan을 만들지 않는다.
Sync-RomSystem은 Unsupported에서 기존 Mirror-SystemFolder를 직접 실행한다.
동일 path의 SHA conflict 추정, 다른 path의 SHA suppression, 자동 ROM 이동은 하지 않는다.
따라서 일반 Android-only 파일 삭제를 포함한 v1.4.9 strict mirror 의미가 그대로 유지된다.
_TEST/_UNREGISTERED 구성요소는 여전히 비교/전송/삭제 제외이며 whole-node metadata도 보존된다.

미지원 XML은 새 game-level altemulator 변환을 강요하지 않고 기존 Merge 함수를 사용한다.
v1.5.0의 runtime tag 및 alternativeEmulator 보존 정책은 유지한다.
미지원 media는 classification hold 없이 기존 ownership/rollback 정책을 적용한다.
GB/GBC의 정책과 REVIEW media system hold는 변경하지 않는다.
미지원 시스템만 선택하면 classification State/journal gate도 실행하지 않는다.

## status.json summary 공식 계약
ManagedCount, UnmanagedMoveCount, LocalOnlyCount, ReviewCount가 canonical count 필드이다.
별칭을 추가하지 않는다. worker/GUI/tests는 같은 이름을 사용한다.
UnmanagedMoveCount는 완료한 UNMANAGED 이동 수를 표시한다.
현재 counts의 범위는 Supported 시스템 classification inventory이며,
Unsupported legacy 시스템은 SHA 분류 집계에 넣지 않는다.
Items의 REVIEW 상세는 UI 최대 5개, 남은 개수는 상세 로그 안내로 표시한다.
SHA와 technical enum은 기본 UI에 표시하지 않는다.
summary 없는 이전 status 및 기존 실패 창도 지원한다.
공식 normal fixture는 tests/gui-summary/normal-status.json이다.
## Stage 4.2 GUI 육안 smoke / RC checkpoint (2026-10-09)
표시 전용 TEMP GUI와 공식 status fixture로 사용자가 실제 화면을 확인했다.
실제 ADB/worker/sync/다운로드/설치는 실행하지 않았다.
정상 완료(관리 97/이동 1/local-only 2/review 0), Conflict 1개,
PathMismatch 1개, Ambiguous 1개, REVIEW 8개 및 기존 실패 메시지 모두 육안 PASS.
96 DPI에서 문구/버튼 잘림, 화면 밖 배치, 줄바꿈 문제 없음.
REVIEW 상세는 5개만 표시하며 나머지 3개 상세 로그 안내도 정상이다.
SHA/technical enum은 기본 UI에 노출하지 않는다. Conflict는 완료+확인 필요로 표시한다.
실제 다른 모니터 DPI 전환은 이번 확인 범위가 아니며 기존 100%/125% layout 모델 검증과 구분한다.
이 결과는 production GUI 전체 sync 실행이나 실제 설치/업데이트 시험을 의미하지 않는다.
GB/GBC 외 분류 미지원은 정상 legacy sync를 막지 않으며 GBA 작업 결과는 v1.4.9 parity PASS.
save/state mapping UNKNOWN, canonicalization 미지원, REVIEW media system hold,
실기기 REVIEW 사례 부재, GB/GBC 외 자동 분류 미지원, 전용 결과 복사 부재는 non-blocker이다.
## LocalOnlyCount 실제 runtime 집계 (2026-10-10)
LocalOnlyCount는 Supported 시스템의 동기화 준비 시 분류 결과에서
LOCAL_ONLY로 판정된 기존 보호 ROM 수이다.
_TEST와 _UNREGISTERED 모두 포함하며, 검증된 ROM extension만 센다.
Unsupported legacy 시스템, sidecar/비ROM, CONFLICT/REVIEW/INVALID는 포함하지 않는다.

기존 runtime Get-ClassificationAndroidRows는 mirror용 Get-RemoteFiles의 예약 prune를
그대로 사용해 보호 ROM이 분류 입력에서 빠졌고, 실기기 summary가 0으로 표시됐다.
준비 단계는 -IncludeLocalOnly로 단일 read-only 파일 inventory를 받아
일반 ROM과 local-only ROM을 같은 classifier에 전달한다.
local-only는 파일 경로만 분류하며 bytes pull/hash 또는 mutation 대상으로 사용하지 않는다.
Get-RemoteFiles와 mirror/delete의 예약 prune는 그대로 유지한다.
정상 ROM의 후속 concurrent inventory 검증도 기존 prune된 목록으로 유지한다.
summary 함수는 분류 결과만 집계하며 별도 filesystem/ADB scan을 하지 않는다.

UnmanagedMoveCount는 이번 실행에서 새로 이동한 수이며,
LocalOnlyCount는 시작 시 이미 보호 대상이었던 수이다.
이동 후 같은 ROM을 다시 summary 입력에 넣어 이중 집계하지 않는다.
예: 기존 LOCAL_ONLY 2 + 신규 이동 1 → 이동 1 / 로컬 전용 2.
사후 실제 local-only 파일이 3개인 것과 이번 완료 요약의 시작 집계는 구분한다.
실기기 기록의 GB40+LOCAL_ONLY2 / GBC57+LOCAL_ONLY0은 97/0/2/0으로 표시한다.
canonical fields와 GUI formatter/layout은 변경하지 않는다.