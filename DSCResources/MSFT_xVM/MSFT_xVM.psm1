# NOTE: This resource requires WMF5 and PsDscRunAsCredential
$currentPath = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Verbose -Message "CurrentPath: $currentPath"

# Load Common Code
Import-Module $currentPath\..\..\xHyperVHelper.psm1 -Verbose:$false -ErrorAction Stop

function Test-MoveRequired
{
    $MoveRequired = $false
    $VMConfig = Get-TargetResource -Name $Name
    if($VMConfig.Present)
    {
        if($VMConfig.Path -ne $Path)
        {
             Write-Verbose -Message "The VM path for '$($Name)' is currently '$($VMConfig.Path)' when it should be '$($Path)'."
             $MoveRequired = $true
        }
        foreach ($Vhd in $VHDPaths)
        {
            $VhdName = Split-Path $Vhd -Leaf
            $FoundVhd = $VMConfig.VHDPaths | Where-Object { (Split-Path $PSItem -leaf) -eq $VhdName }
            if($FoundVhd)
            {
                Write-Verbose -Message "Found VHD named '$($VhdName)'."
                if((Split-Path $Vhd) -ne (Split-Path $FoundVhd))
                {
                    Write-Verbose -Message "The VHD path for '$($VhdName)' is currently '$($VMConfig.Path)' when it should be '$($Path)'."
                    $MoveRequired = $true
                }
            }
        }
    }
    else
    {
        Write-Verbose -Message "The VM does not exist on this host."
    }
    return $MoveRequired
}

function Test-ClusterVM
{
    if(
        ($VM = Get-ClusterResource -ErrorAction SilentlyContinue | Where-Object {$_.OwnerGroup -eq $Name}) -and
        ($VM | Where-Object {$_.ResourceType -eq "Virtual Machine Configuration"}) -and
        ($VM | Where-Object {$_.ResourceType -eq "Virtual Machine"})
    )
    {
       $true
    }
    else
    {
        $false
    }
}

function Get-TargetResource
{
	[CmdletBinding()]
	[OutputType([System.Collections.Hashtable])]
	param
	(
		[parameter(Mandatory = $true)]
		[System.String]
		$Name
	)

    if(Get-VM -Name $Name -ErrorAction SilentlyContinue)
    {
        $VM = Get-VM -Name $Name
        $Present = $true
		$Path = $VM.Path
		$Generation = $VM.Generation
		$ProcessorCount = $VM.ProcessorCount
		$CompatibilityForMigrationEnabled = (Get-VMProcessor -VM $VM).CompatibilityForMigrationEnabled
		if($VM.DynamicMemoryEnabled)
        {
            $MemoryType = "Dynamic"
        }
        else
        {
            $MemoryType = "Static"
        }
		$MemoryStartupBytes = $VM.MemoryStartup
        if($MemoryType -eq "Dynamic")
        {
		    $MemoryMinimumBytes = $VM.MemoryMinimum
		    $MemoryMaximumBytes = $VM.MemoryMaximum
            $MemoryBuffer = (Get-VMMemory -VM $VM).Buffer
        }
		$SwitchName = $VM.NetworkAdapters.SwitchName
		$MacAddress = $VM.NetworkAdapters.MacAddress
		$MacAddressSpoofing = (Get-VMNetworkAdapter -VM $VM).MacAddressSpoofing
        $VHDs = Get-VHD -VMId $VM.Id		
        if($VHDs)
        {
            $VHDPaths = @($VHDs.Path)
        }
		$AutomaticStartAction = $VM.AutomaticStartAction
		$AutomaticStartDelay = $VM.AutomaticStartDelay
		$AutomaticStopAction = $VM.AutomaticStopAction
    }
    else
    {
        $Present = $false
    }

	$returnValue = @{
		Name = $Name
        Present = $Present
		Path = $Path
		Generation = $Generation
		ProcessorCount = $ProcessorCount
		CompatibilityForMigrationEnabled = $CompatibilityForMigrationEnabled
		MemoryType = $MemoryType
		MemoryStartupBytes = $MemoryStartupBytes
		MemoryMinimumBytes = $MemoryMinimumBytes
		MemoryMaximumBytes = $MemoryMaximumBytes
        MemoryBuffer = $MemoryBuffer
		SwitchName = $SwitchName
		MacAddress = $MacAddress
		MacAddressSpoofing = $MacAddressSpoofing
		VHDPaths = $VHDPaths
		AutomaticStartAction = $AutomaticStartAction
		AutomaticStartDelay = $AutomaticStartDelay
		AutomaticStopAction = $AutomaticStopAction
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
		$Name,

		[System.String]
		$Path = (Get-VMHost).VirtualMachinePath,

		[ValidateSet("1","2")]
		[System.String]
		$Generation = "2",

		[System.Byte]
		$ProcessorCount = 1,

		[System.Boolean]
		$CompatibilityForMigrationEnabled = $false,

		[ValidateSet("Dynamic","Static")]
		[System.String]
		$MemoryType = "Static",

		[System.UInt64]
		$MemoryStartupBytes = 536870912,

		[System.UInt64]
		$MemoryMinimumBytes = $MemoryStartupBytes,

		[System.UInt64]
		$MemoryMaximumBytes = $MemoryStartupBytes,

		[System.UInt32]
		$MemoryBuffer = 20,

		[System.String]
		$SwitchName,

		[System.String]
		$MacAddress,

		[ValidateSet("On","Off")]
		[System.String]
		$MacAddressSpoofing,

		[System.String[]]
		$VHDPaths,

		[System.String[]]
		$SharedVHDPaths,

		[ValidateSet("Nothing","StartIfRunning","Start")]
		[System.String]
		$AutomaticStartAction = "StartIfRunning",

		[System.UInt32]
		$AutomaticStartDelay = 0,

		[ValidateSet("TurnOff","Save","ShutDown")]
		[System.String]
		$AutomaticStopAction = "Save",

		[System.Boolean]
		$StartVM,

		[System.Boolean]
		$ClusterVM,

		[System.Boolean]
		$MoveVMStorage
	)

    $VM = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if($MoveVMStorage)
    {
        if($VM)
        {
            $VhdList = @()
            foreach ($Vhd in $VHDPaths)
            {
                $VhdName = Split-Path $Vhd -Leaf
                Write-Verbose -Message "Looking for VHD named '$($VhdName)'."
                $FoundVhd = $VM.HardDrives.Path | Where-Object { (Split-Path $PSItem -leaf) -eq $VhdName }
                if($FoundVhd)
                {
                    Write-Verbose -Message "Found VHD named '$($VhdName)'."
                    if((Split-Path $Vhd) -ne (Split-Path $FoundVhd))
                    {
                        Write-Verbose -Message "The VHD '$($FoundVhd)' needs to be moved to '$($Vhd)'."
                        $VhdList += @{"SourceFilePath" = "$FoundVhd"; "DestinationFilePath" = "$Vhd"}
                    }
                }
            }
            try
            {
                Write-Verbose -Message "Moving '$($VM.Name)' VM storage paths."
                if($VhdList.Count -gt 0)
                {
                    Move-VMStorage -VMName $Name -VirtualMachinePath $Path -SnapshotFilePath "$Path\Snapshots" -SmartPagingFilePath "$Path\SmartPaging" -Vhds $VhdList
                }
                else
                {
                    Write-Verbose -Message "No VHDs need to be moved."
                    Move-VMStorage -VMName $Name -VirtualMachinePath $Path -SnapshotFilePath "$Path\Snapshots" -SmartPagingFilePath "$Path\SmartPaging"
                }
            }
            catch
            {
                throw $PSItem.Exception
            }
        }
    }
    else
    {
        $VM = New-VM -Name $Name -Path $Path -MemoryStartupBytes $MemoryStartupBytes -Generation $Generation
        Set-VMProcessor -VM $VM -Count $ProcessorCount -CompatibilityForMigrationEnabled $CompatibilityForMigrationEnabled
        if($MemoryType -eq 'Dynamic')
        {
            Set-VMMemory -VM $VM -DynamicMemoryEnabled $true -StartupBytes $MemoryStartupBytes -MinimumBytes $MemoryMinimumBytes -MaximumBytes $MemoryMaximumBytes -Buffer $MemoryBuffer
        }
        if($SwitchName)
        {
            Connect-VMNetworkAdapter -VMName $Name -SwitchName $SwitchName
        }
        if($MacAddress)
        {
            Set-VMNetworkAdapter -VM $VM -StaticMacAddress $MacAddress
        }
        if($MacAddressSpoofing)
        {
            Set-VMNetworkAdapter -VM $VM -MacAddressSpoofing $MacAddressSpoofing
        }
        if($VHDPaths)
        {
            if($Generation -eq "1")
            {
                Add-VMHardDiskDrive -VM $VM -ControllerType IDE -ControllerNumber 0 -ControllerLocation 0 -Path $VHDPaths[0]
                $NextControllerLocation = 0
            }
            else
            {
                Add-VMHardDiskDrive -VM $VM -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 0 -Path $VHDPaths[0]
                Set-VMFirmware -VM $VM -FirstBootDevice (Get-VMHardDiskDrive -VM $VM -ControllerLocation 0 -ControllerNumber 0)
                $NextControllerLocation = 1
            }
            if($VHDPaths.Count -gt 1)
            {
                foreach($VHDPath in $VHDPaths[1 .. ($VHDPaths.Count - 1)])
                {
                    Add-VMHardDiskDrive -VM $VM -ControllerType SCSI -ControllerNumber 0 -ControllerLocation $NextControllerLocation -Path $VHDPath
                    $NextControllerLocation++
                }
            }
        }
        if($SharedVHDPaths)
        {
            foreach($SharedVHDPath in $SharedVHDPaths)
            {
                Add-VMHardDiskDrive -VM $VM -ControllerType SCSI -ControllerNumber 0 -ControllerLocation $NextControllerLocation -Path $SharedVHDPath -ShareVirtualDisk
                $NextControllerLocation++
            }
        }

        Set-VM -VM $VM -AutomaticStartAction $AutomaticStartAction -AutomaticStartDelay $AutomaticStartDelay -AutomaticStopAction $AutomaticStopAction

        if($StartVM)
        {
            Start-VM -Name $Name
        }
    }

    if($ClusterVM)
    {
        if(-not(Test-ClusterVM))
        {
            Add-ClusterVirtualMachineRole -VMName $Name
        }
    }

    if(-not(Test-TargetResource -Name $Name))
    {
        throw New-TerminatingError -ErrorType TestFailedAfterSet -ErrorCategory InvalidResult
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
        $Name,

        [System.String]
        $Path,

        [ValidateSet("1","2")]
        [System.String]
        $Generation,

        [System.Byte]
        $ProcessorCount,

        [System.Boolean]
        $CompatibilityForMigrationEnabled,

        [ValidateSet("Dynamic","Static")]
        [System.String]
        $MemoryType,

        [System.UInt64]
        $MemoryStartupBytes,

        [System.UInt64]
        $MemoryMinimumBytes,

        [System.UInt64]
        $MemoryMaximumBytes,

        [System.UInt32]
        $MemoryBuffer = 20,

        [System.String]
        $SwitchName,

        [System.String]
        $MacAddress,

        [ValidateSet("On","Off")]
        [System.String]
        $MacAddressSpoofing,

        [System.String[]]
        $VHDPaths,

        [System.String[]]
        $SharedVHDPaths,

        [ValidateSet("Nothing","StartIfRunning","Start")]
        [System.String]
        $AutomaticStartAction,

        [System.UInt32]
        $AutomaticStartDelay,

        [ValidateSet("TurnOff","Save","ShutDown")]
        [System.String]
        $AutomaticStopAction,

        [System.Boolean]
        $StartVM,

        [System.Boolean]
        $ClusterVM,

        [System.Boolean]
        $MoveVMStorage
    )

    if ($ClusterVM)
    {
        if(Test-ClusterVM)
        {
            if($MoveVMStorage)
            {
                if(Test-MoveRequired)
                {
                    Write-Verbose -Message "A VM storage move is required."
                    $result = $false
                }
                else
                {
                    $result = $true
                }
            }
            else
            {
                $result = $true
            }
        }
        else
        {
            if($MoveVMStorage)
            {
                if(Test-MoveRequired)
                {
                    Write-Verbose -Message "A VM storage move is required."
                    $result = $false
                }
                else
                {
                    $result = $true
                }
            }
            else
            {
               $result = $false
            }
        }
    }
    else
    {
        if(Get-VM -Name $Name -ErrorAction SilentlyContinue)
        {
            if($MoveVMStorage)
            {
                if(Test-MoveRequired)
                {
                    Write-Verbose -Message "A VM storage move is required."
                    $result = $false
                }
                else
                {
                    $result = $true
                }
            }
            else
            {
                $result = $true
            }
        }
        else
        {
            $result = $false
        }
    }
	
	$result
}

Export-ModuleMember -Function *-TargetResource
