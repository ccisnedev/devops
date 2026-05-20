# macss-devops.psm1

$moduleCodeRoot = $PSScriptRoot

Get-ChildItem -Path (Join-Path $moduleCodeRoot 'Functions\*.ps1') | ForEach-Object {
    . $_.FullName
    $functionName = (Get-Content $_.FullName | Select-String -Pattern '^function' | ForEach-Object { ($_ -split ' ')[1] }).Trim()
    Export-ModuleMember -Function $functionName
}

Get-ChildItem -Path (Join-Path $moduleCodeRoot 'Private\*.ps1') -Recurse | ForEach-Object {
    . $_.FullName
}