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
  $net = "$env:windir\system32\net.exe"
  ('Creating user {0}' -f $username)
  & $net USER $username $password /add /y /expires:never

  ('Adding local user {0} to {1}' -f $username, $group)
  & $net LOCALGROUP $group $username /add
}

$secPassword = ConvertTo-SecureString -String $password -AsPlainText -Force
$credential = New-Object -TypeName pscredential -ArgumentList ('{0}\{1}' -f $env:COMPUTERNAME, $username),$secPassword

# Ensure that current process can run scripts.
'Enabling remoting'
Enable-PSRemoting -Force -SkipNetworkProfileCheck

'Changing ExecutionPolicy'
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

# Install Choco
'Installing Chocolatey'
$sb = { Invoke-Expression -Command ((new-object -TypeName net.webclient).DownloadString('https://chocolatey.org/install.ps1')) }
Invoke-Command -ScriptBlock $sb -ComputerName $env:COMPUTERNAME -Credential $credential

#"Install each Chocolatey Package"
$chocoPackages.Split(';') | Sort-Object -Unique | ForEach-Object {
    $command = ('cinst {0} -y -force' -f $_)
    $command
    $sb = [scriptblock]::Create($command)

    # Use the current user profile
    Invoke-Command -ScriptBlock $sb -ArgumentList $chocoPackages -ComputerName $env:COMPUTERNAME -Credential $credential
}


# Delete the artifactInstaller user
$adsi.Delete('User', $userName)

# Delete the artifactInstaller user profile
try {
    Get-WmiObject -Class win32_userprofile | Where-Object { $_.LocalPath -like ('*{0}*' -f $userName) } | ForEach-Object { $_.Delete() }
}
catch
{
    Write-Warning -Message $_
}

# SIG # Begin signature block
# MIINKgYJKoZIhvcNAQcCoIINGzCCDRcCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQU0wkL8kzuXtB83Iqaf6VAyOKi
# abmgggpsMIIFMDCCBBigAwIBAgIQBAkYG1/Vu2Z1U0O1b5VQCDANBgkqhkiG9w0B
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
# AQkEMRYEFI/WvcexJ67q0hoy/uq8cmhmvicDMA0GCSqGSIb3DQEBAQUABIIBABYj
# GBSxI/FDX2owEC/wJNEMDdIqSK38uHibyF5PGZSE55xOcIGcjttEwYySCYVi/pUO
# 2soVcwAhaQBaffAxpT0TYpTH8g4kj7/al3bLgJgtdvW87vnbRpPoAkzJ1wF4dVkn
# CFvzRk0QBs1TWO8aGcsLpZkUPMt4Wju3zPDAdpbK3ar7veuR7giNVQHYbiKHYY8j
# K+1tvlk7JTpZ1pH4T0HZ5L/grOChWrcUs7YkD1T/w1DbfcndVpdsuHR/7uuTaREs
# 3LlBl1yBvzcTuON34/+h3Zul8HOtePMvVLPwvO0InpDtttFXuAk9WM/O6c0I2A7W
# SGac0KzPOyhgFBJ1GKg=
# SIG # End signature block
