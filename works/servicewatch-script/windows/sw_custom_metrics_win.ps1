# =============================================================================
# C:\ServiceWatch\scripts\sw_custom_metrics_win.ps1   작업 스케줄러: SYSTEM, 1분 주기
# =============================================================================
#
# [무엇을 하나] ServiceWatch 사용자 정의 지표 3개를 Windows Exporter textfile 형식으로 출력
#   1. filesystem hang check   custom_fs_hang_status{mountpoint="C:",fstype="NTFS"} 1
#   2. memory usage [actual]   custom_mem_used_bytes / custom_mem_usage_percent
#   3. filesystem usage        custom_fs_used_bytes / custom_fs_usage_percent
#
# [hang check 값] Cloud Monitoring "Filesystem Hang Check"와 같은 정의
#   1 = 정상   : $WaitSec 안에 4KB 쓰기가 디스크까지 성공
#   0 = 비정상 : $WaitSec 안에 끝나지 않음 (hang)
#                / 이전 실행에서 띄운 확인이 아직 멈춰 있음 (hang 지속)
#                / 쓰기 에러 (읽기 전용, 공간 부족, 권한 등)
#                / 확인용 프로세스를 띄우지 못함
#   → 알람 조건: "값 < 1"을 N회 연속 위반 시
#   ※ 이전 버전(0 정상 / 1 hang / 2 실패)과 의미가 반대 — 기존 알람이 있으면 조건 변경 필요
#
# [동작 방식]
#   - 대상: 로컬 고정 디스크(DriveType=3)만. 네트워크 드라이브는 확인하지 않는다.
#   - 확인: 드라이브마다 별도 powershell.exe 프로세스를 띄워 "드라이브 최상위\.sw_hangcheck"에
#           4KB를 WriteThrough(캐시 우회)로 쓰고 Flush(디스크까지) 후 삭제한다.
#           디렉터리 조회/용량 조회는 캐시에서 응답하므로 hang이 드러나지 않기 때문.
#   - 기다리지 않음: I/O에서 멈춘 프로세스는 강제 종료가 안 될 수 있으므로,
#           메인 스크립트는 $WaitSec까지만 보고 넘어간다. 멈춘 프로세스는 그대로 두고
#           pid 파일로 기억해 두었다가 다음 실행에서 "아직 살아 있으면" 새로 띄우지 않고 0.
#           → hang이 길어져도 확인용 프로세스는 드라이브당 1개까지만 존재
#   - 동시 실행: 모든 드라이브의 probe를 먼저 띄우고, 메모리/용량을 수집한 뒤 결과를 본다.
#           → 드라이브가 여러 개여도 전체 대기는 최대 $WaitSec
#   - $WaitSec이 Linux(5초)보다 긴 이유: probe용 powershell.exe 기동 시간(1~3초)이 포함되기 때문
#
# [주의]
#   - 미검증 (작성 환경에 PowerShell 없음) — 테스트 서버에서
#     수동 실행 → .prom 확인 → curl.exe -s http://localhost:9182/metrics | findstr custom_
#   - 매분 드라이브 최상위에 4KB 파일을 만들었다 지우므로 보안 에이전트(FIM/EDR)가 감지할 수 있음
#   - 결과 파일은 C: 의 textfile 디렉터리에 쓴다. C: 자체가 멈추면 결과를 쓰지 못해
#     마지막 값이 남는다 (Linux판의 tmpfs 방식에 해당하는 수단이 Windows엔 기본으로 없음)
#     → ServiceWatch에서 "데이터 없음"도 함께 알람 처리 권장
#   - 작업 스케줄러 등록 시 -MultipleInstances IgnoreNew (register_task.ps1, 경로만 이 파일로 변경)
# =============================================================================

$ErrorActionPreference = 'SilentlyContinue'                        # 개별 오류로 스크립트가 멈추지 않게
$OutDir   = 'C:\Program Files\windows_exporter\textfile_inputs'   # Windows Exporter 기본 textfile 경로
$Out      = Join-Path $OutDir 'sw_custom.prom'
$Tmp      = "$Out.$PID"                                            # .prom으로 끝나지 않게 → 쓰는 중엔 안 읽힘
$StateDir = 'C:\ServiceWatch\state'                                # 드라이브별 pid 파일 저장 위치
$WaitSec  = 10                                                     # probe용 powershell 기동 시간 포함
$StatusOk = 1                                                      # 정상
$StatusNg = 0                                                      # 비정상
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

$inv   = [Globalization.CultureInfo]::InvariantCulture             # 소수점을 항상 "."으로 (로케일 무관)
$lines = New-Object System.Collections.Generic.List[string]        # 출력할 지표 줄 모음
$disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Where-Object { $_.Size -gt 0 })   # 로컬 고정 디스크

# -----------------------------------------------------------------------------
# 1. filesystem hang check (시작) — 모든 드라이브에 쓰기 probe를 동시에 띄움
# -----------------------------------------------------------------------------
# $probes[드라이브] 값:
#   'stuck'          → 이전 probe가 아직 멈춰 있음 (새로 띄우지 않음)
#   Process 개체      → 이번에 띄운 probe
#   $null            → probe를 띄우지 못함
$probes = @{}
$start  = Get-Date                                                 # 대기 마감 시각 계산 기준
foreach ($d in $disks) {
    $mp   = $d.DeviceID                                            # 예: C:
    $pidf = Join-Path $StateDir ($mp.TrimEnd(':') + '.pid')        # 예: C:\ServiceWatch\state\C.pid

    # 이전 probe가 아직 살아 있으면 → 여전히 hang
    # pid 파일 형식: "<pid> <시작시각 Ticks>"
    # PID는 재사용될 수 있으므로 PID와 시작 시각이 모두 같을 때만 같은 프로세스로 본다.
    if (Test-Path $pidf) {
        $saved = (Get-Content $pidf -TotalCount 1) -split ' '
        $prev  = Get-Process -Id ([int]$saved[0]) -ErrorAction SilentlyContinue
        if ($prev -and $saved.Count -ge 2 -and $prev.StartTime.Ticks -eq [int64]$saved[1]) {
            $probes[$mp] = 'stuck'; continue
        }
    }

    # probe 명령: 4KB를 캐시 거치지 않고(WriteThrough) 디스크까지 쓰기(Flush($true)) 후 삭제
    #   성공 → exit 0 / 예외(읽기 전용, 공간 부족 등) → exit 2
    #   (종료 코드는 내부 구분용. 출력 값은 아래 결과 단계에서 1/0 두 가지로만 바뀜)
    $f   = "$mp\.sw_hangcheck"
    $cmd = "try { `$fs = New-Object IO.FileStream('$f', [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough); " +
           "`$fs.Write((New-Object byte[] 4096), 0, 4096); `$fs.Flush(`$true); `$fs.Close(); Remove-Item -LiteralPath '$f' -Force; exit 0 } catch { exit 2 }"
    # -EncodedCommand: 명령을 UTF-16LE Base64로 넘겨 따옴표/특수문자 이스케이프 문제를 피함
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    # 별도 프로세스로 띄우고(-PassThru로 개체 받기) 기다리지 않음
    $p   = Start-Process powershell.exe -ArgumentList "-NoProfile -NonInteractive -EncodedCommand $enc" -WindowStyle Hidden -PassThru
    if ($p) {
        $null = $p.Handle                                          # 핸들을 잡아 둬야 나중에 ExitCode를 읽을 수 있음
        Set-Content -Path $pidf -Value ('{0} {1}' -f $p.Id, $p.StartTime.Ticks)
    }
    $probes[$mp] = $p
}

# -----------------------------------------------------------------------------
# 2. memory usage [actual]  (probe가 도는 동안 수집)
# -----------------------------------------------------------------------------
# FreePhysicalMemory = 사용 가능 메모리 (Linux MemAvailable과 같은 개념), 단위 KB
$os = Get-CimInstance Win32_OperatingSystem
if ($os -and $os.TotalVisibleMemorySize -gt 0) {
    $t = [double]$os.TotalVisibleMemorySize; $a = [double]$os.FreePhysicalMemory      # KB
    $lines.Add(('custom_mem_used_bytes {0}' -f [int64](($t - $a) * 1024)))
    $lines.Add(('custom_mem_usage_percent {0}' -f (($t - $a) / $t * 100).ToString('F2', $inv)))
}

# -----------------------------------------------------------------------------
# 3. filesystem usage [actual]  (Win32_LogicalDisk 값 — 캐시된 정보라 hang 영향 없음)
# -----------------------------------------------------------------------------
foreach ($d in $disks) {
    $used = [double]$d.Size - [double]$d.FreeSpace
    $lbl  = 'mountpoint="{0}",fstype="{1}"' -f $d.DeviceID, $d.FileSystem      # 예: C:, NTFS
    $lines.Add(('custom_fs_used_bytes{{{0}}} {1}' -f $lbl, [int64]$used))
    $lines.Add(('custom_fs_usage_percent{{{0}}} {1}' -f $lbl, ($used / $d.Size * 100).ToString('F2', $inv)))
}

# -----------------------------------------------------------------------------
# 1. filesystem hang check (결과) — 최대 $WaitSec까지만 기다리고 1(정상)/0(비정상) 판정
# -----------------------------------------------------------------------------
#   'stuck'                  → 0, pid 파일 유지
#   $null (실행 실패)         → 0
#   마감 전 종료 + ExitCode 0 → 1, pid 파일 삭제
#   마감 전 종료 + 그 외      → 0, pid 파일 삭제
#   마감까지 안 끝남          → 0, pid 파일 유지 (다음 실행에서 'stuck' 판정에 사용)
$deadline = $start.AddSeconds($WaitSec)
foreach ($d in $disks) {
    $mp = $d.DeviceID; $p = $probes[$mp]
    if ($p -eq 'stuck')   { $status = $StatusNg }
    elseif ($null -eq $p) { $status = $StatusNg }
    else {
        # 0.1초 간격으로 종료 여부 확인. 드라이브들이 같은 마감 시각을 공유하므로 전체 대기는 최대 $WaitSec
        while (-not $p.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
        if ($p.HasExited) {
            $status = if ($p.ExitCode -eq 0) { $StatusOk } else { $StatusNg }
            Remove-Item (Join-Path $StateDir ($mp.TrimEnd(':') + '.pid')) -Force
        } else { $status = $StatusNg }
    }
    $lines.Add(('custom_fs_hang_status{{mountpoint="{0}",fstype="{1}"}} {2}' -f $mp, $d.FileSystem, $status))
}

# -----------------------------------------------------------------------------
# 출력 — UTF-8(BOM 없음) + LF로 임시 파일에 쓰고 교체
# -----------------------------------------------------------------------------
# PowerShell 5.1의 Out-File -Encoding utf8은 BOM을 붙여 Windows Exporter가 파싱에 실패할 수 있음
# 임시 파일 → Move-Item으로 교체해 Exporter가 반쯤 쓰인 파일을 읽지 않게 함
[IO.File]::WriteAllText($Tmp, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
Move-Item -LiteralPath $Tmp -Destination $Out -Force
