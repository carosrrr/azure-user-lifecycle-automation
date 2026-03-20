<#
.SYNOPSIS
    Helper function to connect to Microsoft Graph with appropriate scopes.
#>

function Connect-GraphWithConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $requiredScopes = @(
        "User.ReadWrite.All",
        "Group.ReadWrite.All",
        "Directory.ReadWrite.All",
        "Organization.Read.All"
    )

    Write-Host "`nConnecting to Microsoft Graph..." -ForegroundColor Yellow

    try {
        # Check if already connected
        $context = Get-MgContext
        if ($context) {
            Write-Host "  ✓ Already connected as $($context.Account)" -ForegroundColor Green
            return
        }
    }
    catch {
        # Not connected, proceed with connection
    }

    try {
        if ($Config.authentication.method -eq 'certificate') {
            # Certificate-based auth (for automation / Runbooks)
            Connect-MgGraph `
                -TenantId $Config.tenantId `
                -ClientId $Config.authentication.clientId `
                -CertificateThumbprint $Config.authentication.certificateThumbprint
        }
        elseif ($Config.authentication.method -eq 'clientSecret') {
            # Client secret auth (for testing)
            $clientSecret = ConvertTo-SecureString $Config.authentication.clientSecret -AsPlainText -Force
            $credential = New-Object System.Management.Automation.PSCredential($Config.authentication.clientId, $clientSecret)
            Connect-MgGraph `
                -TenantId $Config.tenantId `
                -ClientSecretCredential $credential
        }
        else {
            # Interactive auth (default)
            Connect-MgGraph -Scopes $requiredScopes -TenantId $Config.tenantId
        }

        $context = Get-MgContext
        Write-Host "  ✓ Connected to tenant: $($context.TenantId)" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to connect to Microsoft Graph: $($_.Exception.Message)"
        exit 1
    }
}
