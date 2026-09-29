<#
.SYNOPSIS
    Activates (or deactivates) Azure PIM eligible role assignments from the command line.

.DESCRIPTION
    Replaces the manual "Activate" clicking in the Azure portal. All activation requests are
    submitted up-front and then polled together, so N resource groups take about as long as one.

    Uses the Azure Resource Manager PIM APIs via the token from `az account get-access-token`:
      - Microsoft.Authorization/roleEligibilityScheduleInstances   (what you may activate)
      - Microsoft.Authorization/roleAssignmentScheduleInstances    (what is active right now)
      - Microsoft.Authorization/roleAssignmentScheduleRequests     (activate / deactivate)

.PARAMETER ResourceGroup
    One or more resource group names. Wildcards supported (e.g. 'az-rg-*').
    Omit to use the saved defaults in Enable-AzPim.config.json.

.PARAMETER Role
    Role name to activate. Default: Contributor. Use '*' for every eligible role.

.PARAMETER Duration
    How long to activate for. Accepts '8h', '30m', '4.5h' or a raw ISO-8601 duration ('PT8H').
    Capped by the PIM policy on the role; if you exceed it the request is rejected.

.PARAMETER Justification
    Business justification recorded in the PIM audit log.

.PARAMETER Subscription
    Optional subscription id or name filter, for when the same RG name exists in several subs.

.PARAMETER List
    Read-only. Shows eligible roles and which are currently active. Changes nothing.

.PARAMETER Deactivate
    Deactivates the matching roles instead of activating them.

.PARAMETER All
    Targets every eligible assignment (subject to -Role / -Subscription filters).

.PARAMETER NoWait
    Submit the requests and return immediately instead of polling to completion.

.PARAMETER TimeoutMinutes
    How long to poll for provisioning. Default 5.

.PARAMETER TicketNumber
    Ticket number, if your PIM policy requires ticket information.

.PARAMETER TicketSystem
    Ticket system name, if your PIM policy requires ticket information.

.PARAMETER SaveDefaults
    Saves the resource groups / role / duration / justification used in this run as the
    defaults in Enable-AzPim.config.json.

.EXAMPLE
    .\Enable-AzPim.ps1 -List

.EXAMPLE
    .\Enable-AzPim.ps1 -ResourceGroup az-rg-dev, az-rg-uat -Duration 8h

.EXAMPLE
    .\Enable-AzPim.ps1 -ResourceGroup 'az-rg-*' -Justification 'Sprint 14 support' -SaveDefaults

.EXAMPLE
    .\Enable-AzPim.ps1            # activates the saved defaults

.EXAMPLE
    .\Enable-AzPim.ps1 -All -Deactivate
#>
[CmdletBinding(DefaultParameterSetName = 'Activate')]
param(
    [Parameter(Position = 0)]
    [string[]]$ResourceGroup,

    [string]$Role = 'Contributor',

    [string]$Duration,

    [string]$Justification,

    [string]$Subscription,

    [switch]$List,

    [switch]$Deactivate,

    [switch]$All,

    [switch]$NoWait,

    [int]$TimeoutMinutes = 5,

    [string]$TicketNumber,

    [string]$TicketSystem,

    [switch]$SaveDefaults,

    [switch]$ShowToken,

    [switch]$NoReauth,

    [string]$TenantId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ApiVersion  = '2020-10-01'
$ArmRoot     = 'https://management.azure.com'
$ConfigPath  = Join-Path $PSScriptRoot 'Enable-AzPim.config.json'

# ---------------------------------------------------------------- helpers ----

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Skip { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }
function Write-Warn { param([string]$Message) Write-Host "    $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "    $Message" -ForegroundColor Red }

function ConvertTo-IsoDuration {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim()
    if ($v -match '^(?i)P') { return $v.ToUpperInvariant() }
    if ($v -match '^(?<n>\d+(\.\d+)?)\s*(?<u>h|hr|hrs|hour|hours|m|min|mins|minute|minutes)$') {
        $n = [double]$Matches['n']
        if ($Matches['u'] -match '^(h|hr|hrs|hour|hours)$') { $mins = [int][math]::Round($n * 60) }
        else { $mins = [int][math]::Round($n) }
        if ($mins -le 0) { throw "Duration '$Value' resolves to zero." }
        if ($mins % 60 -eq 0) { return "PT$($mins / 60)H" }
        return "PT${mins}M"
    }
    throw "Could not parse duration '$Value'. Use e.g. '8h', '90m' or 'PT8H'."
}

function Format-Duration {
    param([string]$Iso)
    try { $ts = [System.Xml.XmlConvert]::ToTimeSpan($Iso) } catch { return $Iso }
    if ($ts.TotalMinutes % 60 -eq 0) { return "$([int]$ts.TotalHours)h" }
    return "$([int]$ts.TotalHours)h $($ts.Minutes)m"
}

function Get-ArmToken {
    Write-Verbose 'Acquiring ARM access token via az CLI.'
    $raw = az account get-access-token --resource $ArmRoot -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az CLI could not get a token. Run 'az login' first.`n$raw"
    }
    return ($raw | ConvertFrom-Json).accessToken
}

function Get-SignedInObjectId {
    $oid = az ad signed-in-user show --query id -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $oid) { return $oid.Trim() }

    # Fallback for service principals / restricted Graph access: read the oid claim.
    $token = Get-ArmToken
    $payload = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    while ($payload.Length % 4) { $payload += '=' }
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    if (-not $claims.oid) { throw 'Unable to determine the signed-in principal object id.' }
    return $claims.oid
}

function Invoke-Arm {
    param(
        [string]$Method,
        [string]$Uri,
        $Body,
        [hashtable]$Headers
    )
    $params = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $Headers
        ContentType = 'application/json'
    }
    if ($null -ne $Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress) }
    return Invoke-RestMethod @params
}

function Get-ArmErrorMessage {
    param($ErrorRecord)
    $detail = $null
    try { $detail = $ErrorRecord.ErrorDetails.Message } catch { }
    if ($detail) {
        try {
            $parsed = $detail | ConvertFrom-Json
            if ($parsed.PSObject.Properties.Name -contains 'error') {
                return "$($parsed.error.code): $($parsed.error.message)"
            }
        } catch { return $detail }
        return $detail
    }
    return $ErrorRecord.Exception.Message
}

function Get-ScopeInfo {
    param([string]$Scope)
    $sub = $null; $rg = $null
    if ($Scope -match '(?i)/subscriptions/(?<sub>[^/]+)') { $sub = $Matches['sub'] }
    if ($Scope -match '(?i)/resourcegroups/(?<rg>[^/]+)')  { $rg  = $Matches['rg'] }
    [pscustomobject]@{ SubscriptionId = $sub; ResourceGroup = $rg }
}

function Get-Eligibilities {
    param([hashtable]$Headers)
    $uri = "$ArmRoot/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=$ApiVersion&`$filter=asTarget()"
    $result = Invoke-Arm -Method GET -Uri $uri -Headers $Headers
    foreach ($item in $result.value) {
        $info = Get-ScopeInfo $item.properties.scope
        [pscustomobject]@{
            RoleName          = $item.properties.expandedProperties.roleDefinition.displayName
            RoleDefinitionId  = $item.properties.roleDefinitionId
            Scope             = $item.properties.scope
            ScopeDisplayName  = $item.properties.expandedProperties.scope.displayName
            ScopeType         = $item.properties.expandedProperties.scope.type
            SubscriptionId    = $info.SubscriptionId
            ResourceGroup     = $info.ResourceGroup
            EligibilityId     = $item.properties.roleEligibilityScheduleId
            MemberType        = $item.properties.memberType
            ViaPrincipal      = $item.properties.expandedProperties.principal.displayName
        }
    }
}

function Get-ActiveAssignments {
    param([hashtable]$Headers)
    $uri = "$ArmRoot/providers/Microsoft.Authorization/roleAssignmentScheduleInstances?api-version=$ApiVersion&`$filter=asTarget()"
    $result = Invoke-Arm -Method GET -Uri $uri -Headers $Headers
    foreach ($item in $result.value) {
        if ($item.properties.assignmentType -ne 'Activated') { continue }
        [pscustomobject]@{
            RoleName         = $item.properties.expandedProperties.roleDefinition.displayName
            RoleDefinitionId = $item.properties.roleDefinitionId
            Scope            = $item.properties.scope
            EndDateTime      = $item.properties.endDateTime
        }
    }
}

function Test-IsActive {
    param($Candidate, $ActiveList)
    foreach ($a in $ActiveList) {
        if ($a.Scope -eq $Candidate.Scope -and
            ($a.RoleDefinitionId -split '/')[-1] -eq ($Candidate.RoleDefinitionId -split '/')[-1]) {
            return $a
        }
    }
    return $null
}

# ------------------------------------------------------------- defaults ------

$config = $null
if (Test-Path $ConfigPath) {
    try { $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json }
    catch { Write-Warn "Ignoring unreadable config file $ConfigPath" }
}

if (-not $ResourceGroup -and -not $All -and -not $List -and $config -and $config.PSObject.Properties.Name -contains 'resourceGroups') {
    $ResourceGroup = @($config.resourceGroups)
    Write-Verbose "Using $($ResourceGroup.Count) resource group(s) from $ConfigPath"
}
if (-not $PSBoundParameters.ContainsKey('Role') -and $config -and $config.PSObject.Properties.Name -contains 'role' -and $config.role) {
    $Role = $config.role
}
if (-not $Duration) {
    if ($config -and $config.PSObject.Properties.Name -contains 'duration' -and $config.duration) { $Duration = $config.duration }
    else { $Duration = '8h' }
}
if (-not $Justification) {
    if ($config -and $config.PSObject.Properties.Name -contains 'justification' -and $config.justification) { $Justification = $config.justification }
    else { $Justification = 'Scheduled operational support work' }
}
if (-not $TicketNumber -and $config -and $config.PSObject.Properties.Name -contains 'ticketNumber') { $TicketNumber = $config.ticketNumber }
if (-not $TicketSystem -and $config -and $config.PSObject.Properties.Name -contains 'ticketSystem') { $TicketSystem = $config.ticketSystem }

$isoDuration = ConvertTo-IsoDuration $Duration

# ---------------------------------------------------------------- main ------

$token   = Get-ArmToken
$headers = @{ Authorization = "Bearer $token" }
$myOid   = Get-SignedInObjectId

if ($ShowToken) {
    $seg = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    while ($seg.Length % 4) { $seg += '=' }
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($seg)) | ConvertFrom-Json
    $amr = @($claims.amr)
    Write-Step 'Current az CLI token'
    Write-Host "    user     : $($claims.upn)"
    Write-Host "    amr      : $($amr -join ', ')"
    Write-Host "    issued   : $(([datetimeoffset]::FromUnixTimeSeconds($claims.iat)).ToLocalTime().ToString('u'))"
    Write-Host "    expires  : $(([datetimeoffset]::FromUnixTimeSeconds($claims.exp)).ToLocalTime().ToString('u'))"
    if ($amr -contains 'mfa') { Write-Ok 'MFA claim present - PIM activation will be accepted.' }
    else { Write-Err 'No "mfa" value in amr - Azure will reject activation. See -? notes on the WAM broker.' }
    Write-Host ''
}

Write-Step 'Reading PIM eligibilities'
$eligible = @(Get-Eligibilities -Headers $headers)
$active   = @(Get-ActiveAssignments -Headers $headers)

if ($eligible.Count -eq 0) {
    Write-Warn 'No eligible PIM role assignments found for your account.'
    return
}
Write-Ok "$($eligible.Count) eligible assignment(s), $($active.Count) currently active."

if ($Subscription) {
    $eligible = @($eligible | Where-Object {
        $_.SubscriptionId -eq $Subscription -or $_.Scope -like "*$Subscription*"
    })
}

if ($List) {
    Write-Host ''
    $eligible |
        Sort-Object RoleName, ResourceGroup |
        ForEach-Object {
            $hit = Test-IsActive -Candidate $_ -ActiveList $active
            $state = 'eligible'
            if ($hit) {
                $remaining = ''
                if ($hit.EndDateTime) {
                    $mins = [int]([datetime]$hit.EndDateTime - [datetime]::UtcNow).TotalMinutes
                    if ($mins -gt 0) { $remaining = " ($([int]($mins / 60))h $($mins % 60)m left)" }
                }
                $state = "ACTIVE$remaining"
            }
            [pscustomobject]@{
                Role          = $_.RoleName
                ResourceGroup = $_.ScopeDisplayName
                Status        = $state
                Subscription  = $_.SubscriptionId
            }
        } | Format-Table -AutoSize
    return
}

# ---- select targets ----------------------------------------------------------

$targets = @()
if ($All) {
    $targets = @($eligible)
} elseif ($ResourceGroup) {
    foreach ($pattern in $ResourceGroup) {
        $matched = @($eligible | Where-Object {
            $_.ResourceGroup -and ($_.ResourceGroup -like $pattern -or $_.ScopeDisplayName -like $pattern)
        })
        if ($matched.Count -eq 0) { Write-Warn "No eligible assignment matches '$pattern'." }
        $targets += $matched
    }
} else {
    throw "Nothing to do. Pass -ResourceGroup, -All, or -List (or save defaults with -SaveDefaults)."
}

if ($Role -ne '*') {
    $targets = @($targets | Where-Object { $_.RoleName -eq $Role })
}
$targets = @($targets | Sort-Object Scope, RoleName -Unique)

if ($targets.Count -eq 0) {
    Write-Warn "No eligible '$Role' assignments matched your filters. Run with -List to see what you have."
    return
}

# ---- build requests ----------------------------------------------------------

$verb        = if ($Deactivate) { 'Deactivating' } else { 'Activating' }
$requestType = if ($Deactivate) { 'SelfDeactivate' } else { 'SelfActivate' }

Write-Step "$verb $Role on $($targets.Count) scope(s)$(if (-not $Deactivate) { " for $(Format-Duration $isoDuration)" })"

function Submit-PimRequest {
    param($Target, [hashtable]$Headers)

    $props = [ordered]@{
        principalId      = $myOid
        roleDefinitionId = $Target.RoleDefinitionId
        requestType      = $requestType
        justification    = $Justification
    }
    if (-not $Deactivate) {
        $props.linkedRoleEligibilityScheduleId = $Target.EligibilityId
        $props.scheduleInfo = [ordered]@{
            startDateTime = $null
            expiration    = [ordered]@{
                type     = 'AfterDuration'
                duration = $isoDuration
            }
        }
    }
    if ($TicketNumber -or $TicketSystem) {
        $props.ticketInfo = [ordered]@{ ticketNumber = $TicketNumber; ticketSystem = $TicketSystem }
    }

    $uri = "$ArmRoot$($Target.Scope)/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/$([guid]::NewGuid())" +
           "?api-version=$ApiVersion"

    try {
        $response = Invoke-Arm -Method PUT -Uri $uri -Headers $Headers -Body @{ properties = $props }
        return [pscustomobject]@{
            Outcome = 'Submitted'
            Name    = $Target.ScopeDisplayName
            Uri     = $uri
            Status  = $response.properties.status
        }
    }
    catch {
        return [pscustomobject]@{
            Outcome = 'Failed'
            Name    = $Target.ScopeDisplayName
            Uri     = $uri
            Message = (Get-ArmErrorMessage $_)
        }
    }
}

# Entra returns the exact claims challenge to satisfy inside the error text.
function Get-ClaimsChallengeFromError {
    param([string]$Message)
    if ($Message -match 'claims=(?<c>[^\s&"'']+)') {
        $decoded = [uri]::UnescapeDataString($Matches['c'])
        try { $null = $decoded | ConvertFrom-Json } catch { return $null }
        return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($decoded))
    }
    return $null
}

function Invoke-StepUpLogin {
    param([string]$ClaimsBase64)

    # az reuses a cached access token even after `az logout`, so the MSAL access-token
    # cache has to be dropped for the step-up token to actually be picked up.
    $cache = Join-Path $HOME '.azure\msal_token_cache.bin'
    if (Test-Path $cache) { Remove-Item $cache -Force -ErrorAction SilentlyContinue }

    $loginArgs = @('login', '--only-show-errors', '--output', 'none')
    if ($ClaimsBase64) { $loginArgs += @('--claims-challenge', $ClaimsBase64) }
    if ($TenantId)     { $loginArgs += @('--tenant', $TenantId) }

    Write-Warn 'Complete the sign-in / MFA prompt in the browser that just opened...'
    & az @loginArgs
    if ($LASTEXITCODE -ne 0) { throw 'Step-up sign-in failed.' }

    $fresh = Get-ArmToken
    return @{ Authorization = "Bearer $fresh" }
}

$pending    = @()
$retryQueue = @()

foreach ($t in $targets) {
    $existing = Test-IsActive -Candidate $t -ActiveList $active

    if (-not $Deactivate -and $existing) {
        $suffix = ''
        if ($existing.EndDateTime) {
            $mins = [int]([datetime]$existing.EndDateTime - [datetime]::UtcNow).TotalMinutes
            if ($mins -gt 0) { $suffix = " (expires in $([int]($mins / 60))h $($mins % 60)m)" }
        }
        Write-Skip "$($t.ScopeDisplayName) - already active$suffix"
        continue
    }
    if ($Deactivate -and -not $existing) {
        Write-Skip "$($t.ScopeDisplayName) - not active"
        continue
    }

    $r = Submit-PimRequest -Target $t -Headers $headers
    if ($r.Outcome -eq 'Submitted') {
        Write-Ok "$($t.ScopeDisplayName) - submitted [$($r.Status)]"
        $pending += $r
        continue
    }

    $msg = $r.Message
    if ($msg -match 'RoleAssignmentExists') {
        Write-Skip "$($t.ScopeDisplayName) - already active"
    }
    elseif ($msg -match 'PendingRoleAssignmentRequest') {
        Write-Warn "$($t.ScopeDisplayName) - a request is already pending (likely awaiting approval)."
    }
    elseif ($msg -match 'AcrsValidationFailed|RequestDisallowedByAzure|(?i)\bMFA\b|MfaRule') {
        # Conditional Access / PIM authentication-context step-up required.
        $retryQueue += [pscustomobject]@{ Target = $t; Message = $msg }
    }
    elseif ($msg -match 'RoleAssignmentRequestPolicyValidationFailed') {
        Write-Err "$($t.ScopeDisplayName) - policy rejected the request: $msg"
        Write-Err '      Common causes: duration exceeds the policy maximum, or justification /'
        Write-Err '      ticket info / approval required. Try -TicketNumber and -TicketSystem.'
    }
    else {
        Write-Err "$($t.ScopeDisplayName) - $msg"
    }
}

# ---- step up and retry -------------------------------------------------------

if ($retryQueue.Count -gt 0) {
    Write-Host ''
    Write-Warn "$($retryQueue.Count) request(s) need a stronger/fresher sign-in (PIM authentication context)."

    if ($NoReauth) {
        foreach ($q in $retryQueue) { Write-Err "$($q.Target.ScopeDisplayName) - $($q.Message)" }
        Write-Warn 'Re-run without -NoReauth to sign in and retry automatically.'
    }
    else {
        $challenge = $null
        foreach ($q in $retryQueue) {
            $challenge = Get-ClaimsChallengeFromError $q.Message
            if ($challenge) { break }
        }
        if (-not $challenge) {
            # Fall back to explicitly demanding an MFA claim.
            $challenge = [Convert]::ToBase64String(
                [Text.Encoding]::UTF8.GetBytes('{"access_token":{"amr":{"essential":true,"values":["mfa"]}}}'))
        }

        Write-Step 'Re-authenticating to satisfy the PIM policy'
        $headers = Invoke-StepUpLogin -ClaimsBase64 $challenge

        Write-Step "Retrying $($retryQueue.Count) request(s)"
        foreach ($q in $retryQueue) {
            $r = Submit-PimRequest -Target $q.Target -Headers $headers
            if ($r.Outcome -eq 'Submitted') {
                Write-Ok "$($r.Name) - submitted [$($r.Status)]"
                $pending += $r
            }
            elseif ($r.Message -match 'RoleAssignmentExists') {
                Write-Skip "$($r.Name) - already active"
            }
            elseif ($r.Message -match 'PendingRoleAssignmentRequest') {
                Write-Warn "$($r.Name) - a request is already pending (likely awaiting approval)."
            }
            else {
                Write-Err "$($r.Name) - $($r.Message)"
            }
        }
    }
}

if ($SaveDefaults) {
    $toSave = [ordered]@{
        resourceGroups = @($targets | ForEach-Object { $_.ScopeDisplayName } | Sort-Object -Unique)
        role           = $Role
        duration       = $Duration
        justification  = $Justification
        ticketNumber   = $TicketNumber
        ticketSystem   = $TicketSystem
    }
    $toSave | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigPath -Encoding UTF8
    Write-Ok "Saved defaults to $ConfigPath"
}

if ($pending.Count -eq 0) {
    Write-Step 'Nothing to wait for.'
    return
}
if ($NoWait) {
    Write-Step "$($pending.Count) request(s) submitted. Not waiting (-NoWait)."
    return
}

# ---- poll --------------------------------------------------------------------

Write-Step "Waiting for $($pending.Count) request(s) to provision (timeout ${TimeoutMinutes}m)"
$deadline  = (Get-Date).AddMinutes($TimeoutMinutes)
$done      = @{}
$terminalOk    = @('Provisioned', 'Granted', 'Revoked', 'Canceled')
$terminalFail  = @('Failed', 'FailedAsResourceIsLocked', 'Denied', 'TimedOut')

# Requests that already came back terminal need no polling.
foreach ($p in $pending) {
    if ($terminalOk -contains $p.Status) { $done[$p.Name] = $p.Status }
}

while ((Get-Date) -lt $deadline -and $done.Count -lt $pending.Count) {
    Start-Sleep -Seconds 5
    foreach ($p in $pending) {
        if ($done.ContainsKey($p.Name)) { continue }
        try {
            $r = Invoke-Arm -Method GET -Uri $p.Uri -Headers $headers
            $s = $r.properties.status
            if ($terminalOk -contains $s) {
                $done[$p.Name] = $s
                Write-Ok "$($p.Name) - $s"
            }
            elseif ($terminalFail -contains $s) {
                $done[$p.Name] = $s
                Write-Err "$($p.Name) - $s"
            }
            elseif ($s -match 'PendingApproval') {
                $done[$p.Name] = $s
                Write-Warn "$($p.Name) - $s (an approver must action this request)"
            }
        }
        catch {
            Write-Verbose "Poll failed for $($p.Name): $(Get-ArmErrorMessage $_)"
        }
    }
    if ($done.Count -lt $pending.Count) { Write-Host '.' -NoNewline -ForegroundColor DarkGray }
}
Write-Host ''

$stillWaiting = @($pending | Where-Object { -not $done.ContainsKey($_.Name) })
foreach ($p in $stillWaiting) {
    Write-Warn "$($p.Name) - still provisioning after ${TimeoutMinutes}m. It will likely complete shortly; re-run with -List to check."
}

$succeeded = @($done.GetEnumerator() | Where-Object { $terminalOk -contains $_.Value })
Write-Step "Done. $($succeeded.Count)/$($pending.Count) request(s) completed."
