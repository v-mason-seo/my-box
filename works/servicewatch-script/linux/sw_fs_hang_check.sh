#!/bin/bash
# sw_fs_hang_check.sh   cron: * * * * *
export LC_ALL=C

OUT_DIR=""                                   # node_exporter textfile 디렉터리 (기존 스크립트 OUT과 같은 곳)
OUT="${OUT_DIR}/sw_fs_hang.prom"
TMP="${OUT}.$$"
ALLOWED_FSTYPES="xfs|ext4"
EXCLUDED_MOUNTPOINTS="^(/boot/efi|/boot)$"
WAIT_SEC=5
STATE_DIR=/run/sw_fs_hang
mkdir -p "$STATE_DIR"

# $1=mountpoint → 0 정상 / 1 hang / 2 쓰기 실패(read-only, 공간 부족 등)
probe() {
	local mp="$1" pidf pid i rc
	pidf="$STATE_DIR/$(echo "$mp" | tr '/' '_').pid"

	# 이전 probe가 아직 멈춰 있으면 → 여전히 hang
	if [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
		echo 1; return
	fi

	# 4KB를 디스크까지 동기 쓰기(dsync) — 페이지 캐시가 아닌 실제 I/O를 확인
	( dd if=/dev/zero of="$mp/.sw_hangcheck" bs=4k count=1 oflag=dsync && rm -f "$mp/.sw_hangcheck" ) >/dev/null 2>&1 &
	pid=$!
	echo "$pid" > "$pidf"

	for (( i=0; i<WAIT_SEC*10; i++ )); do
		if ! kill -0 "$pid" 2>/dev/null; then
			wait "$pid"; rc=$?
			rm -f "$pidf"
			(( rc == 0 )) && echo 0 || echo 2
			return
		fi
		sleep 0.1
	done
	echo 1    # 기다리지 않고 넘어감 (pid 파일은 남겨 다음 실행에서 재확인)
}

{
awk -v re="^(${ALLOWED_FSTYPES})$" '$3 ~ re {print $2, $3}' /proc/mounts | sort -u |
while read -r mountpoint fstype; do
	[[ "$mountpoint" =~ $EXCLUDED_MOUNTPOINTS ]] && continue
	echo "custom_fs_hang_status{mountpoint=\"${mountpoint}\",fstype=\"${fstype}\"} $(probe "$mountpoint")"
done
} > "$TMP" 2>/dev/null

mv "$TMP" "$OUT"
chown node_exporter:node_exporter "$OUT" 2>/dev/null
