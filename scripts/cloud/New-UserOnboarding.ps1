<#
.SYNOPSIS
    Automates user onboarding in Azure Entra ID (formerly Azure AD).

.DESCRIPTION
    Creates a new user account, assigns Microsoft 365 licenses, adds the user
    to security and distribution groups, and optionally sends a welcome email.
    Supports both single-user and bulk operations via CSV.

.PARAMETER FirstName
    First name of the new user.

.PARAMETER LastName
    Last name of the new user.

.PARAMETER Department
    Department the user belongs to.

.PARAMETER JobTitle
    Job title for the new user.

.PARAMETER Manager
    UPN of the user's manager (optional).

.PARAMETER License
    License tier to assign: E1, E3, E5, or F1 (default: E3).

.PARAMETER CsvPath
    Path to a CSV file for bulk onboarding.

.EXAMPLE
    .\New-UserOnboarding.ps1 -FirstName "John" -LastName "Doe" -Department "Engineering" -JobTitle "Developer"

.EXAMPLE
    .\New-UserOnboarding.ps1 -CsvPath ".\data\new_hires.csv"

.AUTHOR
    Caio Santana - https://github.com/carosrrr
#>

[CmdletBinding(DefaultParameterSetName = 'Single')]
param(
    [Parameter(ParameterSetName = 'Single', Mandatory = $true)]
    [string]$FirstName,

    [Parameter(ParameterSetName = 'Single', Mandatory = $true)]
    [string]$LastName,

    [Parameter(ParameterSetName = 'Single', Mandatory = $true)]
    [string]$Department,

    [Parameter(ParameterSetName = 'Single', Mandatory = $true)]
    [string]$JobTitle,

    [Parameter(ParameterSetName = 'Single')]
    [string]$Manager,

    [Parameter(ParameterSetName = 'Single')]
    [ValidateSet('E1', 'E3', 'E5', 'F1')]
    [string]$License = 'E3',

    [Parameter(ParameterSetName = 'Bulk', Mandatory = $true)]
    [string]$CsvPath
)

# ─────────────────────────────────────────────
# Import helpers
# ─────────────────────────────────────────────
$helpersPath = Join-Path $PSScriptRoot "helpers"
. (Join-Path $helpersPath "Connect-GraphHelper.ps1")
. (Join-Path $helpersPath "Write-Report.ps1")
. (Join-Path $helpersPath "Send-Notification.ps1")

# ─────────────────────────────────────────────
# Load configuration
# ─────────────────────────────────────────────
$configPath = Join-Path (Split-Path $PSScriptRoot) "config" "config.json"

if (-not (Test-Path $configPath)) {
    Write-Error "Configuration file not found at $configPath. Please copy config.sample.json and update it."
    exit 1
}

$config = Get-Content $configPath | ConvertFrom-Json
$domain = $config.defaultDomain
$licenseSKUs = @{
    'E1' = $config.licenseSkus.E1
    'E3' = $config.licenseSkus.E3
    'E5' = $config.licenseSkus.E5
    'F1' = $config.licenseSkus.F1
}

# ─────────────────────────────────────────────
# Functions
# ─────────────────────────────────────────────

function New-SecureTemporaryPassword {
    <#
    .SYNOPSIS
        Generates a cryptographically secure temporary password.
    #>
    $length = 16
    $uppercase = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    $lowercase = 'abcdefghijklmnopqrstuvwxyz'
    $numbers = '0123456789'
    $special = '!@#$%&*?'
    $allChars = $uppercase + $lowercase + $numbers + $special

    # Ensure at least one of each type
    $password = @(
        $uppercase[(Get-Random -Maximum $uppercase.Length)]
        $lowercase[(Get-Random -Maximum $lowercase.Length)]
        $numbers[(Get-Random -Maximum $numbers.Length)]
        $special[(Get-Random -Maximum $special.Length)]
    )

    # Fill remaining with random characters
    for ($i = $password.Count; $i -lt $length; $i++) {
        $password += $allChars[(Get-Random -Maximum $allChars.Length)]
    }

    # Shuffle the password
    return ($password | Get-Random -Count $password.Count) -join ''
}

function New-UserPrincipalName {
    <#
    .SYNOPSIS
        Generates a UPN in the format firstname.lastname@domain.
        Handles duplicates by appending a number.
    #>
    param(
        [string]$FirstName,
        [string]$LastName,
        [string]$Domain
    )

    $baseName = "$($FirstName.ToLower()).$($LastName.ToLower())"
    # Remove accents and special characters
    $baseName = $baseName -replace '[^a-z0-9.]', ''
    $upn = "$baseName@$Domain"

    # Check if UPN already exists
    $counter = 1
    while ($true) {
        try {
            $existingUser = Get-MgUser -UserId $upn -ErrorAction Stop
            # User exists, try with number
            $upn = "$baseName$counter@$Domain"
            $counter++
        }
        catch {
            # User doesn't exist, UPN is available
            break
        }
    }

    return $upn
}

function New-OnboardUser {
    <#
    .SYNOPSIS
        Creates a single user with full onboarding workflow.
    #>
    param(
        [string]$FirstName,
        [string]$LastName,
        [string]$Department,
        [string]$JobTitle,
        [string]$Manager,
        [string]$LicenseTier
    )

    $result = [PSCustomObject]@{
        UserPrincipalName = $null
        DisplayName       = "$FirstName $LastName"
        Status            = 'Pending'
        Details           = @()
        Timestamp         = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    }

    try {
        Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
        Write-Host "  Onboarding: $FirstName $LastName" -ForegroundColor Cyan
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

        # Step 1: Generate UPN and password
        Write-Host "`n[1/6] Generating credentials..." -ForegroundColor Yellow
        $upn = New-UserPrincipalName -FirstName $FirstName -LastName $LastName -Domain $domain
        $tempPassword = New-SecureTemporaryPassword
        $result.UserPrincipalName = $upn
        Write-Host "  ✓ UPN: $upn" -ForegroundColor Green

        # Step 2: Create user in Entra ID
        Write-Host "[2/6] Creating user account..." -ForegroundColor Yellow
        $passwordProfile = @{
            Password                      = $tempPassword
            ForceChangePasswordNextSignIn  = $true
        }

        $userParams = @{
            DisplayName       = "$FirstName $LastName"
            GivenName         = $FirstName
            Surname           = $LastName
            UserPrincipalName = $upn
            MailNickname      = ($upn -split '@')[0]
            Department        = $Department
            JobTitle          = $JobTitle
            UsageLocation     = $config.usageLocation
            PasswordProfile   = $passwordProfile
            AccountEnabled    = $true
        }

        $newUser = New-MgUser @userParams
        $result.Details += "Account created successfully"
        Write-Host "  ✓ Account created" -ForegroundColor Green

        # Step 3: Assign license
        Write-Host "[3/6] Assigning $LicenseTier license..." -ForegroundColor Yellow
        $skuId = $licenseSKUs[$LicenseTier]

        if ($skuId) {
            $licenseParams = @{
                AddLicenses    = @(@{ SkuId = $skuId })
                RemoveLicenses = @()
            }
            Set-MgUserLicense -UserId $newUser.Id @licenseParams
            $result.Details += "$LicenseTier license assigned"
            Write-Host "  ✓ $LicenseTier license assigned" -ForegroundColor Green
        }
        else {
            Write-Warning "  ⚠ License SKU not found for tier: $LicenseTier"
            $result.Details += "License assignment skipped - SKU not configured"
        }

        # Step 4: Add to department groups
        Write-Host "[4/6] Adding to groups..." -ForegroundColor Yellow
        $departmentGroups = $config.departmentGroups | Where-Object { $_.department -eq $Department }

        if ($departmentGroups) {
            foreach ($groupId in $departmentGroups.groupIds) {
                try {
                    New-MgGroupMember -GroupId $groupId -DirectoryObjectId $newUser.Id
                    $groupInfo = Get-MgGroup -GroupId $groupId
                    Write-Host "  ✓ Added to group: $($groupInfo.DisplayName)" -ForegroundColor Green
                    $result.Details += "Added to group: $($groupInfo.DisplayName)"
                }
                catch {
                    Write-Warning "  ⚠ Could not add to group $groupId : $_"
                }
            }
        }

        # Add to default groups (all employees)
        foreach ($groupId in $config.defaultGroups) {
            try {
                New-MgGroupMember -GroupId $groupId -DirectoryObjectId $newUser.Id
                $groupInfo = Get-MgGroup -GroupId $groupId
                Write-Host "  ✓ Added to group: $($groupInfo.DisplayName)" -ForegroundColor Green
                $result.Details += "Added to group: $($groupInfo.DisplayName)"
            }
            catch {
                Write-Warning "  ⚠ Could not add to default group $groupId : $_"
            }
        }

        # Step 5: Set manager
        Write-Host "[5/6] Setting manager..." -ForegroundColor Yellow
        if ($Manager) {
            try {
                $managerUser = Get-MgUser -UserId $Manager
                $managerRef = @{
                    "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($managerUser.Id)"
                }
                Set-MgUserManagerByRef -UserId $newUser.Id -BodyParameter $managerRef
                Write-Host "  ✓ Manager set: $Manager" -ForegroundColor Green
                $result.Details += "Manager set: $Manager"
            }
            catch {
                Write-Warning "  ⚠ Could not set manager: $_"
                $result.Details += "Manager assignment failed"
            }
        }
        else {
            Write-Host "  — Skipped (no manager specified)" -ForegroundColor DarkGray
        }

        # Step 6: Send welcome notification
        Write-Host "[6/6] Sending notification..." -ForegroundColor Yellow
        if ($config.notificationEmail) {
            $notificationData = @{
                UserDisplayName   = "$FirstName $LastName"
                UserPrincipalName = $upn
                TempPassword      = $tempPassword
                Department        = $Department
                JobTitle          = $JobTitle
                License           = $LicenseTier
            }
            Send-OnboardingNotification -To $config.notificationEmail -Data $notificationData
            Write-Host "  ✓ Notification sent to $($config.notificationEmail)" -ForegroundColor Green
            $result.Details += "Welcome notification sent"
        }

        $result.Status = 'Success'
        Write-Host "`n  ✅ Onboarding complete for $FirstName $LastName" -ForegroundColor Green
    }
    catch {
        $result.Status = 'Failed'
        $result.Details += "Error: $($_.Exception.Message)"
        Write-Host "`n  ❌ Onboarding failed: $($_.Exception.Message)" -ForegroundColor Red
    }

    return $result
}

# ─────────────────────────────────────────────
# Main Execution
# ─────────────────────────────────────────────

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Azure Entra ID - User Onboarding Tool     ║" -ForegroundColor Cyan
Write-Host "║   github.com/carosrrr                       ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan

# Connect to Microsoft Graph
Connect-GraphWithConfig -Config $config

$results = @()

if ($PSCmdlet.ParameterSetName -eq 'Bulk') {
    # Bulk onboarding from CSV
    if (-not (Test-Path $CsvPath)) {
        Write-Error "CSV file not found: $CsvPath"
        exit 1
    }

    $users = Import-Csv $CsvPath
    $total = $users.Count
    Write-Host "`nProcessing $total users from CSV..." -ForegroundColor Yellow

    $counter = 0
    foreach ($user in $users) {
        $counter++
        Write-Host "`n[$counter/$total]" -ForegroundColor DarkGray

        $result = New-OnboardUser `
            -FirstName $user.FirstName `
            -LastName $user.LastName `
            -Department $user.Department `
            -JobTitle $user.JobTitle `
            -Manager $user.Manager `
            -LicenseTier ($user.License ?? 'E3')

        $results += $result
    }
}
else {
    # Single user onboarding
    $result = New-OnboardUser `
        -FirstName $FirstName `
        -LastName $LastName `
        -Department $Department `
        -JobTitle $JobTitle `
        -Manager $Manager `
        -LicenseTier $License

    $results += $result
}

# ─────────────────────────────────────────────
# Generate Report
# ─────────────────────────────────────────────
$reportPath = Join-Path (Split-Path $PSScriptRoot) "reports"
if (-not (Test-Path $reportPath)) {
    New-Item -ItemType Directory -Path $reportPath -Force | Out-Null
}

$reportFile = Join-Path $reportPath "onboarding-report-$(Get-Date -Format 'yyyy-MM-dd-HHmmss').json"
$reportData = @{
    GeneratedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    TotalUsers  = $results.Count
    Successful  = ($results | Where-Object { $_.Status -eq 'Success' }).Count
    Failed      = ($results | Where-Object { $_.Status -eq 'Failed' }).Count
    Results     = $results
}

$reportData | ConvertTo-Json -Depth 5 | Out-File $reportFile -Encoding UTF8

# Summary
Write-Host "`n╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                  SUMMARY                     ║" -ForegroundColor Cyan
Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  Total processed: $($results.Count)                        ║" -ForegroundColor White
Write-Host "║  Successful:      $($reportData.Successful)                        ║" -ForegroundColor Green
Write-Host "║  Failed:          $($reportData.Failed)                        ║" -ForegroundColor $(if ($reportData.Failed -gt 0) { 'Red' } else { 'White' })
Write-Host "║  Report saved:    $reportFile  ║" -ForegroundColor White
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
