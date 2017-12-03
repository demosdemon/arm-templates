#requires -Version 3.0
param(
    [Parameter(Mandatory)]
    [string]$chocoPackages,
    [Parameter(Mandatory)]
    [string]$AdminUserName,
    [Parameter(Mandatory)]
    [string]$AdminPassword
)

# Disable UAC so WinRM Works
Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name LocalAccountTokenFilterPolicy -Value 1

$secPassword = ConvertTo-SecureString -String $AdminPassword -AsPlainText -Force
$credential = New-Object -TypeName pscredential -ArgumentList ('{0}\{1}' -f $env:COMPUTERNAME, $AdminUserName),$secPassword

$so = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
$session = New-PSSession -ComputerName $env:COMPUTERNAME -Credential $credential -EnableNetworkAccess -UseSSL -SessionOption $so

# Ensure that current process can run scripts.
# 'Enabling remoting'
# Enable-PSRemoting -Force -SkipNetworkProfileCheck

# 'Changing ExecutionPolicy'
# Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

# Install Choco
'Installing Chocolatey'
$sb = { Invoke-Expression -Command ((new-object -TypeName net.webclient).DownloadString('https://chocolatey.org/install.ps1')) }
Invoke-Command -Session $session -ScriptBlock $sb

#"Install each Chocolatey Package"
$chocoPackages.Split(';') | Sort-Object -Unique | ForEach-Object {
    $command = ('C:\ProgramData\Chocolatey\bin\choco install {0} -y -force' -f $_)
    $command
    $sb = [scriptblock]::Create($command)

    # Use the current user profile
    Invoke-Command -ScriptBlock $sb -Session $session
}
