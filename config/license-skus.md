# Common Microsoft 365 License SKU Reference

Use these SKU IDs in your `config.json` file. You can find your tenant's specific SKU IDs by running:

```powershell
Connect-MgGraph -Scopes "Organization.Read.All"
Get-MgSubscribedSku | Select-Object SkuPartNumber, SkuId, ConsumedUnits
```

## Frequently Used SKUs

| License | SKU Part Number | SKU ID |
|---------|----------------|--------|
| Microsoft 365 E1 | STANDARDPACK | `18181a46-0d4e-45cd-891e-60aabd171b4e` |
| Microsoft 365 E3 | ENTERPRISEPACK | `6fd2c87f-b296-42f0-b197-1e91e994b900` |
| Microsoft 365 E5 | ENTERPRISEPREMIUM | `c7df2760-2c81-4ef7-b578-5b5392b571df` |
| Microsoft 365 F1 | M365_F1 | `66b55226-6b4f-492c-910c-a3b7a3c9d993` |
| Microsoft 365 Business Basic | O365_BUSINESS_ESSENTIALS | `3b555118-da6a-4418-894f-7df1e2096870` |
| Microsoft 365 Business Standard | O365_BUSINESS_PREMIUM | `f245ecc8-75af-4f8e-b61f-27d8114de5f3` |
| Microsoft 365 Business Premium | SPB | `cbdc14ab-d96c-4c30-b9f4-6ada7cdc1d46` |
| Exchange Online Plan 1 | EXCHANGESTANDARD | `4b9405b0-7788-4568-add1-99614e613b69` |
| Exchange Online Plan 2 | EXCHANGEENTERPRISE | `19ec0d23-8335-4cbd-94ac-6050e30712fa` |

## Notes

- SKU IDs are globally unique and consistent across all tenants
- `ConsumedUnits` shows how many licenses are currently assigned
- Always verify available licenses before bulk onboarding
- Some licenses include sub-services that can be individually enabled/disabled
