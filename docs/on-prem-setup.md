# Hybrid / On-Premises Setup Guide

This guide covers setting up the **on-prem** scripts that manage users in Active Directory and sync changes to Entra ID via AAD Connect.

## Prerequisites

- Azure Automation Account
- Hybrid Runbook Worker (domain-joined Windows server)
- Active Directory RSAT tools installed on the worker
- Azure AD Connect installed (for sync to Entra ID)

## Architecture

```
Webhook → Azure Automation → Hybrid Runbook Worker → AD RSAT → On-Prem AD
                                                                    │
                                                              AAD Connect
                                                              Delta Sync
                                                                    │
                                                                    ▼
                                                              Azure Entra ID
```

## 1. Set Up Hybrid Runbook Worker

### On your domain-joined Windows server:

1. Install the **Log Analytics agent** or **Azure Arc** agent
2. Register it as a Hybrid Runbook Worker in your Automation Account
3. Ensure AD RSAT is installed:

```powershell
# Check if AD module is available
Get-Module -ListAvailable ActiveDirectory

# Install if missing (Windows Server)
Install-WindowsFeature -Name RSAT-AD-PowerShell
```

4. Ensure the worker's service account has permission to:
   - Create users in the target OU
   - Add users to groups
   - Disable accounts
   - Move objects between OUs

## 2. Configure the Scripts

Edit the **SETTINGS** section at the top of each script:

### Create-OnPremADUser.ps1

```powershell
$DefaultTargetOU         = "OU=Users,OU=YourCompany,DC=yourdomain,DC=com"
$DefaultGroups           = @("grp_ssl_users", "grp_default_access")
$DefaultCompany          = "YourCompany"
$DefaultChangePwdAtLogon = $false
```

### Disable-OnPremADUser.ps1

```powershell
$TargetOU              = "OU=Disabled Users,OU=YourCompany,DC=yourdomain,DC=com"
$DescriptionPrefix     = "Leaver"
$TriggerAadConnectSync = $true
$AdSyncModulePath      = "C:\Program Files\Microsoft Azure AD Sync\Bin\ADSync\ADSync.psd1"
```

## 3. Import Runbooks

1. In Azure Portal, go to your **Automation Account**
2. Go to **Runbooks** > **Import a runbook**
3. Upload `Create-OnPremADUser.ps1`
4. Set type to **PowerShell** and runtime to **5.1** (required for AD module)
5. Click **Publish**
6. Repeat for `Disable-OnPremADUser.ps1`

## 4. Create Webhooks

For each Runbook:

1. Open the published Runbook
2. Click **Webhooks** > **Add Webhook**
3. Set **Run on:** to your **Hybrid Worker Group**
4. Copy the webhook URL (shown only once!)
5. Set an expiration date

## 5. Test

### Test onboarding:

```bash
curl -X POST "https://your-webhook-url" \
  -H "Content-Type: application/json" \
  -d '{
    "firstName": "Test",
    "lastName": "User",
    "userPrincipalName": "test.user@company.com",
    "jobTitle": "Test Account",
    "department": "IT",
    "autoGeneratePassword": true,
    "returnPassword": true
  }'
```

### Test offboarding:

```bash
curl -X POST "https://your-webhook-url" \
  -H "Content-Type: application/json" \
  -d '{
    "workEmail": "test.user@company.com",
    "reason": "Test offboarding"
  }'
```

Check the Runbook job output in **Azure Portal > Automation Account > Jobs** for the JSON response.

## Offboarding Actions

The offboarding script performs these steps in order:

1. **Disable** the AD account
2. **Remove** from all security and distribution groups
3. **Clear** the manager attribute
4. **Set description** with date and reason (e.g., `2026/03/20 - Leaver (BambooHR status -> Inactive)`)
5. **Move** the object to the Disabled Users OU
6. **Trigger** AAD Connect delta sync (optional)

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `ActiveDirectory module not found` | Install RSAT on the Hybrid Worker |
| `Access denied creating user` | Check the worker's service account permissions on the target OU |
| Webhook returns no output | Ensure the Runbook is set to run on the Hybrid Worker Group, not Azure |
| AAD Connect sync fails | Verify the ADSync module path and that the worker is the AAD Connect server |
| User exists warning | Expected — the script is idempotent and skips existing users |

## Author

**Caio Santana** — [Portfolio](https://carosrrr.github.io)
