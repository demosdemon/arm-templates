#requires -Version 3.0 -Modules Microsoft.PowerShell.Management, PackageManagement, PowerShellGet
[CmdletBinding()]
param(
  [string]$TimeZoneName = 'Central Standard Time',

  [string]$LogFile,

  [switch]$Fork,

  [string]$InstallModules,

  [string]$chocoPackages,

  [string]$CertificateThumbprint = '0E16BB33DB11773999FE2848D881D02103BD6B29',

  [Parameter(Mandatory)]
  [string]$AdminUserName,

  [Parameter(Mandatory)]
  [string]$AdminPassword
)
$VerbosePreference = 'Continue'
$ErrorActionPreference = 'Continue'

Add-Type -AssemblyName System.Security

if (-not $LogFile) {
    $LogFile = '{0}\SetupLog-{1}.txt' -f $env:HOMEDRIVE, (Get-Date -Format yyyy-MM-dd-HH-mm-ss)
}

trap{
  $_ | Out-String | Out-File -Append -FilePath $LogFile
  $_
  Exit 2
}

Get-Date | Out-String | Out-File -FilePath $LogFile -Append

$vs_url = 'https://aka.ms/vs/15/release/vs_professional.exe'
$rs_url = 'https://lbcdropbox.blob.core.windows.net/dependencies/windows/development/jetbrains.exe?st=2017-11-15T22%3A37Z&se=2018-02-15T22%3A07Z&sp=r&sv=2017-04-17&sr=c&sig=7WszV6xUvS1BrK0hkOqQgqK1Y%2BnMp47uvVcQW/mtSk0%3D'

$modules = "ISESteroids;PSWindowsUpdate;$InstallModules".Split(';') |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Sort-Object -Unique

$chocoPackages = "linqpad;sysinternals;fiddler4;visualstudiocode;$chocoPackages".Split(';') |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Sort-Object -Unique
$chocoPackages = $chocoPackages -join ';'

#region Functions

function Write-Log {
  param(
    [Parameter(Mandatory, Position=0, ValueFromPipeline)]
    [AllowNull()][AllowEmptyString()]
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

  if (Test-Path $env:HOMEDRIVE\SetupComplete.txt)
  {
    return
  }

  Write-Log -Message 'Resizing main partition'
  $size = Get-PartitionSupportedSize -DiskNumber 0 -PartitionNumber 1
  Resize-Partition -DiskNumber 0 -PartitionNumber 1 -Size $size.SizeMax -ErrorAction SilentlyContinue
  Get-Partition -DiskNumber 0 -PartitionNumber 1 | Write-Log

  Write-Log -Message 'Disabling Internet Explorer Enhansed Security Configuration'
  Disable-InternetExplorerESC

  Write-Log -Message ('Setting TimeZone to {0}' -f $TimeZoneName)
  Set-TimeZone -Name $TimeZoneName

  Write-Log -Message 'Updating Help.'
  Update-Help -Module * -ErrorAction Ignore -Confirm:$false

  Write-Log -Message 'Installing NuGet Package Provider'
  Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Write-Log

  Write-Log -Message 'Installing Modules'
  $Modules | Invoke-InstallModule

  Write-Log -Message 'Decrypting Secrets'
  $files = Get-ChildItem -Path $PSScriptRoot\..\secrets -Filter '*.enc' | Invoke-UnprotectFile

  Write-Log -Message 'Copying ISESteroids License'
  $files | Add-ISESteroidsLicense

  Write-Log -Message 'Setting up Chocolatet'
  & "$PSScriptRoot\SetupChocolatey.ps1" -chocoPackages $chocoPackages -AdminUserName $AdminUserName -AdminPassword $AdminPassword | Write-Log

  Write-Log -Message 'Adding Microsoft Update Service'
  Add-WUServiceManager -ServiceID 7971f918-a847-4430-9279-4a52d1efe18d -Confirm:$false | Write-Log

  Write-Log -Message 'Running Windows Updates'
  Get-WindowsUpdate -IgnoreReboot -Install -AcceptAll -MicrosoftUpdate | Write-Log

  # https://github.com/MicrosoftDocs/visualstudio-docs/blob/master/docs/install/use-command-line-parameters-to-install-visual-studio.md
  $vs_args = '--all', '--includeRecommended', '--includeOptional', '--wait', '--quiet', '--norestart'
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

  Get-Date | Out-File -FilePath $env:HOMEDRIVE\SetupComplete.txt

  shutdown /r
}

#endregion

if ($Fork) {
  $params = @(foreach($kvp in $PSBoundParameters.GetEnumerator()) { if ($kvp.Key -ne 'Fork') { '-{0} "{1}"' -f $kvp.Key,$kvp.Value } })
  $params += '-LogFile "{0}"' -f $LogFile
  $command = '"{0}" {1}' -f $PSCommandPath,($params -join ' ')
  Write-Verbose -Message $command
  Start-Process -FilePath powershell -ArgumentList ('-command', $command)
  return
}

Start-Task
