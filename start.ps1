<#
==============================================================================
 绘职 AI — 后端启动器 / 看门狗          start.ps1
------------------------------------------------------------------------------
 解决的历史故障：后端曾被以「当前终端的子进程」方式启动，终端会话被回收时
 进程被一并杀掉，表现为「网站打不开 / 服务不可用」，而端口、资源、配置都正常。

 本脚本做三件事：
   1) 幂等启动：已有健康实例就直接复用，不重复起进程
   2) 清理残留：先干掉残留后端与占用端口的进程，避免绑定失败
   3) 自愈：-Watch 模式下定时体检，掉线自动拉起

 已知环境限制（实测）：
   · WMI 脱离式创建在此机器上被拦截（Win32_Process.Create 返回 0，但进程随即被杀）
   · 注册计划任务需要管理员权限，普通权限下 schtasks 返回 Access is denied
   因此本脚本用 Start-Process 启动。若要做到「重启后自动恢复」，
   请以管理员身份执行：
     schtasks /create /tn HuizhiAI-Backend /sc onlogon /rl LIMITED ^
       /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"D:\AI_vibecoding\Design\start.ps1\""

 用法：
   powershell -ExecutionPolicy Bypass -File start.ps1            # 确保在跑
   powershell -ExecutionPolicy Bypass -File start.ps1 -Force     # 强制重启
   powershell -ExecutionPolicy Bypass -File start.ps1 -Watch     # 前台看门狗
==============================================================================
#>
[CmdletBinding()]
param(
    [int]$Port = 8230,
    [switch]$Force,                  # 忽略已有实例，强制重启
    [switch]$Watch,                  # 以前台看门狗方式运行
    [int]$IntervalSec = 20,          # 看门狗检查间隔
    [int]$MaxFail = 2                # 连续失败几次后重启
)

$ErrorActionPreference = 'Continue'

$Root       = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ServerPath = Join-Path $Root 'server.ps1'
$HealthUrl  = "http://localhost:$Port/api/health"

function Get-Health {
    try {
        $r = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec 4
        if ($r.StatusCode -eq 200) { return ($r.Content | ConvertFrom-Json) }
    } catch { }
    return $null
}

# 用拼接构造关键字，避免匹配到调用方自身的命令行
function Get-OwnProcesses {
    $needle = 'server' + '.' + 'ps1'
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            [string]$_.CommandLine -like "*$Root*$needle*" -and $_.ProcessId -ne $PID
        }
}

function Stop-Stale {
    $killed = 0
    foreach ($p in Get-OwnProcesses) {
        Write-Host "  停止残留后端进程 PID $($p.ProcessId)"
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        $killed++
    }
    # 端口仍被别的进程占着也要清掉，否则新实例绑不上
    $owners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
              Select-Object -ExpandProperty OwningProcess -Unique
    foreach ($op in $owners) {
        if ($op -and $op -ne 0 -and $op -ne 4) {
            Write-Host "  停止占用端口 $Port 的进程 PID $op"
            Stop-Process -Id $op -Force -ErrorAction SilentlyContinue
            $killed++
        }
    }
    if ($killed -gt 0) { Start-Sleep -Seconds 2 }
    return $killed
}

function Start-Backend {
    if (-not (Test-Path $ServerPath)) {
        Write-Host "  找不到 server.ps1：$ServerPath" -ForegroundColor Red
        return $false
    }

    $logDir = Join-Path $Root 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    $out = Join-Path $logDir 'server.out.log'
    $err = Join-Path $logDir 'server.err.log'

    # 顺带把 stdout/stderr 落盘，日后进程静默退出可以从这里查证
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ServerPath`"") `
        -WorkingDirectory $Root -WindowStyle Hidden `
        -RedirectStandardOutput $out -RedirectStandardError $err
    return $true
}

function Wait-Healthy {
    param([int]$Seconds = 30)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 700
        $h = Get-Health
        if ($h) { return $h }
    }
    return $null
}

function Show-Status {
    param($Health)
    Write-Host "  地址   : http://localhost:$Port/"
    Write-Host "  版本   : v$($Health.version)"
    Write-Host "  已接入 : $($Health.providerCount) 个模型"
    if ($Health.configured) {
        Write-Host "  文本模型: $($Health.chat.model)" -ForegroundColor Gray
        Write-Host "  图像模型: $($Health.image.model)" -ForegroundColor Gray
    } else {
        Write-Host "  提示   : 还没有接入大模型，请打开 设置 页配置后再生成。" -ForegroundColor Yellow
    }
}

function Ensure-Running {
    if (-not $Force) {
        $h = Get-Health
        if ($h) {
            Write-Host "  ✓ 服务已在运行，无需重启" -ForegroundColor Green
            Show-Status $h
            return $true
        }
        Write-Host "  健康检查未通过，准备启动…"
    } else {
        Write-Host "  强制重启模式"
    }

    Stop-Stale | Out-Null

    if (-not (Start-Backend)) { return $false }

    $h = Wait-Healthy -Seconds 30
    if ($h) {
        Write-Host "  ✓ 后端已启动并通过健康检查" -ForegroundColor Green
        Show-Status $h
        return $true
    }

    Write-Host "  ✗ 启动后 30 秒内仍未通过健康检查" -ForegroundColor Red
    Write-Host "    请查看 logs\api-calls.log 定位原因" -ForegroundColor Red
    return $false
}

# ============================== 入口 ==============================

Write-Host ""
Write-Host "  绘职 AI · 后端启动器" -ForegroundColor Cyan
Write-Host "  ----------------------------------------"

if ($Watch) {
    Write-Host "  看门狗模式：每 $IntervalSec 秒体检一次，连续失败 $MaxFail 次即自动拉起" -ForegroundColor Cyan
    Write-Host "  按 Ctrl+C 退出看门狗（后端进程会继续运行）"
    Write-Host ""

    Ensure-Running | Out-Null

    $fails = 0
    while ($true) {
        Start-Sleep -Seconds $IntervalSec
        $stamp = (Get-Date).ToString('HH:mm:ss')
        $h = Get-Health
        if ($h) {
            if ($fails -gt 0) { Write-Host "  [$stamp] 已恢复" -ForegroundColor Green }
            $fails = 0
        } else {
            $fails++
            Write-Host "  [$stamp] 健康检查失败（第 $fails 次）" -ForegroundColor Yellow
            if ($fails -ge $MaxFail) {
                Write-Host "  [$stamp] 触发自动重启…" -ForegroundColor Yellow
                Stop-Stale | Out-Null
                if (Start-Backend) {
                    $h2 = Wait-Healthy -Seconds 30
                    if ($h2) {
                        Write-Host "  [$stamp] ✓ 已自动拉起" -ForegroundColor Green
                        Show-Status $h2
                    } else {
                        Write-Host "  [$stamp] ✗ 自动拉起失败，请看 logs\api-calls.log" -ForegroundColor Red
                    }
                }
                $fails = 0
            }
        }
    }
}

if (Ensure-Running) { exit 0 } else { exit 1 }