#!/bin/bash
# =============================================================================
# sw_fs_hang_check_v3.sh — 로컬 파일시스템 hang 체크 (ServiceWatch 사용자 정의 지표)
#
#   버전      : v3.0 (2026-11-09) — "읽기 전용" 간소화판
#   이전 버전 : sw_fs_hang_check.sh (v1), sw_fs_hang_check_v2.sh (v2) — 둘 다 그대로 둠
#   지표/값   : v1·v2와 같음 → custom_fs_hang_status (1 정상 / 0 비정상). 알람 설정 변경 불필요
# =============================================================================
#
# [v3의 핵심: 운영 디스크에 아무것도 쓰지 않는다]
#   v1·v2는 기본값(write 모드)으로 매분 "마운트 최상위/.sw_hangcheck" 파일을 만들고 지웠다.
#   그래서 심볼릭 링크 공격 대비, Pod 볼륨 회피, FIM/EDR 알림, 저널 커밋 같은 고려가 필요했다.
#   v3는 write 모드를 없애고 "장치에서 4KB를 직접 읽기"만 한다.
#
#     하는 일                          디스크 영향
#     ------------------------------   ---------------------------------------------
#     장치 맨 앞 4KB 직접 읽기(1분 1회)  읽기 4KB뿐. 파일 생성·수정·삭제 없음, 저널 커밋 없음
#     /proc/self/mountinfo 읽기         커널 메모리 정보. 디스크 I/O 없음
#     결과 파일 쓰기                    /run (tmpfs = 메모리). 디스크 아님
#     textfile 디렉터리에 링크 만들기    최초 1회만 (이미 있으면 건드리지 않음)
#
#   → 확인 방법이 "읽기"뿐이라 앱 데이터·Pod 볼륨·권한 문제를 건드릴 일이 없다.
#     (v2의 ① 심볼릭 링크 문제, write 관련 주의사항이 통째로 사라짐)
#
# [v2 대비 무엇이 단순해졌나]
#   - write 모드, PROBE_MODE / PROBE_FILE 설정 삭제
#   - "이전 확인이 아직 멈춰 있나?" 판단을 pid 파일 + 프로세스 시작 시각 비교 대신
#     pgrep 한 줄로 처리: "이 장치를 읽는 dd가 아직 떠 있으면 = 아직 멈춰 있음"
#     (명령줄 전체가 똑같은 프로세스만 찾으므로 PID 재사용 걱정이 없다)
#   - 겹쳐 마운트(over-mount) 처리를 awk 2단계 대신 "같은 경로는 처음 1개만" 으로 단순화
#
# [v2에서 그대로 가져온 안전장치]
#   - 확인(dd)은 백그라운드로 띄우고 최대 WAIT_SEC만 기다린다 (멈춘 I/O는 kill로도 안 죽음)
#   - 장치당 멈춘 dd는 1개까지만 (hang이 길어져도 매분 쌓이지 않음)
#   - 결과는 /run(tmpfs)에, textfile 디렉터리에는 링크만 (디스크가 멈춰도 결과 갱신)
#   - flock 중복 실행 방지 + 스크립트 자체가 멈추면 결과를 전부 0으로 (옛 "정상" 값이 남지 않게)
#   - Kubernetes kubelet 내부 마운트(Pod PVC) 제외, 컨테이너 안 실행 차단
#   - umask 022, cd /, 설정 오류 메시지
#
# [무엇을 하나]
#   Cloud Monitoring Agent의 "Filesystem Hang Check" 지표를 ServiceWatch용으로 재현한다.
#     Cloud Monitoring 정의: FileSystem | Filesystem Hang Check | state | 1m |
#                            filesystem(local/NFS) hang 체크 (정상:1, 비정상:0)
#   대상은 로컬 파일시스템(xfs/ext4)만. NFS는 sw_custom_metrics.sh의 custom_nfs_mount_up으로 본다.
#
#     custom_fs_hang_status{mountpoint="/data",fstype="xfs"} 1
#
#     1 = 정상   : 장치 읽기가 WAIT_SEC 안에 성공으로 끝남
#     0 = 비정상 : 아래 중 하나
#                  - WAIT_SEC 안에 끝나지 않음 (hang)
#                  - 이전 실행에서 띄운 읽기가 아직도 멈춰 있음 (hang 지속)
#                  - 읽기가 에러로 끝남 (장치 I/O 에러)
#                  - 이 스크립트 자체가 이전 실행에서 멈춰 있음
#
#   → 알람 조건: "값 < 1" (= 0) 을 N회 연속 위반 시
#
# [왜 ls/stat/df가 아니라 장치 직접 읽기인가]
#   로컬 파일시스템의 ls/stat/df는 커널 메모리 캐시에서 응답하므로 디스크가 멈춰도 정상으로 보인다.
#   dd의 iflag=direct(O_DIRECT)는 페이지 캐시를 거치지 않고 매번 실제 장치에 읽기 요청을 보낸다.
#   → 디스크/스토리지 경로가 멈추면 이 요청이 돌아오지 않는다 = hang 감지.
#
# [이 방식이 잡는 것 / 잡지 못하는 것 — v1·v2(write 모드)와 비교]
#                                         v3(읽기)   v1·v2 write 모드
#   디스크/스토리지 경로 멈춤 (본래 목적)      0            0
#   장치 I/O 에러                              0            0
#   fsfreeze (백업 스냅샷 중 쓰기 정지)        1            0   ← v3는 백업 때 오탐이 없음
#   ext4 디스크 에러 → 자동 read-only 전환     1 (못 잡음)  0
#   xfs 강제 종료(shutdown)                    1 (못 잡음)  0
#
#   못 잡는 두 경우는 "멈춤(hang)"이 아니라 "파일시스템 에러로 쓰기 불가" 상태다.
#   쓰지 않고 이것을 알아내는 방법을 찾아봤지만 믿을 만한 것이 없었다 (Rocky 9.7 실측):
#     - ext4 에러로 read-only가 돼도 mountinfo·statfs에는 계속 "rw"로 나온다
#       → mountinfo의 ro 여부로 판단하는 방식은 동작하지 않는다
#     - xfs shutdown 후에도 statfs(df)는 성공한다
#       → node_exporter의 node_filesystem_device_error / node_filesystem_readonly 도 0으로 남는다
#   이 상태까지 꼭 잡아야 하면 write 방식(v2)을 써야 한다. 커널 로그(dmesg)의 "EXT4-fs error",
#   "Remounting filesystem read-only", "xfs ... Shutting down" 감시로 보완하는 방법도 있다.
#
#   그 밖에:
#   - 장치는 멀쩡한데 파일시스템 내부만 멈춘 경우(예: 저널 교착)는 못 잡는다 (드묾)
#   - 장치 맨 앞 4KB만 읽으므로 디스크 일부 영역만 고장 난 경우는 못 잡는다 (hang 체크 목적상 충분)
#
# [어디서 실행하나 — 일반 VM / Kubernetes 노드]
#   일반 VM          : root cron 1분.
#   Kubernetes 노드  : 노드(호스트)에서 root cron 1분. Pod 안에서 직접 실행하지 않는다.
#                      - 노드가 새로 만들어지면 cron이 사라짐 → 노드 초기화 스크립트/이미지에 포함
#                      - DaemonSet이 꼭 필요하면 privileged + hostPID 로 띄우고
#                          nsenter -t 1 -m -- /usr/local/bin/sw_fs_hang_check_v3.sh
#   node_exporter 위치에 따라 TEXTFILE_DIR 지정
#      - 호스트에 설치(ServiceWatch Agent 기본 방식): --collector.textfile.directory 값 (링크 방식)
#      - Pod(DaemonSet)으로 실행: TEXTFILE_DIR=/run/sw_fs_hang (= STATE_DIR, 링크 없이 직접)
#        → DaemonSet에 hostPath /run/sw_fs_hang 을 마운트하고 textfile 디렉터리로 지정
#
# [운영 시 알아둘 점]
#   - root로 실행해야 한다 (장치 직접 읽기).
#   - 재부팅 직후 첫 실행 전에는 /run이 비어 node_textfile_scrape_error=1 (최대 1분).
#   - 디스크가 완전히 멈추고 명령 실행 파일까지 캐시에서 밀려나면 cron도 스크립트를 못 띄운다.
#     → node_textfile_mtime_seconds(결과 파일 수정 시각)가 오래되면 이상으로 보는 보조 감시 권장.
#   - 이 스크립트에서는 here-string(<<<)/here-doc(<<)을 쓰지 않는다.
#     bash 5.0 이하는 이것을 /tmp 디스크 파일로 만들어, 디스크가 멈추면 스크립트도 멈출 수 있다.
#
# [설치]
#   1) TEXTFILE_DIR 설정 (위 [어디서 실행하나])
#   2) cron (root):  * * * * * /usr/local/bin/sw_fs_hang_check_v3.sh
#      v1/v2를 쓰고 있었다면 그 cron 줄은 지우고 이 줄로 바꾼다 (같이 돌리지 않는다).
#   3) 확인:  curl -s localhost:9100/metrics | grep custom_fs_hang_status
#   4) ServiceWatch Agent metric.json의 metricMetas에 custom_fs_hang_status 추가 (dimensions: mountpoint)
#
# [검증] Rocky Linux 9.7 (SELinux Enforcing), bash 5.1, node_exporter 1.8.2, loop/dm 장치 xfs·ext4
#   정상, dmsetup suspend(실제 I/O 멈춤)·멈춘 채 반복 실행·resume, fsfreeze,
#   ext4 에러 → 자동 read-only 및 xfs shutdown (둘 다 못 잡음을 확인 — 위 표),
#   kubelet PVC 마운트 모사, 컨테이너 안 실행, 스크립트 멈춤 모사, 동시 실행,
#   실행 중 디스크 쓰기량 측정(/sys/block/*/stat — 10회 실행 동안 스크립트로 인한 쓰기 0건, 읽기 1회당 1건)
#   미검증: 실제 Kubernetes 클러스터(SKE), 실제 디스크 고장
# =============================================================================

export LC_ALL=C                     # 숫자/문자 처리를 로케일과 무관하게 고정
PATH=/usr/sbin:/usr/bin:/sbin:/bin  # cron의 최소 PATH에서도 명령을 찾도록
umask 022                           # 만드는 파일 644 / 디렉터리 755 → node_exporter(일반 계정)가 읽을 수 있게
cd / || exit 1                      # 백그라운드 dd가 실행 위치(cwd)를 붙잡지 않게

# ----------------------------------------------------------------------------- 설정
TEXTFILE_DIR=""                         # node_exporter --collector.textfile.directory 값 (필수)
OUT_NAME="sw_fs_hang.prom"              # 출력 파일명 (textfile collector는 *.prom만 읽음)
ALLOWED_FSTYPES="xfs|ext4"              # 확인할 로컬 파일시스템 종류 (정규식). nfs 등은 넣지 않는다
EXCLUDED_MOUNTPOINTS="^(/boot/efi|/boot)$|^/var/lib/kubelet/"
                                        # 제외할 마운트포인트 (정규식)
                                        #   ^(/boot/efi|/boot)$ : 부트 영역
                                        #   ^/var/lib/kubelet/  : Kubernetes Pod 볼륨(PVC 등). 일반 VM에는 없는 경로
INCLUDED_MOUNTPOINTS=""                 # 비우면 전체. 지정하면 이 정규식에 맞는 것만 (예: "^(/|/data)$")
WAIT_SEC=5                             # 이 시간 안에 읽기가 안 끝나면 비정상(0)
LOCK_WAIT_SEC=10                        # 이전 실행이 이 시간 넘게 안 끝나면 "스크립트가 멈춤" → 전부 0
STATE_DIR=/run/sw_fs_hang               # tmpfs(메모리) — 디스크가 멈춰도 결과를 쓸 수 있는 곳

# dd에 넘기는 옵션. "아직 멈춰 있는 dd" 를 찾을 때(pgrep)도 같은 문자열을 쓰므로 한 곳에서 정의한다.
#   of=/dev/null  : 읽은 내용은 버림
#   bs=4k count=1 : 4KB 한 번만
#   iflag=direct  : 페이지 캐시를 거치지 않고 장치에 직접 요청 (캐시 응답으로 속지 않게)
DD_OPTS="of=/dev/null bs=4k count=1 iflag=direct"

STATUS_OK=1                             # 정상
STATUS_NG=0                             # 비정상
RESULT_FILE="$STATE_DIR/$OUT_NAME"      # 결과 파일 (항상 tmpfs)

# ----------------------------------------------------------------------------- 실행 전 확인
log_err() { echo "sw_fs_hang_check: $*" >&2; }   # cron 메일 / journalctl -u crond 에서 볼 수 있음

TEXTFILE_DIR=${TEXTFILE_DIR%/}          # 끝의 / 제거 (STATE_DIR과 비교할 때 "/run/x/" 와 "/run/x" 를 같게)
[[ -n "$TEXTFILE_DIR" ]] || { log_err "TEXTFILE_DIR is empty. Set it in the script."; exit 1; }
(( EUID == 0 ))          || { log_err "must run as root."; exit 1; }

# 컨테이너 안에서 실행됐는지 확인
# 마운트포인트가 "/" 인 줄의 fstype을 본다 (여러 줄이면 마지막 = 실제로 보이는 것).
#   호스트: xfs/ext4 등   컨테이너(Pod): overlay, fuse.fuse-overlayfs(rootless), aufs(옛 docker)
# 컨테이너 안에서는 호스트가 아닌 컨테이너 기준 마운트가 보여서 엉뚱한 결과가 나오므로 멈춘다.
root_fstype=$(awk '$5 == "/" { for (i = 7; i <= NF; i++) if ($i == "-") { fs = $(i+1); break } }
                   END { print fs }' /proc/self/mountinfo)
case "$root_fstype" in
	overlay|aufs|fuse.*)
		log_err "running inside a container (root fstype: $root_fstype). Run on the host, or via nsenter -t 1 -m."
		exit 1 ;;
esac

mkdir -p "$STATE_DIR" || { log_err "cannot create $STATE_DIR"; exit 1; }
chmod 755 "$STATE_DIR"                  # 예전에 700으로 만들어졌어도 node_exporter가 읽을 수 있게

# ----------------------------------------------------------------------------- 중복 실행 방지
# fd 9에 lock 파일을 열고 최대 LOCK_WAIT_SEC초 기다리며 잠근다.
#   - 정상 실행은 최대 WAIT_SEC(5초) 안에 끝나므로, 수동 실행과 cron이 겹쳐도 잠깐 기다렸다 진행한다.
#   - 그래도 못 잡으면 이전 실행이 비정상적으로 멈춰 있는 것
#     → 마지막 결과의 1을 전부 0으로 바꿔 둔다 (그대로 두면 옛 "정상" 값이 계속 보고됨).
#       sed로 새 파일을 만든 뒤 mv로 바꿔치기 → node_exporter가 반쯤 쓰인 파일을 읽지 않음
# 백그라운드 dd에는 "9>&-"로 이 fd를 넘기지 않는다.
#   (멈춘 dd가 fd를 물고 있으면 lock이 안 풀려 이후 실행이 전부 막힘)
exec 9>"$STATE_DIR/lock"
if ! flock -w "$LOCK_WAIT_SEC" 9; then
	if [[ -f "$RESULT_FILE" ]]; then
		sed "s/ ${STATUS_OK}\$/ ${STATUS_NG}/" "$RESULT_FILE" > "$RESULT_FILE.stuck.tmp" &&
			mv -f "$RESULT_FILE.stuck.tmp" "$RESULT_FILE"
	fi
	log_err "previous run still holds the lock after ${LOCK_WAIT_SEC}s (stuck?). All results set to ${STATUS_NG}."
	exit 1
fi

# ----------------------------------------------------------------------------- 대상 선정 + 읽기 시작
# /proc/self/mountinfo 한 줄 형식:
#   마운트ID 부모ID 주:부번호 root 마운트포인트 옵션 [선택필드...] - fstype 장치 슈퍼블록옵션
#   예) 98 1 253:2 / /data rw,relatime shared:50 - xfs /dev/mapper/vg-data rw,attr2
#
# awk에서 1차로 고른다:
#   - fstype이 ALLOWED_FSTYPES(xfs/ext4)인 것만
#   - root($4)가 "/"인 것만 → bind mount(하위 디렉터리를 다시 마운트한 것) 제외
#   출력: 주:부번호 마운트포인트 fstype 장치
#
# while에서 2차로 거른다:
#   - 공백(\040 등 이스케이프)·큰따옴표가 든 경로 → 지표 레이블이 깨지므로 제외
#   - EXCLUDED / INCLUDED 적용
#   - 같은 장치는 1번만, 같은 마운트포인트도 1번만 (같은 디스크 중복 확인·같은 레이블 2줄 방지)
#
# 장치별 상태(states)를 정한다:
#   stuck : 이 장치를 읽는 dd가 아직 떠 있음 = 이전 읽기가 아직 멈춰 있음 → 새로 안 띄움, 결과 0
#   probe : 새로 읽기를 띄움 → 아래에서 결과를 기다림
#
# 이 단계는 mountinfo(커널 메모리)와 /proc(pgrep)만 보므로 디스크가 멈춰도 멈추지 않는다.
declare -A seen_dev seen_mp
mps=(); fstypes=(); keys=(); states=()
while read -r majmin mp fstype src; do
	[[ "$mp" == *\\* || "$mp" == *\"* ]] && continue                          # 레이블이 깨지는 경로
	[[ -n "$EXCLUDED_MOUNTPOINTS" && "$mp" =~ $EXCLUDED_MOUNTPOINTS ]] && continue
	[[ -n "$INCLUDED_MOUNTPOINTS" && ! "$mp" =~ $INCLUDED_MOUNTPOINTS ]] && continue
	[[ -n "${seen_dev[$majmin]}" || -n "${seen_mp[$mp]}" ]] && continue      # 중복
	seen_dev[$majmin]=1; seen_mp[$mp]=1

	key=${majmin/:/_}                   # 예: 253:0 → 253_0 (결과 메모 파일 이름에 사용)

	# 읽을 장치 경로: /dev/block/주:부번호 (udev가 만드는 링크)를 우선 사용.
	# mountinfo의 장치 이름이 /dev/root 처럼 실제로 없는 이름인 시스템이 있어서.
	dev="$src"
	[[ -b "/dev/block/$majmin" ]] && dev="/dev/block/$majmin"

	mps+=("$mp"); fstypes+=("$fstype"); keys+=("$key")

	if pgrep -f -x "dd if=$dev $DD_OPTS" >/dev/null; then
		# -f: 명령줄 전체로 찾기, -x: 정확히 같은 것만 → 우리가 띄운 이 장치의 dd만 찾는다
		states+=("stuck")
	else
		# 백그라운드로 4KB 읽기. 끝나면 종료 코드를 /run/sw_fs_hang/<key>.rc 에 남긴다.
		#   rc 파일을 먼저 지움 → "rc 파일이 생김 = 이번 읽기가 끝남"
		#   tmp에 쓰고 mv → 반쯤 쓰인 rc 파일을 읽지 않게
		#   </dev/null >/dev/null 2>&1 : 입출력을 끊어 스크립트를 붙잡지 않게
		#   9>&-                        : lock fd를 넘기지 않음
		rm -f "$STATE_DIR/$key.rc"
		# shellcheck disable=SC2086  # DD_OPTS는 일부러 따옴표 없이: 옵션 여러 개로 나눠 넘겨야 함
		( dd if="$dev" $DD_OPTS
		  echo $? > "$STATE_DIR/$key.rc.tmp" && mv -f "$STATE_DIR/$key.rc.tmp" "$STATE_DIR/$key.rc"
		) </dev/null >/dev/null 2>&1 9>&- &
		states+=("probe")
	fi
done < <(awk -v re="^(${ALLOWED_FSTYPES})$" '{
		for (i = 7; i <= NF; i++) if ($i == "-") break    # 선택 필드 개수가 가변이라 "-" 위치를 찾음
		if ($(i+1) !~ re || $4 != "/") next               # fstype 불일치 / bind mount 제외
		print $3, $5, $(i+1), $(i+2)                      # 주:부번호 마운트포인트 fstype 장치
	}' /proc/self/mountinfo)
# ※ "while ... done < <(...)": 파이프(|)로 넘기면 while이 서브셸에서 돌아 배열이 사라지므로 이 형태 사용

# ----------------------------------------------------------------------------- 결과 대기
# 새로 띄운(probe) 것들의 rc 파일이 모두 생길 때까지 0.1초 간격으로 최대 WAIT_SEC 기다린다.
# 동시에 띄웠으므로 마운트가 여러 개여도 전체 대기는 최대 WAIT_SEC.
for (( t = 0; t < WAIT_SEC * 10; t++ )); do
	pending=0
	for i in "${!keys[@]}"; do
		[[ "${states[$i]}" == probe && ! -f "$STATE_DIR/${keys[$i]}.rc" ]] && pending=1
	done
	(( pending == 0 )) && break
	sleep 0.1
done

# ----------------------------------------------------------------------------- 결과 기록
# 장치별 판정:
#   probe + rc 파일 있음 + 내용 0 → 읽기 성공               → 1
#   probe + rc 파일 있음 + 0 아님 → 읽기 에러               → 0
#   probe + rc 파일 없음          → WAIT_SEC 안에 안 끝남    → 0 (dd는 남아 있다가 다음 실행에서 stuck으로 잡힘)
#   stuck                         → 이전 읽기가 아직 멈춰 있음 → 0
# 결과는 tmpfs에 tmp로 쓰고 mv로 교체 → node_exporter가 반쯤 쓰인 파일을 읽지 않음
{
for i in "${!keys[@]}"; do
	status=$STATUS_NG
	if [[ "${states[$i]}" == probe && -f "$STATE_DIR/${keys[$i]}.rc" ]]; then
		rc=""
		read -r rc < "$STATE_DIR/${keys[$i]}.rc"
		[[ "$rc" == "0" ]] && status=$STATUS_OK
	fi
	echo "custom_fs_hang_status{mountpoint=\"${mps[$i]}\",fstype=\"${fstypes[$i]}\"} ${status}"
done
} > "$RESULT_FILE.tmp"
mv -f "$RESULT_FILE.tmp" "$RESULT_FILE"

# ----------------------------------------------------------------------------- textfile 디렉터리 연결
# TEXTFILE_DIR = STATE_DIR 이면(node_exporter가 /run/sw_fs_hang을 직접 읽음) 할 일 없음.
# 아니면 textfile 디렉터리에 tmpfs 결과 파일을 가리키는 링크를 둔다.
#   이미 올바른 링크면 건드리지 않는다 → 디스크 쓰기는 최초 1회뿐 (링크 확인은 캐시에서 응답)
if [[ "$TEXTFILE_DIR" != "$STATE_DIR" ]]; then
	link="$TEXTFILE_DIR/$OUT_NAME"
	if [[ ! -L "$link" || "$(readlink "$link")" != "$RESULT_FILE" ]]; then
		ln -sfn "$RESULT_FILE" "$link" || log_err "cannot create link $link (does TEXTFILE_DIR exist?)"
	fi
fi
