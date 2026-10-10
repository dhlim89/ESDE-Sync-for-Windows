# v1.5.0 Stage 1 명세 및 구현 경계

기준: stable v1.4.9 / 8f47ce19d482a8258f6f00b1a18039ef0da3187b.
dev 작업이며 main/tag/Release 및 실제 설치본을 변경하지 않는다.
실제 adoption, Dropbox 쓰기, Android ROM 이동/삭제는 Stage 1에 존재하지 않는다.

## 1. 현재 v1.4.9 구조
ROM/media/gamelist bucket은 각각 ROMs, ES-DE/downloaded_media, ES-DE/gamelists로 향한다.
ROM은 Mirror-SystemFolder strict mirror다. Is-ExcludedRelativePath, Get-ManagedLocalItems,
Get-RemoteEntries의 find prune 및 Assert-RemotePath/삭제 검사가 _TEST/_UNREGISTERED 구성요소를 제외한다.
원본 부재 삭제도 Remove-ManagedRemoteContents에서 예약 영역을 제외한다.
ROM 채택용 Android→PC pull은 없다. 기존 pull은 gamelist와 media read-back/backup/hash용이다.
gamelist는 Dropbox BASE의 일반 whole-node + Android local-only whole-node 병합이다.
일반 Android playcount/lastplayed/playtime 및 game-level altemulator의 별도 처리가 없었다.
top-level alternativeEmulator와 game-level altemulator는 다른 노드다.

## 2. 관찰된 실제 자료
선택 원본은 roms/gb와 roms/gbc. Android serial 7b67d4e2 / ES-DE 3.5.0-65(r52).
GB 40개, GBC 57개를 normalized path로 비교했다. XML은 두 top-level sibling 구조를 사용한다.
GB 및 GBC 각각 2개 게임에서 플레이 기록 3개 태그가 다르며 다른 관찰 metadata는 동일하다.
GB 피카츄: playcount 37→39, playtime 34432→34755, lastplayed 20261005T182332→20261006T225514.
GBC 데굴데굴 커비: playcount 51→59, playtime 8218→8847, lastplayed 20260616T230748→20261006T230122.
Big 2 Small.gb: 양쪽 21 / 3286 / 20261005T182044.
GBC 커비의 game-level altemulator는 양쪽 My OldBoy! (Standalone) 1개.
양쪽 top-level alternativeEmulator/label은 SameBoy이며 변환하지 않는다.
favorite/kidgame/hidden/broken은 이 샘플에서 없다. GBC에는 sortname, hidemetadata가 있다.
전체 값/존재 여부/분류 표와 SHA는 ignored reports/v150-stage1-*에 보존한다.
Android 설정은 ParseGamelistOnly=false, SaveGamelistsMode=always다. ROM 존재 여부를 XML에 의존하지 않는다.
실제 Legion Go S 설정 파일에 직접 접근한 것은 아니다. Dropbox XML과 설치 APK의 동버전
Linux/Android system definition 및 공식 source를 대조했으며 이 근거를 혼동하지 않는다.

## 3. 일반 gamelist tag-level 정책
Dropbox 일반 library metadata가 authoritative.
동일 normalized managed path에 Android playcount/lastplayed/playtime가 존재하면 각 태그 전체를 보존.
0/빈 값도 존재하는 값이다. 없으면 Dropbox 값을 유지. 없는 game을 합성하지 않는다.
중복 managed path/runtime tag는 모호하므로 차단한다.
_TEST 및 미채택 _UNREGISTERED는 기존 Android whole-node 보존 그대로.
favorite/hidden/kidgame/broken/completed/hidemetadata/nomultiscrape/nogamecount/controller/screen/
collectionsortname 등 사용자 preference 또는 기기 관련 후보는 별도 정책 미확정.
Stage 1은 이 태그들을 임의로 Android 우선으로 변경하지 않는다. 현행 managed BASE 규칙만 유지.
태그 의미 근거: https://gitlab.com/es-de/emulationstation-de/-/raw/master/es-app/src/MetaData.cpp

## 4. game-level altemulator 변환
순수 함수는 입력 bytes/DOM을 변경하지 않는 Android staging 사본을 만든다.
arcade flag는 검증된 system definition/정책으로 caller가 명시해야 한다. 모르면 분류하지 말고 차단.
설치 APK에서 platform=arcade인 시스템에는 arcade, atomiswave, consolearcade, cps/cps1/cps2/cps3,
fba, fbneo, mame, mame-advmame, model2/model3, naomi/naomi2/naomigd, pcarcade, stv, triforce, type-x가 있다.
neogeo는 별도 platform=neogeo여서 arcade family 포함 여부를 사용자 정책으로 확정해야 한다.
- arcade: altemulator 그대로 유지.
- non-arcade 비Standalone: Android staging에서 제거.
- non-arcade Standalone: 확인 mapping만 적용. 미확정은 warning + 전체 staging 실패.
- 이미 mapping의 Android label이면 그대로 유지해 재실행에도 안전.
- 기존 local-only whole-node 및 top-level alternativeEmulator는 변환하지 않는다.

확정 mapping (사용자 전환 의도 + 설치 APK의 label 존재 + 공식 Linux label):
| system | Linux | Android |
|---|---|---|
| gb | SameBoy (Standalone) | My OldBoy! (Standalone) |
| gbc | Sameboy (Standalone) | My OldBoy! (Standalone) |

입력 label 비교는 대소문자 무시, 출력은 확인한 정확한 표기. 다른 mapping은 없다.
Linux label은 실제 Android APK의 assets/systems/linux에도 존재하지만 Legion 실제 설정 증거는 아니다.
https://gitlab.com/es-de/emulationstation-de/-/raw/master/resources/systems/linux/es_systems.xml
https://gitlab.com/es-de/emulationstation-de/-/raw/master/resources/systems/android/es_systems.xml
Stage 1 변환 함수는 worker I/O 경로에 아직 연결하지 않는다.

## 5. adoption 발견과 목적지
선택 시스템의 루트 _UNREGISTERED inbox만 열거한다. _TEST는 탐색/채택하지 않는다.
inbox 안의 _TEST/중첩 _UNREGISTERED도 제외한다. 일반 mirror의 예약 보호를 바꾸지 않는다.
대상은 실제 ES-DE system extension으로 확인한 ROM 파일만이다.
systeminfo.txt/gamelist.xml/save/설정 파일은 ROM으로 채택하지 않는다.
초기 Stage 2는 실제 확인된 GB/GBC 단일 ROM/불투명 압축 ROM부터 적용한다.
cue/m3u 등 복합 파일은 참조 파일 묶음 검증 없이 자동 채택하지 않는다.
_UNREGISTERED/sub/A.gb → source roms/<system>/sub/A.gb 및 Android 정식 sub/A.gb.
하위 구조 유지. traversal/absolute/control/Windows 예약 이름/예약 구성요소/선택 밖/대소문자 충돌 차단.
새 목적지: 검증 후 InstallNew. 동일 SHA: ReuseIdentical. 다른 SHA: 전체 adoption 차단.
Android hash와 pull한 PC staged SHA를 비교한다. unknown hash는 삭제 근거가 아니다.
Stage 1 plan은 hash snapshot만 받는 순수 함수며 source 삭제 flag는 항상 false다.
동일 SHA라는 사실만으로 cleanup하지 않는다.

## 6. Dropbox gamelist와 Android 승격
ROM 파일 채택만으로 ES-DE가 공유 XML 엔트리를 생성한다고 가정하지 않는다.
Dropbox gamelist를 갱신하는 단계가 adoption transaction에 반드시 포함된다.
- 기존 Dropbox 정식 entry 있음: 일반 metadata/플랫폼 선택은 BASE 유지, Android runtime 3개만
  Android 승격 노드에 적용한다. Dropbox 기존 runtime를 Android 값으로 덮어쓰지 않는다.
- 기존 BASE entry 없음 + Android inbox entry 있음: path를 정식 경로로 바꾼 공유 노드 proposal을 만든다.
  공용/unknown metadata는 whole-node 보존하지만 기기 runtime 3개는 새 공유 node에서 제외한다.
  Android 승격 node는 runtime를 포함한 원본 metadata를 보존한다.
  preference/platform/media 필드가 포함되면 NeedsPolicyDecision=true로 source commit/cleanup을 차단한다.
  이 단계에서 Android altemulator/절대 media 경로를 Linux 원본에 무조건 복사하지 않는다.
  해당 공유 정책 확정 후에만 commit하며 임의로 태그를 삭제해 통과시키지 않는다.
- 양쪽 entry 없음: ROM만 채택한다. 가상의 game을 만들지 않는다. 다른 기기는 ROM 스캔으로 발견 가능.
- Android 정식 path와 inbox path 둘 다 있음: runtime 모순은 충돌 차단, 합산/최댓값 추정 금지.
  모든 game key를 정규화하고 결과에는 정식 entry를 하나만 남긴다.
- source gameList가 없으면 실제 inbox metadata가 있는 경우에만 parser로 gameList를 구성한다.
  기존 declaration/top-level sibling/order/alternativeEmulator는 보존한다.

New-AdoptionGamePromotion은 위 정책의 순수 proposal만 구현한다.
ROM 성공 증거 없이 proposal을 실제 쓰면 안 된다.
unknown field 내 플랫폼 경로 가능성 및 사용자 preference 공유 정책은 Stage 2 입력 validation 항목.

## 7. transaction/journal 경계
State/adoption-transactions/<source-device identity>/<sessionId>/journal.json.
schemaVersion, sessionId, sourceRoot normalized identity, ADB serial, selectedSystems,
state, startedAt/updatedAt, originalError, cleanupError, snapshot/backup/staging 경로를 기록한다.
per-item: inbox path, managed path, size/hash, source/Android 기존 target snapshot,
reused/created 여부, Dropbox/Android gamelist before/after SHA, committed step 증거.
source cloud의 다른 PC 변경은 Windows mutex만으로 막을 수 없으므로 CAS(hash/경로 재확인)가 필수다.
JSON temp→reparse→flush→replace로 저장. 미완료/손상 journal은 전체 sync mutation 전에 차단.
자동 crash recovery는 넣지 않는다. 완료도 identity/파일 hash를 재검증하고 새 adoption을 반복하지 않는다.

상태:
discovered → staged → source-verified → dropbox-installed → gamelist-prepared
→ dropbox-gamelist-installed → android-rom-installed → android-gamelist-installed
→ android-source-removed → completed.

android-rom-installed는 정상 경로 ROM SHA가 inbox 원본과 같음을 검증하는 추가 필수 단계다.
PC Dropbox ROM만 존재하거나 XML path만 바뀐 상태에서 inbox를 지우면 안 된다.
일반 ROM mirror가 해당 정상 경로에 배포한 경우도 동일한 SHA 완료 증거를 사용한다.
Android 삭제 gate는 양쪽 ROM/양쪽 XML 검증, source unchanged, policy gate 해소를 요구한다.
삭제 직전 현재 inbox hash/size/path/identity를 재확인하고 해당 단일 파일만 삭제한다.
삭제 실패 시 공유 파일은 남기고 journal은 failed로 차단한다. 재실행 자동 삭제 금지.

준비/실패 원칙:
- ES-DE stop 이후 inbox/Android XML 확보. 전체 source/selected plans 검증 후 mutation.
- PC staging은 Dropbox 밖. 목적지 volume의 temporary 검증본을 FileMode.CreateNew로 만들고
  덮어쓰기 없는 move로 ROM 설치. cross-volume move의 atomic성을 가정하지 않는다.
- 동일 volume temporary가 source 트리 안에 필요하면 journal에 이름을 기록하고,
  pending/출처 불명 temporary는 source mirror 전에 차단하여 Android에 유출되지 않게 한다.
- Dropbox XML snapshot→parser→staging→CAS→atomic replace→read-back 검증.
- Android 정상 ROM SHA 검증→gamelist temp push/pull/SHA/CAS/mv→최종 read-back.
- Android inbox 원본 삭제는 마지막. 아직 이동/복사/삭제하는 production adoption 함수는 없다.
- 실패 때 inbox/PC staged ROM/기존 XML 백업을 보존한다.
  이미 공유한 새 Dropbox ROM을 자동으로 지우지 않는다. 다른 기기가 사용했을 수 있다.
  기존 media reverse rollback을 ROM/Dropbox adoption으로 확대하지 않는다.
- adoption 변경 후 기존 jobs.GamelistSource cache는 승인된 새 snapshot으로 갱신하고
  전체 XML/media 계획을 재검증한다. 낡은 BASE로 새 공유 node를 지우지 않는다.
- operation mutex는 유지. 미완료 adoption이 있으면 이후 ROM strict mirror도 시작하지 않는다.

Stage 1 pure removal gate의 DropboxRomVerified/AndroidGamelistVerified는 위 상세 검증 완료 증거를
caller가 모아서 넘기는 입력이다. AndroidManagedRomVerified와 PolicyResolved도 별도 필수이며 기본값 false로 차단한다.

## 8. GUI 잘림과 수정
기존 form 외곽 Size=760x640, AutoScaleMode 명시 없음.
Segoe UI 10의 실제 Label PreferredSize 높이=76, info y=220 → bottom=296.
updateLabel y=282이므로 14px 겹침. 버튼 y=278이며 warning y=315였다.
새 Get-EsdeGuiLayout을 좌표의 단일 원본으로 하고 Set-EsdeGuiLayout에서 적용한다.
client 740x670, AutoScaleDimensions=96x96, AutoScaleMode=Dpi, MinimumSize 설정.
info=(30,220,690,84) bottom=304; update y=316 (12px 여유).
warn y=358 height40; sync y=410; progress y=468; status y=500; log y=538 height110, bottom648.
client 하단 22px 여백. 기존 GUI 기능/이벤트/버튼 승인/동기화 로직 변경 없음.
100%/125% 좌표 모델 + GDI 실제 텍스트 측정 + 숨겨진 Forms Scale 검증.
실제 모니터 DPI 이동/OS 배율 변경 또는 실사용 GUI 시각 재시험은 별도 단계.

## 9. 테스트와 남은 Stage 2
새 tests:
- gamelist-local-metadata-static: 3개 runtime, BASE 갱신, 누락/0/빈 값, reserved whole-node, 중복 차단, input 불변.
- altemulator-conversion-static: arcade/known/nonStandalone/unknown/idempotency/source 불변/sibling/reserved 보호.
- unregistered-adoption-static: 신규/동일/충돌/hash/path/scope/중간 상태/delete gate/양쪽 metadata proposal/중복 runtime.
- gui-layout-static: client bounds/overlap/minimum height/100·125% GDI/Forms Scale.
adoption의 pull/install/XML/delete 실패 테스트는 순수 계획 입력·완료 gate까지만 검증한다.
실제 I/O 실패 주입·journal atomic save·source CAS·rollback/재실행 executor 테스트는 Stage 2에서 추가한다.

Stage 2 구현 순서:
1) journal load/identity/pending gate 및 시스템 ROM extension catalog 검증.
2) read-only inbox discovery/hash/pull/staging 및 전체 conflict plan.
3) 공유 XML proposal/policy gate/CAS와 Android 정상 ROM/metadata 배포.
4) 모든 hash 완료 증거 후 단일 inbox 원본 cleanup.
5) executor mock failure/restart/idempotency 테스트. 실기기 쓰기는 별도 승인 후.
6) altemulator system catalog(arcade family 포함) 확인 후 staging 변환 연결.
미확정 preference, neogeo family 분류, 다른 emulator mapping은 기본값으로 추측하지 않고 차단/정책 확인한다.

## 10. 버전과 배포
version.json=1.5.0, releaseTag=v1.5.0, channel=stable, updater/minimum=1.0.0.
stable 값은 기존 validator가 이해하는 package 계약이며 dev tree의 공개를 의미하지 않는다.
정식 tag/Release를 생성하지 않는다. README는 Development로 표시한다.
새 App runtime 파일 없음. App 8개 계약 및 v1.4.8 actual validator 테스트 유지.