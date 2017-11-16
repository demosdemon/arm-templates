#requires -Version 3.0 -Modules Microsoft.PowerShell.Management, PackageManagement, PowerShellGet
[CmdletBinding()]
param(
    [string]$TimeZoneName = 'Central Standard Time',

    [string]$LogFile = "$env:HOMEDRIVE\SetupLog.txt",

    [switch]$Fork,

    [string]$chocoPackages = ''
)
$VerbosePreference = 'Continue'
$ErrorActionPreference = 'Stop'

trap{
    $_ | Out-String | Out-File -Append -FilePath $LogFile
    $_
    Exit 2
}

Get-Date | Out-String | Out-File -FilePath $LogFile

$vs_url = 'https://aka.ms/vs/15/release/vs_community.exe'
$rs_url = 'https://lbcdropbox.blob.core.windows.net/dependencies/windows/development/jetbrains.exe?st=2017-11-15T22%3A37Z&se=2018-02-15T22%3A07Z&sp=r&sv=2017-04-17&sr=c&sig=7WszV6xUvS1BrK0hkOqQgqK1Y%2BnMp47uvVcQW/mtSk0%3D'

$modules = @(
    'ISESteroids', 'PSWindowsUpdate'
)

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
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force |
        Write-Log

    foreach ($mod in $Modules) {
        Write-Log -Message ('Installing {0}' -f $mod)
        Install-Module -Name $mod -Force |
            Write-Log
        Write-Log -Message 'Done.'
    }

    & "$PSScriptRoot\SetupChocolatey.ps1" -chocoPackages ('linqpad;sysinternals;fiddler4;visualstudiocode;' + $chocoPackages) |
        Write-Log

    Write-Log -Message 'Adding Microsoft Update Service'
    Add-WUServiceManager -ServiceID 7971f918-a847-4430-9279-4a52d1efe18d -Confirm:$false |
        Write-Log

    Write-Log -Message 'Running Windows Updates'
    Get-WindowsUpdate -IgnoreReboot -Install -AcceptAll -MicrosoftUpdate |
        Write-Log

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

if ($Fork) {
    $params = foreach($kvp in $PSBoundParameters.GetEnumerator()) { if ($kvp.Key -ne 'Fork') { '-{0} "{1}"' -f $kvp.Key,$kvp.Value } }
    $command = '"{0}" {1}' -f $PSCommandPath,($params -join ' ')
    Write-Verbose -Message $command
    Start-Process -FilePath powershell -ArgumentList ('-command', $command)
    return
}

Start-Task
