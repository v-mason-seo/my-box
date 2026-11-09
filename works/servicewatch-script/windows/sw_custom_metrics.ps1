# C:\ServiceWatch\scripts\sw_custom_metrics.ps1
$ErrorActionPreference = 'SilentlyContinue'
$OutDir = 'C:\Program Files\windows_exporter\textfile_inputs'   # Windows Exporter 기본 textfile 경로
$Out    = Join-Path $OutDir 'sw_custom.prom'
$Tmp    = "$Out.$PID"                                            # .prom으로 끝나지 않게 → 쓰는 중엔 안 읽힘
$NetMounts = @()   # Linux의 fstab NFS 대응. 예: @('Z:\', '\\nas01\share'). 없으면 비워둠

$inv   = [Globalization.CultureInfo]::InvariantCulture
$lines = New-Object System.Collections.Generic.List[string]

# Memory Usage [Actual]  (FreePhysicalMemory = 사용 가능 메모리 → Linux MemAvailable과 같은 개념)
$os = Get-CimInstance Win32_OperatingSystem
if ($os -and $os.TotalVisibleMemorySize -gt 0) {
    $t = [double]$os.TotalVisibleMemorySize; $a = [double]$os.FreePhysicalMemory   # KB
    $lines.Add(('custom_mem_used_bytes {0}' -f [int64](($t - $a) * 1024)))
    $lines.Add(('custom_mem_usage_percent {0}' -f (($t - $a) / $t * 100).ToString('F2', $inv)))
}

# Filesystem Usage [Actual]  (DriveType=3 = 로컬 고정 디스크만. 네트워크 드라이브는 조회 안 하므로 hang 영향 없음)
Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Where-Object { $_.Size -gt 0 } | ForEach-Object {
    $used = [double]$_.Size - [double]$_.FreeSpace
    $lbl  = 'mountpoint="{0}",fstype="{1}"' -f $_.DeviceID, $_.FileSystem      # 예: C:, NTFS
    $lines.Add(('custom_fs_used_bytes{{{0}}} {1}' -f $lbl, [int64]$used))
    $lines.Add(('custom_fs_usage_percent{{{0}}} {1}' -f $lbl, ($used / $_.Size * 100).ToString('F2', $inv)))
}

# 네트워크 마운트 상태 (hang 대비: 별도 프로세스에서 확인하고 3초 넘으면 실패 처리)
foreach ($p in $NetMounts) {
    $job = Start-Job -ScriptBlock { param($x) Test-Path -LiteralPath $x } -ArgumentList $p
    $ok  = $false
    if (Wait-Job $job -Timeout 3) { $ok = [bool](Receive-Job $job) }
    Remove-Job $job -Force
    $lines.Add(('custom_nfs_mount_up{{mountpoint="{0}"}} {1}' -f $p.Replace('\','\\'), [int]$ok))
}

# UTF-8(BOM 없음) + LF로 쓰고 교체
[IO.File]::WriteAllText($Tmp, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
Move-Item -LiteralPath $Tmp -Destination $Out -Force
