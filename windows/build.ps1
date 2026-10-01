param([switch]$Test, [switch]$CheckUi, [switch]$Integration)
$ErrorActionPreference='Stop'
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskDotnet=Join-Path $taskRoot 'build\dotnet\dotnet.exe'
if (-not (Test-Path -LiteralPath $taskDotnet)) { throw '项目内缺少 .NET SDK，请先按 README 配置 build/dotnet。' }
$env:DOTNET_CLI_HOME=Join-Path $PSScriptRoot '.dotnet-home'
$env:NUGET_PACKAGES=Join-Path $PSScriptRoot '.nuget\packages'
$env:DOTNET_NOLOGO='1'
$env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='false'
$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
Push-Location $PSScriptRoot
try {
    & $taskDotnet build 'src\SongNote.Windows\SongNote.Windows.csproj' -c Release
    if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
    if ($Test) {
        & $taskDotnet run --project 'tests\SongNote.Core.Tests\SongNote.Core.Tests.csproj' -c Release
        if ($LASTEXITCODE -ne 0) { throw 'Core tests failed' }
    }
    if ($CheckUi) {
        $taskExe=Join-Path $PSScriptRoot 'src\SongNote.Windows\bin\Release\net10.0-windows\SongNote.exe'
        $taskUi=Join-Path $taskRoot 'build\windows-ui-check'
        $taskProcess=Start-Process -FilePath $taskExe -ArgumentList @('--check-ui','--output',"`"$taskUi`"") -WindowStyle Hidden -Wait -PassThru
        if ($taskProcess.ExitCode -ne 0) { throw 'Native WPF UI check failed' }
        Get-Content (Join-Path $taskUi 'result.txt')
    }
    if ($Integration) {
        $taskServerInfo=[System.Diagnostics.ProcessStartInfo]::new()
        $taskServerInfo.FileName=(Get-Command node).Source
        $taskServerInfo.ArgumentList.Add((Join-Path $PSScriptRoot 'tests\local-server.mjs'))
        $taskServerInfo.RedirectStandardInput=$true
        $taskServerInfo.RedirectStandardOutput=$true
        $taskServerInfo.UseShellExecute=$false
        $taskServerInfo.CreateNoWindow=$true
        $taskServer=[System.Diagnostics.Process]::Start($taskServerInfo)
        try {
            $taskLineRead=$taskServer.StandardOutput.ReadLineAsync()
            if (-not $taskLineRead.Wait(15000)) { throw 'Test server startup timed out' }
            $taskPortLine=$taskLineRead.Result
            if ($taskPortLine -notmatch '^TEST_SERVER_PORT:(\d+)$') { throw 'Invalid test server port' }
            $taskEndpoint='http://127.0.0.1:'+$Matches[1]
            & $taskDotnet run --project 'tests\SongNote.Core.Tests\SongNote.Core.Tests.csproj' -c Release -- --integration-only --integration $taskEndpoint
            if ($LASTEXITCODE -ne 0) { throw 'Loopback protocol integration failed' }
        } finally {
            if (-not $taskServer.HasExited) {
                $taskServer.StandardInput.WriteLine('stop')
                if (-not $taskServer.WaitForExit(5000)) { $taskServer.Kill() }
            }
            $taskServer.Dispose()
        }
    }
} finally { Pop-Location }
