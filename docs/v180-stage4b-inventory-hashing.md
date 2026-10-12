# v1.8 Stage 4B inventory/SHA 최적화

version/releaseTag는 1.7.0/v1.7.0을 유지한다. persistent cache, mtime-only unchanged 판단, 병렬 전송은 도입하지 않는다.

## Android batch

ROM, media, save/state root를 기존 허용 경계 안에서만 조회한다. root/ancestor symlink와 canonical root redirect를 검증하고, `find -exec stat -c … {} +`로 size/mtime/mode/device/inode/path를 수집한다. regular file만 허용한다. SHA는 여러 절대 경로를 안전하게 quote한 하나의 sha256sum 호출로 묶는다. chunk는 1,000개 이하·인자 약12,000 UTF-16 문자 이하로 제한한다.

stat 출력은 TAB 구분 고정 숫자 필드 5개와 마지막 전체 path이다. SHA 출력은 64 hex + 두 공백 + 전체 path이다. 공백 split을 사용하지 않는다. 기존 path contract가 TAB/newline/control 문자를 금지하므로 delimiter를 숨긴 malformed path는 BLOCK이다. 한글/공백/괄호/대괄호/apostrophe/ampersand/Unicode는 보존한다.

metadata를 SHA 전후 두 번 읽어 generation 내 변화·부분 목록·경로/SHA binding mismatch를 차단한다. missing/permission/partial SHA 실패는 BLOCK이다. native/toybox 명령 자체가 없을 때만 기존 pull/local SHA fallback을 허용한다. `_TEST` prune이 적용된 목록에 `_TEST`가 다시 나타나면 hard reject한다.

## selective SHA와 staging

classification auxiliary 및 지원하지 않는 local-only extension은 기존 정책대로 SHA 대상에서 제외한다. media는 source/ownership 비교에 필요한 경로만 Android SHA를 계산하며, unknown Android-only media는 보존한다. 동일 SHA 판단·collision·recovery에 필요한 SHA는 계속 계산한다.

source media는 한 번 해시하고 변경 계획이 없는 파일은 복사하지 않는다. create/update 계획이 있는 파일만 **모든 Android mutation 전에** staging copy를 만들고 SHA를 재검증한다. mutation adapter의 remote temp/final SHA 및 외부 변경 검증은 유지한다. size mismatch만으로 owned media 변경을 허용하지 않는다.

planning ROM은 batch native SHA를 사용한다. 기존 Read-ClassificationRom의 mutation 호출은 native+pull verification을 유지한다. `PlanningOnly`만 native 성공 시 binary pull을 생략한다.

## session memo와 snapshot

source SHA memo는 source/device identity·절대 path·volume/file ID·size·mtime key에 묶는다. 해당 파일의 deny-write/delete read handle이 유지되는 동안만 재사용한다. fresh handle의 file ID도 확인하여 같은 path의 다른 파일과 혼동하지 않는다. Windows file identity를 얻지 못하면 memo를 사용하지 않고 fresh SHA로 돌아간다.

mutation/recovery revalidation과 Android pull 임시 파일은 memo를 우회한다. push/move/delete 직전에 source memo와 guards를 폐기하고 새 generation을 만든다. device/source 변경, 새 operation, completion/failure에서는 이전 session을 폐기한다. 디스크 SHA cache는 없다.

Android SHA는 size+mtime만으로 memo하지 않는다. 각 batch는 createdAt/generation/rootFingerprint를 가지며, fingerprint는 metadata와 계산한 SHA를 포함한다. DuplicateScan은 동일 snapshot 안에서 Get-RenameContentEvidence가 확보한 ROM rows를 다시 사용하여 두 번째 전체 해시를 제거한다. cleanup/revalidation은 **새 batch snapshot**을 만든다. 서로 다른 GUI request/operation의 오래된 snapshot은 재사용하지 않는다.

## mtime 신뢰성

Android shared storage의 epoch seconds와 Dropbox/copy/push/FAT-like mtime은 byte 동일 증거가 아니다. 이번 단계에서는 모든 환경에서 mtime-only fast-path를 비활성화한다. same-size/same-mtime bytes 변경은 SHA로 검출한다. PC memo의 안전 근거는 timestamp가 아니라 파일 identity와 유지 중인 read guard다.

## 진행률 및 검증

batch 목록 수집은 indeterminate, SHA 총량 확보 후 chunk current/total을 표시한다. batch는 별도 nested phase로 표시하여 hash 완료가 media 비교 완료로 오인되지 않게 한다. 긴 ADB 명령의 500ms heartbeat, 기존 status/summary contract를 유지한다.

Stage 4A commit 014f60f를 reference로 classification/summary, media unchanged/create/update/collision, duplicate 3등급·asset/delete plan·XML bytes를 비교한다. 실제 Android는 read-only planning/scan만 수행한다. no-op 계획, actual mutation 0, 기존 REVIEW 유지가 필요하다.

전체 SHA 50% 감소는 목표이며 안전 조건이 아니다. 처음 보는 unmanaged media의 동일 bytes 여부나 duplicate safety inventory는 SHA 없이 입증할 수 없으므로 목표 달성을 위해 생략하지 않는다.

## 2026-10-12 읽기 전용 측정

동일 기기/격리 source의 Stage 4A baseline과 비교했다. TEMP/ESDE-stage4b-profile-frozen-*의 normal-performance.json, duplicate-performance.json 및 plan.json이 원본 evidence다. baseline의 gitCheckpoint는 측정 당시 base commit이고 implementationSha256으로 최종 source와 연결한다. 실제 GUI sync 전체 실행 시간으로 해석하지 않는다.

| 항목 | Stage 4A | Stage 4B |
|---|---:|---:|
| planning elapsed ms | 135533 | 18144 |
| ADB 전체/shell/pull | 1470/1364/106 | 44/42/2 |
| ADB hash 명령 | 620 | 6 |
| 전체 SHA | 2651 | 1641 |
| media 비교 ms | 83325 | 2497 |
| GB/GBC ROM 준비 ms | 14437/18952 | 1824/2031 |
| source media 준비 ms | 16296 | 9467 |
| DuplicateScan elapsed ms | 83989 | 11487 |
| DuplicateScan ADB/SHA | 52/1763 | 64/1369 |

planning 시간 86.6%, ADB 97.0%, media 비교 97.0%, DuplicateScan 시간 86.3% 단축. 전체 SHA 감소는 38.1%로 50% 목표 미달이다. DuplicateScan ADB는 stat 전후·chunk 검증 추가로 증가했지만 반복 root SHA 및 shell 내 파일별 process 비용을 줄여 시간은 크게 단축됐다.

normal summary는 Stage 4A와 동일(Managed 99 / UnmanagedMove 0 / Promoted 0 / LocalOnly 5 / Review 1), GB media HOLD 유지, 실제 transfer/delete/rename/mutation 모두 0. DuplicateScan 기존 REVIEW 1건 유지, source memo hits 99, 동일 snapshot ROM inventory reuse 1회.

progress write 55회/106.3045ms, 최대 silence 1472ms; DuplicateScan 41회/130.9861ms, 최대 silence 2012ms. 모든 update silence는 5초 미만이다.

신규 inventory/differential fixture 38 PASS, 전체 41 tests ExitCode=0. 다음 단계는 source media SHA/read-guard overhead, 실제 normal sync의 mandatory revalidation 비용, PS collection lookup 비용을 조사한다. 실제 GUI no-op sync timing은 별도 검증이며 이번 단계에서는 실행하지 않았다.
