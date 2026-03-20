# Cloud-Only Setup Guide

This guide covers setting up the **cloud-only** scripts that manage users directly in Azure Entra ID using the Microsoft Graph API.

## Prerequisites

- PowerShell 7.x or later
- Microsoft Graph PowerShell SDK
- Azure Entra ID tenant with admin access

## 1. Install Required Modules

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
Install-Module Microsoft.Graph.Users -Scope CurrentUser
Install-Module Microsoft.Graph.Groups -Scope CurrentUser
Install-Module Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser
```

## 2. Configure

```powershell
cp config/config.sample.json config/config.json
```

Edit `config/config.json` with your:

| Field | Description |
|-------|-------------|
| `tenantId` | Your Azure tenant ID |
| `defaultDomain` | Primary domain (e.g., `company.com`) |
| `usageLocation` | Country code for license assignment (e.g., `US`, `BR`) |
| `licenseSkus` | Map license tiers to your tenant's SKU IDs |
| `defaultGroups` | Group IDs all new users should be added to |
| `departmentGroups` | Map department names to specific group IDs |
| `notificationEmail` | Email to receive onboarding/offboarding notifications |

To find your license SKU IDs:

```powershell
Connect-MgGraph -Scopes "Organization.Read.All"
Get-MgSubscribedSku | Select-Object SkuPartNumber, SkuId, ConsumedUnits
```

## 3. Required Permissions

The account or app registration needs these Microsoft Graph permissions:

- `User.ReadWrite.All`
- `Group.ReadWrite.All`
- `Directory.ReadWrite.All`
- `Organization.Read.All`
- `Mail.Send` (for email notifications)

## 4. Authentication Methods

### Interactive (for testing)

```json
"authentication": {
    "method": "interactive"
}
```

### Certificate-based (for Runbooks / automation)

```json
"authentication": {
    "method": "certificate",
    "clientId": "YOUR-APP-CLIENT-ID",
    "certificateThumbprint": "YOUR-CERT-THUMBPRINT"
}
```

## 5. Usage

See the main [README](../README.md) for usage examples.

## Author

**Caio Santana** — [Portfolio](https://carosrrr.github.io)
