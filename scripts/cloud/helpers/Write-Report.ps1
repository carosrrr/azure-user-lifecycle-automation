<#
.SYNOPSIS
    Helper functions for generating onboarding/offboarding reports.
#>

function Write-OnboardingReport {
    param(
        [array]$Results,
        [string]$OutputPath
    )

    $report = @{
        ReportType  = 'Onboarding'
        GeneratedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Summary     = @{
            Total      = $Results.Count
            Successful = ($Results | Where-Object { $_.Status -eq 'Success' }).Count
            Failed     = ($Results | Where-Object { $_.Status -eq 'Failed' }).Count
        }
        Details     = $Results
    }

    $report | ConvertTo-Json -Depth 5 | Out-File $OutputPath -Encoding UTF8
    return $OutputPath
}

function Write-OffboardingReport {
    param(
        [array]$Results,
        [string]$OutputPath
    )

    $report = @{
        ReportType  = 'Offboarding'
        GeneratedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Summary     = @{
            Total      = $Results.Count
            Successful = ($Results | Where-Object { $_.Status -eq 'Success' }).Count
            Failed     = ($Results | Where-Object { $_.Status -eq 'Failed' }).Count
        }
        Details     = $Results
    }

    $report | ConvertTo-Json -Depth 5 | Out-File $OutputPath -Encoding UTF8
    return $OutputPath
}
