# v1.5.0 Stage 3.1 — adoption capability / journal inspector

실제 ACL/Dropbox/Android/journal을 변경하거나 실패 transaction을 재실행하지 않는다.
runtime 구현은 sync-worker.ps1 내부이며 App 8개 계약을 유지한다.

## Capability

현재 WindowsIdentity token을 DuplicateToken(SecurityImpersonation)한 뒤 Windows AccessCheck를 사용한다.
user/group/Everyone, deny-only/restricted token 및 DACL ACE 순서는 Windows가 평가한다.
generic file API에 맞춘 read/write mask를 사용하며 FullControl을 일괄 요구하지 않는다.
basic Allow/Deny CommonAce와 canonical DACL만 지원한다.
callback/object ACE, creator-group 상속, 비canonical/불완전 SD, API 오류는 Unknown.
미생성 child의 ACL은 지원하는 단순 상속 규칙으로 예측한다. creator-owner는 생성 사용자로 대체한다.
권한을 변경하거나 시험 파일을 생성하지 않는다.

plan별:
- 신규 ROM/XML: parent CreateFile, staging read/write, delete/rename capability.
- 없는 parent chain: 각 parent mkdir 및 상속된 child capability.
- 기존 XML replace: 기존 XML read/write/delete 또는 parent delete-child와 staging capability.
- 동일 SHA ROM reuse: ROM generic read만.
- SharedOutput 없음: XML write 검사 없음.

Allowed는 지원 범위 DACL 판정이다. 잠금/보안 필터/권한 변경/디스크 실패를 보장하지 않는다.
VolumeStatus/FreeSpaceStatus=NotChecked. destination sibling staging 설계는 유지하며 volume/space 조회는 TODO.
path/hash/policy validation → capability → journal gate → journal 생성 → 기존 transaction 순서.
직접 executor는 capability 부족 시 journal 생성 전에 throw.
worker는 capability 부족/Unknown인 adoption만 skip하고 normal sync를 계속한다.
inbox/reserved node는 보존하고 Android-only 일반 ROM 보존 wrapper도 유지한다.
미완료/손상 journal 자체는 유효 resolution이 없으면 기존처럼 모든 mutation을 차단한다. 권한 부족만으로 normal sync를 막지는 않는다.

## Inspector

Get-AdoptionInspection은 source/Android 상태를 읽고 파일을 만들지 않는다.
Android hash는 sha256sum/toybox만 사용하며 지원하지 않으면 Unknown; PC pull fallback 파일을 생성하지 않는다.
schema/id/identity/선택 경로/expected SHA/history/timestamp와 실제 ROM/XML 및 staging residue를 비교한다.
결과: NO_COMMIT_CONFIRMED / PARTIAL_COMMIT / STATE_MISMATCH / UNKNOWN.
확인되지 않은 hash, 누락 evidence, residue, 비terminal journal은 abandon 가능 판정하지 않는다.
새 journal에는 Android canonical before hash 및 systemSnapshots의 양쪽 XML before hash가 기록된다.
구 journal은 명시적으로 제공한 legacy GB baseline으로만 보충한다.
baseline을 새로 쓰거나 원본 journal 내용을 고치지 않는다.

실제 transaction e7415928fd2e4f648ccf602ffce743f3은 current-before.json을 근거로 읽기 전용 검사:
NO_COMMIT_CONFIRMED. 원본 journal SHA 동일. 실제 resolution 생성 없음.
ADB daemon 초기화 stderr가 첫 조회에 포함되면 Unknown으로 보수적으로 처리한다.
호출자는 먼저 대상 serial get-state를 확인한 후 관찰하며 error를 임의 제거하지 않는다.

## Explicit abandon resolution

New-AdoptionAbandonResolution은 Reason 및 Approved 명시가 없으면 차단한다.
실행 직전 inspector가 failed journal을 NO_COMMIT_CONFIRMED로 판정해야 한다.
원본 journal은 삭제/수정/completed 변경하지 않는다.
State/adoption-resolutions/<source-device identity>/<transaction>.json만 신규 atomic/no-overwrite 생성한다.
schema/id/identity/approval time/approver SID/reason/inspectorResult/journal SHA/evidence SHA 및 관찰값을 기록한다.
전체 XML/ROM bytes/security descriptor를 기록하지 않는다.
gate는 기존 journal hash/history와 resolution의 ROM/XML baseline/관찰/잔여물 증거를 검증한다.
위조·손상·다른 id·불완전 evidence는 차단한다.
resolution은 같은 사용자 State 신뢰 경계의 감사 기록이며 암호학적 서명/악성 관리자 방어는 아니다.
기존 journal 완료 또는 유효 explicit resolution만 해당 journal의 unresolved gate를 해제한다.
자동 abandon/rollback/resume 없음. 실제 abandon UI는 구현하지 않는다.

향후 UX:
Dropbox 관리 라이브러리가 읽기 전용입니다. 새 ROM을 추가할 수 없습니다.
차단: 신규 ROM/공유 XML 쓰기. 기존 관리 ROM 읽기/Android 동기화는 가능할 수 있습니다.
이전 adoption이 완료되지 않았습니다. 상태 검토와 명시적 승인이 필요합니다.

## 재시험 전 사용자 결정

실제 Dropbox 쓰기 capability를 갖는 정상 환경을 사용할지 결정해야 한다. 앱은 ACL을 고치지 않는다.
기존 failed journal의 inspector 증거를 확인하고 별도 explicit abandon 승인을 해야 한다.
이번 Stage에서는 실제 abandon/재시험을 하지 않는다.
그 뒤 inbox SHA/전체 baseline/foreground SAFE와 회귀 검증을 재확인한다.