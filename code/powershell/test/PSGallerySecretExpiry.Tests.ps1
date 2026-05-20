BeforeAll {
    $metadataPath = Join-Path $PSScriptRoot 'PSGallerySecretMetadata.psd1'
    $metadata = Import-PowerShellDataFile $metadataPath

    $secretName = $metadata.PowerShellGallery.SecretName
    $expiryDate = [datetime]::ParseExact(
        $metadata.PowerShellGallery.SecretExpiryDate,
        'yyyy-MM-dd',
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $warningWindowDays = [int]$metadata.PowerShellGallery.WarningWindowDays
    $daysRemaining = [math]::Floor(($expiryDate.Date - (Get-Date).Date).TotalDays)

    $message = "$secretName expires on $($expiryDate.ToString('yyyy-MM-dd')) ($daysRemaining days remaining). Rotate it before expiration."

    if ($daysRemaining -le 0) {
        Write-Host "::error title=$secretName expired::$message"
    }
    elseif ($daysRemaining -le $warningWindowDays) {
        Write-Host "::warning title=$secretName expiry::$message"
    }
    else {
        Write-Host "::notice title=$secretName expiry::$message"
    }
}

Describe 'PSGallery secret expiry metadata' {
    It 'defines a valid expiry date' {
        $expiryDate | Should -BeOfType ([datetime])
    }

    It 'keeps the PSGallery API key active' {
        $daysRemaining | Should -BeGreaterThan 0
    }
}