# FlutterDevOps.psm1

# Importar todas las funciones públicas
Get-ChildItem -Path "$PSScriptRoot\src\Functions\*.ps1" | ForEach-Object {
    . $_.FullName
    # Exportar las funciones públicas
    $functionName = (Get-Content $_.FullName | Select-String -Pattern '^function' | ForEach-Object { ($_ -split ' ')[1] }).Trim()
    Export-ModuleMember -Function $functionName
}

# Importar todas las funciones privadas
Get-ChildItem -Path "$PSScriptRoot\src\Private\*.ps1" -Recurse | ForEach-Object { 
    . $_.FullName 
}
