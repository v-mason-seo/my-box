# ServiceWatch 사용자 정의 지표 스크립트

Node Exporter / Windows Exporter의 textfile collector로 노출 → ServiceWatch Agent가 수집·전송.
원본 정리 노트: vault `DailyNote/20261109.md`

| 파일 | 내용 | 실행 |
|---|---|---|
| `linux/sw_custom_metrics.sh` | 회사 원본 (오타만 수정): uptime·memory·filesystem usage·NFS 마운트 상태 | 기존 운영 방식 |
| `linux/sw_fs_hang_check.sh` | 로컬 FS hang 체크 (0 정상 / 1 hang / 2 쓰기 실패), 출력 `sw_fs_hang.prom` | cron 1분 |
| `windows/sw_custom_metrics_win.ps1` | **3개 항목 전용**: FS hang check · memory usage · FS usage | 작업 스케줄러 1분, SYSTEM |
| `windows/sw_custom_metrics.ps1` | 첫 버전 (memory · FS usage · 네트워크 마운트) — `_win.ps1`로 대체, 같은 출력 파일이므로 하나만 등록 | — |
| `windows/register_task.ps1` | 작업 스케줄러 등록 (사용할 스크립트 경로로 수정) | 관리자 PowerShell 1회 |

- Linux 스크립트의 `OUT` / `OUT_DIR`은 비어 있음 → node_exporter textfile 디렉터리로 지정
- Windows 스크립트는 실서버 미검증
