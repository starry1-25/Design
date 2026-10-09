# ==============================================================================
#  HuiZhi AI  (HuiZhi)  -  Role-based Visual Agent  /  local backend
#  Runtime : Windows PowerShell 5.1 + System.Net.HttpListener
#  Purpose : static site host + Agnes AI gateway
#            (chat planning, image generation, multi-turn refinement,
#             history persistence)
#
#  Model service is fixed to Agnes AI (OpenAI-compatible). There is no
#  user-facing model configuration: credentials live in .env only, which is
#  git-ignored, so the key is never published with the repository.
#
#  NOTE: This file is intentionally ASCII-only. All Chinese prompt engineering
#        lives in data/roles.json and is read explicitly as UTF-8.
#        PowerShell 5.1 parses BOM-less UTF-8 scripts as GBK -> mojibake.
# ==============================================================================

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- paths & dirs
$Root       = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$DataDir    = Join-Path $Root 'data'
$ImgDir     = Join-Path $DataDir 'images'
$LogDir     = Join-Path $Root 'logs'
$RolesFile  = Join-Path $DataDir 'roles.json'
$RecordFile = Join-Path $DataDir 'records.json'
$EnvFile    = Join-Path $Root '.env'

foreach ($d in @($DataDir, $ImgDir, $LogDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------- logging
function Write-Log {
    param([string]$Message)
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$stamp] $Message"
    try { Add-Content -Path (Join-Path $LogDir 'api-calls.log') -Value $line -Encoding UTF8 } catch {}
    Write-Host $line
}

# --------------------------------------------------------------------- env load
function Load-EnvFile {
    param([string]$Path)
    $map = @{}
    if (-not (Test-Path $Path)) { return $map }
    foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $t.Substring(0, $i).Trim()
        $v = $t.Substring($i + 1).Trim().Trim('"').Trim("'")
        $map[$k] = $v
    }
    return $map
}

$Env = Load-EnvFile -Path $EnvFile

function Get-Cfg {
    param([string]$Key, [string]$Default)
    if ($Env.ContainsKey($Key) -and $Env[$Key] -ne '') { return [string]$Env[$Key] }
    $fromProc = [Environment]::GetEnvironmentVariable($Key)
    if ($fromProc) { return [string]$fromProc }
    return $Default
}

# ------------------------------------------------------------ Agnes AI config
# Credentials come from .env (git-ignored) and are never written into source.
$script:ApiKey     = Get-Cfg 'AGNES_API_KEY' ''
$script:BaseUrl    = Get-Cfg 'AGNES_BASE_URL' 'https://api.agnes-ai.cn/v1'
$script:TextModel  = Get-Cfg 'AGNES_TEXT_MODEL' 'agnes-3.0-flash'
$script:ImageModel = Get-Cfg 'AGNES_IMAGE_MODEL' 'agnes-image-2.5-flash'
$script:ImageModelFallback = Get-Cfg 'AGNES_IMAGE_MODEL_FALLBACK' 'agnes-image-2.1-flash'
$script:MaxTokens  = [int](Get-Cfg 'AGNES_MAX_TOKENS' '4096')

$script:Port      = [int](Get-Cfg 'PORT' '8230')
$script:BindAll   = (Get-Cfg 'BIND_ALL' 'false') -eq 'true'

# ratio -> upstream pixel size (verified: upstream honours the aspect exactly)
$script:RatioSizes = @{
    '1:1'  = '1024x1024'
    '16:9' = '1280x720'
    '9:16' = '720x1280'
    '4:3'  = '1024x768'
}
$script:Ratios = @('1:1', '16:9', '9:16', '4:3')

# baseUrl normalization: strip trailing slash before appending the path
function Normalize-BaseUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return '' }
    return $Url.Trim().TrimEnd('/')
}

# ------------------------------------------------------------------ json helpers
function ConvertTo-JsonBytes {
    param($Object)
    $json = $Object | ConvertTo-Json -Depth 24 -Compress
    return [Text.Encoding]::UTF8.GetBytes($json)
}

function Parse-LlmJson {
    param([string]$Text)
    if (-not $Text) { return $null }
    $t = $Text.Trim()
    if ($t.StartsWith('```')) {
        $t = $t -replace '^```[a-zA-Z]*\s*', ''
        $t = $t -replace '```\s*$', ''
        $t = $t.Trim()
    }
    $i = $t.IndexOf('{')
    $j = $t.LastIndexOf('}')
    if ($i -ge 0 -and $j -gt $i) { $t = $t.Substring($i, $j - $i + 1) }
    try { return ($t | ConvertFrom-Json) } catch { return $null }
}

# ------------------------------------------------------------------- role config
function Get-RoleConfig {
    if (-not (Test-Path $RolesFile)) { throw "roles.json not found at $RolesFile" }
    $raw = [IO.File]::ReadAllText($RolesFile, [Text.Encoding]::UTF8)
    return ($raw | ConvertFrom-Json)
}

function Get-Role {
    param($Config, [string]$RoleId)
    foreach ($r in $Config.roles) { if ($r.id -eq $RoleId) { return $r } }
    return $Config.roles[0]
}

# --------------------------------------------------------------------- ai calls
# Agnes AI request layer (OpenAI-compatible): auth header, retry with backoff
# and error classification live here so the stages below stay declarative.
function Invoke-AgnesPost {
    param(
        [string]$Path,
        [hashtable]$Payload,
        [int]$MaxAttempts = 3,
        [int]$TimeoutSec = 120
    )
    $root = Normalize-BaseUrl -Url $script:BaseUrl
    if ([string]::IsNullOrWhiteSpace($root)) {
        return @{ ok = $false; status = 0; body = ''; ms = 0; attempts = 0; msg = 'no_base_url' }
    }
    $url   = $root + $Path
    $bytes = ConvertTo-JsonBytes -Object $Payload
    $backoff = @(5, 10)
    $lastStatus = 0
    $lastMsg = ''

    for ($i = 1; $i -le $MaxAttempts; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $resp = $null
        try {
            $req = [Net.HttpWebRequest]::Create($url)
            $req.Method           = 'POST'
            $req.ContentType      = 'application/json; charset=utf-8'
            $req.Accept           = 'application/json'
            if (-not [string]::IsNullOrWhiteSpace($script:ApiKey)) {
                $req.Headers.Add('Authorization', "Bearer $($script:ApiKey)")
            }
            $req.Timeout          = $TimeoutSec * 1000
            $req.ReadWriteTimeout = $TimeoutSec * 1000
            $req.KeepAlive        = $false

            $stream = $req.GetRequestStream()
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Close()

            $resp = $req.GetResponse()
            $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
            $body = $sr.ReadToEnd()
            $sr.Close(); $resp.Close()
            $sw.Stop()
            return @{ ok = $true; status = 200; body = $body; ms = $sw.ElapsedMilliseconds; attempts = $i }
        }
        catch [Net.WebException] {
            $sw.Stop()
            $ex = $_.Exception
            $code = 0
            $errBody = ''
            if ($ex.Response) {
                try {
                    $code = [int]$ex.Response.StatusCode
                    $sr = New-Object IO.StreamReader($ex.Response.GetResponseStream(), [Text.Encoding]::UTF8)
                    $errBody = $sr.ReadToEnd(); $sr.Close()
                } catch {}
            }
            if ($ex.Status -eq [Net.WebExceptionStatus]::Timeout -or $ex.Status -eq [Net.WebExceptionStatus]::RequestCanceled) {
                $code = 504
            }
            elseif ($code -eq 0) { $code = 502 }

            # Distinguish "wrong address / offline" from "server said no" so the
            # UI can tell the user which one to fix.
            $reason = ''
            if ($ex.Status -eq [Net.WebExceptionStatus]::NameResolutionFailure) { $reason = 'dns' }
            elseif ($ex.Status -eq [Net.WebExceptionStatus]::ConnectFailure) { $reason = 'connect' }
            elseif ($ex.Status -eq [Net.WebExceptionStatus]::TrustFailure) { $reason = 'tls' }
            elseif ($ex.Status -eq [Net.WebExceptionStatus]::SecureChannelFailure) { $reason = 'tls' }

            $lastStatus = $code
            $lastMsg = $errBody
            if ($lastMsg.Length -gt 240) { $lastMsg = $lastMsg.Substring(0, 240) }
            if (-not $lastMsg) { $lastMsg = $ex.Message }
            if ($resp) { try { $resp.Close() } catch {} }

            $retryable = @(429, 500, 502, 503, 504) -contains $code
            if ($retryable -and $i -lt $MaxAttempts) {
                $wait = $backoff[[Math]::Min($i - 1, $backoff.Count - 1)]
                Write-Log "RETRY path=$Path attempt=$i status=$code wait=${wait}s ms=$($sw.ElapsedMilliseconds)"
                Start-Sleep -Seconds $wait
                continue
            }
            return @{ ok = $false; status = $code; body = $errBody; ms = $sw.ElapsedMilliseconds; attempts = $i; msg = $lastMsg; reason = $reason }
        }
        catch {
            $sw.Stop()
            $m = $_.Exception.Message
            Write-Log "FAIL path=$Path attempt=$i ex=$m ms=$($sw.ElapsedMilliseconds)"
            return @{ ok = $false; status = 502; body = ''; ms = $sw.ElapsedMilliseconds; attempts = $i; msg = $m; reason = 'unknown' }
        }
    }
    return @{ ok = $false; status = $lastStatus; body = $lastMsg; ms = 0; attempts = $MaxAttempts; msg = $lastMsg }
}


# Agnes text completion. Returns a failure hash when the key is missing so the
# UI can explain the situation instead of surfacing a raw transport error.
function Invoke-ChatCompletion {
    param([string]$Prompt, [double]$Temperature = 1.0, [int]$TimeoutSec = 60)
    if ([string]::IsNullOrWhiteSpace($script:ApiKey)) {
        return @{ ok = $false; status = 0; attempts = 0; ms = 0; msg = 'no_api_key' }
    }

    $payload = @{
        model       = $script:TextModel
        messages    = @(@{ role = 'user'; content = $Prompt })
        temperature = $Temperature
        max_tokens  = $script:MaxTokens
    }
    $r = Invoke-AgnesPost -Path '/chat/completions' -Payload $payload -MaxAttempts 3 -TimeoutSec $TimeoutSec
    if (-not $r.ok) { return $r }

    $parsed = $null
    try { $parsed = $r.body | ConvertFrom-Json } catch {}
    if ($parsed -and $parsed.choices -and $parsed.choices.Count -gt 0) {
        $msg = $parsed.choices[0].message
        $content = [string]$msg.content
        # reasoning models may leave content empty and fill reasoning_content
        if ([string]::IsNullOrWhiteSpace($content) -and $msg.reasoning_content) {
            $content = [string]$msg.reasoning_content
            Write-Log "CHAT reasoning_content fallback used model=$($script:TextModel)"
        }
        $r.content = $content
    }
    else {
        $r.ok = $false
        $r.status = 502
        $r.msg = 'unexpected chat response shape'
    }
    return $r
}

# ------------------------------------------------------------- image generation
function Save-RemoteImage {
    param([string]$RemoteUrl)
    $name = [Guid]::NewGuid().ToString('N') + '.png'
    $dest = Join-Path $ImgDir $name
    try {
        $wc = New-Object Net.WebClient
        $wc.Headers.Add('User-Agent', 'HuiZhiAI/1.0')
        $wc.DownloadFile($RemoteUrl, $dest)
        return @{ file = $name; url = "/data/images/$name"; local = $true }
    }
    catch {
        Write-Log "IMAGE download failed, falling back to remote url: $($_.Exception.Message)"
        return @{ file = ''; url = $RemoteUrl; local = $false }
    }
}

function Invoke-ImageGeneration {
    param([string]$Prompt, [string]$Ratio)
    $size = $script:RatioSizes[$Ratio]
    if (-not $size) { $size = '1024x1024' ; $Ratio = '1:1' }

    if ([string]::IsNullOrWhiteSpace($script:ApiKey)) {
        return @{ ok = $false; status = 0; attempts = 0; ms = 0; msg = 'no_api_key' }
    }

    $payload = @{ model = $script:ImageModel; prompt = $Prompt; n = 1; size = $size }
    $r = Invoke-AgnesPost -Path '/images/generations' -Payload $payload -MaxAttempts 2 -TimeoutSec 75
    # Fall back to the previous-generation image model once before giving up.
    if (-not $r.ok -and $script:ImageModelFallback) {
        Write-Log "IMAGE retry with fallback model=$($script:ImageModelFallback) ratio=$Ratio"
        $payload.model = $script:ImageModelFallback
        $r = Invoke-AgnesPost -Path '/images/generations' -Payload $payload -MaxAttempts 1 -TimeoutSec 75
    }
    if (-not $r.ok) { return $r }

    $parsed = $null
    try { $parsed = $r.body | ConvertFrom-Json } catch {}
    $data = $null
    if ($parsed -and $parsed.data) { $data = $parsed.data[0] }
    if (-not $data) {
        $r.ok = $false; $r.status = 502; $r.msg = 'unexpected image response shape'
        return $r
    }

    $saved = @{ file = ''; url = ''; local = $false }
    if ($data.url) { $saved = Save-RemoteImage -RemoteUrl $data.url }
    elseif ($data.b64_json) {
        $name = [Guid]::NewGuid().ToString('N') + '.png'
        [IO.File]::WriteAllBytes((Join-Path $ImgDir $name), [Convert]::FromBase64String($data.b64_json))
        $saved = @{ file = $name; url = "/data/images/$name"; local = $true }
    }
    else {
        $r.ok = $false; $r.status = 502; $r.msg = 'image response contains neither url nor b64_json'
        return $r
    }

    $r.imageUrl  = $saved.url
    $r.imageFile = $saved.file
    $r.size      = $size
    $r.ratio     = $Ratio
    return $r
}

# ------------------------------------------------------------------ record store
function Get-Records {
    if (-not (Test-Path $RecordFile)) { return @() }
    $raw = [IO.File]::ReadAllText($RecordFile, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    try {
        $o = $raw | ConvertFrom-Json
        if ($o -is [Array]) { return $o }
        return @($o)
    } catch { return @() }
}

function Save-Records {
    param($Records)
    $json = $Records | ConvertTo-Json -Depth 24
    [IO.File]::WriteAllText($RecordFile, $json, (New-Object Text.UTF8Encoding($false)))
}

function Get-RecordById {
    param($Records, [string]$Id)
    foreach ($r in $Records) { if ($r.id -eq $Id) { return $r } }
    return $null
}

# public projection: never leak imagePrompt / prompt engineering to the client
function ConvertTo-PublicRecord {
    param($Record)
    if (-not $Record) { return $null }
    return @{
        id            = $Record.id
        roleId        = $Record.roleId
        roleName      = $Record.roleName
        roleIndex     = $Record.roleIndex
        requirement   = $Record.requirement
        ratio         = $Record.ratio
        title         = $Record.title
        summary       = $Record.summary
        visiblePrompt = $Record.visiblePrompt
        agentReply    = $Record.agentReply
        keywords      = $Record.keywords
        imageUrl      = $Record.imageUrl
        imageFile     = $Record.imageFile
        size          = $Record.size
        createdAt     = $Record.createdAt
        updatedAt     = $Record.updatedAt
        revisions     = $Record.revisions
        messages      = $Record.messages
    }
}

# -------------------------------------------------------------------- utilities
function New-VariationSeed {
    return ((Get-Random -Minimum 100000 -Maximum 999999).ToString() + '-' + [DateTime]::Now.Ticks.ToString())
}

function Get-RandomDirections {
    param($Config, [int]$Count = 3)
    $pool = @($Config.shared.variationDirections)
    $picked = @()
    $guard = 0
    while ($picked.Count -lt $Count -and $guard -lt 100) {
        $guard++
        $c = $pool[(Get-Random -Minimum 0 -Maximum $pool.Count)]
        if ($picked -notcontains $c) { $picked += $c }
    }
    $lines = @()
    foreach ($p in $picked) { $lines += ("- " + $p) }
    return ($lines -join "`n")
}

function Fill-Template {
    param([string]$Template, [hashtable]$Vars)
    $out = $Template
    foreach ($k in $Vars.Keys) { $out = $out.Replace('{' + $k + '}', [string]$Vars[$k]) }
    return $out
}

function New-RecordId {
    return ('g' + (Get-Date).ToString('yyMMddHHmmss') + (Get-Random -Minimum 100 -Maximum 999))
}

function Get-NowIso { return (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }

# ------------------------------------------------------------------ http writers
function Add-CorsHeaders {
    param($Ctx)
    $Ctx.Response.Headers.Add('Access-Control-Allow-Origin', '*')
    $Ctx.Response.Headers.Add('Access-Control-Allow-Headers', 'Content-Type, Authorization')
    $Ctx.Response.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS')
}

function Write-Json {
    param($Ctx, $Object, [int]$Status = 200)
    $bytes = ConvertTo-JsonBytes -Object $Object
    $Ctx.Response.StatusCode = $Status
    $Ctx.Response.ContentType = 'application/json; charset=utf-8'
    try { $Ctx.Response.Headers.Add('Cache-Control', 'no-store') } catch {}
    Add-CorsHeaders $Ctx
    $Ctx.Response.ContentLength64 = $bytes.Length
    $Ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Ctx.Response.Close()
}

function Write-Fail {
    param($Ctx, [string]$Code, [string]$Message, [int]$Status = 400)
    Write-Json $Ctx @{ ok = $false; error = $Code; message = $Message } $Status
}

function Write-UpstreamFail {
    param($Ctx, $Result, [string]$Stage)
    Write-Log "UPSTREAM_FAIL stage=$Stage status=$($Result.status) attempts=$($Result.attempts) ms=$($Result.ms) err=$($Result.msg)"

    # Nothing is broken upstream - the Agnes key simply is not configured.
    if ($Result.msg -eq 'no_api_key' -or $Result.msg -eq 'no_base_url') {
        Write-Fail $Ctx 'no_api_key' 'AGNES_API_KEY is not set in .env' 503
        return
    }

    $status = 502
    if ($Result.status -eq 429) { $status = 429 }
    elseif ($Result.status -eq 504) { $status = 504 }
    $code = 'upstream_error'
    if ($Result.status -eq 401 -or $Result.status -eq 403) { $code = 'upstream_auth_failed' }
    elseif ($Result.status -eq 429) { $code = 'upstream_rate_limited' }
    elseif ($Result.status -eq 504) { $code = 'upstream_timeout' }
    Write-Fail $Ctx $code ("model endpoint failed at stage '" + $Stage + "' status=" + $Result.status) $status
}

function Read-RequestBody {
    param($Ctx)
    if (-not $Ctx.Request.HasEntityBody) { return $null }
    $sr = New-Object IO.StreamReader($Ctx.Request.InputStream, [Text.Encoding]::UTF8)
    $raw = $sr.ReadToEnd(); $sr.Close()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Get-Step {
    param($Body, [string]$Name, [string]$Default = '')
    if ($null -eq $Body) { return $Default }
    $v = $Body.$Name
    if ($null -eq $v) { return $Default }
    $s = [string]$v
    if ($s -eq '') { return $Default }
    return $s
}

# ----------------------------------------------------------------- api: planning
# Stage 1 - LLM turns the natural-language brief into a production image prompt.
function Invoke-PlanStage {
    param($Ctx, $Body)
    $Config = Get-RoleConfig
    $role   = Get-Role -Config $Config -RoleId (Get-Step $Body 'roleId' 'pm')
    $req    = Get-Step $Body 'requirement' ''
    if ([string]::IsNullOrWhiteSpace($req)) {
        Write-Fail $Ctx 'empty_requirement' 'requirement is required'; return
    }
    # No length cap: the AI requirement box accepts unlimited input by design.

    $ratio = Get-Step $Body 'ratio' $role.defaultRatio
    if ($script:Ratios -notcontains $ratio) { $ratio = $role.defaultRatio }

    $seed = New-VariationSeed
    $prompt = Fill-Template -Template $Config.shared.plannerTemplate -Vars @{
        roleName    = $role.name
        deliverable = $role.deliverable
        styleGuide  = $role.styleGuide
        requirement = $req
        ratio       = $ratio
        seed        = $seed
        directions  = (Get-RandomDirections -Config $Config -Count 3)
    }

    $t0 = Get-Date
    Write-Log "PLAN start role=$($role.id) ratio=$ratio seed=$seed reqLen=$($req.Length)"
    $llm = Invoke-ChatCompletion -Prompt $prompt -Temperature 1.0 -TimeoutSec 60
    if (-not $llm.ok) { Write-UpstreamFail $Ctx $llm 'plan'; return }

    $plan = Parse-LlmJson -Text $llm.content
    if (-not $plan -or -not $plan.imagePrompt) {
        Write-Log "PLAN parse_failed stage=plan ms=$($llm.ms) rawLen=$($llm.content.Length)"
        Write-Fail $Ctx 'plan_parse_failed' 'The model did not return a parsable plan.' 502
        return
    }

    $Records = Get-Records
    $record = [ordered]@{
        id            = (New-RecordId)
        roleId        = $role.id
        roleName      = $role.name
        roleIndex     = $role.index
        requirement   = $req
        ratio         = $ratio
        size          = $script:RatioSizes[$ratio]
        seed          = $seed
        title         = [string]$plan.title
        summary       = [string]$plan.summary
        visiblePrompt = [string]$plan.visiblePrompt
        imagePrompt   = [string]$plan.imagePrompt
        agentReply    = [string]$plan.agentReply
        keywords      = @($plan.keywords)
        imageUrl      = ''
        imageFile     = ''
        createdAt     = (Get-NowIso)
        updatedAt     = (Get-NowIso)
        revisions     = @()
        messages      = @(
            @{ role = 'agent'; text = [string]$plan.agentReply; at = (Get-NowIso) },
            @{ role = 'user';  text = $req;                       at = (Get-NowIso) }
        )
    }
    $Records = @($Records) + @([pscustomobject]$record)
    Save-Records -Records $Records

    $secs = [Math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    Write-Log "PLAN ok id=$($record.id) ms=$($llm.ms) total=${secs}s"
    Write-Json $Ctx @{ ok = $true; record = (ConvertTo-PublicRecord -Record $record) }
}

# ----------------------------------------------------------------- api: rendering
# Stage 2 - image model renders the stored prompt at the requested aspect ratio.
function Invoke-RenderStage {
    param($Ctx, $Body)
    $id = Get-Step $Body 'id' ''
    $Records = Get-Records
    $record = Get-RecordById -Records $Records -Id $id
    if (-not $record) { Write-Fail $Ctx 'not_found' "record $id not found" 404; return }
    if ([string]::IsNullOrWhiteSpace($record.imagePrompt)) {
        Write-Fail $Ctx 'missing_prompt' 'record has no image prompt'; return
    }

    $ratio = Get-Step $Body 'ratio' $record.ratio
    if ($script:Ratios -notcontains $ratio) { $ratio = $record.ratio }

    $t0 = Get-Date
    Write-Log "RENDER start id=$id ratio=$ratio"
    $img = Invoke-ImageGeneration -Prompt $record.imagePrompt -Ratio $ratio
    if (-not $img.ok) { Write-UpstreamFail $Ctx $img 'render'; return }

    $rev = [pscustomobject]@{
        at        = (Get-NowIso)
        ratio     = $img.ratio
        size      = $img.size
        imageUrl  = $img.imageUrl
        imageFile = $img.imageFile
        note      = 'initial'
    }
    $record.imageUrl  = $img.imageUrl
    $record.imageFile = $img.imageFile
    $record.ratio     = $img.ratio
    $record.size      = $img.size
    $record.revisions = @($record.revisions) + @($rev)
    $record.updatedAt = (Get-NowIso)
    Save-Records -Records $Records

    $secs = [Math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    Write-Log "RENDER ok id=$id ms=$($img.ms) total=${secs}s local=$($img.imageFile -ne '')"
    Write-Json $Ctx @{ ok = $true; record = (ConvertTo-PublicRecord -Record $record) }
}

# ------------------------------------------------------------------ api: refine
# Agent multi-turn: only the delta is regenerated, everything else is preserved.
function Invoke-RefineStage {
    param($Ctx, $Body)
    $id = Get-Step $Body 'id' ''
    $instruction = Get-Step $Body 'instruction' ''
    if ([string]::IsNullOrWhiteSpace($instruction)) {
        Write-Fail $Ctx 'empty_instruction' 'instruction is required'; return
    }
    # No length cap, consistent with the requirement box.

    $Config = Get-RoleConfig
    $Records = Get-Records
    $record = Get-RecordById -Records $Records -Id $id
    if (-not $record) { Write-Fail $Ctx 'not_found' "record $id not found" 404; return }

    $role = Get-Role -Config $Config -RoleId $record.roleId

    $sessionLines = @()
    foreach ($m in $record.messages) {
        $who = if ($m.role -eq 'user') { 'user' } else { 'agent' }
        $sessionLines += ("[$who] " + $m.text)
    }
    $session = ($sessionLines -join "`n")

    $prompt = Fill-Template -Template $Config.shared.refineTemplate -Vars @{
        roleName       = $role.name
        styleGuide     = $role.styleGuide
        ratio          = $record.ratio
        currentPrompt  = $record.imagePrompt
        currentVisible = $record.visiblePrompt
        session        = $session
        instruction    = $instruction
    }

    $t0 = Get-Date
    Write-Log "REFINE start id=$id instrLen=$($instruction.Length)"
    $llm = Invoke-ChatCompletion -Prompt $prompt -Temperature 0.3 -TimeoutSec 60
    if (-not $llm.ok) { Write-UpstreamFail $Ctx $llm 'refine'; return }

    $upd = Parse-LlmJson -Text $llm.content
    if (-not $upd -or -not $upd.imagePrompt) {
        Write-Log "REFINE parse_failed ms=$($llm.ms) rawLen=$($llm.content.Length)"
        Write-Fail $Ctx 'refine_parse_failed' 'The model did not return a parsable refinement.' 502
        return
    }

    $record.imagePrompt   = [string]$upd.imagePrompt
    if ($upd.visiblePrompt) { $record.visiblePrompt = [string]$upd.visiblePrompt }
    $reply = [string]$upd.agentReply
    if (-not $reply) { $reply = [string]$upd.changed }
    $record.agentReply = $reply
    $record.messages = @($record.messages) + @(
        [pscustomobject]@{ role = 'user';  text = $instruction; at = (Get-NowIso) },
        [pscustomobject]@{ role = 'agent'; text = $reply;       at = (Get-NowIso) }
    )
    $record.updatedAt = (Get-NowIso)
    Save-Records -Records $Records

    $secs = [Math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    Write-Log "REFINE ok id=$id ms=$($llm.ms) total=${secs}s"
    Write-Json $Ctx @{ ok = $true; record = (ConvertTo-PublicRecord -Record $record); changed = [string]$upd.changed }
}

# --------------------------------------------------------- api: rerender / redo
# Ratio switch: same prompt, new canvas size -> keeps content consistent.
function Invoke-RerenderStage {
    param($Ctx, $Body)
    $id = Get-Step $Body 'id' ''
    $ratio = Get-Step $Body 'ratio' ''
    if ($script:Ratios -notcontains $ratio) { Write-Fail $Ctx 'bad_ratio' 'unsupported ratio'; return }

    $Records = Get-Records
    $record = Get-RecordById -Records $Records -Id $id
    if (-not $record) { Write-Fail $Ctx 'not_found' "record $id not found" 404; return }

    $t0 = Get-Date
    Write-Log "RERENDER start id=$id ratio=$ratio"
    $img = Invoke-ImageGeneration -Prompt $record.imagePrompt -Ratio $ratio
    if (-not $img.ok) { Write-UpstreamFail $Ctx $img 'rerender'; return }

    $rev = [pscustomobject]@{
        at        = (Get-NowIso)
        ratio     = $img.ratio
        size      = $img.size
        imageUrl  = $img.imageUrl
        imageFile = $img.imageFile
        note      = ("ratio " + $ratio)
    }
    $record.imageUrl  = $img.imageUrl
    $record.imageFile = $img.imageFile
    $record.ratio     = $img.ratio
    $record.size      = $img.size
    $record.revisions = @($record.revisions) + @($rev)
    $record.updatedAt = (Get-NowIso)
    Save-Records -Records $Records

    $secs = [Math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    Write-Log "RERENDER ok id=$id ms=$($img.ms) total=${secs}s"
    Write-Json $Ctx @{ ok = $true; record = (ConvertTo-PublicRecord -Record $record) }
}

# Re-roll: brand new creative direction + seed, same brief. Guarantees that the
# same input never yields the same visual twice.
function Invoke-RegenerateStage {
    param($Ctx, $Body)
    $id = Get-Step $Body 'id' ''
    $Records = Get-Records
    $record = Get-RecordById -Records $Records -Id $id
    if (-not $record) { Write-Fail $Ctx 'not_found' "record $id not found" 404; return }

    $Config = Get-RoleConfig
    $role = Get-Role -Config $Config -RoleId $record.roleId
    $seed = New-VariationSeed

    $prompt = Fill-Template -Template $Config.shared.plannerTemplate -Vars @{
        roleName    = $role.name
        deliverable = $role.deliverable
        styleGuide  = $role.styleGuide
        requirement = $record.requirement
        ratio       = $record.ratio
        seed        = $seed
        directions  = (Get-RandomDirections -Config $Config -Count 3)
    }

    $t0 = Get-Date
    Write-Log "REGENERATE start id=$id seed=$seed"
    $llm = Invoke-ChatCompletion -Prompt $prompt -Temperature 1.0 -TimeoutSec 60
    if (-not $llm.ok) { Write-UpstreamFail $Ctx $llm 'regenerate'; return }

    $plan = Parse-LlmJson -Text $llm.content
    if (-not $plan -or -not $plan.imagePrompt) {
        Write-Fail $Ctx 'plan_parse_failed' 'The model did not return a parsable plan.' 502; return
    }

    $img = Invoke-ImageGeneration -Prompt ([string]$plan.imagePrompt) -Ratio $record.ratio
    if (-not $img.ok) { Write-UpstreamFail $Ctx $img 'regenerate-render'; return }

    $rev = [pscustomobject]@{
        at        = (Get-NowIso)
        ratio     = $img.ratio
        size      = $img.size
        imageUrl  = $img.imageUrl
        imageFile = $img.imageFile
        note      = 'regenerate'
    }
    $record.title = [string]$plan.title
    $record.summary = [string]$plan.summary
    $record.visiblePrompt = [string]$plan.visiblePrompt
    $record.imagePrompt = [string]$plan.imagePrompt
    $record.agentReply = [string]$plan.agentReply
    $record.keywords = @($plan.keywords)
    $record.seed = [string]$seed
    $record.imageUrl  = $img.imageUrl
    $record.imageFile = $img.imageFile
    $record.ratio     = $img.ratio
    $record.size      = $img.size
    $record.revisions = @($record.revisions) + @($rev)
    $record.messages  = @($record.messages) + @(
        [pscustomobject]@{ role = 'agent'; text = [string]$plan.agentReply; at = (Get-NowIso) }
    )
    $record.updatedAt = (Get-NowIso)
    Save-Records -Records $Records

    $secs = [Math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    Write-Log "REGENERATE ok id=$id ms=$($llm.ms)+$($img.ms) total=${secs}s"
    Write-Json $Ctx @{ ok = $true; record = (ConvertTo-PublicRecord -Record $record) }
}

# ---------------------------------------------------------------- api: dispatch
function Handle-Api {
    param($Ctx, [string]$Path)
    $method = $Ctx.Request.HttpMethod

    if ($method -eq 'OPTIONS') {
        $Ctx.Response.StatusCode = 204
        Add-CorsHeaders $Ctx
        $Ctx.Response.Close(); return
    }

    if ($Path -eq '/api/health') {
        $keyOk = -not [string]::IsNullOrWhiteSpace($script:ApiKey)
        $chatPub = @{ configured = $keyOk; name = 'Agnes AI'; model = $script:TextModel;  baseUrl = $script:BaseUrl }
        $imgPub  = @{ configured = $keyOk; name = 'Agnes AI'; model = $script:ImageModel; baseUrl = $script:BaseUrl }
        Write-Json $Ctx @{
            ok         = $true
            service    = 'huizhi-ai'
            version    = '3.0.0'
            provider   = 'Agnes AI'
            baseUrl    = $script:BaseUrl
            ratios     = $script:Ratios
            chat       = $chatPub
            image      = $imgPub
            configured = $keyOk
            time       = (Get-NowIso)
        }
        return
    }

    if ($Path -eq '/api/roles') {
        $Config = Get-RoleConfig
        $pub = @()
        foreach ($r in $Config.roles) {
            $pub += @{
                id           = $r.id
                index        = $r.index
                name         = $r.name
                short        = $r.short
                icon         = $r.icon
                tagline      = $r.tagline
                description  = $r.description
                defaultRatio = $r.defaultRatio
            }
        }
        Write-Json $Ctx @{ ok = $true; roles = $pub; ratios = $script:Ratios }
        return
    }

    if ($Path -eq '/api/history' -and $method -eq 'GET') {
        $Records = Get-Records
        $out = @()
        foreach ($r in $Records) { $out += (ConvertTo-PublicRecord -Record $r) }
        Write-Json $Ctx @{ ok = $true; records = $out }
        return
    }

    if ($Path -eq '/api/history' -and $method -eq 'DELETE') {
        $id = [string]$Ctx.Request.QueryString['id']
        if (-not $id) { Write-Fail $Ctx 'missing_id' 'query id is required'; return }
        $Records = @(Get-Records | Where-Object { $_.id -ne $id })
        Save-Records -Records $Records
        Write-Log "HISTORY delete id=$id"
        Write-Json $Ctx @{ ok = $true }
        return
    }

    if ($Path -eq '/api/history/clear' -and $method -eq 'POST') {
        Save-Records -Records @()
        Write-Log "HISTORY clear"
        Write-Json $Ctx @{ ok = $true }
        return
    }

    # Resolve the path first so an unknown endpoint returns a proper 404,
    # leaving 405 to mean "right endpoint, wrong method".
    $postOnly = @('/api/plan', '/api/render', '/api/refine', '/api/rerender', '/api/regenerate')
    if ($postOnly -notcontains $Path) {
        Write-Fail $Ctx 'unknown_endpoint' ("unknown endpoint " + $Path) 404
        return
    }
    if ($method -ne 'POST') { Write-Fail $Ctx 'method_not_allowed' 'unsupported method' 405; return }

    # Each stage checks the Agnes key itself and reports 'no_api_key' so the UI
    # can tell the user exactly what is missing.

    $Body = Read-RequestBody $Ctx
    switch ($Path) {
        '/api/plan'       { Invoke-PlanStage       -Ctx $Ctx -Body $Body }
        '/api/render'     { Invoke-RenderStage     -Ctx $Ctx -Body $Body }
        '/api/refine'     { Invoke-RefineStage     -Ctx $Ctx -Body $Body }
        '/api/rerender'   { Invoke-RerenderStage   -Ctx $Ctx -Body $Body }
        '/api/regenerate' { Invoke-RegenerateStage -Ctx $Ctx -Body $Body }
    }
}

# ----------------------------------------------------------------- static files
$script:MimeTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.svg'  = 'image/svg+xml'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.jpeg' = 'image/jpeg'
    '.webp' = 'image/webp'
    '.ico'  = 'image/x-icon'
    '.woff2'= 'font/woff2'
    '.txt'  = 'text/plain; charset=utf-8'
}

# NOTE: compared against a path already normalised to backslashes.
$script:DeniedPaths = @(
    '.env', '.env.example', '.gitignore', 'server.ps1', 'server', 'readme.md',
    'data\roles.json', 'data\records.json'
)

function Serve-Static {
    param($Ctx, [string]$UrlPath)
    $rel = [Uri]::UnescapeDataString($UrlPath).TrimStart('/')
    if ($rel -eq '') { $rel = 'index.html' }

    $lower = $rel.ToLower().Replace('/', '\')
    if ($script:DeniedPaths -contains $lower) { $Ctx.Response.StatusCode = 404; $Ctx.Response.Close(); return }
    if ($lower.StartsWith('logs\')) { $Ctx.Response.StatusCode = 404; $Ctx.Response.Close(); return }

    $full = [IO.Path]::GetFullPath((Join-Path $Root $rel))
    $rootFull = [IO.Path]::GetFullPath($Root)
    if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        $Ctx.Response.StatusCode = 403; $Ctx.Response.Close(); return
    }

    # extensionless routes: /history -> history.html
    if (-not (Test-Path $full) -and -not [IO.Path]::HasExtension($full)) {
        $alt = $full + '.html'
        if (Test-Path $alt) { $full = $alt }
    }

    if (-not (Test-Path $full) -or (Get-Item $full).PSIsContainer) {
        $Ctx.Response.StatusCode = 404
        $Ctx.Response.ContentType = 'text/plain'
        $Ctx.Response.Close(); return
    }

    $ext = [IO.Path]::GetExtension($full).ToLower()
    $mime = $script:MimeTypes[$ext]
    if (-not $mime) { $mime = 'application/octet-stream' }

    $bytes = [IO.File]::ReadAllBytes($full)
    $Ctx.Response.StatusCode = 200
    $Ctx.Response.ContentType = $mime
    Add-CorsHeaders $Ctx
    if ($ext -eq '.html') {
        $Ctx.Response.Headers.Add('Cache-Control', 'no-cache')
    } else {
        $Ctx.Response.Headers.Add('Cache-Control', 'public, max-age=300')
    }
    $Ctx.Response.ContentLength64 = $bytes.Length
    $Ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Ctx.Response.Close()
}

# --------------------------------------------------------------------- listener
function Get-LanAddresses {
    $out = @()
    try {
        foreach ($ip in [Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName())) {
            if ($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
                $ip.IPAddressToString -notlike '169.254.*') { $out += $ip.IPAddressToString }
        }
    } catch {}
    return $out
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$candidates = @()
if ($script:BindAll) { $candidates += "http://+:$($script:Port)/" }
if ($isAdmin -and -not $script:BindAll) { $candidates += "http://+:$($script:Port)/" }
$candidates += "http://localhost:$($script:Port)/"
$candidates += "http://127.0.0.1:$($script:Port)/"

$listener = $null
$started = $false

# The previous instance may still be releasing the port for a moment, so retry
# a few rounds instead of dying on the first refusal.
for ($round = 1; $round -le 3 -and -not $started; $round++) {
    foreach ($prefix in $candidates) {
        try {
            $listener = New-Object Net.HttpListener
            $listener.Prefixes.Clear()
            $listener.Prefixes.Add($prefix)
            $listener.Start()
            $script:ActivePrefix = $prefix
            $started = $true
            break
        } catch {
            if ($listener) { try { $listener.Close() } catch {} }
            $listener = $null
        }
    }
    if (-not $started -and $round -lt 3) {
        Write-Log "BIND retry round=$round port=$($script:Port) not free yet"
        Start-Sleep -Seconds 2
    }
}

if (-not $started) {
    # Recorded to the log too, so a silent exit is diagnosable later.
    Write-Log "SERVER fatal: cannot bind port $($script:Port); another process may hold it"
    Write-Host "[FATAL] Cannot bind port $($script:Port). Another process may be using it." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor DarkCyan
Write-Host "   HuiZhi AI  -  Role-based Visual Agent  (backend online)"    -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor DarkCyan
Write-Host "   Local    : http://localhost:$($script:Port)/"
foreach ($ip in Get-LanAddresses) {
    if ($script:ActivePrefix -eq "http://+:$($script:Port)/") {
        Write-Host "   Mobile   : http://${ip}:$($script:Port)/" -ForegroundColor Green
    }
}
$keyOk2 = -not [string]::IsNullOrWhiteSpace($script:ApiKey)
Write-Host "   Provider : Agnes AI"
Write-Host "   BaseUrl  : $($script:BaseUrl)"
Write-Host "   Text     : $($script:TextModel)"
Write-Host "   Image    : $($script:ImageModel)"
Write-Host "   KEY      : $(if ($keyOk2) { 'configured (from .env)' } else { 'MISSING -> set AGNES_API_KEY in .env' })" -ForegroundColor $(if ($keyOk2) { 'Gray' } else { 'Yellow' })
Write-Host "   Bind     : $($script:ActivePrefix)"
Write-Host "   Stop     : Ctrl + C"
Write-Host ""

Write-Log "SERVER start prefix=$($script:ActivePrefix) provider=AgnesAI text=$($script:TextModel) image=$($script:ImageModel) key=$($keyOk2)"

while ($listener.IsListening) {
    $ctx = $null
    try {
        $ctx = $listener.GetContext()
        $path = $ctx.Request.Url.AbsolutePath
        if ($path.StartsWith('/api/')) {
            Handle-Api -Ctx $ctx -Path $path
        }
        else {
            Serve-Static -Ctx $ctx -UrlPath $path
        }
    }
    catch {
        Write-Log "REQ_ERROR $($_.Exception.Message)"
        if ($ctx) {
            try {
                $ctx.Response.StatusCode = 500
                $ctx.Response.Close()
            } catch { }
        }
    }
}
