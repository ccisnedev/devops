# Inicializar el objeto Shell.Application
$openWindows = New-Object -ComObject Shell.Application
    
# Abrir la carpeta "release" o ponerla en primer plano
$folderPath = (Get-Item ".\release").FullName
$normalizedFolderPath = "file:///$($folderPath.Replace('\', '/'))"
# $found = $false
# Write-Host "Normalizando la URL de la carpeta: $normalizedFolderPath" -ForegroundColor Green
foreach ($window in $openWindows.Windows()) {
    # Normalizar la URL de la ventana para comparación
    $normalizedWindowURL = $window.LocationURL -replace '%20', ' ' # Reemplazar espacios codificados
    # Write-Host "Comparando: $normalizedWindowURL con $normalizedFolderPath" -ForegroundColor Green
    if ($normalizedWindowURL -eq $normalizedFolderPath) {
        $window.Quit() # Cerrar la ventana si ya está abierta
        # $found = $true
        break
    }
}

$window = $openWindows.ShellExecute("explorer.exe", $folderPath, "", "open", 1)

Write-Host "=======================================" -ForegroundColor Yellow