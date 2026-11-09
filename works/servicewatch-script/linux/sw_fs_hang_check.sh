#!/bin/bash
# =============================================================================
# sw_fs_hang_check.sh — 로컬 파일시스템 hang 체크 (ServiceWatch 사용자 정의 지표)
# =============================================================================
#
# [무엇을 하나]
#   Cloud Monitoring Agent의 "Filesystem Hang Check" 지표를 ServiceWatch용으로 재현한다.
#     Cloud Monitoring 정의: FileSystem | Filesystem Hang Check | state | 1m |
#                            filesystem(local/NFS) hang 체크 (정상:1, 비정상:0)
#   값의 정의(1/0)는 같게 맞추고, 대상은 로컬 파일시스템(xfs/ext4)만 확인한다.
#   (NFS는 대상에서 제외 — 마운트 상태는 sw_custom_metrics.sh의 custom_nfs_mount_up으로 본다)
#
#   마운트된 xfs/ext4 로컬 파일시스템마다 "캐시를 거치지 않는 디스크 I/O"를 한 번 보내고,
#   WAIT_SEC 안에 성공으로 끝나는지 확인한다. 결과는 node_exporter textfile collector
#   형식으로 출력한다.
#
#     custom_fs_hang_status{mountpoint="/data",fstype="xfs"} 1
#
#     1 = 정상   : WAIT_SEC 안에 요청이 성공으로 끝남
#     0 = 비정상 : 아래 중 하나
#                  - WAIT_SEC 안에 끝나지 않음 (hang)
#                  - 이전 실행에서 띄운 확인이 아직도 멈춰 있음 (hang 지속)
#                  - I/O가 에러로 끝남 (read-only 전환, 공간 부족, 권한 등)
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
#       마지막 값(정상)을 계속 보내 장애를 놓친다 — 이전 버전에서 실측)
#   4) flock으로 중복 실행을 막는다. 단, probe에는 lock fd를 넘기지 않는다.
#      (멈춘 probe가 lock을 쥐고 있으면 이후 실행이 전부 막혀 결과가 갱신되지 않음)
#   5) bind mount(하위 디렉터리 재마운트, 컨테이너 볼륨 등)는 제외하고,
#      같은 장치는 한 번만 확인한다. → 앱/컨테이너 디렉터리에 파일을 쓰지 않음
#   6) 모든 probe를 동시에 띄우므로 마운트가 많아도 전체 대기는 최대 WAIT_SEC.
#
# [운영 시 알아둘 점]
#   - root로 실행해야 한다 (마운트 최상위 쓰기 / 장치 직접 읽기).
#   - write 모드는 매분 "마운트 최상위/.sw_hangcheck"(4KB)를 만들었다 바로 지운다.
#     디렉터리 감시 앱이나 보안 에이전트(FIM/EDR)가 감지할 수 있다.
#     문제가 되면 PROBE_MODE="read" 또는 INCLUDED_MOUNTPOINTS로 대상을 좁힌다.
#   - write 모드의 동기 쓰기(dsync)는 저널 커밋을 1회 유발한다 (fsync 1회 수준).
#   - write 모드는 fsfreeze(백업 스냅샷) 중 0이 나올 수 있다 → 알람은 "N회 연속 위반"으로.
#   - NFS 등 네트워크 파일시스템은 확인하지 않는다 (ALLOWED_FSTYPES에 넣지 말 것 —
#     NFS는 장치 경로가 없어 read 모드가 동작하지 않고, write 모드는 공유 스토리지에 파일을 만든다)
#   - 재부팅 직후 첫 실행 전에는 /run이 비어 있어 node_textfile_scrape_error=1이 된다
#     (최대 1분). 같은 디렉터리의 다른 .prom 파일은 영향 없음 (확인함).
#   - 값의 의미가 이전 버전(0 정상/1 hang/2 실패)과 반대다.
#     이전 버전 기준으로 만든 알람("0이 아니면")이 있으면 "1 미만이면"으로 바꿔야 한다.
#
# [모드별 결과]
#                            write(기본)       read
#   디스크/스토리지 멈춤           0              0
#   fsfreeze                       0              1
#   read-only 전환                 0              1
#   파일 생성                  있음(즉시 삭제)    없음
#
# [설치]
#   1) TEXTFILE_DIR을 node_exporter --collector.textfile.directory 값으로 설정
#   2) cron (root):  * * * * * /usr/local/bin/sw_fs_hang_check.sh
#   3) 확인:  curl -s localhost:9100/metrics | grep custom_fs_hang_status
#   4) ServiceWatch Agent metric.json의 metricMetas에 custom_fs_hang_status 추가
#      (dimensions: mountpoint)
#
# [검증 환경] Rocky Linux 9.7 (SELinux Enforcing), node_exporter 1.8.2,
#   loop 장치 위 xfs/ext4 + dmsetup suspend --nolockfs(실제 I/O 멈춤)·fsfreeze·
#   read-only remount·동시 실행·PID 재사용·env -i(cron 환경) 시나리오.
#   실제 디스크 고장, 권한이 제한된(SELinux confined) node_exporter는 미검증.
# =============================================================================

# 숫자/문자 처리를 로케일과 무관하게 고정하고, cron의 최소 PATH에서도 명령을 찾도록 지정
export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin

# ----------------------------------------------------------------------------- 설정
TEXTFILE_DIR=""                         # node_exporter --collector.textfile.directory 값 (필수)
OUT_NAME="sw_fs_hang.prom"              # 출력 파일명 (textfile collector는 *.prom만 읽음)
ALLOWED_FSTYPES="xfs|ext4"              # 확인할 로컬 파일시스템 종류 (정규식). 네트워크 FS(nfs 등)는 넣지 않는다
EXCLUDED_MOUNTPOINTS="^(/boot/efi|/boot)$"   # 제외할 마운트포인트 (정규식)
INCLUDED_MOUNTPOINTS=""                 # 비우면 전체. 지정하면 이 정규식에 맞는 것만 (예: "^(/|/data)$")
PROBE_MODE="write"                      # 확인 방식
                                        #   write: 4KB 동기 쓰기 후 삭제
                                        #   read : 장치에서 4KB 직접 읽기 (파일 생성 없음)
PROBE_FILE=".sw_hangcheck"              # write 모드에서 마운트 최상위에 잠깐 만드는 파일명
WAIT_SEC=5                              # 이 시간 안에 끝나지 않으면 비정상(0)
STATE_DIR=/run/sw_fs_hang               # tmpfs(메모리) — 디스크가 멈춰도 결과를 쓸 수 있는 곳

# 결과 값 (Cloud Monitoring "Filesystem Hang Check"와 같은 정의)
STATUS_OK=1                             # 정상
STATUS_NG=0                             # 비정상 (hang / hang 지속 / 에러)

# TEXTFILE_DIR 미설정 시 아무것도 하지 않고 종료
[[ -n "$TEXTFILE_DIR" ]] || exit 1
mkdir -p "$STATE_DIR" || exit 1

# ----------------------------------------------------------------------------- 중복 실행 방지
# fd 9에 lock 파일을 열고 비차단(-n)으로 잠근다. 이미 다른 실행이 잡고 있으면 조용히 종료.
# 주의: 아래 probe 실행 시 "9>&-"로 이 fd를 닫아서 넘긴다.
#       멈춘 probe가 fd를 물고 있으면 lock이 풀리지 않아 이후 실행이 전부 막히기 때문.
exec 9>"$STATE_DIR/lock"
flock -n 9 || exit 0

# ----------------------------------------------------------------------------- 함수
# 프로세스 시작 시각(/proc/<pid>/stat 22번째 필드, 부팅 후 clock tick)을 출력한다.
# PID는 재사용될 수 있으므로 "PID + 시작 시각"이 같아야 같은 프로세스로 본다.
# 2번째 필드(comm)는 괄호 안에 공백이 들어갈 수 있어서, 마지막 ") " 뒤부터 잘라 센다.
#   → 잘라낸 뒤 1번째 = 원래 3번째 필드, 따라서 원래 22번째 = 20번째
proc_start() {
	local s
	s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1   # 프로세스가 없으면 실패(1) 반환
	s=${s##*) }                                         # 마지막 ") " 까지 제거
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
#   - ( ... ) &                   : 서브셸을 백그라운드로 실행. 멈추면 이 서브셸이 D 상태로 남는다
start_probe() {
	local key="$1" mp="$2" src="$3" rc="$STATE_DIR/$1.rc"
	rm -f "$rc"                                 # 이전 결과 제거 → rc 파일 존재 = 이번 probe 완료
	if [[ "$PROBE_MODE" == "read" ]]; then
		# read: 장치 맨 앞 4KB를 페이지 캐시를 거치지 않고(iflag=direct) 읽는다. 파일 생성 없음.
		( dd if="$src" of=/dev/null bs=4k count=1 iflag=direct; echo $? > "$rc.tmp" && mv -f "$rc.tmp" "$rc" ) </dev/null >/dev/null 2>&1 9>&- &
	else
		# write: 4KB를 디스크까지 동기 쓰기(oflag=dsync)한 뒤 바로 삭제한다.
		#   쓰기 실패(read-only, 공간 부족)면 dd가 0이 아닌 코드로 끝나 → 비정상(0)
		#   "&&" 이므로 dd가 실패하면 rm은 실행하지 않고 dd의 종료 코드가 rc에 남는다
		( dd if=/dev/zero of="$mp/$PROBE_FILE" bs=4k count=1 oflag=dsync && rm -f "$mp/$PROBE_FILE"
		  echo $? > "$rc.tmp" && mv -f "$rc.tmp" "$rc" ) </dev/null >/dev/null 2>&1 9>&- &
	fi
	# 방금 띄운 probe의 PID와 시작 시각 기록 (다음 실행에서 "아직 멈춰 있는지" 판단용)
	echo "$! $(proc_start $!)" > "$STATE_DIR/$key.pid"
}

# ----------------------------------------------------------------------------- 대상 선정 + probe 시작
# /proc/self/mountinfo 형식:
#   마운트ID 부모ID 주번호:부번호 root 마운트포인트 옵션 [선택필드...] - fstype 장치 슈퍼옵션
#   예) 98 1 253:2 / /data rw,relatime shared:50 - xfs /dev/mapper/vg-data rw,attr2
# 선정 규칙:
#   - fstype이 ALLOWED_FSTYPES에 맞는 것만 → 로컬 xfs/ext4 (nfs, tmpfs, overlay 등 제외)
#   - root($4)가 "/"인 것만 → bind mount(파일시스템의 하위 디렉터리를 다시 마운트한 것) 제외
#   - 같은 장치(주:부번호)는 처음 1개만 → 같은 디스크를 중복 확인하지 않음
#   - 공백 등이 들어간 경로는 \040처럼 이스케이프되어 지표 레이블이 깨지므로 제외
# 여기서는 mountinfo(커널 메모리 정보)만 읽으므로 디스크가 멈춰도 이 단계는 멈추지 않는다.
keys=(); mps=(); fstypes=(); waitkeys=()
while read -r majmin mp fstype src; do
	[[ "$mp" == *\\* ]] && continue
	[[ "$mp" =~ $EXCLUDED_MOUNTPOINTS ]] && continue
	[[ -n "$INCLUDED_MOUNTPOINTS" && ! "$mp" =~ $INCLUDED_MOUNTPOINTS ]] && continue
	key=${majmin/:/_}                       # 예: 253:0 → 253_0 (state 파일 이름으로 사용)
	keys+=("$key"); mps+=("$mp"); fstypes+=("$fstype")
	if ! probe_alive "$key"; then           # 이전 probe가 아직 멈춰 있으면 새로 띄우지 않음(→ 바로 0)
		start_probe "$key" "$mp" "$src"
		waitkeys+=("$key")                  # 이번에 새로 띄운 것만 결과를 기다린다
	fi
done < <(awk -v re="^(${ALLOWED_FSTYPES})$" '{
		for (i = 7; i <= NF; i++) if ($i == "-") break    # 선택 필드 개수가 가변이라 "-" 위치를 찾음
		if ($(i+1) !~ re || $4 != "/" || seen[$3]++) next  # fstype 불일치 / bind mount / 중복 장치 제외
		print $3, $5, $(i+1), $(i+2)                       # 주:부번호 마운트포인트 fstype 장치
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
		[[ "$(cat "$STATE_DIR/$key.rc")" == "0" ]] && status=$STATUS_OK || status=$STATUS_NG
		rm -f "$STATE_DIR/$key.pid"
	else
		status=$STATUS_NG
	fi
	echo "custom_fs_hang_status{mountpoint=\"${mps[$i]}\",fstype=\"${fstypes[$i]}\"} ${status}"
done
} > "$STATE_DIR/$OUT_NAME.tmp"
chmod 644 "$STATE_DIR/$OUT_NAME.tmp"        # node_exporter 계정이 읽을 수 있게
mv -f "$STATE_DIR/$OUT_NAME.tmp" "$STATE_DIR/$OUT_NAME"

# textfile 디렉터리에 tmpfs 결과 파일을 가리키는 심볼릭 링크를 둔다.
# 이미 링크면 건드리지 않는다 (매번 디스크에 쓰지 않기 위해 — 링크 확인은 캐시에서 응답).
# 이전 버전이 만든 일반 파일이 있으면 링크로 교체된다.
[[ -L "$TEXTFILE_DIR/$OUT_NAME" ]] || ln -sfn "$STATE_DIR/$OUT_NAME" "$TEXTFILE_DIR/$OUT_NAME"
