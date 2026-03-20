<#
.SYNOPSIS
    Helper functions for sending email notifications via Microsoft Graph.
#>

function Send-OnboardingNotification {
    param(
        [string]$To,
        [hashtable]$Data
    )

    try {
        $body = @"
<h2>New User Onboarded Successfully</h2>
<table style="border-collapse: collapse; font-family: Arial, sans-serif;">
    <tr><td style="padding: 8px; font-weight: bold;">Name:</td><td style="padding: 8px;">$($Data.UserDisplayName)</td></tr>
    <tr><td style="padding: 8px; font-weight: bold;">UPN:</td><td style="padding: 8px;">$($Data.UserPrincipalName)</td></tr>
    <tr><td style="padding: 8px; font-weight: bold;">Department:</td><td style="padding: 8px;">$($Data.Department)</td></tr>
    <tr><td style="padding: 8px; font-weight: bold;">Job Title:</td><td style="padding: 8px;">$($Data.JobTitle)</td></tr>
    <tr><td style="padding: 8px; font-weight: bold;">License:</td><td style="padding: 8px;">$($Data.License)</td></tr>
    <tr><td style="padding: 8px; font-weight: bold;">Temp Password:</td><td style="padding: 8px; font-family: monospace; background: #f0f0f0;">$($Data.TempPassword)</td></tr>
</table>
<p style="margin-top: 16px; color: #666;">This is an automated notification from the Azure User Lifecycle Automation tool.</p>
"@

        $message = @{
            Message = @{
                Subject      = "Onboarding Complete: $($Data.UserDisplayName)"
                Body         = @{
                    ContentType = "HTML"
                    Content     = $body
                }
                ToRecipients = @(
                    @{ EmailAddress = @{ Address = $To } }
                )
            }
            SaveToSentItems = $false
        }

        # Send via Graph API (requires Mail.Send permission)
        Send-MgUserMail -UserId $To -BodyParameter $message
    }
    catch {
        Write-Warning "Could not send notification: $($_.Exception.Message)"
    }
}

function Send-OffboardingNotification {
    param(
        [string]$To,
        [hashtable]$Data
    )

    try {
        $body = @"
<h2>User Offboarded Successfully</h2>
<table style="border-collapse: collapse; font-family: Arial, sans-serif;">
    <tr><td style="padding: 8px; font-weight: bold;">Name:</td><td style="padding: 8px;">$($Data.UserDisplayName)</td></tr>
    <tr><td style="padding: 8px; font-weight: bold;">UPN:</td><td style="padding: 8px;">$($Data.UserPrincipalName)</td></tr>
    <tr><td style="padding: 8px; font-weight: bold;">Groups Removed:</td><td style="padding: 8px;">$($Data.GroupsRemoved)</td></tr>
    <tr><td style="padding: 8px; font-weight: bold;">Licenses Removed:</td><td style="padding: 8px;">$($Data.LicensesRemoved)</td></tr>
</table>
<p style="margin-top: 16px; color: #c00;">Account has been disabled and all sessions revoked.</p>
<p style="color: #666;">This is an automated notification from the Azure User Lifecycle Automation tool.</p>
"@

        $message = @{
            Message = @{
                Subject      = "Offboarding Complete: $($Data.UserDisplayName)"
                Body         = @{
                    ContentType = "HTML"
                    Content     = $body
                }
                ToRecipients = @(
                    @{ EmailAddress = @{ Address = $To } }
                )
            }
            SaveToSentItems = $false
        }

        Send-MgUserMail -UserId $To -BodyParameter $message
    }
    catch {
        Write-Warning "Could not send notification: $($_.Exception.Message)"
    }
}
