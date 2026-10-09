# v1.5.0 Stage 3.2 실환경 검증

결과: **PASS**. 제품 코드는 Stage 3 checkpoint
1b2df0deb62fffdd433f2dd18fcd915579d9858f 그대로 사용했다.

- 기기: Retroid Pocket Mini V2 / ADB serial 7b67d4e2.
- 선택 system: gb. 변조 없는 기존 ROM의 격리 사본 1개만 사용했다.
- source: ROMs/gb/ESDE_SYNC_UNMANAGED_CAT_TEST.gb.
- destination: ROMs/gb/_UNREGISTERED/ESDE_SYNC_UNMANAGED_CAT_TEST.gb.
- 실제 Android source/destination SHA-256 모두
  a8a5e1266f3603153eb97a9762f2d907a773efcaadc985c3744f2a43ff6aee65.
- source는 없어지고 destination은 존재한다.
- UNMANAGED 판정 → production Android 내부 이동 → LOCAL_ONLY / Preserve 확인.
- classification State는 completed. 후속 managed mirror의 시험 대상 move/delete/push 없음.
- 기존 game node가 없는 사례: synthetic node 생성 없음.
- 기존 gamelist 40개 node metadata/runtime 의미 변화 없음.
- system-level alternativeEmulator subtree 보존.
- Managed / _TEST / 기존 _UNREGISTERED 및 비선택 GBC 보호.
- media/save/state 변화 없음, Dropbox write 0, unexpected mutation 0.
- ES-DE 재실행 성공. 사용자 wake/unlock 후 production foreground SAFE를
  읽기 전용으로 최종 확인했다.
- 직전 수면 상태 PARTIAL은 이동 재실행 없이 최종 SAFE 확인으로 PASS가 됐다.

전체 백업과 전후 path/size/SHA를 사용했다. 시험 ROM과 증거는 보존했으며
제품은 historical TEMP report 경로에 의존하지 않는다.

이 검증은 단일 UNMANAGED happy-path에 한정한다.
Conflict/PathMismatch/Ambiguous 실환경 mutation, save/state canonicalization,
fault injection 및 다른 vendor/DPI 검증을 통과했다는 의미는 아니다.