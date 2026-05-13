param (
    [string]$FFUDevelopmentPath = $PSScriptRoot,
    [string]$adkPath = 'C:\Program Files (x86)\Windows Kits\10\',
    [string]$WindowsArch = 'x64',
    [bool]$CopyPEDrivers = $false,
    [string]$DeployISO = "$PSScriptRoot\WinPE_FFU_Deploy_x64.iso",
    [string]$LogFile = "$PSScriptRoot\Create-PEMedia.log"
)

# Added function to set password and key
function Set-SecurePW {
    if ((-not (Test-Path "$FFUDevelopmentPath\WinPEDeployFFUFiles\Password.txt")) -and (-not (Test-Path "$FFUDevelopmentPath\WinPEDeployFFUFiles\AES.key"))) {
        $KeyFile = "$FFUDevelopmentPath\WinPEDeployFFUFiles\AES.key"
        $Key = New-Object Byte[] 32
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($Key)
        $Key | Out-File $KeyFile
        $PasswordFile = "$FFUDevelopmentPath\WinPEDeployFFUFiles\Password.txt"
        $Key = Get-Content $KeyFile
        $Password = Read-Host -MaskInput -Prompt "Type your FFU Share Service Account password here" | ConvertTo-SecureString -AsPlainText -Force
        $Password | ConvertFrom-SecureString -key $Key | Out-File $PasswordFile
    }
}

function WriteLog($LogText) { 
    Add-Content -path $LogFile -value "$((Get-Date).ToString()) $LogText" -Force -ErrorAction SilentlyContinue
    Write-Verbose $LogText
}

function Invoke-Process {
    [CmdletBinding(SupportsShouldProcess)]
    param
    (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ArgumentList
    )

    $ErrorActionPreference = 'Stop'

    try {
        $stdOutTempFile = "$env:TEMP\$((New-Guid).Guid)"
        $stdErrTempFile = "$env:TEMP\$((New-Guid).Guid)"

        $startProcessParams = @{
            FilePath               = $FilePath
            ArgumentList           = $ArgumentList
            RedirectStandardError  = $stdErrTempFile
            RedirectStandardOutput = $stdOutTempFile
            Wait                   = $true;
            PassThru               = $true;
            NoNewWindow            = $true;
        }
        if ($PSCmdlet.ShouldProcess("Process [$($FilePath)]", "Run with args: [$($ArgumentList)]")) {
            $cmd = Start-Process @startProcessParams
            $cmdOutput = Get-Content -Path $stdOutTempFile -Raw
            $cmdError = Get-Content -Path $stdErrTempFile -Raw
            if ($cmd.ExitCode -ne 0) {
                if ($cmdError) {
                    throw $cmdError.Trim()
                }
                if ($cmdOutput) {
                    throw $cmdOutput.Trim()
                }
            }
            else {
                if ([string]::IsNullOrEmpty($cmdOutput) -eq $false) {
                    WriteLog $cmdOutput
                }
            }
        }
    }
    catch {
        #$PSCmdlet.ThrowTerminatingError($_)
        WriteLog $_
        Write-Host "Script failed - $Logfile for more info"
        throw $_

    }
    finally {
        Remove-Item -Path $stdOutTempFile, $stdErrTempFile -Force -ErrorAction Ignore
		
    }
	
}

function New-PEMedia {
    param ()
    #Need to use the Demployment and Imaging tools environment to create winPE media
    $DandIEnv = "$adkPath`Assessment and Deployment Kit\Deployment Tools\DandISetEnv.bat"
    $WinPEFFUPath = "$FFUDevelopmentPath\WinPE"

    If (Test-path -Path "$WinPEFFUPath") {
        WriteLog "Removing old WinPE path at $WinPEFFUPath"
        Remove-Item -Path "$WinPEFFUPath" -Recurse -Force | out-null
    }

    WriteLog "Copying WinPE files to $WinPEFFUPath"
    if($WindowsArch -eq 'x64') {
        & cmd /c """$DandIEnv"" && copype amd64 $WinPEFFUPath" | Out-Null
    }
    elseif($WindowsArch -eq 'arm64') {
        & cmd /c """$DandIEnv"" && copype arm64 $WinPEFFUPath" | Out-Null
    }
    #Invoke-Process cmd "/c ""$DandIEnv"" && copype amd64 $WinPEFFUPath"
    WriteLog 'Files copied successfully'

    WriteLog 'Mounting WinPE media to add WinPE optional components'
    Mount-WindowsImage -ImagePath "$WinPEFFUPath\media\sources\boot.wim" -Index 1 -Path "$WinPEFFUPath\mount" | Out-Null
    WriteLog 'Mounting complete'

    $Packages = @(
        "WinPE-WMI.cab",
        "en-us\WinPE-WMI_en-us.cab",
        "WinPE-NetFX.cab",
        "en-us\WinPE-NetFX_en-us.cab",
        "WinPE-Scripting.cab",
        "en-us\WinPE-Scripting_en-us.cab",
        "WinPE-PowerShell.cab",
        "en-us\WinPE-PowerShell_en-us.cab",
        "WinPE-StorageWMI.cab",
        "en-us\WinPE-StorageWMI_en-us.cab",
        "WinPE-DismCmdlets.cab",
        "en-us\WinPE-DismCmdlets_en-us.cab"
    )

    if($WindowsArch -eq 'x64'){
        $PackagePathBase = "$adkPath`Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\"
    }
    elseif($WindowsArch -eq 'arm64'){
        $PackagePathBase = "$adkPath`Assessment and Deployment Kit\Windows Preinstallation Environment\arm64\WinPE_OCs\"
    }
    
    # Added call to function to set password
    WriteLog "Setting PW for Deployment Share"
    Set-SecurePW

    foreach ($Package in $Packages) {
        $PackagePath = Join-Path $PackagePathBase $Package
        WriteLog "Adding Package $Package"
        Add-WindowsPackage -Path "$WinPEFFUPath\mount" -PackagePath $PackagePath | Out-Null
        WriteLog "Adding package complete"
    }
    WriteLog "Copying $FFUDevelopmentPath\WinPEDeployFFUFiles\* to WinPE deploy media"
    Copy-Item -Path "$FFUDevelopmentPath\WinPEDeployFFUFiles\*" -Destination "$WinPEFFUPath\mount" -Recurse -Force | Out-Null
    WriteLog 'Copy complete'
    #If $CopyPEDrivers = $true, add drivers to WinPE media using dism
    if ($CopyPEDrivers) {
        WriteLog "Adding drivers to WinPE media"
        try {
            Add-WindowsDriver -Path "$WinPEFFUPath\Mount" -Driver "$FFUDevelopmentPath\PEDrivers" -Recurse -ErrorAction SilentlyContinue | Out-null
        }
        catch {
            WriteLog 'Some drivers failed to be added to the FFU. This can be expected. Continuing.'
        }
        WriteLog "Adding drivers complete"
    }
    $WinPEISOFile = $DeployISO
    WriteLog 'Dismounting WinPE media' 
    Dismount-WindowsImage -Path "$WinPEFFUPath\mount" -Save | Out-Null
    WriteLog 'Dismount complete'
    #Make ISO
    if ($WindowsArch -eq 'x64') {
        $OSCDIMGPath = "$adkPath`Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg"
    }
    elseif ($WindowsArch -eq 'arm64') {
        $OSCDIMGPath = "$adkPath`Assessment and Deployment Kit\Deployment Tools\arm64\Oscdimg"
    }
    $OSCDIMG = "$OSCDIMGPath\oscdimg.exe"
    WriteLog "Creating WinPE ISO at $WinPEISOFile"
    # & "$OSCDIMG" -m -o -u2 -udfver102 -bootdata:2`#p0,e,b$OSCDIMGPath\etfsboot.com`#pEF,e,b$OSCDIMGPath\Efisys_noprompt.bin $WinPEFFUPath\media $FFUDevelopmentPath\$WinPEISOName | Out-null
    if($WindowsArch -eq 'x64'){
        $OSCDIMGArgs = "-m -o -u2 -udfver102 -bootdata:2`#p0,e,b`"$OSCDIMGPath\etfsboot.com`"`#pEF,e,b`"$OSCDIMGPath\Efisys.bin`" `"$WinPEFFUPath\media`" `"$WinPEISOFile`""
    }
    elseif($WindowsArch -eq 'arm64'){
        $OSCDIMGArgs = "-m -o -u2 -udfver102 -bootdata:1`#pEF,e,b`"$OSCDIMGPath\Efisys.bin`" `"$WinPEFFUPath\media`" `"$WinPEISOFile`""
    }
    Invoke-Process $OSCDIMG $OSCDIMGArgs
    WriteLog "ISO created successfully"
        # Export WIM before deleting WinPE folder
    WriteLog 'Exporting boot wim'
    Copy-Item "$WinPEFFUPath\media\sources\boot.wim" -Destination "$FFUDevelopmentPath\boot.wim" -Force | Out-Null

    # Uploads new image to WDS if found
      if ( (get-windowsfeature WDS-Deployment).InstallState -eq "Installed" ) {
        $currentbootimg = (Get-WdsBootImage -ImageName "FFU UI" | ? Enabled -EQ "True" | select -first 1)
        $bootwim = $FFUDevelopmentPath + "\boot.wim"
        
        # Checks for exiting image
        if ( $currentbootimg -eq $null ) {
            $ijob = {
                Param($boot)
                Import-WdsBootImage -Path $boot -NewImageName "FFU UI" -NewDescription "FFU UI" -DisplayOrder 500000
                }
                $i = Start-job -ScriptBlock $ijob -argumentlist $bootwim
                Wait-job $i | Receive-job
        }
        
        else { 
            $oa = ""
            while ($oa -notmatch '^[oa]$') {

                Write-host "Existing Image found."
                $oa = Read-Host "(O)verwrite or (A)ppend?"

                if ($oa -eq 'o') { 
                    $ojob = {
                        Param($boot,$arch,$do)
                        Remove-WdsBootImage -ImageName "FFU UI" -Architecture $arch
                        Start-Sleep -seconds 30
                        Import-WdsBootImage -Path $boot -NewImageName "FFU UI" -NewDescription "FFU UI" -DisplayOrder $do
                        }
                    $o = Start-Job -scriptblock $ojob -ArgumentList $bootwim,$WindowsArch,$currentbootimg.DisplayOrder
                    Wait-Job $o | Receive-Job
                    }
                
                elseif ( $oa -eq 'a') {
                    $ajob = {
                         Param($boot,$do)
                         $do++
                         Import-WdsBootImage -Path $boot -NewImageName "FFU UI" -NewDescription "FFU UI" -DisplayOrder $do
                         }
                    $a = Start-Job -scriptblock $ajob -ArgumentList $bootwim,$currentbootimg.DisplayOrder
                    Wait-Job $a | Receive-Job
                    }
            }
        }
    # Comment the next line if you want to keep the resulting WIM file available after upload to WDS.
    Remove-Item "$FFUDevelopmentPath\boot.wim" -Force
    Write-host "Upload to WDS complete."
    }
    
    Else {
    WriteLog 'WDS not installed, preserving .wim'
    Write-host "Be sure to upload your wim file to the WDS server"
    }
    
    WriteLog "Cleaning up $WinPEFFUPath"
    Remove-Item -Path "$WinPEFFUPath" -Recurse -Force

    # Added lines to clean up password files
    # Comment the remove-item line out if you are comfortable with leaving the password and key files intact.
    WriteLog "Cleaning up password files"
    Remove-Item -Path "$FFUDevelopmentPath\WinPEDeployFFUFiles\*" -Include "*.txt","*.key" -Exclude "*.ps1" -Force

    WriteLog 'Cleanup complete'
}

New-PEMedia