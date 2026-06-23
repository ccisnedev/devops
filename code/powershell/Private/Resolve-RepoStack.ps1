function Resolve-RepoStack {
    <#
    .SYNOPSIS
    Auto-detecta el stack tecnológico de un repo a partir de su árbol de archivos.

    .PARAMETER Files
    Array de objetos con propiedades 'path' y 'type' (del endpoint git/trees).

    .OUTPUTS
    PSCustomObject con Stack y SuggestedType.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [object[]]$Files
    )

    $fileNames = $Files | Where-Object { $_.type -eq 'blob' } | ForEach-Object { $_.path }
    $dirNames  = $Files | Where-Object { $_.type -eq 'tree' } | ForEach-Object { $_.path }

    # Dart / Flutter
    if ($fileNames -contains 'pubspec.yaml') {
        $stack = 'dart'
        if ($dirNames -contains 'web') {
            $suggestedType = 'flutter-web'
        }
        elseif ($dirNames -contains 'android' -or $dirNames -contains 'ios') {
            $suggestedType = 'flutter-apk'
        }
        else {
            $suggestedType = 'unknown'
        }
        return [PSCustomObject]@{ Stack = $stack; SuggestedType = $suggestedType }
    }

    # SQL Server
    $hasSqlproj = $fileNames | Where-Object { $_ -match '\.sqlproj$' }
    if ($hasSqlproj) {
        return [PSCustomObject]@{ Stack = 'sql'; SuggestedType = 'sqlserver-db' }
    }

    # C#
    $hasCsproj = $fileNames | Where-Object { $_ -match '\.csproj$' }
    if ($hasCsproj) {
        return [PSCustomObject]@{ Stack = 'csharp'; SuggestedType = 'unknown' }
    }

    # Node / TypeScript / JavaScript
    if ($fileNames -contains 'package.json') {
        $hasTsConfig = $fileNames | Where-Object { $_ -match 'tsconfig' }
        if ($hasTsConfig) {
            return [PSCustomObject]@{ Stack = 'typescript'; SuggestedType = 'node-api' }
        }
        return [PSCustomObject]@{ Stack = 'javascript'; SuggestedType = 'node-api' }
    }

    # Unknown
    return [PSCustomObject]@{ Stack = 'generic'; SuggestedType = 'unknown' }
}
