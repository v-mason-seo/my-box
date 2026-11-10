#!/bin/bash
# =============================================================================
# sw_fs_hang_check_v3_test.sh — v3 테스트판 (단계별 로그)
#
#   sw_fs_hang_check_v3.sh와 판정 로직은 같고, 단계마다 로그를 남긴다. VM에서 직접 돌려보는 용도.
#   지표 : custom_fs_hang_status{mountpoint,fstype}  1 정상 / 0 비정상(hang, I/O 에러, 이전 읽기 멈춤)
#   방식 : 장치 맨 앞 4KB를 O_DIRECT로 읽기만 한다 (디스크에 쓰지 않음). 결과는 /run(tmpfs)
#
#   로그 : 실행한 위치(현재 디렉터리)/sw_fs_hang_check_v3_test.log 에 이어 쓴다.
#          LOG_FILE=/경로/파일 로 바꿀 수 있다.
#          ※ 멈추게 할 디스크 위에서 실행하면 로그 쓰기도 같이 멈춘다 → 테스트 대상이 아닌 곳에서 실행
#
#   설정 : 아래 기본값을 쓰고, 환경변수로 덮어쓸 수 있다.
#          예) WAIT_SEC=2 INCLUDED_MOUNTPOINTS='^/data$' ./sw_fs_hang_check_v3_test.sh
#          TEXTFILE_DIR이 비어 있으면 node_exporter 연결(7단계)만 건너뛴다 (v3 원본은 에러로 종료).
# =============================================================================

export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 022

# ----------------------------------------------------------------------------- 설정
DEF_EXCLUDED='^(/boot/efi|/boot)$|^/var/lib/kubelet/'

TEXTFILE_DIR=${TEXTFILE_DIR-}                          # node_exporter textfile 디렉터리 (비우면 7단계 건너뜀)
OUT_NAME=${OUT_NAME:-sw_fs_hang.prom}
ALLOWED_FSTYPES=${ALLOWED_FSTYPES:-xfs|ext4}           # 확인할 fstype (정규식)
EXCLUDED_MOUNTPOINTS=${EXCLUDED_MOUNTPOINTS-$DEF_EXCLUDED}
INCLUDED_MOUNTPOINTS=${INCLUDED_MOUNTPOINTS-}          # 비우면 전체
WAIT_SEC=${WAIT_SEC:-5}                                # 이 안에 읽기가 안 끝나면 0
LOCK_WAIT_SEC=${LOCK_WAIT_SEC:-10}                     # 이전 실행이 이만큼 안 끝나면 "스크립트 멈춤" → 전부 0
STATE_DIR=${STATE_DIR:-/run/sw_fs_hang}                # tmpfs

DD_OPTS="of=/dev/null bs=4k count=1 iflag=direct"      # 멈춘 dd를 pgrep으로 찾을 때도 이 문자열을 씀
STATUS_OK=1
STATUS_NG=0
TEXTFILE_DIR=${TEXTFILE_DIR%/}
RESULT_FILE="$STATE_DIR/$OUT_NAME"

# ----------------------------------------------------------------------------- 로그
SCRIPT_NAME=${0##*/}
LOG_FILE=${LOG_FILE:-$PWD/${SCRIPT_NAME%.sh}.log}
exec 8>>"$LOG_FILE" || { echo "$SCRIPT_NAME: cannot open log file $LOG_FILE" >&2; exit 1; }
cd / || exit 1                                         # 백그라운드 dd가 실행 위치를 붙잡지 않게

RUN_T0=${EPOCHREALTIME/./}

ts() {      # 현재 시각 HH:MM:SS.mmm
	local us=${EPOCHREALTIME/./}
	printf '%(%H:%M:%S)T.%03d' "${us:0:${#us}-6}" "$(( 10#${us:${#us}-6} / 1000 ))"
}
since() {   # $1(마이크로초)부터 지난 시간 → 12ms / 1.23s
	local ms=$(( (${EPOCHREALTIME/./} - $1) / 1000 ))
	if (( ms < 1000 )); then echo "${ms}ms"; else printf '%d.%02ds' $(( ms / 1000 )) $(( ms % 1000 / 10 )); fi
}
log()      { printf '%s\n' "$*" >&8; }
step()     { STEP_T0=${EPOCHREALTIME/./}; log "[$(ts)] STEP $*"; }
item()     { log "    $*"; }
step_end() { log "  => $*  ($(since "$STEP_T0"))"; log ""; }
end_run() { # $1 종료 코드, $2 요약
	log "[$(ts)] END  $2  (exit $1, 총 $(since "$RUN_T0"))"
	log ""
	log ""
	[[ -t 1 ]] && echo "$SCRIPT_NAME: $2 (exit $1) — log: $LOG_FILE"
	exit "$1"
}
fail() {    # 단계 실패 → 로그 + stderr(cron 메일) 후 종료
	item "[ERR] $*"
	step_end "실패"
	echo "$SCRIPT_NAME: $*" >&2
	end_run 1 "실패: $*"
}
dd_msg() {  # dd stderr 파일 → 에러 줄(있으면), 없으면 마지막 줄("... copied, 0.0004 s, 9.9 MB/s")
	local line last="" err=""
	[[ -s "$1" ]] || return
	while IFS= read -r line; do
		[[ -z "$err" && "$line" == dd:* ]] && err=$line
		last=$line
	done < "$1"
	echo "${err:-$last}"
}

log "################################################################################"
log "# RUN  $(printf '%(%Y-%m-%d %H:%M:%S)T' -1)   host=$HOSTNAME   pid=$$   kernel=$(uname -r)"
log "#      WAIT_SEC=$WAIT_SEC  LOCK_WAIT_SEC=$LOCK_WAIT_SEC  STATE_DIR=$STATE_DIR  TEXTFILE_DIR=${TEXTFILE_DIR:-(없음)}"
log "#      FSTYPES=$ALLOWED_FSTYPES  EXCLUDED=${EXCLUDED_MOUNTPOINTS:-(없음)}  INCLUDED=${INCLUDED_MOUNTPOINTS:-(전체)}"
log "################################################################################"
log ""

# ----------------------------------------------------------------------------- 1. 사전 확인
step "1/7 사전 확인"
(( EUID == 0 )) || fail "root가 아님 (uid=$EUID)"
item "user      : root"

# "/" 의 fstype이 overlay 등이면 컨테이너 안 → 호스트 마운트가 안 보이므로 중단
root_fstype=$(awk '$5 == "/" { for (i = 7; i <= NF; i++) if ($i == "-") { fs = $(i+1); break } }
                   END { print fs }' /proc/self/mountinfo)
case "$root_fstype" in
	overlay|aufs|fuse.*) fail "컨테이너 안에서 실행됨 (/ fstype=$root_fstype). 호스트에서 또는 nsenter -t 1 -m 으로 실행" ;;
esac
item "/ fstype  : $root_fstype (호스트)"

mkdir -p "$STATE_DIR" || fail "$STATE_DIR 생성 실패"
chmod 755 "$STATE_DIR"
item "STATE_DIR : $STATE_DIR 준비됨"
step_end "OK"

# ----------------------------------------------------------------------------- 2. 중복 실행 방지
# 못 잡으면 이전 실행이 멈춘 것 → 옛 "정상" 값이 남지 않게 결과의 1을 전부 0으로 바꾸고 종료
step "2/7 중복 실행 방지 (flock, 최대 ${LOCK_WAIT_SEC}s 대기)"
exec 9>"$STATE_DIR/lock"
if flock -w "$LOCK_WAIT_SEC" 9; then
	step_end "OK  lock 획득"
else
	item "[NG] ${LOCK_WAIT_SEC}s 안에 lock을 못 잡음 → 이전 실행이 멈춘 것으로 판단"
	if [[ -f "$RESULT_FILE" ]]; then
		sed "s/ ${STATUS_OK}\$/ ${STATUS_NG}/" "$RESULT_FILE" > "$RESULT_FILE.stuck.tmp" &&
			mv -f "$RESULT_FILE.stuck.tmp" "$RESULT_FILE"
		item "결과 파일의 1을 전부 0으로 바꿈: $RESULT_FILE"
		while IFS= read -r line; do item "  $line"; done < "$RESULT_FILE"
	else
		item "결과 파일 없음 → 바꿀 것 없음"
	fi
	step_end "중단"
	echo "$SCRIPT_NAME: previous run still holds the lock after ${LOCK_WAIT_SEC}s (stuck?). All results set to ${STATUS_NG}." >&2
	end_run 1 "이전 실행 멈춤 의심 — 결과 전부 0"
fi

# ----------------------------------------------------------------------------- 3. 대상 선정
# mountinfo: 마운트ID 부모ID 주:부 root 마운트포인트 옵션 [선택필드...] - fstype 장치 슈퍼블록옵션
# awk는 ALLOWED_FSTYPES만 골라 "주:부 마운트포인트 fstype 장치 root" 로 넘긴다. 나머지 거르기는 while에서.
step "3/7 대상 선정 (/proc/self/mountinfo, fstype=$ALLOWED_FSTYPES)"
declare -A seen_dev seen_mp
mps=(); fstypes=(); devs=(); keys=()
n_skip=0
while read -r majmin mp fstype src root; do
	reason=""
	if   [[ "$root" != "/" ]];                                                  then reason="bind mount (root=$root)"
	elif [[ "$mp" == *\\* || "$mp" == *\"* ]];                                  then reason="경로에 공백/따옴표 (레이블 깨짐)"
	elif [[ -n "$EXCLUDED_MOUNTPOINTS" && "$mp" =~ $EXCLUDED_MOUNTPOINTS ]];    then reason="EXCLUDED에 해당"
	elif [[ -n "$INCLUDED_MOUNTPOINTS" && ! "$mp" =~ $INCLUDED_MOUNTPOINTS ]];  then reason="INCLUDED에 없음"
	elif [[ -n "${seen_dev[$majmin]}" ]];                                       then reason="같은 장치 (${seen_dev[$majmin]}에서 확인)"
	elif [[ -n "${seen_mp[$mp]}" ]];                                            then reason="같은 경로에 겹쳐 마운트됨"
	fi
	if [[ -n "$reason" ]]; then
		item "$(printf '[제외] %-20s %-5s %-8s %s' "$mp" "$fstype" "$majmin" "$reason")"
		(( n_skip++ ))
		continue
	fi
	seen_dev[$majmin]=$mp
	seen_mp[$mp]=1

	dev=$src                                            # /dev/root 처럼 없는 이름일 수 있어
	[[ -b "/dev/block/$majmin" ]] && dev="/dev/block/$majmin"   # udev 링크를 우선 사용

	mps+=("$mp"); fstypes+=("$fstype"); devs+=("$dev"); keys+=("${majmin/:/_}")
	item "$(printf '[대상] %-20s %-5s %-8s %s' "$mp" "$fstype" "$majmin" "$dev")"
done < <(awk -v re="^(${ALLOWED_FSTYPES})$" '{
		for (i = 7; i <= NF; i++) if ($i == "-") break
		if ($(i+1) ~ re) print $3, $5, $(i+1), $(i+2), $4
	}' /proc/self/mountinfo)
if (( ${#keys[@]} == 0 )); then step_end "대상 없음 (제외 ${n_skip}개) — 빈 결과 파일을 쓴다"
else                             step_end "대상 ${#keys[@]}개 / 제외 ${n_skip}개"
fi

# ----------------------------------------------------------------------------- 4. 읽기 시작
# 이 장치를 읽는 dd가 아직 떠 있으면 = 이전 읽기가 멈춰 있음(STUCK) → 새로 띄우지 않는다 (장치당 최대 1개)
# 아니면 백그라운드로 4KB 읽기. 끝나면 종료 코드를 <key>.rc, dd 출력을 <key>.err 에 남긴다 (둘 다 tmpfs)
step "4/7 읽기 시작 (dd 4KB, O_DIRECT, 백그라운드)"
states=()
n_probe=0
n_stuck=0
for i in "${!keys[@]}"; do
	dev=${devs[$i]}
	key=${keys[$i]}
	old_pid=$(pgrep -o -f -x "dd if=$dev $DD_OPTS")
	if [[ -n "$old_pid" ]]; then
		states+=("stuck")
		(( n_stuck++ ))
		item "$(printf '[STUCK] %-20s 이전 dd가 아직 실행 중 (pid %s, 경과 %s) → 새로 안 띄움' \
			"${mps[$i]}" "$old_pid" "$(ps -o etime= -p "$old_pid" | tr -d ' ')")"
	else
		rm -f "$STATE_DIR/$key.rc" "$STATE_DIR/$key.err"
		# shellcheck disable=SC2086  # DD_OPTS는 옵션 여러 개로 나눠 넘겨야 해서 따옴표 없음
		( dd if="$dev" $DD_OPTS 2>"$STATE_DIR/$key.err"
		  echo $? > "$STATE_DIR/$key.rc.tmp" && mv -f "$STATE_DIR/$key.rc.tmp" "$STATE_DIR/$key.rc"
		) </dev/null >/dev/null 2>&1 8>&- 9>&- &        # 로그·lock fd를 넘기지 않음
		states+=("probe")
		(( n_probe++ ))
		item "$(printf '[START] %-20s dd if=%s' "${mps[$i]}" "$dev")"
	fi
done
step_end "새로 시작 ${n_probe}개 / 이전 멈춤 ${n_stuck}개"

# ----------------------------------------------------------------------------- 5. 결과 대기
step "5/7 결과 대기 (최대 ${WAIT_SEC}s, 0.1s 간격 확인)"
declare -A finished
for (( t = 0; t < WAIT_SEC * 10; t++ )); do
	pending=0
	for i in "${!keys[@]}"; do
		[[ "${states[$i]}" == probe && -z "${finished[$i]}" ]] || continue
		if [[ -f "$STATE_DIR/${keys[$i]}.rc" ]]; then
			finished[$i]=1
			item "$(printf '[DONE]  %-20s ~%s 에 끝남' "${mps[$i]}" "$(since "$STEP_T0")")"
		else
			pending=1
		fi
	done
	(( pending == 0 )) && break
	sleep 0.1
done
n_late=0
for i in "${!keys[@]}"; do
	if [[ "${states[$i]}" == probe && -z "${finished[$i]}" ]]; then
		item "$(printf '[LATE]  %-20s %ss 안에 안 끝남' "${mps[$i]}" "$WAIT_SEC")"
		(( n_late++ ))
	fi
done
if   (( n_probe == 0 )); then step_end "기다릴 것 없음"
elif (( n_late  >  0 )); then step_end "시간 초과 ${n_late}개 / 완료 $(( n_probe - n_late ))개"
else                          step_end "모두 완료"
fi

# ----------------------------------------------------------------------------- 6. 판정 + 결과 기록
#   READ OK  : rc=0              → 1
#   IO ERROR : rc≠0              → 0
#   HANG     : WAIT_SEC 안에 안 끝남 → 0 (dd는 남아 있다가 다음 실행에서 STUCK)
#   STUCK    : 이전 읽기가 아직 멈춤 → 0
step "6/7 판정 + 결과 기록"
lines=()
n_ok=0
n_ng=0
for i in "${!keys[@]}"; do
	status=$STATUS_NG
	rc_file="$STATE_DIR/${keys[$i]}.rc"
	if [[ "${states[$i]}" == stuck ]]; then
		kind="STUCK";    why="이전 읽기가 아직 멈춰 있음"
	elif [[ ! -f "$rc_file" ]]; then
		kind="HANG";     why="${WAIT_SEC}s 안에 안 끝남 (dd는 남아 다음 실행에서 STUCK)"
	else
		rc=""
		read -r rc < "$rc_file"
		msg=$(dd_msg "$STATE_DIR/${keys[$i]}.err")
		if [[ "$rc" == "0" ]]; then
			status=$STATUS_OK
			kind="READ OK";  why="${msg#*copied, }"
		else
			kind="IO ERROR"; why="rc=$rc  ${msg}"
		fi
	fi
	if (( status == STATUS_OK )); then tag="[OK]"; (( n_ok++ )); else tag="[NG]"; (( n_ng++ )); fi
	item "$(printf '%s %-20s = %s  %-8s  %s' "$tag" "${mps[$i]}" "$status" "$kind" "$why")"
	lines+=("custom_fs_hang_status{mountpoint=\"${mps[$i]}\",fstype=\"${fstypes[$i]}\"} ${status}")
done
{ for l in "${lines[@]}"; do echo "$l"; done; } > "$RESULT_FILE.tmp" &&
	mv -f "$RESULT_FILE.tmp" "$RESULT_FILE"            # tmp에 쓰고 mv → 반쯤 쓰인 파일을 읽지 않게
item "기록: $RESULT_FILE (${#lines[@]}줄)"
step_end "정상 ${n_ok} / 비정상 ${n_ng}"

# ----------------------------------------------------------------------------- 7. textfile 디렉터리 연결
# textfile 디렉터리에 tmpfs 결과 파일을 가리키는 링크를 둔다. 이미 맞으면 건드리지 않음 (디스크 쓰기 최초 1회)
step "7/7 textfile 디렉터리 연결"
if [[ -z "$TEXTFILE_DIR" ]]; then
	step_end "건너뜀 (TEXTFILE_DIR 비어 있음)"
elif [[ "$TEXTFILE_DIR" == "$STATE_DIR" ]]; then
	step_end "건너뜀 (TEXTFILE_DIR = STATE_DIR, node_exporter가 직접 읽음)"
else
	link="$TEXTFILE_DIR/$OUT_NAME"
	item "$link -> $RESULT_FILE"
	if [[ -L "$link" && "$(readlink "$link")" == "$RESULT_FILE" ]]; then
		step_end "이미 연결됨 (변경 없음)"
	elif err=$(ln -sfn "$RESULT_FILE" "$link" 2>&1); then
		step_end "링크 만듦"
	else
		item "[ERR] $err"
		echo "$SCRIPT_NAME: cannot create link $link (does TEXTFILE_DIR exist?)" >&2
		step_end "실패 (TEXTFILE_DIR이 있는지 확인)"
	fi
fi

end_run 0 "정상 ${n_ok} / 비정상 ${n_ng}"
