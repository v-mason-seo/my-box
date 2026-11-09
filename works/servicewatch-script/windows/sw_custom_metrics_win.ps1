# C:\ServiceWatch\scripts\sw_custom_metrics_win.ps1   작업 스케줄러: 1분 주기
# 1. filesystem hang check  2. memory usage [actual]  3. filesystem usage [actual]
$ErrorActionPreference = 'SilentlyContinue'
$OutDir   = 'C:\Program Files\windows_exporter\textfile_inputs'   # Windows Exporter 기본 textfile 경로
$Out      = Join-Path $OutDir 'sw_custom.prom'
$Tmp      = "$Out.$PID"                                            # .prom으로 끝나지 않게
$StateDir = 'C:\ServiceWatch\state'
$WaitSec  = 10                                                     # probe용 powershell 기동 시간 포함
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

$inv   = [Globalization.CultureInfo]::InvariantCulture
$lines = New-Object System.Collections.Generic.List[string]
$disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Where-Object { $_.Size -gt 0 })   # 로컬 고정 디스크

# 1. filesystem hang check (시작) — 모든 드라이브에 쓰기 probe를 동시에 띄움
$probes = @{}
$start  = Get-Date
foreach ($d in $disks) {
    $mp   = $d.DeviceID                                            # 예: C:
    $pidf = Join-Path $StateDir ($mp.TrimEnd(':') + '.pid')

    # 이전 probe가 아직 살아 있으면 → 여전히 hang
    $prev = $null
    if (Test-Path $pidf) { $prev = Get-Process -Id ([int](Get-Content $pidf)) -ErrorAction SilentlyContinue }
    if ($prev -and $prev.ProcessName -eq 'powershell') { $probes[$mp] = 'stuck'; continue }

    # 4KB를 캐시 거치지 않고 디스크까지 쓰기(WriteThrough + Flush) → 성공 0 / 실패 2
    $f   = "$mp\.sw_hangcheck"
    $cmd = "try { `$fs = New-Object IO.FileStream('$f', [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough); " +
           "`$fs.Write((New-Object byte[] 4096), 0, 4096); `$fs.Flush(`$true); `$fs.Close(); Remove-Item -LiteralPath '$f' -Force; exit 0 } catch { exit 2 }"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $p   = Start-Process powershell.exe -ArgumentList "-NoProfile -NonInteractive -EncodedCommand $enc" -WindowStyle Hidden -PassThru
    if ($p) {
        $null = $p.Handle                                          # ExitCode를 나중에 읽으려면 필요
        Set-Content -Path $pidf -Value $p.Id
    }
    $probes[$mp] = $p
}

# 2. memory usage [actual]  (FreePhysicalMemory = 사용 가능 메모리, Linux MemAvailable과 같은 개념)
$os = Get-CimInstance Win32_OperatingSystem
if ($os -and $os.TotalVisibleMemorySize -gt 0) {
    $t = [double]$os.TotalVisibleMemorySize; $a = [double]$os.FreePhysicalMemory      # KB
    $lines.Add(('custom_mem_used_bytes {0}' -f [int64](($t - $a) * 1024)))
    $lines.Add(('custom_mem_usage_percent {0}' -f (($t - $a) / $t * 100).ToString('F2', $inv)))
}

# 3. filesystem usage [actual]
foreach ($d in $disks) {
    $used = [double]$d.Size - [double]$d.FreeSpace
    $lbl  = 'mountpoint="{0}",fstype="{1}"' -f $d.DeviceID, $d.FileSystem
    $lines.Add(('custom_fs_used_bytes{{{0}}} {1}' -f $lbl, [int64]$used))
    $lines.Add(('custom_fs_usage_percent{{{0}}} {1}' -f $lbl, ($used / $d.Size * 100).ToString('F2', $inv)))
}

# 1. filesystem hang check (결과) — 최대 $WaitSec까지만 기다리고, 안 끝나면 hang(1)으로 기록
$deadline = $start.AddSeconds($WaitSec)
foreach ($d in $disks) {
    $mp = $d.DeviceID; $p = $probes[$mp]
    if ($p -eq 'stuck')   { $status = 1 }
    elseif ($null -eq $p) { $status = 2 }                          # probe 실행 자체 실패
    else {
        while (-not $p.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
        if ($p.HasExited) {
            $status = if ($p.ExitCode -eq 0) { 0 } else { 2 }
            Remove-Item (Join-Path $StateDir ($mp.TrimEnd(':') + '.pid')) -Force
        } else { $status = 1 }                                     # pid 파일은 남겨 다음 실행에서 재확인
    }
    $lines.Add(('custom_fs_hang_status{{mountpoint="{0}",fstype="{1}"}} {2}' -f $mp, $d.FileSystem, $status))
}

# UTF-8(BOM 없음) + LF로 쓰고 교체
[IO.File]::WriteAllText($Tmp, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
Move-Item -LiteralPath $Tmp -Destination $Out -Force
