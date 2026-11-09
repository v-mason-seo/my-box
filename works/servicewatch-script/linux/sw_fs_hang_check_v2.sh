#!/bin/bash
# =============================================================================
# sw_fs_hang_check_v2.sh — 로컬 파일시스템 hang 체크 (ServiceWatch 사용자 정의 지표)
#
#   버전      : v2.0 (2026-11-09)
#   이전 버전 : sw_fs_hang_check.sh (v1, 커밋 77ff71e) — 원본은 그대로 두고 이 파일을 새로 만듦
#   지표/값   : v1과 같음 → custom_fs_hang_status (1 정상 / 0 비정상). 알람 설정은 바꿀 필요 없음
# =============================================================================
#
# [v1 → v2 에서 바뀐 것]  (모두 Rocky 9.7 loop 장치로 v1 재현 → v2 해결 확인)
#
#   ① [보안·필수] 심볼릭 링크를 따라가 다른 파일을 0으로 덮어쓰던 문제
#      v1: dd가 "마운트 최상위/.sw_hangcheck"를 그냥 열었다. 일반 계정이 쓸 수 있는
#          디렉터리(예: 777인 /data, 앱 계정 소유 마운트)에 누군가
#            ln -s /etc/shadow /data/.sw_hangcheck
#          를 만들어 두면, root로 도는 dd가 링크를 따라가 /etc/shadow를 4KB 0으로 덮어쓴다.
#          (실측: root 소유 테스트 파일이 4KB 0으로 바뀜)
#      v2: 먼저 rm -f로 같은 이름을 지운 뒤, dd를 conv=excl(=O_CREAT|O_EXCL)로 연다.
#          O_EXCL은 "새 파일을 만들 때만 성공"하므로 링크·FIFO·하드링크를 절대 따라가지 않는다.
#          (rm과 dd 사이에 누가 다시 심어도 dd가 실패할 뿐 → 값 0, 다른 파일은 안전)
#
#   ② [Kubernetes·필수] Pod의 PVC(영구 볼륨) 안에 파일을 만들던 문제
#      v1: "root가 / 인 마운트만 = bind mount 제외" 규칙으로 컨테이너 볼륨을 걸렀지만,
#          Kubernetes PVC는 디스크 전체를 bind하므로 root가 "/"로 나와 걸러지지 않았다.
#            /var/lib/kubelet/plugins/.../globalmount              ← CSI가 디스크를 붙인 곳
#            /var/lib/kubelet/pods/<pod-uid>/volumes/.../mount     ← 같은 디스크를 Pod에 bind
#          → Pod이 보는 데이터 디렉터리 최상위에 .sw_hangcheck가 매분 생겼다 지워짐.
#            (예: DB가 "빈 디렉터리여야 초기화" 하는 경우 초기화 실패 가능, Pod 종료 시 umount 방해 가능)
#          → 지표 레이블도 pod UID가 들어간 긴 경로가 되어 Pod이 옮겨갈 때마다 새 지표가 생김.
#      v2: EXCLUDED_MOUNTPOINTS 기본값에 "^/var/lib/kubelet/" 를 추가.
#          (노드 자체 디스크 /, /var 등은 그대로 확인. kubelet 내부 마운트만 제외)
#
#   ③ [Kubernetes·컨테이너] 컨테이너 안에서 실행하면 엉뚱한 곳을 확인하던 문제
#      컨테이너 안에서 /proc/self/mountinfo를 읽으면 호스트가 아니라 컨테이너가 보는 마운트가 나온다.
#      (예: 호스트 / 를 /host로 마운트했다면 mountpoint="/host"로 확인·보고, 컨테이너 볼륨에 파일 생성)
#      v2: 실행 위치의 "/"가 overlay 등 컨테이너 파일시스템이면 경고를 남기고 종료한다.
#          → 노드(호스트)에서 cron으로 돌리거나, 컨테이너라면 nsenter로 호스트 네임스페이스에서 실행.
#
#   ④ [Kubernetes] node_exporter가 Pod(DaemonSet)일 때 심볼릭 링크가 깨지던 문제
#      v1: textfile 디렉터리에 /run/sw_fs_hang/sw_fs_hang.prom 을 가리키는 링크를 둔다.
#          node_exporter가 컨테이너면 컨테이너 안에는 /run/sw_fs_hang이 없어서 링크가 깨진다.
#      v2: TEXTFILE_DIR을 STATE_DIR(/run/sw_fs_hang)과 같게 지정하면 링크 없이 그 자리에 직접 쓴다.
#          → DaemonSet에서 hostPath /run/sw_fs_hang 을 textfile 디렉터리로 마운트하면 된다.
#          (그 디렉터리의 lock/pid/rc 파일은 이름이 .prom이 아니라서 node_exporter가 읽지 않음)
#
#   ⑤ [안정성] 스크립트 자체가 멈추면 "정상(1)"이 계속 남던 문제
#      디스크가 멈춘 상태에서 스크립트가 쓰는 명령(awk 등) 실행이 캐시에 없으면 스크립트 자체가 멈출 수 있다.
#      v1: 다음 실행들이 lock에 막혀 조용히 종료 → 결과 파일이 안 바뀌어 node_exporter는 옛 값을 계속 보냄.
#      v2: lock을 LOCK_WAIT_SEC(10초)까지 기다려도 못 잡으면 = 이전 실행이 비정상적으로 오래 멈춤
#          → 마지막 결과 파일의 값을 전부 0(비정상)으로 바꿔 둔다.
#          (정상 실행은 최대 WAIT_SEC=5초 안에 끝나므로, 사람이 수동 실행과 cron이 겹쳐도 오탐 없음)
#
#   ⑥ [버그] 제외 대상이 같은 장치의 다른 마운트까지 지워버리던 문제
#      v1: "같은 장치는 1번만" 을 awk에서 먼저 하고, 제외(EXCLUDED/INCLUDED)를 나중에 했다.
#          같은 장치가 /boot(제외)와 /mnt/x 에 둘 다 마운트돼 있으면 /boot만 남았다가 제외되어
#          그 장치는 아예 확인되지 않았다.
#      v2: 제외를 먼저 하고, 남은 것 중에서 장치 중복을 거른다.
#
#   ⑦ [버그] 같은 경로에 겹쳐 마운트(over-mount)하면 같은 레이블이 2줄 나오던 문제
#      v2: 같은 마운트포인트가 여러 번 나오면 마지막(= 실제로 보이는 위쪽) 것만 확인한다.
#
#   ⑧ [작은 개선]
#      - read 모드: 장치 경로를 /dev/block/<주:부번호> 로 우선 사용
#        (mountinfo에 /dev/root 처럼 실제로 없는 이름이 나오는 시스템 대응)
#      - 설정 오류(TEXTFILE_DIR 비어 있음, root 아님 등)는 이유를 stderr로 출력하고 종료
#        (cron 메일 / journalctl -u crond 에서 확인 가능. v1은 조용히 종료)
#      - umask 022 고정: root의 umask가 077인 보안 강화 서버에서 /run/sw_fs_hang이 700으로 만들어져
#        node_exporter(일반 계정)가 결과를 못 읽던 경우 방지
#      - cd / : probe가 실행 위치(cwd)를 붙잡아 다른 마운트의 umount를 방해하지 않게
#      - EXCLUDED_MOUNTPOINTS를 비워도 동작 (v1은 비우면 정규식 ""가 모든 경로에 맞아 전부 제외됨)
#      - 마운트 경로에 큰따옴표(")가 있으면 제외 (레이블이 깨져 .prom 파일 전체가 무효가 되는 것 방지)
#
# -----------------------------------------------------------------------------
# [무엇을 하나]
#   Cloud Monitoring Agent의 "Filesystem Hang Check" 지표를 ServiceWatch용으로 재현한다.
#     Cloud Monitoring 정의: FileSystem | Filesystem Hang Check | state | 1m |
#                            filesystem(local/NFS) hang 체크 (정상:1, 비정상:0)
#   값의 정의(1/0)는 같게 맞추고, 대상은 로컬 파일시스템(xfs/ext4)만 확인한다.
#   (NFS는 대상에서 제외 — 마운트 상태는 sw_custom_metrics.sh의 custom_nfs_mount_up으로 본다)
#
#   마운트된 xfs/ext4 로컬 파일시스템마다 "캐시를 거치지 않는 디스크 I/O"를 한 번 보내고,
#   WAIT_SEC 안에 성공으로 끝나는지 확인한다. 결과는 node_exporter textfile collector 형식:
#
#     custom_fs_hang_status{mountpoint="/data",fstype="xfs"} 1
#
#     1 = 정상   : WAIT_SEC 안에 요청이 성공으로 끝남
#     0 = 비정상 : 아래 중 하나
#                  - WAIT_SEC 안에 끝나지 않음 (hang)
#                  - 이전 실행에서 띄운 확인이 아직도 멈춰 있음 (hang 지속)
#                  - I/O가 에러로 끝남 (read-only 전환, 공간 부족, 권한 등)
#                  - 이 스크립트 자체가 이전 실행에서 멈춰 있음 (v2 추가, 위 ⑤)
#
#   → 알람 조건: "값 < 1" (= 0) 을 N회 연속 위반 시  (일시 오탐 완화, 아래 [운영 시 알아둘 점])
#
# [왜 ls/stat/df가 아니라 실제 I/O인가]
#   로컬 파일시스템의 ls/stat/df(statfs)는 커널 메모리 캐시에서 응답하므로 디스크 I/O가
#   멈춰도 정상 응답한다. node_exporter의 node_filesystem_device_error도 0으로 남는다.
#   (테스트: dmsetup suspend로 I/O를 멈춘 상태에서 모두 정상 응답 확인)
#     - df(statfs) : 여유 블록 수를 메모리 카운터에서 바로 계산 → 디스크를 아예 안 읽음
#     - stat / ls  : inode·dentry 캐시에 있으면 디스크를 안 읽음. 만료 시간 없이
#                    메모리 압박으로 밀려날 때까지 유지 (자주 보는 경로는 사실상 계속 캐시)
#     - 일반 write : 페이지 캐시에 쓰고 바로 성공 반환. 디스크 기록은 나중에 flusher가 함
#   → 4KB 동기 쓰기(write 모드) 또는 장치 직접 읽기(read 모드)로 디스크까지 닿게 한다.
#
# [운영 시스템에 영향을 주지 않기 위한 설계]
#   1) 확인(probe)은 백그라운드로 띄우고 기다리지 않는다.
#      I/O에서 멈춘 프로세스(D 상태)는 kill -9로도 죽지 않으므로,
#      timeout으로 감싸면 스크립트 전체가 같이 멈춘다.
#   2) 멈춘 probe는 장치당 1개까지만 존재한다.
#      이전 probe가 아직 살아 있으면 새로 띄우지 않고 바로 0(비정상)으로 판정한다.
#      → hang이 몇 시간 이어져도 멈춘 프로세스가 매분 쌓이지 않는다.
#   3) 결과 파일은 tmpfs(/run)에 쓰고, textfile 디렉터리에는 심볼릭 링크만 둔다.
#      textfile 디렉터리가 있는 디스크(보통 /)가 멈춰도 결과를 계속 갱신할 수 있다.
#      (결과를 디스크에 직접 쓰면 스크립트가 멈추고, node_exporter는
#       마지막 값(정상)을 계속 보내 장애를 놓친다 — v1 이전 버전에서 실측)
#   4) flock으로 중복 실행을 막는다. 단, probe에는 lock fd를 넘기지 않는다.
#      (멈춘 probe가 lock을 쥐고 있으면 이후 실행이 전부 막혀 결과가 갱신되지 않음)
#   5) bind mount, Kubernetes kubelet 내부 마운트(PVC 등)는 제외하고, 같은 장치는 한 번만 확인한다.
#      → 앱/컨테이너/Pod 디렉터리에 파일을 쓰지 않음
#   6) 모든 probe를 동시에 띄우므로 마운트가 많아도 전체 대기는 최대 WAIT_SEC.
#   7) write 모드 파일은 O_EXCL로만 만든다 → 링크를 따라가 다른 파일을 건드리지 않음 (위 ①)
#
# [어디서 실행하나 — 일반 VM / Kubernetes 노드]
#   일반 VM          : root cron 1분. 그대로 사용.
#   Kubernetes 노드  : "노드(호스트)"에서 root cron 1분으로 실행한다. Pod 안에서 직접 실행하지 않는다.
#                      - 노드 OS가 확인 대상(/, /var 등). Pod의 PVC는 제외됨 (위 ②)
#                      - 노드가 오토스케일/업그레이드로 새로 만들어지면 cron이 사라진다
#                        → 노드 초기화 스크립트(user data)나 노드 이미지에 설치를 넣어 둘 것
#                      - 꼭 DaemonSet으로 돌려야 하면 privileged + hostPID 로 띄우고
#                          nsenter -t 1 -m -- /usr/local/bin/sw_fs_hang_check_v2.sh
#                        처럼 호스트 마운트 네임스페이스에서 실행 (위 ③의 검사를 통과함)
#   node_exporter 위치에 따라 TEXTFILE_DIR 지정 (위 ④)
#      - 호스트에 설치(ServiceWatch Agent 기본 방식)
#            TEXTFILE_DIR = node_exporter --collector.textfile.directory 값  (링크 방식)
#      - Pod(DaemonSet)으로 실행
#            TEXTFILE_DIR=/run/sw_fs_hang  (= STATE_DIR, 링크 없이 직접 씀)
#            DaemonSet에 hostPath /run/sw_fs_hang 을 마운트하고
#            --collector.textfile.directory 를 그 마운트 경로로 지정
#
# [운영 시 알아둘 점]
#   - root로 실행해야 한다 (마운트 최상위 쓰기 / 장치 직접 읽기).
#   - write 모드는 매분 "마운트 최상위/.sw_hangcheck"(4KB)를 만들었다 바로 지운다.
#     디렉터리 감시 앱이나 보안 에이전트(FIM/EDR)가 감지할 수 있다.
#     문제가 되면 PROBE_MODE="read" 또는 INCLUDED_MOUNTPOINTS로 대상을 좁힌다.
#   - write 모드의 동기 쓰기(dsync)는 저널 커밋을 1회 유발한다 (fsync 1회 수준).
#   - write 모드는 fsfreeze(백업 스냅샷) 중 0이 나올 수 있다 → 알람은 "N회 연속 위반"으로.
#   - write 모드는 일부러 read-only로 마운트한 파일시스템을 항상 0으로 본다
#     (장애로 read-only가 된 것과 구분할 수 없음) → 그런 마운트는 EXCLUDED_MOUNTPOINTS에 추가.
#   - 마운트 최상위에 같은 이름(.sw_hangcheck)의 "디렉터리"가 있으면 지울 수 없어 0이 된다.
#   - Kubernetes "Local PV"처럼 디스크 최상위를 그대로 Pod에 주는 노드 디스크
#     (예: /mnt/disks/ssd1)는 kubelet 경로가 아니라 제외되지 않는다.
#     Pod에 파일이 보이면 안 되면 EXCLUDED_MOUNTPOINTS에 추가하거나 read 모드 사용.
#   - NFS 등 네트워크 파일시스템은 확인하지 않는다 (ALLOWED_FSTYPES에 넣지 말 것 —
#     NFS는 장치 경로가 없어 read 모드가 동작하지 않고, write 모드는 공유 스토리지에 파일을 만든다)
#   - 재부팅 직후 첫 실행 전에는 /run이 비어 있어 node_textfile_scrape_error=1이 된다
#     (최대 1분). 같은 디렉터리의 다른 .prom 파일은 영향 없음 (v1에서 확인).
#   - 디스크가 완전히 멈추고 명령 실행 파일까지 캐시에서 밀려나면 cron도 스크립트를 못 띄운다.
#     이 경우는 어떤 스크립트로도 못 잡는다 → node_exporter의 node_textfile_mtime_seconds
#     (결과 파일 수정 시각)가 오래되면 이상으로 보는 보조 감시를 권장.
#   - 이 스크립트 안에서는 here-string(<<<)/here-doc(<<)을 쓰지 않는다.
#     bash 5.0 이하(RHEL8, Ubuntu 20.04 등)는 이것을 /tmp 디스크 파일로 만들어서,
#     디스크가 멈추면 스크립트가 같이 멈출 수 있다. (수정할 때도 주의)
#
# [모드별 결과]
#                            write(기본)       read
#   디스크/스토리지 멈춤           0              0
#   fsfreeze                       0              1
#   read-only 전환                 0              1
#   파일 생성                  있음(즉시 삭제)    없음
#
# [설치]
#   1) TEXTFILE_DIR 설정 (위 [어디서 실행하나] 참고)
#   2) cron (root):  * * * * * /usr/local/bin/sw_fs_hang_check_v2.sh
#      v1을 쓰고 있었다면 v1의 cron 줄은 지우고 이 줄로 바꾼다 (둘을 같이 돌리지 않는다).
#      v1과 같은 상태 디렉터리·파일 이름을 쓰므로 그대로 교체하면 된다.
#   3) 확인:  curl -s localhost:9100/metrics | grep custom_fs_hang_status
#   4) ServiceWatch Agent metric.json의 metricMetas에 custom_fs_hang_status 추가
#      (dimensions: mountpoint)
#
# [검증 환경] Rocky Linux 9.7 (SELinux Enforcing), bash 5.1, coreutils 8.32
#   v1: node_exporter 1.8.2, loop 장치 xfs/ext4 + dmsetup suspend --nolockfs·fsfreeze·
#       read-only remount·동시 실행·PID 재사용·env -i(cron 환경)
#   v2: 위 항목 재확인 + 심볼릭 링크/FIFO 심기, kubelet PVC 마운트 모사, 컨테이너(docker) 안 실행,
#       lock을 잡은 채 멈춘 실행 모사, 제외+중복 장치, over-mount, umask 077, TEXTFILE_DIR=STATE_DIR
#   미검증: 실제 Kubernetes 클러스터(SKE), 실제 디스크 고장, SELinux confined node_exporter
# =============================================================================

# 숫자/문자 처리를 로케일과 무관하게 고정하고, cron의 최소 PATH에서도 명령을 찾도록 지정
export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 022     # 만드는 디렉터리 755 / 파일 644 → node_exporter(일반 계정)가 읽을 수 있게 (위 ⑧)
cd / || exit 1   # 백그라운드 probe가 실행 위치(cwd)를 붙잡지 않게 (위 ⑧)

# ----------------------------------------------------------------------------- 설정
TEXTFILE_DIR=""                         # node_exporter --collector.textfile.directory 값 (필수)
                                        #   node_exporter가 Pod(DaemonSet)이면 STATE_DIR과 같은 값으로 (위 ④)
OUT_NAME="sw_fs_hang.prom"              # 출력 파일명 (textfile collector는 *.prom만 읽음)
ALLOWED_FSTYPES="xfs|ext4"              # 확인할 로컬 파일시스템 종류 (정규식). 네트워크 FS(nfs 등)는 넣지 않는다
EXCLUDED_MOUNTPOINTS="^(/boot/efi|/boot)$|^/var/lib/kubelet/"
                                        # 제외할 마운트포인트 (정규식)
                                        #   ^(/boot/efi|/boot)$ : 부트 영역
                                        #   ^/var/lib/kubelet/  : Kubernetes Pod 볼륨(PVC 등). 일반 VM에는 없는 경로라 영향 없음
                                        #                         (/var/lib/kubelet 자체가 별도 디스크면 그것은 확인함)
INCLUDED_MOUNTPOINTS=""                 # 비우면 전체. 지정하면 이 정규식에 맞는 것만 (예: "^(/|/data)$")
PROBE_MODE="write"                      # 확인 방식
                                        #   write: 4KB 동기 쓰기 후 삭제
                                        #   read : 장치에서 4KB 직접 읽기 (파일 생성 없음)
PROBE_FILE=".sw_hangcheck"              # write 모드에서 마운트 최상위에 잠깐 만드는 파일명
WAIT_SEC=5                              # 이 시간 안에 끝나지 않으면 비정상(0)
LOCK_WAIT_SEC=10                        # 이전 실행이 이 시간 넘게 lock을 쥐고 있으면 "스크립트가 멈춤" → 전부 0 (위 ⑤)
                                        #   WAIT_SEC보다 넉넉히 크게. cron 주기(60초)보다는 작게.
STATE_DIR=/run/sw_fs_hang               # tmpfs(메모리) — 디스크가 멈춰도 결과를 쓸 수 있는 곳

# 결과 값 (Cloud Monitoring "Filesystem Hang Check"와 같은 정의)
STATUS_OK=1                             # 정상
STATUS_NG=0                             # 비정상 (hang / hang 지속 / 에러)

# 결과 파일은 항상 STATE_DIR(tmpfs)에 만든다
RESULT_FILE="$STATE_DIR/$OUT_NAME"

# ----------------------------------------------------------------------------- 실행 전 확인
# 문제가 있으면 이유를 stderr에 남기고 종료한다 (cron 메일, journalctl -u crond 등에서 확인 가능).
log_err() { echo "sw_fs_hang_check: $*" >&2; }

TEXTFILE_DIR=${TEXTFILE_DIR%/}          # 끝의 / 제거 → "/run/sw_fs_hang/" 와 "/run/sw_fs_hang" 를 같게 비교
[[ -n "$TEXTFILE_DIR" ]]                         || { log_err "TEXTFILE_DIR is empty. Set it in the script."; exit 1; }
(( EUID == 0 ))                                  || { log_err "must run as root."; exit 1; }
[[ "$PROBE_MODE" == "write" || "$PROBE_MODE" == "read" ]] \
                                                 || { log_err "PROBE_MODE must be write or read: $PROBE_MODE"; exit 1; }

# 컨테이너 안에서 실행됐는지 확인 (위 ③)
# mountinfo에서 마운트포인트가 "/" 인 줄의 fstype을 본다 (여러 줄이면 마지막 = 실제로 보이는 것).
#   호스트          : xfs / ext4 등
#   컨테이너(Pod)   : overlay (docker·containerd·podman), fuse.fuse-overlayfs(rootless), aufs(옛 docker)
root_fstype=$(awk '$5 == "/" { for (i = 7; i <= NF; i++) if ($i == "-") { fs = $(i+1); break } }
                   END { print fs }' /proc/self/mountinfo)
case "$root_fstype" in
	overlay|aufs|fuse.*)
		log_err "running inside a container (root fstype: $root_fstype). Run on the host, or via nsenter -t 1 -m."
		exit 1 ;;
esac

mkdir -p "$STATE_DIR" || { log_err "cannot create $STATE_DIR"; exit 1; }
chmod 755 "$STATE_DIR"                  # 이미 700으로 만들어져 있던 경우도 고침 (위 ⑧)

# ----------------------------------------------------------------------------- 중복 실행 방지
# fd 9에 lock 파일을 열고 잠근다. 최대 LOCK_WAIT_SEC초 기다린다.
#   - 정상이면 이전 실행은 최대 WAIT_SEC(5초) 안에 끝나므로 곧 lock을 잡는다.
#     (사람이 수동 실행한 것과 cron이 겹쳐도 몇 초 기다렸다 정상 진행)
#   - 그래도 못 잡으면 이전 실행이 비정상적으로 멈춰 있는 것 (위 ⑤)
#     → 마지막 결과의 값 1을 전부 0으로 바꿔 둔다. 그대로 두면 옛 "정상" 값이 계속 보고된다.
#       (sed로 새 파일을 만들고 mv로 바꿔치기 → node_exporter가 반쯤 쓰인 파일을 읽지 않음)
# 주의: 아래 probe 실행 시 "9>&-"로 이 fd를 닫아서 넘긴다.
#       멈춘 probe가 fd를 물고 있으면 lock이 풀리지 않아 이후 실행이 전부 막히기 때문.
exec 9>"$STATE_DIR/lock"
if ! flock -w "$LOCK_WAIT_SEC" 9; then
	if [[ -f "$RESULT_FILE" ]]; then
		sed "s/ ${STATUS_OK}\$/ ${STATUS_NG}/" "$RESULT_FILE" > "$RESULT_FILE.stuck.tmp" &&
			mv -f "$RESULT_FILE.stuck.tmp" "$RESULT_FILE"
	fi
	log_err "previous run still holds the lock after ${LOCK_WAIT_SEC}s (stuck?). All results set to ${STATUS_NG}."
	exit 1
fi

# ----------------------------------------------------------------------------- 함수
# 프로세스 시작 시각(/proc/<pid>/stat 22번째 필드, 부팅 후 clock tick)을 출력한다.
# PID는 재사용될 수 있으므로 "PID + 시작 시각"이 같아야 같은 프로세스로 본다.
# 2번째 필드(comm)는 괄호 안에 공백이 들어갈 수 있어서, 마지막 ") " 뒤부터 잘라 센다.
#   → 잘라낸 뒤 1번째 = 원래 3번째 필드, 따라서 원래 22번째 = 20번째
# $(< 파일) 은 cat 프로그램을 실행하지 않고 bash가 직접 읽는다 (디스크에서 프로그램을 안 불러옴).
# { ...; } 2>/dev/null : 프로세스가 이미 없을 때 나오는 "No such file" 메시지를 숨김
proc_start() {
	local s
	{ s=$(< "/proc/$1/stat"); } 2>/dev/null || return 1   # 프로세스가 없으면 실패(1) 반환
	s=${s##*) }                                         # 마지막 ") " 까지 제거
	# shellcheck disable=SC2086  # 일부러 따옴표 없이: 공백 기준으로 나눠야 함 (값은 숫자/문자뿐이라 안전)
	set -- $s                                           # 공백 기준으로 $1, $2 ... 에 나눠 담음
	echo "${20}"
}

# 이전 실행에서 띄운 probe가 아직 살아 있는지 확인한다. ($1 = 장치 key)
# pid 파일 형식: "<pid> <starttime>"
#   - pid 파일이 없음                → 이전 probe 없음 (또는 정상 종료 후 정리됨)  → false
#   - 같은 pid가 있고 시작 시각도 같음 → 그 probe가 아직 멈춰 있음                 → true
#   - pid는 있는데 시작 시각이 다름   → probe는 끝났고 다른 프로세스가 pid를 재사용 → false
probe_alive() {
	local pid st
	[[ -f "$STATE_DIR/$1.pid" ]] || return 1
	read -r pid st < "$STATE_DIR/$1.pid" || return 1
	[[ -n "$pid" && -n "$st" && "$(proc_start "$pid")" == "$st" ]]
}

# probe를 백그라운드로 띄운다. ($1 = 장치 key, $2 = 마운트포인트, $3 = 장치 경로)
# probe가 끝나면 종료 코드를 <key>.rc 파일에 남긴다 (tmp에 쓰고 mv → 반쯤 쓰인 파일 방지).
# 메인 스크립트는 wait하지 않고 이 rc 파일이 생겼는지만 본다.
#   - </dev/null >/dev/null 2>&1 : 표준 입출력을 끊어 스크립트 출력/파이프를 붙잡지 않게 함
#   - 9>&-                        : lock fd를 넘기지 않음 (위 "중복 실행 방지" 참고)
#   - ( ... ) &                   : 서브셸을 백그라운드로 실행. 멈추면 이 서브셸 아래 dd가 D 상태로 남는다
start_probe() {
	local key="$1" mp="$2" dev="$3"
	local rc="$STATE_DIR/$key.rc"
	local f="${mp%/}/$PROBE_FILE"               # "/" 이면 "/.sw_hangcheck", "/data" 이면 "/data/.sw_hangcheck"
	rm -f "$rc"                                 # 이전 결과 제거 → rc 파일 존재 = 이번 probe 완료
	if [[ "$PROBE_MODE" == "read" ]]; then
		# read: 장치 맨 앞 4KB를 페이지 캐시를 거치지 않고(iflag=direct) 읽는다. 파일 생성 없음.
		( dd if="$dev" of=/dev/null bs=4k count=1 iflag=direct
		  echo $? > "$rc.tmp" && mv -f "$rc.tmp" "$rc" ) </dev/null >/dev/null 2>&1 9>&- &
	else
		# write: 아래 3단계를 차례로. 하나라도 실패하면 뒤는 건너뛰고 그 종료 코드가 rc에 남는다 (&&).
		#   1) rm -f     : 같은 이름이 있으면 먼저 지운다
		#                  (지난번 probe가 남긴 파일, 또는 누가 심어 둔 심볼릭 링크·FIFO.
		#                   링크를 지우면 링크만 지워지고 가리키던 파일은 그대로)
		#   2) dd        : 4KB를 디스크까지 동기 쓰기(oflag=dsync)
		#                  conv=excl = "없는 파일을 새로 만들 때만 성공" (O_CREAT|O_EXCL)
		#                  → 1)과 2) 사이에 누가 링크를 다시 심어도 따라가지 않고 실패만 한다 (위 ①)
		#                  쓰기 실패(read-only, 공간 부족)도 0이 아닌 코드 → 비정상(0)
		#   3) rm -f     : 만든 파일을 바로 지운다
		( rm -f "$f" &&
		  dd if=/dev/zero of="$f" bs=4k count=1 oflag=dsync conv=excl &&
		  rm -f "$f"
		  echo $? > "$rc.tmp" && mv -f "$rc.tmp" "$rc" ) </dev/null >/dev/null 2>&1 9>&- &
	fi
	# 방금 띄운 probe의 PID와 시작 시각 기록 (다음 실행에서 "아직 멈춰 있는지" 판단용)
	echo "$! $(proc_start $!)" > "$STATE_DIR/$key.pid"
}

# ----------------------------------------------------------------------------- 대상 선정 + probe 시작
# /proc/self/mountinfo 형식:
#   마운트ID 부모ID 주번호:부번호 root 마운트포인트 옵션 [선택필드...] - fstype 장치 슈퍼옵션
#   예) 98 1 253:2 / /data rw,relatime shared:50 - xfs /dev/mapper/vg-data rw,attr2
#
# 1단계 (awk) — 후보 고르기
#   - fstype이 ALLOWED_FSTYPES에 맞는 것만 → 로컬 xfs/ext4 (nfs, tmpfs, overlay 등 제외)
#   - root($4)가 "/"인 것만 → bind mount(파일시스템의 하위 디렉터리를 다시 마운트한 것) 제외
#   - 같은 마운트포인트가 여러 번 나오면 마지막 것만 (위 ⑦)
#     mountinfo는 마운트한 순서대로 나오므로, 마지막 것이 위에 덮여 실제로 보이는 마운트다.
#     → 모든 줄을 일단 저장하고(line[]), 마운트포인트별 마지막 줄 번호(last[])를 기억했다가
#       END에서 "마지막 줄인 것"만 원래 순서대로 출력
#
# 2단계 (bash while) — 제외 후 장치 중복 거르기 (위 ⑥: 제외를 먼저, 중복을 나중에)
#   - 공백 등이 들어간 경로는 \040처럼 이스케이프되어 지표 레이블이 깨지므로 제외
#   - 큰따옴표(")가 들어간 경로도 레이블이 깨지므로 제외
#   - EXCLUDED_MOUNTPOINTS / INCLUDED_MOUNTPOINTS 적용
#   - 같은 장치(주:부번호)는 처음 1개만 → 같은 디스크를 중복 확인하지 않음
#
# 여기서는 mountinfo(커널 메모리 정보)만 읽으므로 디스크가 멈춰도 이 단계는 멈추지 않는다.
declare -A seen_dev                     # 이미 확인 대상으로 넣은 장치 (주:부번호 → 1)
keys=(); mps=(); fstypes=(); waitkeys=()
while read -r majmin mp fstype src; do
	[[ "$mp" == *\\* ]] && continue                                            # \040 등 이스케이프
	[[ "$mp" == *\"* ]] && continue                                            # 큰따옴표
	[[ -n "$EXCLUDED_MOUNTPOINTS" && "$mp" =~ $EXCLUDED_MOUNTPOINTS ]] && continue
	[[ -n "$INCLUDED_MOUNTPOINTS" && ! "$mp" =~ $INCLUDED_MOUNTPOINTS ]] && continue
	[[ -n "${seen_dev[$majmin]}" ]] && continue                                # 같은 장치는 1번만
	seen_dev[$majmin]=1

	key=${majmin/:/_}                       # 예: 253:0 → 253_0 (state 파일 이름으로 사용)

	# read 모드용 장치 경로: /dev/block/주:부번호 (udev가 만드는 링크)가 있으면 그것을 쓴다.
	# mountinfo의 장치 이름은 /dev/root 처럼 실제로 없는 이름일 때가 있다 (위 ⑧).
	dev="$src"
	[[ -b "/dev/block/$majmin" ]] && dev="/dev/block/$majmin"

	keys+=("$key"); mps+=("$mp"); fstypes+=("$fstype")
	if ! probe_alive "$key"; then           # 이전 probe가 아직 멈춰 있으면 새로 띄우지 않음(→ 바로 0)
		start_probe "$key" "$mp" "$dev"
		waitkeys+=("$key")                  # 이번에 새로 띄운 것만 결과를 기다린다
	fi
done < <(awk -v re="^(${ALLOWED_FSTYPES})$" '
	{
		for (i = 7; i <= NF; i++) if ($i == "-") break    # 선택 필드 개수가 가변이라 "-" 위치를 찾음
		if ($(i+1) !~ re || $4 != "/") next               # fstype 불일치 / bind mount 제외
		n++
		line[n] = $3 " " $5 " " $(i+1) " " $(i+2)         # 주:부번호 마운트포인트 fstype 장치
		mp[n]   = $5
		last[$5] = n                                      # 이 마운트포인트의 마지막 줄 번호
	}
	END {
		for (k = 1; k <= n; k++) if (last[mp[k]] == k) print line[k]
	}' /proc/self/mountinfo)
# ※ "while ... done < <(...)" 형태: 파이프(|)로 넘기면 while이 서브셸에서 돌아
#    배열(keys 등)이 루프 밖에서 사라지므로 프로세스 치환을 사용

# ----------------------------------------------------------------------------- 결과 대기
# 이번에 띄운 probe만 0.1초 간격으로 최대 WAIT_SEC까지 기다린다.
# 동시에 띄웠으므로 마운트가 여러 개여도 전체 대기 시간은 WAIT_SEC를 넘지 않는다.
# 모든 probe의 rc 파일이 생기면(= 전부 끝나면) 바로 빠져나온다.
for (( t = 0; t < WAIT_SEC * 10 && ${#waitkeys[@]} > 0; t++ )); do
	pending=0
	for key in "${waitkeys[@]}"; do
		[[ -f "$STATE_DIR/$key.rc" ]] || pending=1
	done
	(( pending == 0 )) && break
	sleep 0.1
done

# ----------------------------------------------------------------------------- 결과 기록
# 장치별 판정:
#   rc 파일 있음 + 내용 0  → probe가 성공으로 끝남           → 정상(1),   pid 파일 정리
#   rc 파일 있음 + 0 아님  → probe가 에러로 끝남             → 비정상(0), pid 파일 정리
#   rc 파일 없음           → WAIT_SEC 안에 안 끝남 / 이전 probe가 아직 멈춰 있음
#                           → 비정상(0), pid 파일은 남겨 다음 실행에서 재확인
# 결과는 tmpfs에 tmp로 쓰고 mv로 교체 → node_exporter가 반쯤 쓰인 파일을 읽지 않음
{
for i in "${!keys[@]}"; do
	key=${keys[$i]}
	if [[ -f "$STATE_DIR/$key.rc" ]]; then
		rc=""
		read -r rc < "$STATE_DIR/$key.rc"
		[[ "$rc" == "0" ]] && status=$STATUS_OK || status=$STATUS_NG
		rm -f "$STATE_DIR/$key.pid"
	else
		status=$STATUS_NG
	fi
	echo "custom_fs_hang_status{mountpoint=\"${mps[$i]}\",fstype=\"${fstypes[$i]}\"} ${status}"
done
} > "$RESULT_FILE.tmp"
mv -f "$RESULT_FILE.tmp" "$RESULT_FILE"

# ----------------------------------------------------------------------------- textfile 디렉터리 연결
# TEXTFILE_DIR이 STATE_DIR과 같으면(= node_exporter가 /run/sw_fs_hang을 직접 읽음) 할 일 없음 (위 ④).
# 다르면 textfile 디렉터리에 tmpfs 결과 파일을 가리키는 심볼릭 링크를 둔다.
#   - 이미 올바른 링크면 건드리지 않는다 (매번 디스크에 쓰지 않기 위해 — 링크 확인은 캐시에서 응답)
#   - 링크가 다른 곳을 가리키거나, 이전 버전이 만든 일반 파일이면 링크로 교체된다
if [[ "$TEXTFILE_DIR" != "$STATE_DIR" ]]; then
	link="$TEXTFILE_DIR/$OUT_NAME"
	if [[ ! -L "$link" || "$(readlink "$link")" != "$RESULT_FILE" ]]; then
		ln -sfn "$RESULT_FILE" "$link" || log_err "cannot create link $link (does TEXTFILE_DIR exist?)"
	fi
fi
