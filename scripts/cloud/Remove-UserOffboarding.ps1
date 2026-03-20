<#
.SYNOPSIS
    Automates user offboarding in Azure Entra ID (formerly Azure AD).

.DESCRIPTION
    Disables user account, revokes sessions, removes licenses and group
    memberships, optionally converts mailbox to shared, and generates
    an offboarding report.

.PARAMETER UserPrincipalName
    UPN of the user to offboard.

.PARAMETER ConvertToShared
    Convert the user's mailbox to a shared mailbox before removing license.

.PARAMETER CsvPath
    Path to a CSV file for bulk offboarding.

.EXAMPLE
    .\Remove-UserOffboarding.ps1 -UserPrincipalName "john.doe@company.com"

.EXAMPLE
    .\Remove-UserOffboarding.ps1 -CsvPath ".\data\terminated_users.csv"

.AUTHOR
    Caio Santana - https://github.com/carosrrr
#>

[CmdletBinding(DefaultParameterSetName = 'Single')]
param(
    [Parameter(ParameterSetName = 'Single', Mandatory = $true)]
    [string]$UserPrincipalName,

    [Parameter(ParameterSetName = 'Single')]
    [switch]$ConvertToShared,

    [Parameter(ParameterSetName = 'Bulk', Mandatory = $true)]
    [string]$CsvPath
)

# ------------------------------------------------
# Import helpers
# ------------------------------------------------
$helpersPath = Join-Path $PSScriptRoot "helpers"
. (Join-Path $helpersPath "Connect-GraphHelper.ps1")
. (Join-Path $helpersPath "Write-Report.ps1")
. (Join-Path $helpersPath "Send-Notification.ps1")

# ------------------------------------------------
# Load configuration
# ------------------------------------------------
$configPath = Join-Path (Join-Path (Split-Path $PSScriptRoot) "config") "config.json"

if (-not (Test-Path $configPath)) {
    Write-Error "Configuration file not found at $configPath."
    exit 1
}

$config = Get-Content $configPath | ConvertFrom-Json

# ------------------------------------------------
# Functions
# ------------------------------------------------

function Remove-OffboardUser {
    <#
    .SYNOPSIS
        Executes the full offboarding workflow for a single user.
    #>
    param(
        [string]$UPN,
        [bool]$ConvertMailbox = $false
    )

    $result = [PSCustomObject]@{
        UserPrincipalName = $UPN
        DisplayName       = $null
        Status            = 'Pending'
        Details           = @()
        Timestamp         = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    }

    try {
        Write-Host "`n---------------------------------------------------------------------------------------------------------------------------" -ForegroundColor Red
        Write-Host "  Offboarding: $UPN" -ForegroundColor Red
        Write-Host "---------------------------------------------------------------------------------------------------------------------------" -ForegroundColor Red

        # Verify user exists
        $user = Get-MgUser -UserId $UPN -Property "Id,DisplayName,UserPrincipalName,AssignedLicenses"
        $result.DisplayName = $user.DisplayName
        Write-Host "  Found: $($user.DisplayName)" -ForegroundColor DarkGray

        # Step 1: Disable account
        Write-Host "`n[1/6] Disabling account..." -ForegroundColor Yellow
        Update-MgUser -UserId $user.Id -AccountEnabled:$false
        $result.Details += "Account disabled"
        Write-Host "  - Account disabled" -ForegroundColor Green

        # Step 2: Revoke all sessions
        Write-Host "[2/6] Revoking active sessions..." -ForegroundColor Yellow
        Revoke-MgUserSignInSession -UserId $user.Id
        $result.Details += "All sessions revoked"
        Write-Host "  - All sessions revoked" -ForegroundColor Green

        # Step 3: Reset password to random (extra security)
        Write-Host "[3/6] Resetting password..." -ForegroundColor Yellow
        $randomPassword = -join ((48..57) + (65..90) + (97..122) + (33..47) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
        $passwordProfile = @{
            Password                      = $randomPassword
            ForceChangePasswordNextSignIn  = $true
        }
        Update-MgUser -UserId $user.Id -PasswordProfile $passwordProfile
        $result.Details += "Password reset to random value"
        Write-Host "  - Password reset" -ForegroundColor Green

        # Step 4: Remove group memberships
        Write-Host "[4/6] Removing group memberships..." -ForegroundColor Yellow
        $groups = Get-MgUserMemberOf -UserId $user.Id
        $removedGroups = 0

        foreach ($group in $groups) {
            try {
                # Only remove from groups (not directory roles)
                if ($group.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.group') {
                    Remove-MgGroupMemberByRef -GroupId $group.Id -DirectoryObjectId $user.Id
                    $removedGroups++
                }
            }
            catch {
                # Some groups may not allow removal (dynamic groups)
                Write-Host "  - Could not remove from group: $($group.Id)" -ForegroundColor DarkYellow
            }
        }

        $result.Details += "Removed from $removedGroups groups"
        Write-Host "  - Removed from $removedGroups groups" -ForegroundColor Green

        # Step 5: Convert mailbox to shared (optional)
        Write-Host "[5/6] Mailbox conversion..." -ForegroundColor Yellow
        if ($ConvertMailbox) {
            # Note: Requires Exchange Online PowerShell module
            try {
                Set-Mailbox -Identity $UPN -Type Shared
                $result.Details += "Mailbox converted to shared"
                Write-Host "  - Mailbox converted to shared" -ForegroundColor Green
            }
            catch {
                Write-Warning "  - Could not convert mailbox. Ensure Exchange Online module is loaded."
                $result.Details += "Mailbox conversion failed - requires Exchange Online module"
            }
        }
        else {
            Write-Host "  --- Skipped (not requested)" -ForegroundColor DarkGray
        }

        # Step 6: Remove licenses
        Write-Host "[6/6] Removing licenses..." -ForegroundColor Yellow
        $assignedLicenses = $user.AssignedLicenses

        if ($assignedLicenses.Count -gt 0) {
            $licenseParams = @{
                AddLicenses    = @()
                RemoveLicenses = $assignedLicenses.SkuId
            }
            Set-MgUserLicense -UserId $user.Id @licenseParams
            $result.Details += "Removed $($assignedLicenses.Count) licenses"
            Write-Host "  - Removed $($assignedLicenses.Count) licenses" -ForegroundColor Green
        }
        else {
            Write-Host "  --- No licenses to remove" -ForegroundColor DarkGray
        }

        # Update user properties to mark as offboarded
        $offboardNote = "Offboarded on $(Get-Date -Format 'yyyy-MM-dd') by automation script"
        Update-MgUser -UserId $user.Id -Department "OFFBOARDED" -CompanyName $offboardNote

        $result.Status = 'Success'
        Write-Host "`n  - Offboarding complete for $($user.DisplayName)" -ForegroundColor Green

        # Send notification
        if ($config.notificationEmail) {
            $notificationData = @{
                UserDisplayName   = $user.DisplayName
                UserPrincipalName = $UPN
                GroupsRemoved     = $removedGroups
                LicensesRemoved   = $assignedLicenses.Count
            }
            Send-OffboardingNotification -To $config.notificationEmail -Data $notificationData
            Write-Host "  - Notification sent" -ForegroundColor Green
        }
    }
    catch {
        $result.Status = 'Failed'
        $result.Details += "Error: $($_.Exception.Message)"
        Write-Host "`n  - Offboarding failed: $($_.Exception.Message)" -ForegroundColor Red
    }

    return $result
}

# ------------------------------------------------
# Main Execution
# ------------------------------------------------

Write-Host ""
Write-Host "-------------------------------------------------" -ForegroundColor Red
Write-Host "-   Azure Entra ID - User Offboarding Tool    -" -ForegroundColor Red
Write-Host "-   github.com/carosrrr                       -" -ForegroundColor Red
Write-Host "------------------------------------------------" -ForegroundColor Red

# Connect to Microsoft Graph
Connect-GraphWithConfig -Config $config

$results = @()

if ($PSCmdlet.ParameterSetName -eq 'Bulk') {
    if (-not (Test-Path $CsvPath)) {
        Write-Error "CSV file not found: $CsvPath"
        exit 1
    }

    $users = Import-Csv $CsvPath
    $total = $users.Count
    Write-Host "`n- About to offboard $total users. Continue? (Y/N)" -ForegroundColor Yellow
    $confirm = Read-Host

    if ($confirm -ne 'Y') {
        Write-Host "Aborted." -ForegroundColor Red
        exit 0
    }

    $counter = 0
    foreach ($user in $users) {
        $counter++
        Write-Host "`n[$counter/$total]" -ForegroundColor DarkGray

        $shouldConvert = $user.ConvertToShared -eq 'Yes'
        $result = Remove-OffboardUser -UPN $user.UserPrincipalName -ConvertMailbox $shouldConvert
        $results += $result
    }
}
else {
    $result = Remove-OffboardUser -UPN $UserPrincipalName -ConvertMailbox $ConvertToShared.IsPresent
    $results += $result
}

# ------------------------------------------------
# Generate Report
# ------------------------------------------------
$reportPath = Join-Path (Split-Path $PSScriptRoot) "reports"
if (-not (Test-Path $reportPath)) {
    New-Item -ItemType Directory -Path $reportPath -Force | Out-Null
}

$reportFile = Join-Path $reportPath "offboarding-report-$(Get-Date -Format 'yyyy-MM-dd-HHmmss').json"
$reportData = @{
    GeneratedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    TotalUsers  = $results.Count
    Successful  = ($results | Where-Object { $_.Status -eq 'Success' }).Count
    Failed      = ($results | Where-Object { $_.Status -eq 'Failed' }).Count
    Results     = $results
}

$reportData | ConvertTo-Json -Depth 5 | Out-File $reportFile -Encoding UTF8

# Summary
Write-Host "`n-------------------------------------------------" -ForegroundColor Red
Write-Host "-                  SUMMARY                     -" -ForegroundColor Red
Write-Host "------------------------------------------------" -ForegroundColor Red
Write-Host "-  Total processed: $($results.Count)                        -" -ForegroundColor White
Write-Host "-  Successful:      $($reportData.Successful)                        -" -ForegroundColor Green
Write-Host "-  Failed:          $($reportData.Failed)                        -" -ForegroundColor $(if ($reportData.Failed -gt 0) { 'Red' } else { 'White' })
Write-Host "-  Report saved:    $reportFile  -" -ForegroundColor White
Write-Host "------------------------------------------------" -ForegroundColor Red
