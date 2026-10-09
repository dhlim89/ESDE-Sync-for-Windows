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
MANAGED는 warning 없음. CONFLICT는 ROM version/revision/patch 확인 warning과 PreserveRom 처리이다.
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
