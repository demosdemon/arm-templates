param([Parameter(Mandatory=$true)][string]$chocoPackages)

# Ensure that current process can run scripts.
"Enabling remoting"
Enable-PSRemoting -Force -SkipNetworkProfileCheck

"Changing ExecutionPolicy"
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

# Install Choco
"Installing Chocolatey"
$sb = { iex ((new-object net.webclient).DownloadString('https://chocolatey.org/install.ps1')) }
Invoke-Command -ScriptBlock $sb -ComputerName $env:COMPUTERNAME

"Disabling UAC"
$sb = { Set-ItemProperty -path HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System -name EnableLua -value 0 }
Invoke-Command -ScriptBlock $sb -ComputerName $env:COMPUTERNAME

#"Install each Chocolatey Package"
$chocoPackages.Split(";") | Sort-Object -Unique | ForEach {
    $command = "cinst $_ -y -force"
    $command
    $sb = [scriptblock]::Create("$command")

    # Use the current user profile
    Invoke-Command -ScriptBlock $sb -ArgumentList $chocoPackages -ComputerName $env:COMPUTERNAME
}
