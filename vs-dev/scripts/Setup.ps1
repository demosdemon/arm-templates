#requires -Version 3.0 -Modules Microsoft.PowerShell.Management, PackageManagement, PowerShellGet
[CmdletBinding()]
param(
  [string]$TimeZoneName = 'Central Standard Time',

  [string]$LogFile = "$env:HOMEDRIVE\SetupLog.txt",

  [switch]$Fork,

  [string]$InstallModules = '',

  [string]$chocoPackages = '',

  [string]$CertificateThumbprint = '0E16BB33DB11773999FE2848D881D02103BD6B29'
)
$VerbosePreference = 'Continue'
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Security

trap{
  $_ | Out-String | Out-File -Append -FilePath $LogFile
  $_
  Exit 2
}

Get-Date | Out-String | Out-File -FilePath $LogFile

$vs_url = 'https://aka.ms/vs/15/release/vs_community.exe'
$rs_url = 'https://lbcdropbox.blob.core.windows.net/dependencies/windows/development/jetbrains.exe?st=2017-11-15T22%3A37Z&se=2018-02-15T22%3A07Z&sp=r&sv=2017-04-17&sr=c&sig=7WszV6xUvS1BrK0hkOqQgqK1Y%2BnMp47uvVcQW/mtSk0%3D'

$modules = @('ISESteroids', 'PSWindowsUpdate') + ($InstallModules.Split(';') | Sort-Object -Unique)
$chocoPackages = ('linqpad;sysinternals;fiddler4;visualstudiocode;' + $chocoPackages)

#region Functions

function Write-Log {
  param(
    [Parameter(Mandatory, Position=0, ValueFromPipeline)]
    [AllowNull()]
    $Message
  )
  process {
    $now = Get-Date -Format 'yyyy-MM-dd hh:mm:ss tt K'

    $text = @(($Message | Out-String) -split [Environment]::NewLine)
    foreach ($line in $text)
    {
      $msg = ('[{0}] {1}' -f $now, $line)
      $msg | Out-File -Append -FilePath $LogFile
      Write-Verbose -Message $msg
    }
  }
}

function Get-Uri {
  param(
    [Parameter(Mandatory, Position=0)]
    [uri]$DownloadUri,

    [Parameter(Position=1)]
    [string]$OutPath = $null,

    [int]$MaxRetries = 5
  )

  $tries = 0
  while ($tries -lt $MaxRetries)
  {
    $tries += 1
    try
    {
      Write-Log -Message ('Attempt {0}: downloading {1}' -f $tries, $DownloadUri)
      if ($OutPath)
      {
        Invoke-WebRequest -UseBasicParsing -Uri $DownloadUri -OutFile $OutPath
      }
      else
      {
        Invoke-WebRequest -UseBasicParsing -Uri $DownloadUri | Select-Object -ExpandProperty Content
      }
      break
    }
    catch
    {
      start-sleep -Seconds 10
    }
  }
}

function Invoke-DownloadInstall {
  param(
    [Parameter(Mandatory, Position=0)]
    [uri]$DownloadUri,

    [Parameter(Position=1)]
    [string[]] $ArgumentList = @()
  )

  $filename = [IO.Path]::GetFileName($DownloadUri.LocalPath)
  $exec_file = '{0}\{1}' -f $env:TEMP,$filename

  Write-Log -Message ('Downloading {0}' -f $DownloadUri)
  Get-Uri -DownloadUri $DownloadUri -OutPath $exec_file

  Write-Log -Message ('Starting {0} {1}' -f $exec_file, ($ArgumentList -join ' '))
  Start-Process -FilePath $exec_file -ArgumentList $ArgumentList -NoNewWindow -Wait
  Write-Log -Message ('Finished: {0}' -f $LastExitCode)
}

function Disable-InternetExplorerESC {
  $AdminKey = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}'
  $UserKey = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}'
  Set-ItemProperty -Path $AdminKey -Name 'IsInstalled' -Value 0
  Set-ItemProperty -Path $UserKey -Name 'IsInstalled' -Value 0
  Stop-Process -Name Explorer -ErrorAction Ignore -Force
  Write-Log -Message 'IE Enhanced Security Configuration (ESC) has been disabled.'
}

function Enable-InternetExplorerESC {
  $AdminKey = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}'
  $UserKey = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}'
  Set-ItemProperty -Path $AdminKey -Name 'IsInstalled' -Value 1
  Set-ItemProperty -Path $UserKey -Name 'IsInstalled' -Value 1
  Stop-Process -Name Explorer -ErrorAction Ignore -Force
  Write-Log -Message 'IE Enhanced Security Configuration (ESC) has been enabled.'
}

function Disable-UserAccessControl {
  Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'ConsentPromptBehaviorAdmin' -Value 00000000
  Write-Log -Message 'User Access Control (UAC) has been disabled.'
}

function Select-PKCS7Data {
  param(
    [Parameter(Mandatory, ValueFromPipeline)]
    [string] $line
  )

  begin {
    $Output = $null
  }

  process {
    if ($Output -eq $null -and $line.Trim() -eq '-----BEGIN PKCS7-----')
    {
      $Output = ''
    }
    elseif ($Output -ne $null -and $line.Trim() -eq '-----END PKCS7-----')
    {
      $Output
      $Output = $null
    }
    elseif ($Output -ne $null)
    {
      $Output += $line.Trim()
    }
  }
}

function Unprotect-File {
  param(
    [Parameter(Mandatory, Position=0)]
    [Alias('Cert')]
    [ValidateScript({ $_.HasPrivateKey })]
    [X509Certificate] $Certificate,

    [Parameter(Mandatory, Position=1, ValueFromPipeline)]
    [Alias('PSPath', 'Path')]
    [ValidateScript({ $_.Exists })]
    [IO.FileInfo] $FilePath,

    [string] $OutPath = $null
  )

  process {
        
    $b64data = [IO.File]::ReadAllLines($FilePath.FullName) | Select-PKCS7Data
    $envelope = New-Object -TypeName System.Security.Cryptography.Pkcs.EnvelopedCms
    $envelope.Decode([Convert]::FromBase64String($b64data))
    $envelope.Decrypt($Certificate)
    ,$envelope.ContentInfo.Content
  }
}

function Invoke-UnprotectFile {
  param(
    [Parameter(Mandatory, ValueFromPipeline)]
    [ValidateScript({ $_.Exists })]
    [IO.FileInfo] $FilePath
  )
  
  begin {
    $cert = Get-Item -Path Cert:\LocalMachine\My\$CertificateThumbprint
    if ($cert -eq $null) {
      throw "No Certificate!"
    }
  }
  
  process {
    if ($FilePath.Extension -ne '.enc') 
    {
      return
    }
    
    $baseName = $FilePath.Directory.FullName + '\' + $FilePath.BaseName
    $decrypted = $FilePath | Unprotect-File -Certificate $cert
    [IO.File]::WriteAllBytes($baseName, $decrypted)
    [IO.FileInfo]$baseName
  }
}

function Invoke-InstallModule {
  param(
    [Parameter(Mandatory, ValueFromPipeline)]
    [string] $Module
  )
  process {
    Write-Log -Message ('Installing {0}' -f $Module)
    Install-Module -Name $Module -Force | Write-Log
    Write-Log -Message Done.
  }
}

function Add-ISESteroidsLicense {
  param(
    [Parameter(Mandatory, ValueFromPipeline)]
    [IO.FileInfo]$FilePath
  )
  process {
    if ($FilePath.Name -ne 'isesteroids.license') { return }
    
    $outDir = Get-Item -Path "$env:ProgramFiles\WindowsPowerShell\Modules\ISESteroids\*\License"
    if ($outDir -eq $null) {
      Write-Warning -Message 'No ISESteroids module directory to place license.'
    } else {
      $null = Copy-Item -Path $FilePath.FullName -Destination $outDir.FullName
    }
  }
}

function Start-Task {
  [CmdletBinding()]
  param(
  )

  Write-Log -Message 'Disabling Internet Explorer Enhansed Security Configuration'
  Disable-InternetExplorerESC

  Write-Log -Message ('Setting TimeZone to {0}' -f $TimeZoneName)
  Set-TimeZone -Name $TimeZoneName

  Write-Log -Message 'Updating Help.'
  Update-Help -Module * -Force -ErrorAction Ignore

  Write-Log -Message 'Installing NuGet Package Provider'
  Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Write-Log
  
  Write-Log -Message 'Installing Modules'
  $Modules | Invoke-InstallModule
  
  Write-Log -Message 'Decrypting Secrets'
  $files = Get-ChildItem -Path $PSScriptRoot\..\secrets -Filter '*.enc' | Invoke-UnprotectFile
  
  Write-Log -Message 'Copying ISESteroids License'
  $files | Add-ISESteroidsLicense  

  Write-Log -Message 'Setting up Chocolatet'
  & "$PSScriptRoot\SetupChocolatey.ps1" -chocoPackages $chocoPackages | Write-Log

  Write-Log -Message 'Adding Microsoft Update Service'
  Add-WUServiceManager -ServiceID 7971f918-a847-4430-9279-4a52d1efe18d -Confirm:$false | Write-Log

  Write-Log -Message 'Running Windows Updates'
  Get-WindowsUpdate -IgnoreReboot -Install -AcceptAll -MicrosoftUpdate | Write-Log

  # https://github.com/MicrosoftDocs/visualstudio-docs/blob/master/docs/install/use-command-line-parameters-to-install-visual-studio.md
  $vs_args = '--all', '--includeRecommended', '--includeOptional', '--wait', '--quiet'
  Invoke-DownloadInstall -DownloadUri $vs_url -ArgumentList $vs_args

  try
  {
    $rs_args = '/VsVersion=15.0', '/SpecificProductNames=dotCover;dotMemory;dotPeek;dotTrace;ReSharperCpp;teamCityAddin;ReSharper', '/Silent=True', '/PerMachine=True'
    Invoke-DownloadInstall -DownloadUri $rs_url -ArgumentList $rs_args
  }
  catch
  {
    Write-Log -Message ('Failed installing ReSharper Ultimate {0}' -f $_)
  }
}

#endregion

if ($Fork) {
  $params = foreach($kvp in $PSBoundParameters.GetEnumerator()) { if ($kvp.Key -ne 'Fork') { '-{0} "{1}"' -f $kvp.Key,$kvp.Value } }
  $command = '"{0}" {1}' -f $PSCommandPath,($params -join ' ')
  Write-Verbose -Message $command
  Start-Process -FilePath powershell -ArgumentList ('-command', $command)
  return
}

Start-Task

# SIG # Begin signature block
# MIINKgYJKoZIhvcNAQcCoIINGzCCDRcCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQU7qWdXIQrZ8ZPbSpQlj7bjhQl
# lGmgggpsMIIFMDCCBBigAwIBAgIQBAkYG1/Vu2Z1U0O1b5VQCDANBgkqhkiG9w0B
# AQsFADBlMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYD
# VQQLExB3d3cuZGlnaWNlcnQuY29tMSQwIgYDVQQDExtEaWdpQ2VydCBBc3N1cmVk
# IElEIFJvb3QgQ0EwHhcNMTMxMDIyMTIwMDAwWhcNMjgxMDIyMTIwMDAwWjByMQsw
# CQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cu
# ZGlnaWNlcnQuY29tMTEwLwYDVQQDEyhEaWdpQ2VydCBTSEEyIEFzc3VyZWQgSUQg
# Q29kZSBTaWduaW5nIENBMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA
# +NOzHH8OEa9ndwfTCzFJGc/Q+0WZsTrbRPV/5aid2zLXcep2nQUut4/6kkPApfmJ
# 1DcZ17aq8JyGpdglrA55KDp+6dFn08b7KSfH03sjlOSRI5aQd4L5oYQjZhJUM1B0
# sSgmuyRpwsJS8hRniolF1C2ho+mILCCVrhxKhwjfDPXiTWAYvqrEsq5wMWYzcT6s
# cKKrzn/pfMuSoeU7MRzP6vIK5Fe7SrXpdOYr/mzLfnQ5Ng2Q7+S1TqSp6moKq4Tz
# rGdOtcT3jNEgJSPrCGQ+UpbB8g8S9MWOD8Gi6CxR93O8vYWxYoNzQYIH5DiLanMg
# 0A9kczyen6Yzqf0Z3yWT0QIDAQABo4IBzTCCAckwEgYDVR0TAQH/BAgwBgEB/wIB
# ADAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwMweQYIKwYBBQUH
# AQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wQwYI
# KwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFz
# c3VyZWRJRFJvb3RDQS5jcnQwgYEGA1UdHwR6MHgwOqA4oDaGNGh0dHA6Ly9jcmw0
# LmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcmwwOqA4oDaG
# NGh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RD
# QS5jcmwwTwYDVR0gBEgwRjA4BgpghkgBhv1sAAIEMCowKAYIKwYBBQUHAgEWHGh0
# dHBzOi8vd3d3LmRpZ2ljZXJ0LmNvbS9DUFMwCgYIYIZIAYb9bAMwHQYDVR0OBBYE
# FFrEuXsqCqOl6nEDwGD5LfZldQ5YMB8GA1UdIwQYMBaAFEXroq/0ksuCMS1Ri6en
# IZ3zbcgPMA0GCSqGSIb3DQEBCwUAA4IBAQA+7A1aJLPzItEVyCx8JSl2qB1dHC06
# GsTvMGHXfgtg/cM9D8Svi/3vKt8gVTew4fbRknUPUbRupY5a4l4kgU4QpO4/cY5j
# DhNLrddfRHnzNhQGivecRk5c/5CxGwcOkRX7uq+1UcKNJK4kxscnKqEpKBo6cSgC
# PC6Ro8AlEeKcFEehemhor5unXCBc2XGxDI+7qPjFEmifz0DLQESlE/DmZAwlCEIy
# sjaKJAL+L3J+HNdJRZboWR3p+nRka7LrZkPas7CM1ekN3fYBIM6ZMWM9CBoYs4Gb
# T8aTEAb8B4H6i9r5gkn3Ym6hU/oSlBiFLpKR6mhsRDKyZqHnGKSaZFHvMIIFNDCC
# BBygAwIBAgIQBlMozGGmYII/eb2suZnz+jANBgkqhkiG9w0BAQsFADByMQswCQYD
# VQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGln
# aWNlcnQuY29tMTEwLwYDVQQDEyhEaWdpQ2VydCBTSEEyIEFzc3VyZWQgSUQgQ29k
# ZSBTaWduaW5nIENBMB4XDTE3MDcxNTAwMDAwMFoXDTIwMDcyMjEyMDAwMFowcTEL
# MAkGA1UEBhMCVVMxEjAQBgNVBAgTCUxvdWlzaWFuYTEUMBIGA1UEBxMLTmV3IE9y
# bGVhbnMxGzAZBgNVBAoTEkxlQmxhbmMgQ29kZXMsIExMQzEbMBkGA1UEAxMSTGVC
# bGFuYyBDb2RlcywgTExDMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA
# yVn9OuwRTeowWQM0c4khmmpch+Box3vJOcaJu1zjp2Xiaoa1EE0wODIW2rIdYizg
# EFrF21W44K77lRMX37Isdb3lc1e7BciCTqp9W6XgAbG47TvpFxfYJs3tjtDxsx1v
# fpox6mMVeoC3a6GbJdmT7uE14XXj1nd0Ab9W83lYXPlA9SRvvPMQ8wHrDyUzhVu+
# dp4AGFvcklHdAuAeCu1mvyYBLLJl2DVt4JjEWxMHAY0/mjK/wSxrJQ/LPWbDEW5+
# rQr6Qz6xP+kTqOvso5l6l4E3lix2rcYRjRU7FgbYRYNcgfuPhMieB8f72+BQQ4g9
# 57hwjguMdiD/8VXzUTwbUwIDAQABo4IBxTCCAcEwHwYDVR0jBBgwFoAUWsS5eyoK
# o6XqcQPAYPkt9mV1DlgwHQYDVR0OBBYEFPJsIb0jSsEhGxMundyUQvkvlIJwMA4G
# A1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDAzB3BgNVHR8EcDBuMDWg
# M6Axhi9odHRwOi8vY3JsMy5kaWdpY2VydC5jb20vc2hhMi1hc3N1cmVkLWNzLWcx
# LmNybDA1oDOgMYYvaHR0cDovL2NybDQuZGlnaWNlcnQuY29tL3NoYTItYXNzdXJl
# ZC1jcy1nMS5jcmwwTAYDVR0gBEUwQzA3BglghkgBhv1sAwEwKjAoBggrBgEFBQcC
# ARYcaHR0cHM6Ly93d3cuZGlnaWNlcnQuY29tL0NQUzAIBgZngQwBBAEwgYQGCCsG
# AQUFBwEBBHgwdjAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29t
# ME4GCCsGAQUFBzAChkJodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNl
# cnRTSEEyQXNzdXJlZElEQ29kZVNpZ25pbmdDQS5jcnQwDAYDVR0TAQH/BAIwADAN
# BgkqhkiG9w0BAQsFAAOCAQEAd5Z9CZIjXJN6r/qNfb799jNPVO/LaIHO+VYOJ+fB
# ymsmqylhxpqJCI2VWFMaeygEshIHrvnQjMLU+Wuy5SF9tuE2AdggFASt7yeMCHEu
# 2DhAAdJcwzx7CWu85he/zLKRv5Tt8hE+hOL3JtjZlftyPPdEexRn+FyQs+wIvon9
# ra/qS2oOVDLgVSoSXIB5D+3uXDGVCygsOwmhpTSG9bLNV+GWjbl22P9n+KqqkA1z
# 0AFHDuF3o1/0Zs/mTNBIRnGASQOTux38oSf1RhNhRO5ucdA9BROKUFYl9FDEGAcX
# ptAmwT94ohA3EHn2AIYK9syxHPDbLlMFIImQAHTr7BfG0DGCAigwggIkAgEBMIGG
# MHIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsT
# EHd3dy5kaWdpY2VydC5jb20xMTAvBgNVBAMTKERpZ2lDZXJ0IFNIQTIgQXNzdXJl
# ZCBJRCBDb2RlIFNpZ25pbmcgQ0ECEAZTKMxhpmCCP3m9rLmZ8/owCQYFKw4DAhoF
# AKB4MBgGCisGAQQBgjcCAQwxCjAIoAKAAKECgAAwGQYJKoZIhvcNAQkDMQwGCisG
# AQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwIwYJKoZIhvcN
# AQkEMRYEFMrdHF2jWUyrVjp7DjoY6682gfwlMA0GCSqGSIb3DQEBAQUABIIBAFVr
# xBtCqglh/Hadl2MZqidb3Ae4tGC4XrSQ/sUyLQsrRdYNIaHCLlNfN3tT1xYyMOIr
# xNOatzP3n3w5I7O3C2RMYkGIA/GYGRByzGZ+EXCddazjPXpVBAQjEesemwhJBoR4
# jxrissM3teH8dLn3gSWHLVqWQOXFzi0ihBcxcOvGgWPCoZ5RQN3K7EVfJUwWlOxx
# /vNspwrE4ZcHNUe15OqVF1l9Nd37POf1Z59vUH7VXeQwW42PQNYux0u0jz4dB0It
# okE5Y7LOn5Eg0fHmrKijNgsyHQ9FBnM6jDnedqhDfo3FqevxKDc4z45SCo6tV/7k
# Quid+QRampzzNLnmDW4=
# SIG # End signature block
