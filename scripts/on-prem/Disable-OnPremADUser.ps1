<#
.SYNOPSIS
    Disables a user in on-premises Active Directory via webhook trigger.

.DESCRIPTION
    Designed to run as an Azure Automation Runbook on a Hybrid Runbook Worker.
    Receives user data via webhook (e.g., Zapier triggered by BambooHR status change),
    disables the account, removes all group memberships, clears manager,
    moves to a Disabled Users OU, and triggers AAD Connect delta sync.

    Requires: Windows PowerShell 5.1, AD RSAT, AAD Connect on the Hybrid Worker.

.TRIGGER
    Webhook (Zapier from BambooHR, Power Automate, etc.)

.EXAMPLE PAYLOAD
    {
        "workEmail": "john.doe@company.com",
        "reason": "BambooHR status -> Inactive"
    }

.AUTHOR
    Caio Santana - https://github.com/carosrrr
#>

param(
    [Parameter(Mandatory = $false)]
    [object]$WebhookData
)

# 
# SETTINGS  Update these for your environment
# 
$TargetOU              = "OU=Disabled Users,OU=Company,OU=Offices,DC=yourdomain,DC=com"
$DescriptionPrefix     = "Leaver"
$TriggerAadConnectSync = $true
$AdSyncModulePath      = "C:\Program Files\Microsoft Azure AD Sync\Bin\ADSync\ADSync.psd1"

# 
# HELPERS
# 

function Norm([object]$v) {
    if ($null -eq $v) { $null }
    else { ([string]$v).Trim() }
}

function OutJson($obj) {
    $obj | ConvertTo-Json -Depth 6 -Compress | Write-Output
}

# 
# MAIN EXECUTION
# 

if (-not $WebhookData) {
    Write-Output "This runbook must be called via webhook."
    exit 1
}

Import-Module ActiveDirectory -ErrorAction Stop

# Parse payload
try {
    $Body = $WebhookData.RequestBody | ConvertFrom-Json -ErrorAction Stop
} catch {
    OutJson @{
        status  = "error"
        stage   = "parse"
        message = "$($_.Exception.Message)"
    }
    exit 1
}

# Accept common keys from BambooHR/Zapier payloads
$workEmail = Norm $Body.workEmail
$upn       = Norm $Body.userPrincipalName
$email     = if ($workEmail) { $workEmail } else { $upn }
$reason    = Norm $Body.reason

if ([string]::IsNullOrWhiteSpace($email)) {
    OutJson @{
        status  = "error"
        stage   = "validate"
        message = "Missing workEmail/userPrincipalName"
    }
    exit 1
}

#  Find the user (UPN first, then mail/proxyAddresses) 
$user = Get-ADUser -Filter "UserPrincipalName -eq '$email'" `
    -Properties MemberOf, Manager, Enabled, DistinguishedName `
    -ErrorAction SilentlyContinue

if (-not $user) {
    $user = Get-ADUser -LDAPFilter "(|(proxyAddresses=SMTP:$email)(mail=$email))" `
        -Properties MemberOf, Manager, Enabled, DistinguishedName `
        -ErrorAction SilentlyContinue
}

if (-not $user) {
    OutJson @{ status = "not_found"; query = $email }
    exit 0
}

$dn    = $user.DistinguishedName
$today = Get-Date -Format "yyyy/MM/dd"
$desc  = "$today - $DescriptionPrefix" + $(if ($reason) { " ($reason)" } else { "" })

$actions = @()

#  Step 1: Disable account 
try {
    if (-not $user.Enabled) {
        $actions += @{ action = "disable"; result = "already_disabled" }
    } else {
        Disable-ADAccount -Identity $dn -ErrorAction Stop
        $actions += @{ action = "disable"; result = "ok" }
    }
} catch {
    $actions += @{ action = "disable"; result = "error"; error = "$($_.Exception.Message)" }
}

#  Step 2: Remove from all groups 
try {
    $removed = @()
    foreach ($g in $user.MemberOf) {
        try {
            Remove-ADGroupMember -Identity $g -Members $user -Confirm:$false -ErrorAction Stop
            $removed += (Get-ADGroup $g).Name
        } catch {
            $actions += @{
                action = "remove_group"
                group  = $g
                result = "error"
                error  = "$($_.Exception.Message)"
            }
        }
    }
    $actions += @{
        action = "remove_groups"
        result = "ok"
        count  = $removed.Count
        groups = $removed
    }
} catch {
    $actions += @{ action = "remove_groups"; result = "error"; error = "$($_.Exception.Message)" }
}

#  Step 3: Clear manager 
try {
    Set-ADUser -Identity $dn -Manager $null -ErrorAction Stop
    $actions += @{ action = "clear_manager"; result = "ok" }
} catch {
    $actions += @{ action = "clear_manager"; result = "error"; error = "$($_.Exception.Message)" }
}

#  Step 4: Set description with date and reason 
try {
    Set-ADUser -Identity $dn -Description $desc -ErrorAction Stop
    $actions += @{ action = "set_description"; result = "ok"; description = $desc }
} catch {
    $actions += @{ action = "set_description"; result = "error"; error = "$($_.Exception.Message)" }
}

#  Step 5: Move to Disabled Users OU 
try {
    Move-ADObject -Identity $dn -TargetPath $TargetOU -ErrorAction Stop
    $actions += @{ action = "move_ou"; result = "ok"; targetOU = $TargetOU }
} catch {
    $actions += @{
        action   = "move_ou"
        result   = "error"
        error    = "$($_.Exception.Message)"
        targetOU = $TargetOU
    }
}

#  Step 6: Trigger AAD Connect delta sync 
if ($TriggerAadConnectSync) {
    try {
        Import-Module $AdSyncModulePath -ErrorAction Stop
        Start-ADSyncSyncCycle -PolicyType Delta | Out-Null
        $actions += @{ action = "aad_connect_sync"; result = "ok" }
    } catch {
        $actions += @{
            action = "aad_connect_sync"
            result = "error"
            error  = "$($_.Exception.Message)"
        }
    }
}

#  Return structured result 
OutJson @{
    status  = "processed"
    upn     = $email
    dn      = $dn
    actions = $actions
}
