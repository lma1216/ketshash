﻿function Invoke-DetectPTH(){
	<#
		.SYNOPSIS
			Using event viewer to detect suspicious privileged NTLM connections such as Pass-the-Hash
			Author: Eviatar Gerzi (@g3rzi)

			Version 1.2: 17.12.2017
			
		.DESCRIPTION
			This function queries event viewer on remote machine and search for NTLM events (event IDs 4624).
			It checks if the NTLM events were generated by a legitimate\illegitimate logon based on event viewer logs and displays the result.
			
			Requirements:
				- Privileges to get event viewer logs from remote machines
				- Privileges to retrive information about the user and the machine from Active Directory
				- Computers synchronized with the same time, otherwise it can affect the results

		.PARAMETER TargetComputers
			Array of target computers to detect for NTLM connections.

		.PARAMETER TargetComputersFile
			Path to file with list of target computers to detect for NTLM connections.
			
		.PARAMETER StartTime
			Time when the detection starts. The defualt is from the time this function starts.

		.PARAMETER UseKerberosCheck
			Checks for TGT\TGS logons on the DCs on the organization.
			The default is to search for legitimate logon on the source machine.
			Anyway, with or without this switch there is still a query for event ID 4648 on the source machine.
			
		.PARAMETER UseNewCredentialsCheck
			Checks for logon events with logon type 9 (like Mimikatz).
			This is optional, the default algoritm already covers it. 
			It is exist just to show another option to detect suspicious NTLM connections.
			On Windows versions below Windows 10 and Server 2016, "Microsoft-Windows-LSA/Operational" should be enabled in event viewer.
			On Windows 10 and Server 2016, enabling "kerenl object audity" will provide more accurate information such as writing to LSASS.
			
		.PARAMETER LogFile
			Log file path to save the results
		
		.PARAMETER MaxHoursOfLegitLogonPriorToNTLMEvent
			How much hours to look backwards and search for legitimate logon from the time of the NTLM event.

		.EXAMPLE 
			Detect in real time for legit\illegit privileged NTLM connections.
			Invoke-DetectPth -TargetComputers "MARS-7"
			
		.EXAMPLE
			Execute detection on array of computers.
			Invoke-DetectPth -TargetComputers @("MARS-7", "MARS-10")
			
		.EXAMPLE
			Execute detection on multiple computers from a list.
			Invoke-DetectPth -TargetComputersFile "C:\tmp\Computers.txt"
			
			Comptures.txt content:
			MARS-7
			MARS-10
			
		.EXAMPLE
			Detect legit\illegit privileged NTLM connections in the last 4 hours.
			Invoke-DetectPth -TargetComputers "MARS-7" -StartTime (Get-Date).AddHours(-4)
			
		.EXAMPLE
			Detect legit\illegit privileged NTLM connections in specific time.
			Invoke-DetectPth -TargetComputers "MARS-7" -StartTime ([datetime]"2017-11-23 05:35:27 PM")
			
		.EXAMPLE
			Detection is based on Kerberos authentication (TGT\TGS tickets).
			Invoke-DetectPth -TargetComputers "MARS-7" -UseKerberosCheck
			
		.EXAMPLE
			Detection is based on event 4624 with logon type 9 ("NetCredentials") before the NTLM connection.
			Invoke-DetectPth -TargetComputers "MARS-7" -UseNewCredentialsCheck
			
		.EXAMPLE
			Results will be write to "C:\tmp\log.txt".	
			Invoke-DetectPth -TargetComputers "MARS-7" -LogFile "C:\tmp\log.txt"		
		
		.EXAMPLE
			Searching for legitimate logon 1 hour backwards from the NTLM event.
			Invoke-DetectPth -TargetComputers "MARS-7" -MaxHoursOfLegitLogonPriorToNTLMEvent 1	
		#>
		
    [CmdletBinding()]
	param
	(
		[Parameter(
			Mandatory = $true,
			ParameterSetName = 'TargetComputers')
		]
		[array]$TargetComputers,
		[datetime]$StartTime = (date).AddSeconds(-5),
		[Parameter(
			Mandatory = $true,
			ParameterSetName ='MultipleComputersFile')
		]
		[string]$TargetComputersFile,
		[switch]$UseKerberosCheck,
		[switch]$UseNewCredentialsCheck, # The default logic already covers it.
		[string]$LogFile = $null,
		[int]$MaxHoursOfLegitLogonPriorToNTLMEvent = -2 
	)
	
	
	if ($MaxHoursOfLegitLogonPriorToNTLMEvent -gt 0){
		$MaxHoursOfLegitLogonPriorToNTLMEvent = $MaxHoursOfLegitLogonPriorToNTLMEvent * -1
	}
	
	#region script block section

	[ScriptBlock]$detectPTHScriptBlock = {
		[CmdletBinding()]
		param
		(
			$targetComputerName,
			$startTime,
			$LogFile,
			$UseKerberosCheck,
			$UseNewCredentialsCheck,
			$MaxHoursOfLegitLogonPriorToNTLMEvent
		)
		
		$global:WellKnownSIDs = @{
			'S-1-0' = 'Null Authority'
			'S-1-0-0' = 'Nobody'
			'S-1-1' = 'World Authority'
			'S-1-1-0' = 'Everyone'
			'S-1-2' = 'Local Authority'
			'S-1-2-0' = 'Local'
			'S-1-2-1' = 'Console Logon'
			'S-1-3' = 'Creator Authority'
			'S-1-3-0' = 'Creator Owner'
			'S-1-3-1' = 'Creator Group'
			'S-1-3-2' = 'Creator Owner Server'
			'S-1-3-3' = 'Creator Group Server'
			'S-1-3-4' = 'Owner Rights'
			'S-1-5-80-0' = 'All Services'
			'S-1-4' = 'Non-unique Authority'
			'S-1-5' = 'NT Authority'
			'S-1-5-1' = 'Dialup'
			'S-1-5-2' = 'Network'
			'S-1-5-3' = 'Batch'
			'S-1-5-4' = 'Interactive'
			'S-1-5-6' = 'Service'
			'S-1-5-7' = 'Anonymous'
			'S-1-5-8' = 'Proxy'
			'S-1-5-9' = 'Enterprise Domain Controllers'
			'S-1-5-10' = 'Principal Self'
			'S-1-5-11' = 'Authenticated Users'
			'S-1-5-12' = 'Restricted Code'
			'S-1-5-13' = 'Terminal Server Users'
			'S-1-5-14' = 'Remote Interactive Logon'
			'S-1-5-15' = 'This Organization'
			'S-1-5-17' = 'This Organization'
			'S-1-5-18' = 'Local System'
			'S-1-5-19' = 'NT Authority'
			'S-1-5-20' = 'NT Authority'
			'S-1-5-32-544' = 'Administrators'
			'S-1-5-32-545' = 'Users'
			'S-1-5-32-546' = 'Guests'
			'S-1-5-32-547' = 'Power Users'
			'S-1-5-32-548' = 'Account Operators'
			'S-1-5-32-549' = 'Server Operators'
			'S-1-5-32-550' = 'Print Operators'
			'S-1-5-32-551' = 'Backup Operators'
			'S-1-5-32-552' = 'Replicators'
			'S-1-5-64-10' = 'NTLM Authentication'
			'S-1-5-64-14' = 'SChannel Authentication'
			'S-1-5-64-21' = 'Digest Authority'
			'S-1-5-80' = 'NT Service'
			'S-1-5-83-0' = 'NT VIRTUAL MACHINE\Virtual Machines'
			'S-1-16-0' = 'Untrusted Mandatory Level'
			'S-1-16-4096' = 'Low Mandatory Level'
			'S-1-16-8192' = 'Medium Mandatory Level'
			'S-1-16-8448' = 'Medium Plus Mandatory Level'
			'S-1-16-12288' = 'High Mandatory Level'
			'S-1-16-16384' = 'System Mandatory Level'
			'S-1-16-20480' = 'Protected Process Mandatory Level'
			'S-1-16-28672' = 'Secure Process Mandatory Level'
			'S-1-5-32-554' = 'BUILTIN\Pre-Windows 2000 Compatible Access'
			'S-1-5-32-555' = 'BUILTIN\Remote Desktop Users'
			'S-1-5-32-556' = 'BUILTIN\Network Configuration Operators'
			'S-1-5-32-557' = 'BUILTIN\Incoming Forest Trust Builders'
			'S-1-5-32-558' = 'BUILTIN\Performance Monitor Users'
			'S-1-5-32-559' = 'BUILTIN\Performance Log Users'
			'S-1-5-32-560' = 'BUILTIN\Windows Authorization Access Group'
			'S-1-5-32-561' = 'BUILTIN\Terminal Server License Servers'
			'S-1-5-32-562' = 'BUILTIN\Distributed COM Users'
			'S-1-5-32-569' = 'BUILTIN\Cryptographic Operators'
			'S-1-5-32-573' = 'BUILTIN\Event Log Readers'
			'S-1-5-32-574' = 'BUILTIN\Certificate Service DCOM Access'
			'S-1-5-32-575' = 'BUILTIN\RDS Remote Access Servers'
			'S-1-5-32-576' = 'BUILTIN\RDS Endpoint Servers'
			'S-1-5-32-577' = 'BUILTIN\RDS Management Servers'
			'S-1-5-32-578' = 'BUILTIN\Hyper-V Administrators'
			'S-1-5-32-579' = 'BUILTIN\Access Control Assistance Operators'
			'S-1-5-32-580' = 'BUILTIN\Remote Management Users'
		}

		$global:Event4624Fields = @(
		"TargetUserSid",
		"WorkstationName", # source computer
		"Time",
		"TargetLogonId",
		"TargetUserName",
		"TargetDomainName"
		)

		$global:LogonTypes = @{
		'2' = 'Interactive'
		'3' = 'Network'
		'4' = 'Batch'
		'5' = 'Service'
		'7' = 'Unlock'
		'8' = 'NetworkCleartext'
		'9' = 'NewCredentials'
		'10' = 'RemoteInteractive'
		'11' = 'CachedInteractive'
		}
		
		$global:SYSTEM_PID_STR = "0x4"
		$global:LEGIT_LOGON_MAX_HOURS_PRIOR_TO_NTLM_EVENT = $MaxHoursOfLegitLogonPriorToNTLMEvent
		$global:MAX_SECONDS_PRIOR_NTLM_EVENT = -5
		$global:MAX_SECONDS_AFTER_NTLM_EVENT = 5
		$global:Tab = ""
		
	<#
		Add-Type -TypeDefinition @"
		   public enum NewCredentialsUse
		   {
			  USED,
			  LSASS_WRITING,
			  UNUSED
		   }
"@
	#>

		if(-not ("LegitLogonTechnique" -as [type])){
		Add-Type -TypeDefinition @"
		   public enum LegitLogonTechnique
		   {
			  BY_SOURCE,
			  BY_KERBEROS
		   }
"@
	}

		if($UseKerberosCheck){
			$global:DCs = Get-ADDomainController -Filter * | Select-Object name
			$global:LogonTechnique = [LegitLogonTechnique]::BY_KERBEROS
		}else{
			$global:LogonTechnique = [LegitLogonTechnique]::BY_SOURCE
		}
		
		function Test-ComputerExistInAD($computerName)
		{
			$isFound = $false
			try{
				Get-ADComputer $computerName
				$isFound = $true
			}
			catch{
				Write-Verbose "Computer $($computerName) is not exist in AD"
			}

			return $isFound
		}

		function Get-SidFromUser($userName){
			$sid = $null
			try{
				$objUser = New-Object System.Security.Principal.NTAccount($userName)
				$strSID = $objUser.Translate([System.Security.Principal.SecurityIdentifier])
				$sid = $strSID.Value
			}
			catch{
				Write-Warning "Failed to get SID from username: $($userName)"
			}

			return $sid
		}

		function Get-SidFromDomainAndUser($domain, $userName){
			$sid = $null
			try{
				$objUser = New-Object System.Security.Principal.NTAccount($domain, $userName)
				$strSID = $objUser.Translate([System.Security.Principal.SecurityIdentifier])
				$sid = $strSID.Value
			}
			catch{
				Write-Verbose "Failed to get SID from domain and user at 'Get-SidFromDomainAndUser'"
			}

			return $sid
		}

		function Get-UserFromSid($SID){
			$username = $null
			try{
				$objSID = New-Object System.Security.Principal.SecurityIdentifier($SID)
				$objUser = $objSID.Translate([System.Security.Principal.NTAccount])
				$username = $objUser.Value
			}    
			catch{
				Write-Verbose "Failed to get user from SID 'Get-UserFromSid'"
			}

			return $username
		}

		function Get-HostIPAddress($computerName){
			$ip = $null
			if($computerName.EndsWith("$")){
				$computerName = $computerName.Remove($computerName.Length-1)
			}
			try{
				$ip = [System.Net.Dns]::GetHostAddresses($computerName).IPAddressToString
			}
			catch{
				Write-Verbose "$($global:Tab)[*] Not existing computer name: $($computerName)"
			}

			return $ip
		}

		function Get-NtlmEventObject([xml]$ntlmXmlEvent, $targetComputerName){
		   $ntlmEventObject = New-Object psobject

		   foreach($field in $global:Event4624Fields){
			 $value = ($ntlmXmlEvent.Event.EventData.Data | Where-Object {$_.Name -eq $field}).'#text'
			 $ntlmEventObject | Add-Member -MemberType NoteProperty -Name $field -Value $value
		   }

		   # It is possible to remove "Time" from the constant fields of 4624
		   $ntlmEventObject.Time = [datetime]$ntlmXmlEvent.Event.System.TimeCreated.SystemTime
		   
		   $value = Get-HostIPAddress $ntlmEventObject.WorkstationName
		   $ntlmEventObject | Add-Member -MemberType NoteProperty -Name "SourceIp" -Value $value

		   $value = Get-HostIPAddress $targetComputerName
		   $ntlmEventObject | Add-Member -MemberType NoteProperty -Name "DestinationIp" -Value $value
		   $ntlmEventObject | Add-Member -MemberType NoteProperty -Name "DestinationWorkstation" -Value $targetComputerName

		   return $ntlmEventObject
		}

		function Compare-Ip($ipA, $ipB){
			$isSameIp = $false
			
			try{
				if(($ipA -ne $null) -and ($ipB -ne $null)){
					$ipA = [ipaddress]$ipA
					$ipB = [ipaddress]$ipB
					if($ipA.IsIPv4MappedToIPv6){
						if(-not $ipB.IsIPv4MappedToIPv6){
							$ipB = $ipB.MapToIPv6()
						}
					}
					elseif($ipB.IsIPv4MappedToIPv6){
						$ipA = $ipA.MapToIPv6()
					}
					
					$isSameIp = ($ipA -eq $ipB)
				}
			}
			catch{
				Write-Warning "$($global:Tab)[*] Invalid ip addresses: IpA = '$($ipA)', IpB = '$($ipB)'"
			}
			return $isSameIp
		}

		function Is-LegitKerberosLogon($ntlmEventObject){
			$isLegit = $false
			$kerberosEvents = New-Object System.Collections.ArrayList
			try{
				# Need solution for number of DCs
				foreach($dc in $global:DCs){
					try{
						$kerberosEventsTemp = Get-WinEvent -ComputerName $dc.Name -FilterHashtable @{LogName="Security"; id=4768,4769; StartTime = ([datetime]$ntlmEventObject.Time).AddHours($global:LEGIT_LOGON_MAX_HOURS_PRIOR_TO_NTLM_EVENT); EndTime=$ntlmEventObject.Time} -ErrorAction SilentlyContinue
						$kerberosEvents.Add($kerberosEventsTemp)
					}
					catch{
						Write-Verbos "$($global:Tab)[*] No Kerberos events on domain controller: "$dc
					}
				}
				foreach($kerbEvent in $kerberosEvents){
					[xml]$kerberosXmlEvent = $kerbEvent.ToXml()
					$kerberosTargetUserName = ($kerberosXmlEvent.Event.EventData.Data | Where-Object {$_.Name -eq "TargetUserName"}).'#text'
					$kerberosTargetSid = Get-SidFromUser $kerberosTargetUserName
					$kerberosSourceIp = ($kerberosXmlEvent.Event.EventData.Data | Where-Object {$_.Name -eq "IpAddress"}).'#text'
					if(($kerberosTargetSid -eq $ntlmEventObject.TargetUserSid) -and (Compare-Ip $kerberosSourceIp $ntlmEventObject.SourceIp)){
						$isLegit = $true
						break
					}
				}
			}
			catch{
				Write-Warning "$($global:Tab)[*] No kerberos events."
			}

			return $isLegit
		}

		function Is-LegitLogon($ntlmEventObject, $legitLogonOption, [ref]$ntlmDetailsSb){
			$isLegit = $false
			if($legitLogonOption -eq [LegitLogonTechnique]::BY_SOURCE){
				$logonType = $null
				if($isLegit = Is-LegitLogonOnSourceMachine $ntlmEventObject ([ref]$logonType)){
					($ntlmDetailsSb.value).AppendLine("$($global:Tab)[*] Found legit logon (LogonType: $($logonType), '$($global:LogonTypes[$logonType])') prior to this connection") | Out-Null		
				}
			}
			else{ 
				if($isLegit = Is-LegitKerberosLogon $ntlmEventObject){
					($ntlmDetailsSb.value).AppendLine("$($global:Tab)[*] Found legit TGT\TGS ticket prior to this connection")
				}
			}
			
			return $isLegit
		}

		function Is-LegitLogonOnSourceMachine($ntlmEventObject, [ref]$logonType){
			$isLegit = $false
			try{
				$logonEvents = Get-WinEvent -ComputerName $ntlmEventObject.WorkstationName -FilterHashtable @{LogName="Security"; id=4624; StartTime=([datetime]$ntlmEventObject.Time).AddHours($global:LEGIT_LOGON_MAX_HOURS_PRIOR_TO_NTLM_EVENT); EndTime=$ntlmEventObject.Time} -ErrorAction SilentlyContinue | Where-Object {($_.Message -match "Logon Type:`t*[2,7,10,11]{1,2}")}
				foreach($logonEvent in $logonEvents){
					[xml]$xmlLogonEvent = $logonEvent.ToXml()

					$sid = ($xmlLogonEvent.Event.EventData.Data | Where-Object {$_.Name -eq "TargetUserSid"}).'#text'
					if(($sid -eq $ntlmEventObject.TargetUserSid)){
						$logonType.value = ($xmlLogonEvent.Event.EventData.Data | Where-Object {$_.Name -eq "LogonType"}).'#text'
						$isLegit = $true
						break
					}
				}
			}
			catch{
			}

			return $isLegit
		}

		function Is-PrivilegedAccount($ntlmObject){
			
			$isPrivilegedAccount = $false
			try{
				$speicalLogonEvents = Get-WinEvent -ComputerName $ntlmObject.DestinationWorkstation -FilterHashtable @{LogName="Security"; id=4672; StartTime=([datetime]($ntlmObject.Time)).AddSeconds(-3); EndTime=[datetime]($ntlmObject.Time).AddSeconds(2)} -ErrorAction SilentlyContinue 

				foreach($specialLogonEvent in $speicalLogonEvents){
					[xml]$xmlSpecialLogonEvent = $specialLogonEvent.ToXml()
					$xmlSpecialLogonEventLogonId =($xmlSpecialLogonEvent.Event.EventData.Data | Where-Object {$_.Name -eq "SubjectLogonId"}).'#text'
					# Hardening is possible by adding the user's SID\full username to the check
					if($ntlmObject.TargetLogonId -eq $xmlSpecialLogonEventLogonId){
						$isPrivilegedAccount = $true
					}
				}
			}
			catch{
			}

			return $isPrivilegedAccount
		}

		function Is-Windows10($computer){
			$computerProperties = Get-ADComputer -Properties OperatingSystemVersion $computer
			return $computerProperties.OperatingSystemVersion.StartsWith("10")
		}

		function Is-UsingExplicityPassword($ntlmObject){
			$isUsingExplicityPassword = $false
			try{
				 $events4648 = Get-WinEvent -ComputerName $ntlmObject.WorkstationName -FilterHashtable @{LogName="Security"; id=4648; StartTime=([datetime]($ntlmObject.Time)).AddSeconds($global:MAX_SECONDS_PRIOR_NTLM_EVENT); EndTime=([datetime]($ntlmObject.Time)).AddSeconds($global:MAX_SECONDS_AFTER_NTLM_EVENT)} -ErrorAction SilentlyContinue

				 foreach($event4648 in $events4648){
					[xml]$xmlevent4648 = $event4648.ToXml()
					$userName = ($xmlevent4648.Event.EventData.Data | Where-Object {$_.Name -eq "TargetUserName"}).'#text'
					$domain = ($xmlevent4648.Event.EventData.Data | Where-Object {$_.Name -eq "TargetDomainName"}).'#text'
					$sid = Get-SidFromDomainAndUser $domain $userName
					$computerName = ($xmlevent4648.Event.EventData.Data | Where-Object {$_.Name -eq "TargetServerName"}).'#text'
					#$computerName = ($xmlevent4648.Event.EventData.Data | Where-Object {$_.Name -eq "TargetInfo"}).'#text'
					
					# [TODO]: It might be faster to run Get-ADComputer and compare between the SIDs
					$targetIpAddress = Get-HostIPAddress $computerName 
					$processId = ($xmlevent4648.Event.EventData.Data | Where-Object {$_.Name -eq "ProcessId"}).'#text'
					
					if(($processId -ne $global:SYSTEM_PID_STR) -and ($ntlmObject.TargetUserSid -eq $sid) -and (($computerName -eq "localhost") -or ($ntlmObject.DestinationIp -eq $targetIpAddress))){
						$isUsingExplicityPassword = $true
						break
					}
				 }
			 }
			 catch{
			 }

			 return $isUsingExplicityPassword 
		}

		# [OPTIONAL] Adding another variant to this algorithm by creating correlation with 4648
		function Is-LogonWithNewCredentials($ntlmObject, [ref]$ntlmDetailsSb){
			$MAX_MINUTES_PRIOR = -60
			$isNewCredentials = $false
			#$isNewCredentials = [NewCredentialsUse]::UNUSED
			try{
				$newCredEvents = Get-WinEvent -ComputerName $ntlmObject.WorkstationName -FilterHashtable @{LogName="Security"; id=4624; StartTime=([datetime]($ntlmObject.Time)).AddMinutes($MAX_MINUTES_PRIOR); EndTime=$ntlmObject.Time} -ErrorAction SilentlyContinue | Where-Object {($_.Message -match "Logon Type:`t*9") -and ($_.Message -match "Authentication Package:`t*Negotiate")}
				$windows10 = Is-Windows10 $ntlmObject.WorkstationName

				foreach($newCredEvent in $newCredEvents){
					[xml]$xmlnewCredEvent = $newCredEvent.ToXml()
					if($windows10){
						
						$userName = ($xmlnewCredEvent.Event.EventData.Data | Where-Object {$_.Name -eq "TargetOutboundUserName"}).'#text'
						$domain = ($xmlnewCredEvent.Event.EventData.Data | Where-Object {$_.Name -eq "TargetOutboundDomainName"}).'#text'
						$sid = Get-SidFromDomainAndUser $domain $userName
						if($sid -eq $ntlmObject.TargetUserSid){
							$isNewCredentials = $true
							#$isNewCredentials = [NewCredentialsUse]::USED
							($ntlmDetailsSb.Value).AppendLine("$($global:Tab)[*] New credentials are being used (CreateProcessWithLogonW) ! ") | Out-Null
							# Only if the kerenl object audity is on
							$newCredTime = [datetime]$xmlnewCredEvent.Event.System.TimeCreated.SystemTime
							$kernelObjectEvents = Get-WinEvent -ComputerName $ntlmObject.WorkstationName -FilterHashtable @{LogName="Security"; id=4656; StartTime=$newCredTime; EndTime=([datetime]$newCredTime).AddSeconds(5)} -ErrorAction SilentlyContinue
							if($kernelObjectEvents){
								$newCredLogonId = ($xmlnewCredEvent.Event.EventData.Data | Where-Object {$_.Name -eq "SubjectLogonId"}).'#text'
								foreach($kernelObjectEvent in $kernelObjectEvents){
									[xml]$xmlEvent = $kernelObjectEvent.ToXml()
									$accessList = ($xmlEvent.Event.EventData.Data | Where-Object {$_.Name -eq "AccessList"}).'#text'
									$objectName = ($xmlEvent.Event.EventData.Data | Where-Object {$_.Name -eq "ObjectName"}).'#text'
									# "%4485" - Write to process memory
									if($accessList.Contains("%4485") -and $objectName.EndsWith("lsass.exe")){
										$kernelLogonId = ($xmlEvent.Event.EventData.Data | Where-Object {$_.Name -eq "SubjectLogonId"}).'#text'
										if($kernelLogonId -eq $newCredLogonId){
											($ntlmDetailsSb.Value).AppendLine("$($global:Tab)[*] Writing to LSASS after using new credentials ! ") | Out-Null
											$isNewCredentials = $true
											#$isNewCredentials = [NewCredentialsUse]::LSASS_WRITING
											break
										}
									}
								}
							}

							break
						}
					}
					else{
						$newCredEventTime = [datetime]$xmlnewCredEvent.Event.System.TimeCreated.SystemTime
						$events303 = Get-WinEvent -ComputerName $ntlmObject.WorkstationName -FilterHashtable @{LogName="Microsoft-Windows-LSA/Operational"; id=303; StartTime=([datetime]$newCredEventTime).AddSeconds(-1); EndTime=([datetime]$newCredEventTime).AddSeconds(1)} -ErrorAction SilentlyContinue
						if($events303 -ne $null){
							Write-Verbose "$($global:Tab)[*] Does event ID 303 enabled ?"
						}
						
						foreach($event303 in $events303){
							[xml]$xmlEvent303= $event303.ToXml()
							$packName = ($xmlEvent303.Event.EventData.Data | Where-Object {$_.Name -eq "PackageName"}).'#text'
							if($packName -eq "CREDSSP"){
								$userName = ($xmlEvent303.Event.EventData.Data | Where-Object {$_.Name -eq "UserName"}).'#text'
								$domain = ($xmlEvent303.Event.EventData.Data | Where-Object {$_.Name -eq "DomainName"}).'#text'
								$sid = Get-SidFromDomainAndUser $domain $userName
								if($sid -eq $ntlmObject.TargetUserSid){
									$isNewCredentials = $true
									#$isNewCredentials = [NewCredentialsUse]::USED
									($ntlmDetailsSb.Value).AppendLine("$($global:Tab)[*] Session with new credentials was used. Might be Mimikatz ?") | Out-Null
									break
								}
							}
						}
					}
					
					if($isNewCredentials){
						break
					}
					  
				}
			}
			catch{
			}

			return $isNewCredentials
		}

		function Get-FormatedNTLMObject($ntlmObject){
			$ntlmDetailsSb = New-Object -TypeName "System.Text.StringBuilder";
			$tid = [System.Threading.Thread]::CurrentThread.ManagedThreadId
			$ntlmDetailsSb.AppendLine("$($global:Tab)[*] TID: $($tid)") | Out-Null
			$ntlmDetailsSb.AppendLine("$($global:Tab)[*] User Sid: $($ntlmObject.TargetUserSid)") | Out-Null
			$ntlmDetailsSb.AppendLine("$($global:Tab)[*] Source computer name: $($ntlmObject.WorkstationName)") | Out-Null
			$ntlmDetailsSb.AppendLine("$($global:Tab)[*] Target computer name: $($ntlmObject.DestinationWorkstation)") | Out-Null
			$fulluser = $ntlmObject.TargetDomainName + "\" +$ntlmObject.TargetUserName
			$ntlmDetailsSb.AppendLine("$($global:Tab)[*] User: $($fulluser)") | Out-Null
			$ntlmDetailsSb.AppendLine("$($global:Tab)[*] Time: $($ntlmObject.Time)") | Out-Null
			return $ntlmDetailsSb
		}

		function Test-ComputerConnection($TargetComputer){
			$isConnected = $false
			try{
				$isConnected = Test-Connection -ComputerName $TargetComputer -Count 1 -Quiet
			}
			catch{
				Write-Warning "Failed to check computer: $($TargetComputer)"
			}
			return $isConnected
		}


		# Make sure that the PCs has the same time zone.
		# If not, run on the clients:
		# 1) net time /set /y 
		# OR
		# 2) w32tm /config /syncfromflags:domhier /update
		# net stop w32time 
		# net start w32time
		# You must run it as administrator
		
		# I am using "net time" because it doesn't use WinRM which requires the customer for more changes on the client
		function Test-TimeOnRemoteComputer($remoteComputer){
			$timeOnRemoteComputer = net time \\$remoteComputer
			
			if($timeOnRemoteComputer -eq $null){
				Write-Warning "Failed to get time on $($remoteComputer)"
			}
			else{
				$timeOnRemoteComputerFixed = [datetime]($timeOnRemoteComputer[0].Split("is").Trim()[-1])
				$timeOnDc = net time
				if($timeOnDc -eq $null){
				
					Write-Warning "Failed to get time on DC"
				}
				else{
					$timeOnDcFixed = [datetime]($timeOnDc[0].Split("is").Trim()[-1])

					if([math]::Abs(($timeOnDcFixed - $timeOnRemoteComputerFixed).TotalSeconds) -ge 3){
						Write-Warning @"
						Time differences (>= 3 second) found:
						$($timeOnRemoteComputer[0])
						$($timeOnDc[0])
"@
						Write-Warning "It will affect the results"
						Write-Warning "Please run as administrator'net time /set /y' on $($timeOnRemoteComputer[0])"
					}
				}
			}
		}

		<# 
		.Synopsis 
		   Write-Log writes a message to a specified log file with the current time stamp. 
		.DESCRIPTION 
		   The Write-Log function is designed to add logging capability to other scripts. 
		   In addition to writing output and/or verbose you can write to a log file for 
		   later debugging. 
		.NOTES 
		   Created by: Jason Wasser @wasserja 
		   Modified: 11/24/2015 09:30:19 AM   
		 
		   Changelog: 
			* Code simplification and clarification - thanks to @juneb_get_help 
			* Added documentation. 
			* Renamed LogPath parameter to Path to keep it standard - thanks to @JeffHicks 
			* Revised the Force switch to work as it should - thanks to @JeffHicks 
		 
		   To Do: 
			* Add error handling if trying to create a log file in a inaccessible location. 
			* Add ability to write $Message to $Verbose or $Error pipelines to eliminate 
			  duplicates. 
		.PARAMETER Message 
		   Message is the content that you wish to add to the log file.  
		.PARAMETER Path 
		   The path to the log file to which you would like to write. By default the function will  
		   create the path and file if it does not exist.  
		.PARAMETER Level 
		   Specify the criticality of the log information being written to the log (i.e. Error, Warning, Informational) 
		.PARAMETER NoClobber 
		   Use NoClobber if you do not wish to overwrite an existing file. 
		.EXAMPLE 
		   Write-Log -Message 'Log message'  
		   Writes the message to c:\Logs\PowerShellLog.log. 
		.EXAMPLE 
		   Write-Log -Message 'Restarting Server.' -Path c:\Logs\Scriptoutput.log 
		   Writes the content to the specified log file and creates the path and file specified.  
		.EXAMPLE 
		   Write-Log -Message 'Folder does not exist.' -Path c:\Logs\Script.log -Level Error 
		   Writes the message to the specified log file as an error message, and writes the message to the error pipeline. 
		.LINK 
		   https://gallery.technet.microsoft.com/scriptcenter/Write-Log-PowerShell-999c32d0 
		#> 		
		function Write-Log
		{ 
			[CmdletBinding()] 
			Param 
			( 
				[Parameter(Mandatory=$true, 
						   ValueFromPipelineByPropertyName=$true)] 
				[ValidateNotNullOrEmpty()] 
				[Alias("LogContent")] 
				[string]$Message, 
		 
				[Parameter(Mandatory=$false)] 
				[Alias('LogPath')] 
				[string]$Path='C:\Logs\PowerShellLog.log', 
				 
				[Parameter(Mandatory=$false)] 
				[ValidateSet("Error","Warn","Info")] 
				[string]$Level="Info", 
				 
				[Parameter(Mandatory=$false)] 
				[switch]$NoClobber 
			) 
		 
			Begin 
			{ 
				# Set VerbosePreference to Continue so that verbose messages are displayed. 
				#$VerbosePreference = 'Continue' 
			} 
			Process 
			{ 
				 
				# If the file already exists and NoClobber was specified, do not write to the log. 
				if ((Test-Path $Path) -AND $NoClobber) { 
					Write-Error "Log file $Path already exists, and you specified NoClobber. Either delete the file or specify a different name." 
					Return 
					} 
		 
				# If attempting to write to a log file in a folder/path that doesn't exist create the file including the path. 
				elseif (!(Test-Path $Path)) { 
					Write-Verbose "Creating $Path." 
					$NewLogFile = New-Item $Path -Force -ItemType File 
					} 
		 
				else { 
					# Nothing to see here yet. 
					} 
		 
				# Format Date for our Log File 
				$FormattedDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss" 
		 
				# Write message to error, warning, or verbose pipeline and specify $LevelText 
				switch ($Level) { 
					'Error' { 
						Write-Error $Message 
						$LevelText = 'ERROR:' 
						} 
					'Warn' { 
						Write-Warning $Message 
						$LevelText = 'WARNING:' 
						} 
					'Info' { 
						Write-Verbose $Message 
						$LevelText = 'INFO:' 
						} 
					} 
				 
				Write-Verbose "Writing data to $($Path)"
				# Write log entry to $Path 
				"$FormattedDate $LevelText $([environment]::NewLine)$Message" | Out-File -FilePath $Path -Append 
				
			} 
			End 
			{ 
			} 
		}
		
		function Write-LogWithMutex($Message, $LogFile)
		{
			$mtx = New-Object System.Threading.Mutex($false, "TestMutex")
			Write-Verbose "Waiting for mutex"
			If ($mtx.WaitOne(1000)) { #Calling WaitOne() without parameters creates a blocking call until mutex available
				Write-Verbose "Recieved mutex!"
				Write-Log -Message $Message -Path $LogFile
				Write-Verbose "Releasing mutex"
				[void]$mtx.ReleaseMutex()
			} Else {
				Write-Warning "Timed out acquiring mutex!"
			}
		}
		
		function Detect-PTH($targetComputerName, $startTime, $logonTechnique, $UseNewCredentialsCheck){
			Test-TimeOnRemoteComputer $targetComputerName
			$previousNtmlEvent = $null
			$sleepInterval = 2
			Write-Host
			while($true){
				
				Start-Sleep -Seconds $sleepInterval
				$endTime = (date)
				# Adding 1 minute to cover gaps in the assign
				$mili = $endTime.Millisecond * -1
				$endTime = $endTime.AddMilliseconds($mili)
				$startTime = $startTime.AddSeconds(-2)
				
				if(Test-ComputerConnection $targetComputerName)
				{
					try{
						$ntlmEvents = Get-WinEvent -ComputerName $targetComputerName -FilterHashtable @{LogName="Security"; id=4624; StartTime=$startTime; EndTime=$endTime} -ErrorAction SilentlyContinue | Where-Object {($_.Message -match "Logon Type:`t*3") -and ($_.Message -match "Security ID:`t*S-1-0-0") -and ($_.Message -match "Authentication Package:`t*NTLM")}
					}
					catch{
						continue
					}

					$startTime = $endTime.AddTicks(1)
				
					foreach($ntlmEvent in $ntlmEvents){
						$isLegitNTLMConnection = $false
						
						[xml]$ntlmXmlEvent = $ntlmEvent.ToXml()

						$ntlmEventObject = Get-NtlmEventObject $ntlmXmlEvent $targetComputerName
						
						if((Get-UserFromSid $ntlmEventObject.TargetUserSid) -eq $null){
							continue
						}

						if (($global:WellKnownSIDs.ContainsKey($ntlmEventObject.TargetUserSid)) -or ($ntlmEventObject.TargetUserSid -eq $null)){
							#Write-Host "Continue, well known sid"
							continue
						}
						
						if ($ntlmEventObject.WorkstationName -eq $null){
							Write-Verbose "$($global:Tab)[*] No computer name in the log"
							continue
						}				
						
						if(($previousNtmlEvent -ne $null) -and ($previousNtmlEvent.TargetUserSid -eq $ntlmEventObject.TargetUserSid) -and ($previousNtmlEvent.WorkstationName -eq $ntlmEventObject.WorkstationName)){
							if(($previousNtmlEvent.Time - $ntlmEventObject.Time).Seconds -lt $sleepInterval){
								#Write-Host "continue"
								continue
							}
						}

						$isPrivilegedAccount = Is-PrivilegedAccount $ntlmEventObject
			
						if ($isPrivilegedAccount){
							$ntlmDetailsSb = Get-FormatedNTLMObject $ntlmEventObject
									
							if (-not (Test-ComputerExistInAD($ntlmEventObject.WorkstationName))){
								$ntlmDetailsSb.AppendLine("$($global:Tab)[*] Remote login from unidentified computer") | Out-Null
								$ntlmDetailsSb.AppendLine("$($global:Tab)[*] Suspicious NTLM logon" ) | Out-Null
							}
							else{
								Test-TimeOnRemoteComputer $ntlmEventObject.WorkstationName
								$isNewCredUsed = $false
								if($UseNewCredentialsCheck){
									$isNewCredUsed = Is-LogonWithNewCredentials $ntlmEventObject ([ref]$ntlmDetailsSb)
								}
								
								if(-not $isNewCredUsed){
									if(Is-LegitLogon $ntlmEventObject $logonTechnique ([ref]$ntlmDetailsSb)){						
										$isLegitNTLMConnection = $true
									}
									elseif(Is-UsingExplicityPassword $ntlmEventObject){
										$ntlmDetailsSb.AppendLine("$($global:Tab)[*] Found a logon attempt using explicit credentials") | Out-Null
										$isLegitNTLMConnection = $true
									}
								}
							}
							
							Write-Host $ntlmDetailsSb.ToString() -NoNewLine
							
							if ($isLegitNTLMConnection){
								$result = "$($global:Tab)[*] Legit logon"
								Write-Host $result -ForegroundColor Green
							}
							else{
								$result = "$($global:Tab)[*] Illegit logon"
								Write-Host $result -ForegroundColor Red							
							}
							
							$ntlmDetailsSb.AppendLine($result) | Out-Null
							
							if($LogFile){
								Write-LogWithMutex -Message $ntlmDetailsSb.ToString() -LogFile $LogFile
							}
							
							Write-Host
							
						}

						$previousNtmlEvent = $ntlmEventObject
					}
				}
				else{
					Write-Host "No connection to computer "$targetComputerName
				}
			}
		}

		Detect-PTH $targetComputerName $startTime $LogonTechnique $UseNewCredentialsCheck
	}
	
	#endregion script block section
	
	# Requires -Version 2
	# Imported from https://gallery.technet.microsoft.com/scriptcenter/Check-for-Key-Presses-with-7349aadc
	function Test-KeyPress
	{
		<#
			.SYNOPSIS
			Checks to see if a key or keys are currently pressed.

			.DESCRIPTION
			Checks to see if a key or keys are currently pressed. If all specified keys are pressed then will return true, but if 
			any of the specified keys are not pressed, false will be returned.

			.PARAMETER Keys
			Specifies the key(s) to check for. These must be of type "System.Windows.Forms.Keys"

			.EXAMPLE
			Test-KeyPress -Keys ControlKey

			Check to see if the Ctrl key is pressed

			.EXAMPLE
			Test-KeyPress -Keys ControlKey,Shift

			Test if Ctrl and Shift are pressed simultaneously (a chord)

			.LINK
			Uses the Windows API method GetAsyncKeyState to test for keypresses
			http://www.pinvoke.net/default.aspx/user32.GetAsyncKeyState

			The above method accepts values of type "system.windows.forms.keys"
			https://msdn.microsoft.com/en-us/library/system.windows.forms.keys(v=vs.110).aspx

			.LINK
			http://powershell.com/cs/blogs/tips/archive/2015/12/08/detecting-key-presses-across-applications.aspx

			.INPUTS
			System.Windows.Forms.Keys

			.OUTPUTS
			System.Boolean
		#>
		
		[CmdletBinding()]
		param
		(
			[Parameter(Mandatory = $true)]
			[ValidateNotNullOrEmpty()]
			[System.Windows.Forms.Keys[]]
			$Keys
		)
		
		# use the User32 API to define a keypress datatype
		$Signature = @'
		[DllImport("user32.dll", CharSet=CharSet.Auto, ExactSpelling=true)] 
		public static extern short GetAsyncKeyState(int virtualKeyCode); 
'@
		$API = Add-Type -MemberDefinition $Signature -Name 'Keypress' -Namespace Keytest -PassThru
		
		# test if each key in the collection is pressed
		$Result = foreach ($Key in $Keys)
		{
			[bool]($API::GetAsyncKeyState($Key) -eq -32767)
		}
		
		# if all are pressed, return true, if any are not pressed, return false
		$Result -notcontains $false
	}

	# [console]::TreatControlCAsInput = $true
	# The key break is Ctrl+Z
	function Kill-AllThreadsOnKeyBreak($threads){
		$ctrlZPressed = $false
		$killedAll = $false

		if($host.name -eq 'ConsoleHost'){
			if ([console]::KeyAvailable)
			{
				$key = [system.console]::readkey($true)
				if (($key.modifiers -band [consolemodifiers]"control") -and ($key.key -eq "Z"))
				{
					$ctrlZPressed = $true
				}
			}
		}
		else{
			$ctrlZPressed = Test-KeyPress -Keys ([System.Windows.Forms.Keys]::ControlKey),([System.Windows.Forms.Keys]::Z)
		}

		if ($ctrlZPressed){
			Add-Type -AssemblyName System.Windows.Forms
			if ([System.Windows.Forms.MessageBox]::Show("Are you sure you want to exit?", "Exit Script?", [System.Windows.Forms.MessageBoxButtons]::YesNo) -eq "Yes"){
				Write-Host "Terminating threads..."
				ForEach ($Job in $Jobs){
					$Job.Thread.Stop()
					$Job.Thread.Dispose()
					$Job.Thread = $Null
					$Job.Handle = $Null
				}
				
				$killedAll = $true
				Write-Host "Termination completed"
			}
		}
		
		return $killedAll
	}

	function Detect-PTHMultithreaded([array]$Computers, $StartTime, $LogFile, $UseKerberosCheck, $UseNewCredentialsCheck, $MaxHoursOfLegitLogonPriorToNTLMEvent){	
		$SleepTimer = 1
		$MaxThreads = 10000

		$ISS = [system.management.automation.runspaces.initialsessionstate]::CreateDefault()
		$RunspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads, $ISS, $Host)
		$RunspacePool.Open()
		
		$Jobs = @()

		foreach($computer in $Computers){
			$PowershellThread = [powershell]::Create().AddScript($detectPTHScriptBlock)
			$PowershellThread.AddArgument($computer) | out-null
			$PowershellThread.AddArgument($StartTime) | out-null
			$PowershellThread.AddArgument($LogFile) | out-null
			$PowershellThread.AddArgument($UseKerberosCheck) | out-null
			$PowershellThread.AddArgument($UseNewCredentialsCheck) | out-null
			$PowershellThread.AddArgument($MaxHoursOfLegitLogonPriorToNTLMEvent) | out-null
			$PowershellThread.RunspacePool = $RunspacePool
			$Handle = $PowershellThread.BeginInvoke()
			$Job = "" | Select-Object Handle, Thread, object
			$Job.Handle = $Handle
			$Job.Thread = $PowershellThread
			$Job.Object = $computer
			$Jobs += $Job
		}
		
		While (-not (Kill-AllThreadsOnKeyBreak $Jobs))  {
			Start-Sleep -Seconds $SleepTimer
		}

		$RunspacePool.Close() | Out-Null
		$RunspacePool.Dispose() | Out-Null
	}

	#region Main
	
	function Show-Intro
	{
		$AsciiName = @"
	
██╗  ██╗███████╗████████╗███████╗██╗  ██╗ █████╗ ███████╗██╗  ██╗
██║ ██╔╝██╔════╝╚══██╔══╝██╔════╝██║  ██║██╔══██╗██╔════╝██║  ██║
█████╔╝ █████╗     ██║   ███████╗███████║███████║███████╗███████║
██╔═██╗ ██╔══╝     ██║   ╚════██║██╔══██║██╔══██║╚════██║██╔══██║
██║  ██╗███████╗   ██║   ███████║██║  ██║██║  ██║███████║██║  ██║
╚═╝  ╚═╝╚══════╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝

"@

	Write-Host $AsciiName -ForegroundColor Green
	Write-Host "[*] Version 1.2"
	Write-Host "[*] Last update: 17.12.2017"
	Write-Host "[*] To stop press Ctrl+Z and choose 'Yes' on the pop up Window. It will terminate all the opened threads.`n"
	}
	
	#Write-Host "$($global:Tab)[*] When detecting multiple computers, hold Ctrl+Z and choose 'Yes' on the pop up window to stop all the threads"
	
	Show-Intro
	if($TargetComputersFile){
		if(Test-Path ($TargetComputersFile)){
			[array]$TargetComputers = Get-Content $TargetComputersFile
		}
		else{
			Write-Warning "Target computers file does not exist"
			Exit
		}
	}
	
	if($TargetComputers){
		Detect-PTHMultithreaded -Computers $TargetComputers -StartTime $startTime -LogFile $LogFile -UseKerberosCheck $UseKerberosCheck -UseNewCredentialsCheck $UseNewCredentialsCheck -MaxHoursOfLegitLogonPriorToNTLMEvent $MaxHoursOfLegitLogonPriorToNTLMEvent
	}

	#endregion Main
}