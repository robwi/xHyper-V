# NOTE: This resource requires WMF5 and PsDscRunAsCredential
$currentPath = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Debug -Message "CurrentPath: $currentPath"

# Load Common Code
Import-Module $currentPath\..\..\xHyperVHelper.psm1 -Verbose:$false -ErrorAction Stop

function Get-TargetResource
{
	[CmdletBinding()]
	[OutputType([System.Collections.Hashtable])]
	param
	(
		[parameter(Mandatory = $true)]
		[ValidateSet("Copy","Differencing","Fixed","Dynamic","Resize")]
		[System.String]
		$Type,

		[parameter(Mandatory = $true)]
		[System.String]
		$Path
	)

    if(Test-Path -Path $Path)
    {
        $Ensure = "Present"
        if($Type -eq 'Resize')
        {
            $VHD = Get-VHD -Path $Path
            $SizeBytes = $VHD.Size
        }
    }
    else
    {
        $Ensure = "Absent"
    }

    $returnValue = @{
		Ensure = $Ensure
		Path = $Path
		ParentPath = $ParentPath
        SizeBytes = $SizeBytes
	}

	$returnValue
}


function Set-TargetResource
{
	[CmdletBinding()]
	param
	(
		[ValidateSet("Present","Absent")]
		[System.String]
		$Ensure = "Present",

		[parameter(Mandatory = $true)]
		[ValidateSet("Copy","Differencing","Fixed","Dynamic","Resize")]
		[System.String]
		$Type,

		[parameter(Mandatory = $true)]
		[System.String]
		$Path,

		[System.UInt64]
		$SizeBytes,

		[System.String]
		$ParentPath,

		[System.Boolean]
		$OSDisk,

		[System.String]
		$OSName,

		[System.String]
		$WindowsProductKey,

		[System.String[]]
		$FirewallRules,

		[System.Management.Automation.PSCredential]
		$AdministratorPassword
	)

    switch($Ensure)
    {
        "Present"
        {
            if(!(Test-Path -Path ([IO.Path]::GetDirectoryName($Path))))
            {
                Write-Verbose "Creating folder $([IO.Path]::GetDirectoryName($Path))"
                New-Item -Path ([IO.Path]::GetDirectoryName($Path)) -ItemType Directory
            }

            if(Test-Path -Path ([IO.Path]::GetDirectoryName($Path)))
            {
                if(!(Test-Path -Path $Path))
                {
                    switch($Type)
                    {
                        "Copy"
                        {
                            if(Test-Path -Path $ParentPath)
                            {
                                Write-Verbose "Copying $ParentPath to $Path"
                                Copy-Item -Path $ParentPath -Destination $Path
                            }
                            else
                            {
                                throw New-TerminatingError -ErrorType PathNotFound -FormatArgs @($ParentPath) -ErrorCategory ObjectNotFound -TargetObject $ParentPath
                            }
                        }
                        "Differencing"
                        {
                            if(Test-Path -Path $ParentPath)
                            {
                                if($SizeBytes)
                                {
                                    Write-Verbose "Creating differencing disk $Path from $ParentPath with size $SizeBytes"
                                    New-VHD -Path $Path -ParentPath $ParentPath -Differencing -SizeBytes $SizeBytes
                                }
                                else
                                {
                                    Write-Verbose "Creating differencing disk $Path from $ParentPath"
                                    New-VHD -Path $Path -ParentPath $ParentPath -Differencing
                                }
                            }
                            else
                            {
                                throw New-TerminatingError -ErrorType PathNotFound -FormatArgs @($ParentPath) -ErrorCategory ObjectNotFound -TargetObject $ParentPath
                            }
                        }
                        "Fixed"
                        {
                            Write-Verbose "Creating fixed disk $Path with size $SizeBytes"
                            New-VHD -Path $Path -SizeBytes $SizeBytes -Fixed
                        }
                        "Dynamic"
                        {
                            Write-Verbose "Creating dynamic disk $Path with size $SizeBytes"
                            New-VHD -Path $Path -SizeBytes $SizeBytes -Dynamic
                        }
                    }
                }
                else
                {
                    Write-Verbose "$Path already exists"
                }

                if(
                    ($Type -in @('Copy','Differencing','Resize')) -and
                    (
                        ($OSDisk) -or
                        $PSBoundParameters.ContainsKey('SizeBytes')
                    ) 
                )
                {
                    # Resize disk
                    if($PSBoundParameters.ContainsKey('SizeBytes'))
                    {
                        $VHD = Get-VHD -Path $Path
                        if($VHD.Size -ne $SizeBytes)
                        {
                            Write-Verbose "Resizing VHD $Path to $SizeBytes"
                            Resize-VHD -Path $Path -Size $SizeBytes
                            $Resize = $true
                        }
                    }
                    
                    # Mount disk
                    Write-Verbose "Mounting disk $Path"
                    $DiskNumber = $null
                    while($DiskNumber -eq $null)
                    {
                        $DiskNumber = (Mount-VHD -Path $Path -ErrorAction SilentlyContinue -PassThru).DiskNumber
                    }
                    Write-Verbose "Disk $Path mounted as disk $DiskNumber"
                    while((Get-Disk -Number $DiskNumber).IsOffline)
                    {
                        Write-Verbose "Bringing disk $DiskNumber online"
                        Set-Disk -Number $DiskNumber -IsOffline $false
                    }
                    while((Get-Disk -Number $DiskNumber).IsReadOnly)
                    {
                        Write-Verbose "Removing ReadOnly from disk $DiskNumber"
                        Set-Disk -Number $DiskNumber -IsReadOnly $false
                    }
                    $Partitions = Get-Disk -Number $DiskNumber | Get-Partition
                    $Partition = ($Partitions | Sort-Object {$_.Size} -Descending)[0]
                    $Drive = $Partition.DriveLetter
                    $PartitionNumber = $Partition.PartitionNumber
                    Write-Verbose "Disk $Path mounted with partition $PartitionNumber as drive $Drive"

                    if($Drive)
                    {
                        # Resize disk
                        if($Resize)
                        {
                            $SizeMax = (Get-PartitionSupportedSize -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber).SizeMax
                            Write-Verbose "Resizing partition $PartitionNumber to $SizeMax"
                            Resize-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -Size $SizeMax
                        }

                        # OS disk
                        if($OSDisk)
                        {
                            $null = Get-PSDrive
                            while(!(Test-Path -Path "$Drive`:\"))
                            {
                                Write-Verbose "Waiting for $Drive`:\"
                                Start-Sleep 1
                            }
                            Write-Verbose "Inserting unattend.xml"
@"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <ComputerName>$OSName</ComputerName>
            <RegisteredOrganization></RegisteredOrganization>
            <RegisteredOwner></RegisteredOwner>
"@ | Out-File "$Drive`:\unattend.xml" -Encoding ASCII
                            if($WindowsProductKey) {
                                Write-Verbose "Adding Windows Product Key"
@"
            <ProductKey>$WindowsProductKey</ProductKey>
"@ | Out-File "$Drive`:\unattend.xml" -Append -Encoding ASCII
                            }
@"
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <UserAccounts>
                <AdministratorPassword>
                    <Value>$($AdministratorPassword.GetNetworkCredential().Password)</Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
            </UserAccounts>
            <RegisteredOrganization></RegisteredOrganization>
            <RegisteredOwner></RegisteredOwner>
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <SkipMachineOOBE>true</SkipMachineOOBE>
            </OOBE>
        </component>
    </settings>
</unattend>
"@ | Out-File "$Drive`:\unattend.xml" -Append -Encoding ASCII
                            if(!(Test-Path -Path "$Drive`:\Windows\Setup\Scripts"))
                            {
                                Write-Verbose "Creating $Drive`:\Windows\Setup\Scripts"
                                New-Item -Path "$Drive`:\Windows\Setup\Scripts" -ItemType Directory
                            }
                            if($FirewallRules)
                            {
                                foreach($FirewallRule in $FirewallRules)
                                {
                                    Write-Verbose "Adding firewall rule $FirewallRule"
@"
powershell.exe -Command "Set-NetFirewallRule -Name $FirewallRule -Enabled True -Profile Any"
"@ | Out-File "$Drive`:\Windows\Setup\Scripts\SetupComplete.cmd" -Encoding ASCII -Append
                                }
                            }
@"
powershell.exe -Command "Rename-Computer -NewName $OSName -Restart"                    
"@ | Out-File "$Drive`:\Windows\Setup\Scripts\SetupComplete.cmd" -Encoding ASCII -Append
                        }
                    }
                    else
                    {
                        throw New-TerminatingError -ErrorType FailedToMountVHD -FormatArgs @($Path)
                    }

                    Write-Verbose "Dismounting $Path"
                    Dismount-VHD -Path $Path
                }
            }
            else
            {
                Write-Verbose "Failed creating folder $([IO.Path]::GetDirectoryName($Path))"
            }
        }
        "Absent"
        {
            Write-Verbose "Deleting $Path"
            Remove-Item -Path $Path
        }
    }

    if(!(Test-TargetResource -Type $Type -Path $Path))
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
		[ValidateSet("Present","Absent")]
		[System.String]
		$Ensure = "Present",

		[parameter(Mandatory = $true)]
		[ValidateSet("Copy","Differencing","Fixed","Dynamic","Resize")]
		[System.String]
		$Type,

		[parameter(Mandatory = $true)]
		[System.String]
		$Path,

		[System.UInt64]
		$SizeBytes,

		[System.String]
		$ParentPath,

		[System.Boolean]
		$OSDisk,

		[System.String]
		$OSName,

		[System.String]
		$WindowsProductKey,

		[System.String[]]
		$FirewallRules,

		[System.Management.Automation.PSCredential]
		$AdministratorPassword
	)

    if($Type -eq 'Resize')
    {
        $result = ((Get-TargetResource -Type $Type -Path $Path).SizeBytes -eq $SizeBytes)
    }
    else
    {
        $result = ((Get-TargetResource -Type $Type -Path $Path).Ensure -eq $Ensure)
    }

    if(($Ensure -eq 'Present') -and $result -and $OSDisk)
    {
        Write-Verbose "Attempting to mount disk $Path"
        try
        {
            Mount-VHD -Path $Path -ErrorAction Stop
            Write-Verbose "Successfully mounted disk $Path, setting result to false and dismounting"
            $result = $false
            Dismount-VHD -Path $Path
        }
        catch
        {
            Write-Verbose "Failed mounting disk $Path, we will assume it is being used by a VM"
        }
    }

	$result
}


Export-ModuleMember -Function *-TargetResource