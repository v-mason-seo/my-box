#!/bin/bash
export LC_ALL=C

OUT=""
TMP="${OUT}.$$"
ALLOWED_FSTYPES="xfs|ext4"
EXCLUDED_MOUNTPOINTS="^(/boot/efi|/boot)$"

{
# 1. os, uptime
os_uptime_second=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)

# 2. cpu

# memory 
mem_total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
mem_avail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)

if [[ "$mem_total" =~ ^[0-9]+$ &&
		"$mem_avail" =~ ^[0-9]+$ &&
		"$mem_total" -gt 0 ]]; then
	mem_pct=$(awk -v total="$mem_total" -v avail="$mem_avail" 'BEGIN{printf "%.2f", (total - avail) / total * 100}')
else
	mem_pct=0
fi

# 4. filesystem
df_snapshot=$(timeout 5 df -PT 2>/dev/null)
if [[ -n "$df_snapshot" ]]; then
	echo "$df_snapshot" | tail -n +2 | while read -r device fstype size used avail pct mountpoint; do
		if [[ "$fstype" =~ ^(${ALLOWED_FSTYPES})$ && "$size" -gt 0 && ! "$mountpoint" =~ $EXCLUDED_MOUNTPOINTS ]]; then
			usage_pct=$(( (used * 100) / size))
			echo "custom_fs_usage_percent{mountpoint=\"${mountpoint}\",fstype=\"${fstype}\"} ${usage_pct}"
		fi
	done
fi

# 5. nfs 마운트 상태
grep -E '\s(nfs|nfs4)\s' /etc/fstab | grep -v '^\s*#' | grep -vE '(^|,)noauto(,|$)' | \
while read -r device mountpoint fstype options dump pass; do
	if timeout 3 stat "$mountpoint" > /dev/null 2>&1 && mountpoint -q "$mountpoint"; then
		echo "custom_nfs_mount_up{mountpoint=\"${mountpoint}\"} 1"
	else
		echo "custom_nfs_mount_up{mountpoint=\"${mountpoint}\"} 0"
	fi
done
} > "$TMP" 2>/dev/null

mv "$TMP" "$OUT"
chown node_exporter:node_exporter "$OUT" 2>/dev/null
