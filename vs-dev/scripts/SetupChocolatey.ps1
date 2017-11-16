#requires -Version 3.0
param([Parameter(Mandatory)][string]$chocoPackages)

# Disable UAC so WinRM Works
Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name LocalAccountTokenFilterPolicy -Value 1

Add-Type -AssemblyName System.Web

$username = 'artifactInstaller'
$password = [Web.Security.Membership]::GeneratePassword(15, 5)
$group = 'Administrators'

$adsi = [ADSI]"WinNT://$env:COMPUTERNAME"
$existing = $adsi.Children | Where-Object { $_.SchemaClassName -eq 'user' -and $_.Name -eq $username }

if ($existing)
{
  'Setting password for existing user.'
  $existing.SetPassword($password)
}
else
{
  ('Creating user {0}' -f $username)
  & "$env:windir\system32\net.exe" USER $username $password /add /y /expires:never
  
  ('Adding local user {0} to {1}' -f $username, $group)
  & "$env:windir\system32\net.exe" LOCALGROUP $group $username /add
}

$secPassword = ConvertTo-SecureString -String $password -AsPlainText -Force
$credential = New-Object pscredential $username,$secPassword

# Ensure that current process can run scripts.
'Enabling remoting'
Enable-PSRemoting -Force -SkipNetworkProfileCheck

'Changing ExecutionPolicy'
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

# Install Choco
'Installing Chocolatey'
$sb = { Invoke-Expression ((new-object net.webclient).DownloadString('https://chocolatey.org/install.ps1')) }
Invoke-Command -ScriptBlock $sb -ComputerName $env:COMPUTERNAME -Credential $credential

'Disabling UAC'
$sb = { Set-ItemProperty -path HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System -name EnableLua -value 0 }
Invoke-Command -ScriptBlock $sb -ComputerName $env:COMPUTERNAME -Credential $credential

#"Install each Chocolatey Package"
$chocoPackages.Split(';') | Sort-Object -Unique | ForEach-Object 
{
    $command = ('cinst {0} -y -force' -f $_)
    $command
    $sb = [scriptblock]::Create(('{0}' -f $command))

    # Use the current user profile
    Invoke-Command -ScriptBlock $sb -ArgumentList $chocoPackages -ComputerName $env:COMPUTERNAME -Credential $credential
}


# Delete the artifactInstaller user
$adsi.Delete('User', $userName)

# Delete the artifactInstaller user profile
Get-WmiObject win32_userprofile | Where-Object { $_.LocalPath -like ('*{0}*' -f $userName) } | ForEach-Object { $_.Delete() }