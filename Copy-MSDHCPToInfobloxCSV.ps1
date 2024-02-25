function Copy-MSDHCPToInfobloxCSV {
	#Requires -Module DhcpServer
	<#
	.SYNOPSIS
		Exports information from a Microsoft DHCP server and converts it to Infoblox CSV format.
	.DESCRIPTION
		Exports scopes, options, and reservations from a Microsoft DHCP server and converts them to Infoblox CSV format.
	.PARAMETER DHCPServer
		The Microsoft DHCP server that is to be targeted for export.
	.PARAMETER Site
		Optionally specify the site name, which will be added as an extensible attribute in Infoblox.
	.PARAMETER IBDHCPMembers
		Optionally specify a comma-separated list of Infoblox Grid members that will be serving DHCP.  These will be added to "dhcp_members" in the Infoblox CSV file containing networks.
	.PARAMETER IBDHCPFailoverAssociation
		Optionally specify the Infoblox DHCP failover association name.  This will be added to "failover_association" in the Infoblox CSV file containing address ranges.
	.PARAMETER ParseVLANFromScopeName
		Optionally parse the DHCP scope names if they contain the string "VLAN xxx" to get the VLAN number and add it as an extensible attribute.
	.PARAMETER ParseVLANFromScopeDescription
		Optionally parse the DHCP scope descriptions if they contain the string "VLAN xxx" to get the VLAN number and add it as an extensible attribute.
	.PARAMETER AddSiteToComment
		If -Site is specified, prepend it to the network name ("comment") in the Infoblox CSV file containing networks (if it is not already part of the scope name).
	#>
	[cmdletbinding()]
	param(
		[Parameter(Mandatory=$true,Position=1)][string]$DHCPServer,
		[Parameter(Mandatory=$false)][string]$Site,
		[Parameter(Mandatory=$false)][string]$IBDHCPMembers,
		[Parameter(Mandatory=$false)][string]$IBDHCPFailoverAssociation,
		[Parameter(Mandatory=$false)][switch]$ParseVLANFromScopeName,
		[Parameter(Mandatory=$false)][switch]$ParseVLANFromScopeDescription,
		[Parameter(Mandatory=$false)][switch]$AddSiteToComment
	)

	try {
		Test-Connection $DHCPServer -ErrorAction "Stop" > $null
		$objDHCP4Server = New-Object PSObject -Property @{
			"Name" = $DHCPServer;
			"Scopes" = $null;
			"Options" = $null
		}
	}
	catch {
		throw "Unable to ping DHCP server $($DHCPServer).  $($_.Exception.Message)"
	}
	
	# Get server-wide DHCPv4 options.
	$objDHCP4Server.Options = @{}
	try {
		Get-DhcpServerv4OptionValue -ComputerName $DHCPServer -ErrorAction "Stop" | Foreach-Object {
			$objDHCP4Server.Options.Add("$($_.OptionId)",$(
				New-Object PSObject -Property @{
					"Name" = $_.Name;
					"OptionId" = $_.OptionId;
					"Type" = $_."Type";
					"Value" = $_.Value
				}
			)) > $null
		}
	}
	catch {
		Write-Error "Unable to get IPv4 DHCP options from server $($DHCPServer).  $($_.Exception.Message)"
	}
	
	# Get DHCPv4 scope information.
	$objDHCP4Server.Scopes = [System.Collections.ArrayList]@()
	try {
		Get-DhcpServerv4Scope -ComputerName $DHCPServer -ErrorAction "Stop" | Foreach-Object {
			$objDHCP4Server.Scopes.Add($(
				New-Object PSObject -Property @{
					"Id" = $_.ScopeId.ToString();
					"SubnetMask" = $_.SubnetMask.ToString();
					"Range" = $(New-Object PSObject -Property @{"Start" = $_.StartRange.ToString(); "End" = $_.EndRange.ToString(); "ExclusionRanges" = [System.Collections.ArrayList]@()});
					"LeaseDuration" = $_.LeaseDuration.TotalSeconds;
					"Name" = $_.Name;
					"Description" = $_.Description;
					"State" = $_.State;
					"Options" = $null;
					"DNSSettings" = $null
				}
			)) > $null
		}
	}
	catch {
		Write-Error "Unable to get DHCPv4 scopes from server $($DHCPServer).  $($_.Exception.Message)"
	}
	foreach ($objScope in $objDHCP4Server.Scopes) {
		Write-Progress -Activity "Discovering Scope Information" -Status "$($objScope.Id) - $($objScope.Name)" -PercentComplete (($objDHCP4Server.Scopes.IndexOf($objScope)/($objDHCP4Server.Scopes | Measure-Object).Count)*100) -Id 1
		# Get Excluded Ranges.
		try {
			Get-DhcpServerv4ExclusionRange -ComputerName $DHCPServer -ScopeId $objScope.Id -ErrorAction "Stop" | Foreach-Object {
				$objScope.Range.ExclusionRanges.Add($(
					New-Object PSObject -Property @{
						"ExclusionStart" = $_.StartRange.ToString();
						"ExclusionEnd" = $_.EndRange.ToString();
					}
				)) > $null
			}
		}
		catch {
			Write-Error "Unable to determine exclusion range for scope $($objScope.Name) on server $($DHCPServer).  $($_.Exception.Message)"
		}
		
		# Get Fixed Addresses (Reservations).
		$objScope | Add-Member -MemberType "NoteProperty" -Name "Reservations" -Value $null
		$objScope.Reservations = [System.Collections.ArrayList]@()
		try {
			Get-DhcpServerv4Reservation -ComputerName $DHCPServer -ScopeId $objScope.Id -ErrorAction "Stop" | Foreach-Object {
				$objScope.Reservations.Add($(
					New-Object PSObject -Property @{
						"IPAddress" = $_.IPAddress.ToString();
						"AddressState" = $_.AddressState;
						"ClientMacAddress" = $_.ClientId;
						"Description" = $_.Description;
						"Name" = $_.Name;
						"Options" = $null
					}
				)) > $null
			}
		}
		catch {
			Write-Error "Unable to get DHCP reservations for scope $($objScope.Name) on server $($DHCPServer).  $($_.Exception.Message)"
		}
		
		# Get Scope Options.
		$objScope.Options = @{}
		try {
			Get-DhcpServerv4OptionValue -ComputerName $DHCPServer -ScopeId $objScope.Id -ErrorAction "Stop" | Foreach-Object {
				$objScope.Options.Add("$($_.OptionId)",$(
					New-Object PSObject -Property @{
						"Name" = $_.Name;
						"OptionId" = $_.OptionId;
						"Type" = $_."Type";
						"Value" = $_.Value
					}
				)) > $null
			}
		}
		catch {
			Write-Error "Unable to get DHCP options for scope $($objScope.Name) on server $($DHCPServer).  $($_.Exception.Message)"
		}
		
		foreach ($objReservation in $objScope.Reservations) {
			# Get Options For Each Reservation.
			$objReservation.Options = @{}
			try {
				Get-DhcpServerv4OptionValue -ComputerName $DHCPServer -ScopeId $objScope.Id -ReservedIP $objReservation.IPAddress -ErrorAction "Stop" | Foreach-Object {
					$objReservation.Options.Add("$($_.OptionId)",$(
						New-Object PSObject -Property @{
							"Name" = $_.Name;
							"OptionId" = $_.OptionId;
							"Type" = $_."Type";
							"Value" = $_.Value
						}
					)) > $null
				}
			}
			catch {
				Write-Error "Unable to get DHCP options for reservation $($objReservation.Name) in scope $($objScope.Name) on server $($DHCPServer).  $($_.Exception.Message)"
			}
		}
		
		# Get DNS Settings.
		try {
			$objScope.DNSSettings = Get-DhcpServerv4DnsSetting -ComputerName $DHCPServer -ScopeId $objScope.Id -ErrorAction "Stop"
		}
		catch {
			Write-Error "Unable to get DNS settings for scope $($objScope.Name) on server $($DHCPServer).  $($_.Exception.Message)"
		}
	}
	Write-Progress -Activity "Discovering Scope Information" -Completed -Id 1
	
	# Start converting data into the Infoblox CSV import format.
	# Networks
	$IBCSV_Networks = [System.Collections.ArrayList]@()
	foreach ($objScope in $objDHCP4Server.Scopes) {
		$addObj = New-Object PSObject -Property @{
			"header-network" = "network";
			"address*" = $objScope.Id;
			"netmask*" = $objScope.SubnetMask;
			"always_update_dns" = $null;
			"basic_polling_settings" = $null;
			"boot_file" = $null;
			"boot_server" = $null;
			"broadcast_address" = $null;
			"comment" = "$($objScope.Name)";
			"ddns_domainname" = $null;
			"ddns_ttl" = $null;
			"dhcp_members" = $IBDHCPMembers;
			"disabled" = $true;
			"discovery_exclusion_range" = $null;
			"discovery_member" = $null;
			"domain_name" = $null;
			"domain_name_servers" = $null;
			"enable_ddns" = $null;
			"enable_discovery" = $null;
			"enable_option81" = $null;
			"enable_pxe_lease_time" = $null;
			"enable_threshold_email_warnings" = $false;
			"enable_threshold_snmp_warnings" = $false;
			"enable_thresholds" = $null;
			"generate_hostname" = $null;
			"ignore_client_requested_options" = $null;
			"is_authoritative" = $null;
			"lease_scavenge_time" = $null;
			"lease_time" = $objScope.LeaseReservation;
			"mgm_private" = $false;
			"network_view" = "default";
			"next_server" = $null;
			"option_logic_filters" = $null;
			"pxe_lease_time" = $null;
			"range_high_water_mark" = "95";
			"range_high_water_mark_reset" = "85";
			"range_low_water_mark" = "0";
			"range_low_water_mark_reset" = "10";
			"recycle_leases" = $null;
			"routers" = $null;
			"threshold_email_addresses" = $null;
			"update_dns_on_lease_renewal" = $null;
			"update_static_leases" = $null;
			"vlans" = $null;
			"zone_associations" = $null;
			"EA-Creator" = $null;
			"EA-Site" = $Site;
			"EA-VLAN" = $null;
			"OPTION-43" = $null
		}
		# Figure out per-scope settings.
		# Apply DNS servers.
		if ($objScope.Options["6"]) {
			$addObj."domain_name_servers" = $($objScope.Options["6"].Value) -join ","
		} elseif ($objDHCP4Server.Options["6"]) {
			$addObj."domain_name_servers" = $($objDHCP4Server.Options["6"].Value) -join ","
		}
		# Add gateway.
		if ($objScope.Options["3"]) {
			$addObj."routers" = $($objScope.Options["3"].Value) -join ","
		}
		
		if ($ParseVLANFromScopeName) {
			# Parse VLAN ID from scope name.
			switch -regex ($objScope.Name) {
				"(?i)vlan(?-i)\s?(?<VLANNumber>[0-9]*)" {
					$addObj."EA-VLAN" = $matches.VLANNumber
				}
			}
		}
		if ($ParseVLANFromScopeDescription) {
			# Parse VLAN ID from scope description.
			switch -regex ($objScope.Description) {
				"(?i)vlan(?-i)\s?(?<VLANNumber>[0-9]*)" {
					$addObj."EA-VLAN" = $matches.VLANNumber
				}
			}
		}
		
		# Add Option 43 (if exists).
		if ($objScope.Options["43"]) {
			$addObj."OPTION-43" = $objScope.Options["43"].Value
		} elseif ($objDHCP4Server.Options["43"]) {
			$addObj."OPTION-43" = $objDHCP4Server.Options["43"].Value
		}
		# Add boot server.
		if ($objScope.Options["66"]) {
			$addObj."boot_server" = $objScope.Options["66"].Value[0]
		} elseif ($objDHCP4Server.Options["66"]) {
			$addObj."boot_server" = $objDHCP4Server.Options["66"].Value[0]
		}
		# Add boot file name.
		if ($objScope.Options["67"]) {
			$addObj."boot_file" = $objScope.Options["67"].Value[0]
		} elseif ($objDHCP4Server.Options["67"]) {
			$addObj."boot_file" = $objDHCP4Server.Options["67"].Value[0]
		}
		# Add DNS domain name.
		if ($objScope.Options["15"]) {
			$addObj."ddns_domainname" = $objScope.Options["15"].Value[0]
			$addObj."domain_name" = $objScope.Options["15"].Value[0]
		}
		
		if ($AddSiteToComment) {
			# Prepend comment with site name if site name can't be found in the comment already.
			switch -regex ($addObj."comment") {
				"(^|_|-|[^\S])(?i)$($Site)(?-i)(\s|_|-)" {
					break;
				}
				default {
					$addObj."comment" = "$($Site) $($addObj.comment)"
				}
			}
		}
		
		# Check DNS settings.
		if ($objScope.DNSSettings.DeleteDnsRROnLeaseExpiry -eq $true) {
			$addObj."update_dns_on_lease_renewal" = $true
		}
		if ($objScope.DNSSettings.DynamicUpdates -eq "Always") {
			$addObj."always_update_dns" = $true
			$addObj."enable_ddns" = $true
			$addObj."enable_option81" = $true
			$addObj."update_static_leases" = $true
			# Check for DNS domain on scope, if it doesn't exist inherit it from the server.
			if ( -NOT ($objScope.Options["15"])) {
				$addObj."ddns_domainname" = $objDHCP4Server.Options["15"].Value[0]
				$addObj."domain_name" = $objDHCP4Server.Options["15"].Value[0]
			}
		} elseif ($objScope.DNSSettings.DynamicUpdates -eq "OnClientRequest") {
			$addObj."enable_ddns" = $true
			$addObj."enable_option81" = $true
			$addObj."always_update_dns" = $false
			# Check for DNS domain on scope, if it doesn't exist inherit it from the server.
			if ( -NOT ($objScope.Options["15"])) {
				$addObj."ddns_domainname" = $objDHCP4Server.Options["15"].Value[0]
				$addObj."domain_name" = $objDHCP4Server.Options["15"].Value[0]
			}
		}
		
		# Add scope to Infoblox networks CSV.
		$IBCSV_Networks.Add($addObj) > $null
	}
	$IBCSV_Networks | Export-CSV -NoTypeInformation ".\IB_$($DHCPServer)_networks.csv"
	
	# Ranges
	$IBCSV_Ranges = [System.Collections.ArrayList]@()
	foreach ($objScope in $objDHCP4Server.Scopes) {
		$addObj = New-Object PSObject -Property @{
			"header-dhcprange" = "dhcprange";
			"end_address*" = $objScope.Range.End;
			"_new_end_address" = $null;
			"start_address*" = $objScope.Range.Start;
			"_new_start_address" = $null;
			"always_update_dns" = $false;
			"boot_file" = $null;
			"boot_server" = $null;
			"broadcast_address" = $null;
			"comment" = $null
			"ddns_domainname" = $null;
			"deny_all_clients" = $false;
			"deny_bootp" = $null;
			"disabled" = $false;
			"domain_name" = $null;
			"domain_name_servers" = $null;
			"enable_ddns" = $null;
			"enable_pxe_lease_time" = $null;
			"enable_threshold_email_warnings" = $false;
			"enable_threshold_snmp_warnings" = $false;
			"enable_thresholds" = $null;
			"exclusion_ranges" = $null;
			"failover_association" = $IBDHCPFailoverAssociation;
			"fingerprint_filter_rules" = $null;
			"generate_hostname" = $null;
			"ignore_client_requested_options" = $null;
			"known_clients_option" = $null;
			"lease_scavenge_time" = $null;
			"lease_time" = $null;
			"mac_filter_rules" = $null;
			"member" = $null;
			"ms_server" = $null;
			"_new_ms_server" = $null;
			"nac_filter_rules" = $null;
			"name" = $null;
			"network_view" = $default;
			"next_server" = $null;
			"option_filter_rules" = $null;
			"option_logic_filters" = $null;
			"pxe_lease_time" = $null;
			"range_high_water_mark" = "95";
			"range_high_water_mark_reset" = "85";
			"range_low_water_mark" = "0";
			"range_low_water_mark_reset" = "10";
			"recycle_leases" = $null;
			"relay_agent_filter_rules" = $null;
			"routers" = $null;
			"server_association_type" = "FAILOVER";
			"threshold_email_addresses" = $null;
			"unknown_clients_option" = $null;
			"update_dns_on_lease_renewal" = $null
			
		}
		# Handle exclusions.
		if ($objScope.Range.ExclusionRanges) {
			# Build the range exclusion string.
			$exclusion_ranges = [System.Collections.ArrayList]@()
			$objScope.Range.ExclusionRanges | Foreach-Object {
				$exclusion_ranges.Add("$($_.ExclusionStart)-$($_.ExclusionEnd)") > $null
			}
			$addObj."exclusion_ranges" = $exclusion_ranges -join ","
			Remove-Variable exclusion_ranges
		}
		
		# Add scope to Infoblox ranges CSV.
		$IBCSV_Ranges.Add($addObj) > $null
	}
	$IBCSV_Ranges | Export-CSV -NoTypeInformation ".\IB_$($DHCPServer)_ranges.csv"
	
	# Reservations
	$IBCSV_FixedAddresses = [System.Collections.ArrayList]@()
	foreach ($objScope in $objDHCP4Server.Scopes) {
		foreach ($objReservation in $objScope.Reservations) {
			$addObj = New-Object PSObject -Property @{
				"header-fixedaddress" = "fixedaddress";
				"ip_address*" = $objReservation.IPAddress;
				"_new_ip_address" = $null;
				"always_update_dns" = $false;
				"boot_file" = $null;
				"boot_server" = $null;
				"broadcast_address" = $null;
				"circuit_id" = $null;
				"cli_credentials" = $null;
				"comment" = $objReservation.Description;
				"ddns_domainname" = $null;
				"ddns_hostname" = $null;
				"deny_bootp" = $null;
				"dhcp_client_identifier" = $null;
				"disabled" = $false;
				"domain_name" = $null;
				"domain_name_servers" = $null;
				"enable_ddns" = $null;
				"enable_discovery" = $true;
				"enable_immediate_discovery" = $false;
				"enable_pxe_lease_time" = $false;
				"ignore_client_requested_options" = $null;
				"lease_time" = $null;
				"mac_address" = $objReservation.ClientMacAddress -replace "-",":";
				"match_option" = "MAC_ADDRESS";
				"ms_server" = $null;
				"_new_ms_server" = $null;
				"name" = $objReservation.Name;
				"network_view" = "default";
				"next_server" = $null;
				"option_logic_filters" = $null;
				"override_cli_credentials" = $false;
				"override_credential" = $false;
				"prepend_zero" = $false;
				"pxe_lease_time" = $null;
				"remote_id" = $null;
				"routers" = $null;
				"snmpv1v2_credential" = $null;
				"snmpv3_credential" = $null;
				"use_snmpv3_credential" = $null
			}
			# Apply DNS servers.
			if ($objReservation.Options["6"]) {
				$addObj."domain_name_servers" = $($objReservation.Options["6"].Value) -join ","
			}
			# Add gateway.
			if ($objReservation.Options["3"]) {
				$addObj."routers" = $($objReservation.Options["3"].Value) -join ","
			}
			
			# Add reservation to Infoblox fixed addresses CSV.
			$IBCSV_FixedAddresses.Add($addObj) > $null
		}
		$IBCSV_FixedAddresses | Export-CSV -NoTypeInformation ".\IB_$($DHCPServer)_fixedaddresses.csv"
	}
	
	# Write the original data to JSON.
	$objDHCP4Server | ConvertTo-JSON -Depth 10 | Out-File ".\$($DHCPServer).json"
}