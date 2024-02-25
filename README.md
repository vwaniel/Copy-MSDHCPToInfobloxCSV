# Copy-MSDHCPToInfobloxCSV
Powershell function that gets DHCP scopes/ranges/reservations from MS DHCP and convert it to Infoblox CSV format.

I needed a way to quickly get scopes, options, ranges, and reservations out of Microsoft DHCP servers and into Infoblox CSV format for fast and easy import during migration.

## Installation/Loading
```console
Import-Module .\Copy-MSDHCPToInfobloxCSV.ps1
```
