# ServiceWatch 사용자 정의 지표 스크립트

Node Exporter / Windows Exporter의 textfile collector로 노출 → ServiceWatch Agent가 수집·전송.
원본 정리 노트: vault `DailyNote/20261109.md`

| 파일 | 내용 | 실행 |
|---|---|---|
| `linux/sw_custom_metrics.sh` | 회사 원본 (오타만 수정): uptime·memory·filesystem usage·NFS 마운트 상태 | 기존 운영 방식 |
| `linux/sw_fs_hang_check.sh` | 로컬 FS(xfs/ext4) hang 체크 — Cloud Monitoring "Filesystem Hang Check"와 같은 값 (**1 정상 / 0 비정상**). 결과는 `/run`(tmpfs)에 쓰고 textfile 디렉터리엔 심볼릭 링크 → 디스크가 멈춰도 갱신. write/read 모드. 설계·검증 내용은 파일 상단 주석 | cron 1분, root |
| `windows/sw_custom_metrics_win.ps1` | **3개 항목 전용**: FS hang check(1 정상 / 0 비정상, 로컬 디스크) · memory usage · FS usage | 작업 스케줄러 1분, SYSTEM |
| `windows/sw_custom_metrics.ps1` | 첫 버전 (memory · FS usage · 네트워크 마운트) — `_win.ps1`로 대체, 같은 출력 파일이므로 하나만 등록 | — |
| `windows/register_task.ps1` | 작업 스케줄러 등록 (사용할 스크립트 경로로 수정) | 관리자 PowerShell 1회 |

- Linux 스크립트의 `OUT` / `OUT_DIR`은 비어 있음 → node_exporter textfile 디렉터리로 지정
- Windows 스크립트는 실서버 미검증
- `custom_fs_hang_status`는 값 의미가 이전 버전(0 정상)과 반대 → 알람 조건은 "값 < 1"
