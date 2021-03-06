function Get-TargetResource
{
	[CmdletBinding()]
	[OutputType([System.Collections.Hashtable])]
	param
	(
		[parameter(Mandatory = $true)]
		[System.String]
		$VMName
	)

	$VM = Get-VM -Name $VMName

	$returnValue = @{
		VM = $VM
	}

	$returnValue
	
}


function Set-TargetResource
{
	[CmdletBinding()]
	param
	(
		[parameter(Mandatory = $true)]
		[System.String]
		$VMName,

		[System.String[]]
		$VHDPaths,

		[ValidateSet("IDE","SCSI")]
		[System.String]
		$ControllerType = "SCSI",

		[ValidateSet(1,2,3,4)]
		[System.UInt64]
		$MaxNumberOfControllers = 4,

		[System.Boolean]
		$StartVM = $true
	)

	$DPMVM = (Get-TargetResource -VMName $VMName).VM
	if($DPMVM -ne $null)
	{
		$ExistingVMDisks = $DPMVM.HardDrives.Path
		if($ExistingVMDisks -ne $null)
        {
            $ExistingVHDsCount = $ExistingVMDisks.Count
        }
		$VhdsToBeAdded2VM = @()
		foreach($VHD in $VHDPaths)
		{	
			if(!$ExistingVMDisks.Contains($VHD))
			{
				$VhdsToBeAdded2VM += @($VHD)
			}
		}

		if($ControllerType -eq "SCSI" )
		{
		
			#Create SCSCI controllers
			$AdaptersCount = ($DPMVM | Get-VMScsiController).count		
			if($AdaptersCount -lt $MaxNumberOfControllers -and $DPMVM.State -eq 'Running')
			{
				Write-Verbose "New SCSI controllers can't be create while VM is in Running state."
				exit
			}
			while($AdaptersCount -lt $MaxNumberOfControllers)
			{
				$null = $DPMVM | Add-VMScsiController 
				$AdaptersCount++
			}
			#Add VHDs
			

			if(($ExistingVHDsCount + $VhdsToBeAdded2VM.count) -gt ($AdaptersCount * 64))
            {
                Write-Verbose "Exceeded maximum limit to add SCSI disks. Failed to add VHDs to $DPMVM.Name."
				exit
            }

            #VHDsOnBus contains the existing VHDs count for bus(index of array)
            $VHDsOnBus = @{}
            for($Bus = 0; $Bus -lt $AdaptersCount; $Bus++)
            {
                $VDDs = $DPMVM.hardDrives | where{$_.ControllerNumber -eq $Bus -and $_.ControllerType -eq "SCSI"}
                if($VDDs -ne $null)                
                {
                    $VHDsOnBus[$Bus] = $VDDs.Count
                }
				else
				{
					$VHDsOnBus[$Bus] = 0
				}

            }
            
            foreach($VhdTobeAdded in $VhdsToBeAdded2VM)
            {
				#Find the bus with minimumm number of VHDs attached
				 $Bus = ($VHDsOnBus.GetEnumerator() | Sort-Object -Property value)[0].key
                 Add-VMHardDiskDrive -VM $DPMVM -ControllerType SCSI -ControllerNumber $Bus -Path $VhdTobeAdded
				 $VHDsOnBus[$Bus] += 1
            }

		}
		else #Add disk to IDE controller
		{
			foreach($VhdTobeAdded in $VhdsToBeAdded2VM)
            {				 
                 Add-VMHardDiskDrive -VM $DPMVM -ControllerType IDE -ControllerNumber $Bus -Path $VhdTobeAdded				 
            }
		}

		if($StartVM)
        {
            $DPMVM | Start-VM 
        }
	}
	else
	{
		Write-Verbose "$VM is not available on host."
	}		
	

}


function Test-TargetResource
{
	[CmdletBinding()]
	[OutputType([System.Boolean])]
	param
	(
		[parameter(Mandatory = $true)]
		[System.String]
		$VMName,

		[System.String[]]
		$VHDPaths,

		[ValidateSet("IDE","SCSI")]
		[System.String]
		$ControllerType = "SCSI",

		[System.UInt64]
		$MaxNumberOfControllers = 4,

		[System.Boolean]
		$StartVM = $true
	)
	$DPMVM = (Get-TargetResource -VMName $VMName).VM
	$result	= $true
	if($DPMVM -ne $null)
	{
		$ExistingVMDisks = $DPMVM.HardDrives.Path		
		foreach($VHD in $VHDPaths)
		{	
			if(!$ExistingVMDisks.Contains($VHD))
			{
				$result	= $false #Needs to add some VHDs
			}
		}	
	}
	else
	{
		Write-Verbose "$($DPMVM.Name) is not available on host."
	}	
	
	$result	
}


Export-ModuleMember -Function *-TargetResource

