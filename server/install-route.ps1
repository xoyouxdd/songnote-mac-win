$ErrorActionPreference = 'Stop'
$path = 'C:\Server\Caddy\Caddyfile'
$caddy = 'C:\Server\Caddy\caddy.exe'
$original = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
if ($original.Contains('# BEGIN SONGNOTE')) { Write-Output 'SONGNOTE_ROUTE_ALREADY_PRESENT'; exit 0 }
$anchor = '    # BEGIN CO2_UPDATES'
if (($original.Split([string[]]@($anchor), [StringSplitOptions]::None)).Count -ne 2) { throw 'Expected unique route insertion anchor missing' }
$route = @'
    # BEGIN SONGNOTE
    handle_path /songnote/* {
        reverse_proxy 127.0.0.1:18084
    }
    # END SONGNOTE

'@
$candidate = $path + '.songnote-candidate'
$backup = $path + '.before-songnote-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
[IO.File]::WriteAllText($candidate, $original.Replace($anchor, $route + $anchor), (New-Object Text.UTF8Encoding($false)))
& $caddy validate --config $candidate --adapter caddyfile
if ($LASTEXITCODE -ne 0) { throw 'Caddy candidate validation failed' }
Copy-Item $path $backup
try {
    Copy-Item $candidate $path -Force
    & $caddy reload --config $path --adapter caddyfile
    if ($LASTEXITCODE -ne 0) { throw 'Caddy reload failed' }
    $result = Invoke-RestMethod 'https://124.220.229.9/songnote/health'
    if (-not $result.ok) { throw 'Public health check failed' }
    Write-Output ('SONGNOTE_ROUTE_OK backup=' + $backup)
} catch {
    Copy-Item $backup $path -Force
    & $caddy reload --config $path --adapter caddyfile
    throw
}
