<#
.SYNOPSIS
    Creates a new user in on-premises Active Directory via webhook trigger.

.DESCRIPTION
    Designed to run as an Azure Automation Runbook on a Hybrid Runbook Worker.
    Receives user data via webhook (e.g., Zapier triggered by BambooHR),
    creates the AD account, sets attributes, adds to groups, and returns
    a JSON result.

    Requires: Windows PowerShell 5.1, AD RSAT installed on the Hybrid Worker.

.TRIGGER
    Webhook (Zapier, Power Automate, Postman, etc.)

.EXAMPLE PAYLOAD
    {
        "firstName": "John",
        "lastName": "Doe",
        "userPrincipalName": "john.doe@company.com",
        "jobTitle": "Software Engineer",
        "department": "Engineering",
        "manager": "Jane Smith",
        "groups": ["grp_ssl_users", "grp_engineering"],
        "autoGeneratePassword": true,
        "returnPassword": true
    }

.AUTHOR
    Caio Santana - https://github.com/carosrrr
#>

param(
    [Parameter(Mandatory = $false)]
    [object]$WebhookData
)

# ═══════════════════════════════════════════════
# SETTINGS — Update these for your environment
# ═══════════════════════════════════════════════
$DefaultTargetOU         = "OU=Users,OU=Company,OU=Offices,DC=yourdomain,DC=com"
$DefaultGroups           = @("grp_ssl_users", "grp_default_access")
$DefaultCompany          = "YourCompany"
$DefaultChangePwdAtLogon = $false

# ═══════════════════════════════════════════════
# UTILITY FUNCTIONS
# ═══════════════════════════════════════════════

function New-StrongPassword {
    <#
    .SYNOPSIS
        Generates a cryptographically secure password using RNG.
        Ensures at least one uppercase, lowercase, digit, and special char.
    #>
    param([int]$Length = 14)
    if ($Length -lt 8) { throw "Password length must be >= 8." }

    $upper   = "ABCDEFGHJKLMNPQRSTUVWXYZ"
    $lower   = "abcdefghjkmnpqrstuvwxyz"
    $digits  = "23456789"
    $special = "!@#$%&*()=+.?"
    $all     = $upper + $lower + $digits + $special

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    function Get-Rand([int]$max) {
        $bytes = New-Object byte[] 4
        $rng.GetBytes($bytes)
        return [int]([BitConverter]::ToUInt32($bytes, 0) % $max)
    }

    $chars = New-Object System.Collections.Generic.List[char]
    # Guarantee complexity requirements
    $chars.Add($upper[  (Get-Rand $upper.Length)  ])
    $chars.Add($lower[  (Get-Rand $lower.Length)  ])
    $chars.Add($digits[ (Get-Rand $digits.Length) ])
    $chars.Add($special[(Get-Rand $special.Length)])

    # Fill remaining length
    for ($i = $chars.Count; $i -lt $Length; $i++) {
        $chars.Add($all[(Get-Rand $all.Length)])
    }

    # Fisher-Yates shuffle
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = Get-Rand ($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }

    $password = -join $chars
    $rng.Dispose()
    return $password
}

function Resolve-ManagerDN {
    <#
    .SYNOPSIS
        Resolves a manager's Distinguished Name from UPN, SAM, or DisplayName.
    #>
    param(
        [string]$DisplayName,
        [string]$UserPrincipalName,
        [string]$SamAccountName
    )
    try {
        if ($UserPrincipalName) {
            $u = Get-ADUser -Filter "UserPrincipalName -eq '$UserPrincipalName'" -Properties DistinguishedName -ErrorAction SilentlyContinue
            if ($u) { return $u.DistinguishedName }
        }
        if ($SamAccountName) {
            $s = Get-ADUser -Filter "SamAccountName -eq '$SamAccountName'" -Properties DistinguishedName -ErrorAction SilentlyContinue
            if ($s) { return $s.DistinguishedName }
        }
        if ($DisplayName) {
            $d = Get-ADUser -Filter "DisplayName -eq '$DisplayName'" -Properties DistinguishedName -ErrorAction SilentlyContinue
            if ($d) { return $d.DistinguishedName }
        }
    } catch {}
    return $null
}

function Write-JsonResult {
    <#
    .SYNOPSIS
        Outputs a hashtable as compressed JSON for Runbook response.
    #>
    param([hashtable]$Obj)
    $Obj | ConvertTo-Json -Depth 6 -Compress | Write-Output
}

# ═══════════════════════════════════════════════
# INPUT HELPERS
# ═══════════════════════════════════════════════

function Require($value, $name) {
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Missing required field: $name"
    }
}

function Norm([object]$v) {
    if ($null -eq $v) { return $null }
    else { return ([string]$v).Trim() }
}

# ═══════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════

# Verify AD module is available
try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Write-JsonResult @{
        status  = "error"
        stage   = "import-admodule"
        message = "ActiveDirectory module not found on the Hybrid Runbook Worker."
        detail  = "$($_.Exception.Message)"
    }
    exit 1
}

# Validate webhook input
if (-not $WebhookData) {
    Write-JsonResult @{
        status  = "error"
        stage   = "input"
        message = "This runbook must be triggered by a webhook and requires RequestBody."
    }
    exit 1
}

# Parse JSON payload
$BodyRaw = $WebhookData.RequestBody
try {
    $Body = $BodyRaw | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-JsonResult @{
        status    = "error"
        stage     = "json-parse"
        message   = "Invalid JSON body."
        detail    = "$($_.Exception.Message)"
        bodySample = $BodyRaw
    }
    exit 1
}

# ─── Extract and normalize fields ───
$FullNameRaw = Norm $Body.fullName
$FirstName   = Norm $Body.firstName
$LastName    = Norm $Body.lastName
$UPN         = Norm $Body.userPrincipalName
$Email       = Norm $Body.mail
$Sam         = Norm $Body.samAccountName

# Build full name from parts if not provided
if ([string]::IsNullOrWhiteSpace($FullNameRaw)) {
    if (-not [string]::IsNullOrWhiteSpace($FirstName) -or -not [string]::IsNullOrWhiteSpace($LastName)) {
        $FullNameRaw = ($FirstName, $LastName -join ' ').Trim()
    }
}

# Derive SAM from UPN if not provided
if ([string]::IsNullOrWhiteSpace($Sam) -and -not [string]::IsNullOrWhiteSpace($UPN)) {
    $Sam = ($UPN -split '@')[0]
}

$Email      = if ($Email) { $Email } else { $UPN }
$Title      = Norm $Body.jobTitle
$Department = Norm $Body.department
$EmployeeID = Norm $Body.employeeID
$City       = Norm $Body.city
$Country    = Norm $Body.country
$Company    = Norm $Body.company;  if (-not $Company)  { $Company  = $DefaultCompany }
$TargetOU   = Norm $Body.targetOU; if (-not $TargetOU) { $TargetOU = $DefaultTargetOU }

# ─── Parse groups (supports array, comma-separated string, or default) ───
$Groups = @()
if ($Body.PSObject.Properties.Name -contains 'groups' -and $null -ne $Body.groups) {
    if ($Body.groups -is [System.Array]) {
        $Groups = @($Body.groups | ForEach-Object { Norm $_ } | Where-Object { $_ })
    }
    elseif ($Body.groups -is [string]) {
        $clean = (Norm $Body.groups).Trim('[', ']')
        $Groups = @(
            $clean -split '[,;]' |
            ForEach-Object { $_.Trim() } |
            ForEach-Object { $_.Trim('"', "'", ' ') } |
            Where-Object { $_ }
        )
    }
}
if ($Groups.Count -eq 0) { $Groups = $DefaultGroups }

$ChangeAtLogon  = if ($null -ne $Body.changePasswordAtLogon) { [bool]$Body.changePasswordAtLogon } else { $DefaultChangePwdAtLogon }
$ReturnPassword = [bool]$Body.returnPassword

# ─── Validate required fields ───
try {
    Require $FullNameRaw 'fullName or (firstName + lastName)'
    Require $UPN         'userPrincipalName'
    Require $Sam         'samAccountName (or provide userPrincipalName so it can be derived)'
} catch {
    Write-JsonResult @{ status = "error"; stage = "validation"; message = "$($_.Exception.Message)" }
    exit 1
}

$FullName = $FullNameRaw

# ─── Password handling ───
$NeedAuto = $true
if ($Body.PSObject.Properties.Name -contains 'initialPassword' -and [string]::IsNullOrWhiteSpace($Body.initialPassword) -eq $false) {
    if (-not $Body.autoGeneratePassword -or $Body.autoGeneratePassword -eq $false) {
        $NeedAuto = $false
    }
}
$PlainPassword  = if ($NeedAuto) { New-StrongPassword -Length 14 } else { [string]$Body.initialPassword }
$SecurePassword = ConvertTo-SecureString $PlainPassword -AsPlainText -Force

# ─── Resolve manager ───
$ManagerDN = $null
if ($Body.manager -or $Body.managerUpn -or $Body.managerSam) {
    $ManagerDN = Resolve-ManagerDN `
        -DisplayName $Body.manager `
        -UserPrincipalName $Body.managerUpn `
        -SamAccountName $Body.managerSam
}

# ─── Idempotency check: skip if user already exists ───
if ($UPN -and (Get-ADUser -Filter "UserPrincipalName -eq '$UPN'" -ErrorAction SilentlyContinue)) {
    Write-JsonResult @{ status = "exists"; reason = "UPN already present"; upn = $UPN; sam = $Sam }
    exit 0
}
if ($Sam -and (Get-ADUser -Filter "SamAccountName -eq '$Sam'" -ErrorAction SilentlyContinue)) {
    Write-JsonResult @{ status = "exists"; reason = "sAMAccountName already present"; upn = $UPN; sam = $Sam }
    exit 0
}

# ─── Create the user ───
$Params = @{
    Name                  = $FullName
    DisplayName           = $FullName
    UserPrincipalName     = $UPN
    EmailAddress          = $Email
    SamAccountName        = $Sam
    GivenName             = $FirstName
    Surname               = $LastName
    Title                 = $Title
    Description           = $Title
    Department            = $Department
    Company               = $Company
    Path                  = $TargetOU
    Enabled               = $true
    AccountPassword       = $SecurePassword
    ChangePasswordAtLogon = $ChangeAtLogon
}
if ($EmployeeID) { $Params.EmployeeID = $EmployeeID }
if ($City)       { $Params.City       = $City }
if ($Country)    { $Params.Country    = $Country }
if ($ManagerDN)  { $Params.Manager    = $ManagerDN }

try {
    New-ADUser @Params
} catch {
    Write-JsonResult @{
        status  = "error"
        stage   = "create-user"
        message = "$($_.Exception.Message)"
        upn     = $UPN
        sam     = $Sam
    }
    exit 1
}

# ─── Verify user was created (retry up to 5 times) ───
$userObject = $null
for ($i = 0; $i -lt 5; $i++) {
    $userObject = Get-ADUser -Filter "UserPrincipalName -eq '$UPN'" -ErrorAction SilentlyContinue
    if ($userObject) { break }
    Start-Sleep -Milliseconds 500
}
if (-not $userObject) {
    Write-JsonResult @{
        status  = "warning"
        stage   = "post-create-lookup"
        message = "User created but not yet queryable"
        upn     = $UPN
        sam     = $Sam
    }
    exit 0
}

# ─── Add to groups ───
$GroupResults = @()
foreach ($g in $Groups) {
    $grpObj = Get-ADGroup -LDAPFilter "(name=$g)" -ErrorAction SilentlyContinue
    if (-not $grpObj) {
        $GroupResults += @{ group = $g; result = "not_found" }
        continue
    }
    try {
        Add-ADGroupMember -Identity $grpObj -Members $userObject -ErrorAction Stop
        $GroupResults += @{ group = $g; result = "added" }
    } catch {
        $GroupResults += @{ group = $g; result = "failed"; error = "$($_.Exception.Message)" }
    }
}

# ─── Return result ───
$result = @{
    status = "created"
    upn    = $UPN
    sam    = $Sam
    groups = $GroupResults
}
if ($ReturnPassword) { $result.tempPassword = $PlainPassword }

Write-JsonResult $result
