param([Parameter(Mandatory=$true)][string]$CandidateRoot,
      [Parameter(Mandatory=$true)][string]$ExpectedCommit)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$taskRoot='C:\便签'
$taskCandidate=[IO.Path]::GetFullPath($CandidateRoot)
if (-not $taskCandidate.StartsWith($taskRoot+'\releases\',[StringComparison]::OrdinalIgnoreCase) -or $ExpectedCommit -notmatch '^[a-f0-9]{40}$') { throw 'Invalid release identity' }
$taskManifest=Get-Content -LiteralPath (Join-Path $taskCandidate 'manifest.json') -Encoding UTF8 -Raw | ConvertFrom-Json
if ($taskManifest.commit -ne $ExpectedCommit) { throw 'Candidate commit does not match' }
$taskVersion=([IO.File]::ReadAllText((Join-Path $taskCandidate 'VERSION'),[Text.Encoding]::UTF8)).Trim()
if ($taskManifest.version -ne $taskVersion) { throw 'Candidate version does not match' }
$taskFiles=@('VERSION','server\server.mjs')
foreach($taskFile in $taskFiles){
    $taskHash=(Get-FileHash -LiteralPath (Join-Path $taskCandidate $taskFile) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($taskHash -ne $taskManifest.files.($taskFile.Replace('\','/'))) { throw ('Candidate hash mismatch: '+$taskFile) }
}
$taskNode=(Get-Command node).Source
& $taskNode --check (Join-Path $taskCandidate 'server\server.mjs')
if($LASTEXITCODE -ne 0){throw 'Candidate syntax check failed'}
$taskServer=Join-Path $taskRoot 'server\server.mjs'
$taskConfig=Get-Content -LiteralPath (Join-Path $taskRoot 'server\config.json') -Encoding UTF8 -Raw | ConvertFrom-Json
if(-not (Test-Path -LiteralPath $taskConfig.database)){throw 'Existing database missing'}
$taskBefore=Join-Path $taskCandidate 'before'
if(Test-Path -LiteralPath $taskBefore){throw 'This candidate already has a deployment backup; use a fresh candidate directory'}
New-Item -ItemType Directory -Path $taskBefore | Out-Null
Copy-Item -LiteralPath $taskServer -Destination (Join-Path $taskBefore 'server.mjs')
$taskHadVersion=Test-Path -LiteralPath (Join-Path $taskRoot 'VERSION')
if($taskHadVersion){Copy-Item -LiteralPath (Join-Path $taskRoot 'VERSION') -Destination (Join-Path $taskBefore 'VERSION')}
# Prepare a schema-compatible fallback before any production process is stopped.
# It preserves newly committed data and rejects attachment operations rather than
# letting an old server silently ignore them after a database migration.
$taskHelper=Join-Path $taskCandidate 'maintenance.mjs'
$taskHelperCode=@'
import {readFileSync,writeFileSync} from 'node:fs';
import {DatabaseSync} from 'node:sqlite';
const [mode,source,target]=process.argv.slice(2);
if(mode==='rollback') {
  let text=readFileSync(source,'utf8');
  if(text.includes('INSERT INTO notes VALUES(')) {
    text=text.replace('INSERT INTO notes VALUES(', 'INSERT INTO notes(id,text,color,pinned,revision,updated_at,deleted,conflict_of) VALUES(');
    const row='const note = row => ({ ...row, pinned:';
    const sync='const sync = input => {';
    if(!text.includes(row)||!text.includes(sync)) throw Error('Unsupported old server rollback shape');
    text=text.replace(row, "const note = row => ({ ...row, ...(typeof row.attachments === 'string' ? {attachments:JSON.parse(row.attachments)} : {}), pinned:");
    text=text.replace(sync, sync+"\n    if(input?.changes?.some(op=>op?.attachments!==undefined)) throw Object.assign(new Error('Attachment service temporarily unavailable'),{status:503});");
  }
  writeFileSync(target,text);
} else if(mode==='backup') {
  const db=new DatabaseSync(source); db.exec('PRAGMA busy_timeout=10000');
  try {db.prepare('VACUUM INTO ?').run(target);} finally {db.close();}
} else throw Error('Invalid maintenance mode');
'@
[IO.File]::WriteAllText($taskHelper,$taskHelperCode,[Text.UTF8Encoding]::new($false))
& $taskNode $taskHelper rollback $taskServer (Join-Path $taskBefore 'server.rollback.mjs')
if($LASTEXITCODE -ne 0){throw 'Cannot prepare schema-compatible rollback'}
& $taskNode --check (Join-Path $taskBefore 'server.rollback.mjs')
if($LASTEXITCODE -ne 0){throw 'Rollback syntax check failed'}
function Invoke-TaskCommand([string[]]$TaskArguments){
    & schtasks.exe @TaskArguments | Out-Null
    if($LASTEXITCODE -ne 0){throw ('Scheduled task command failed: '+($TaskArguments -join ' '))}
}
function Stop-NoteServer {
    $taskPreviousPreference=$ErrorActionPreference
    try {$ErrorActionPreference='Continue'; & schtasks.exe /End /TN SongNoteServer 2>$null | Out-Null}
    finally {$ErrorActionPreference=$taskPreviousPreference}
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object {$_.CommandLine -and $_.CommandLine.Contains($taskServer)} | ForEach-Object {Stop-Process -Id $_.ProcessId -Force}
    Start-Sleep -Milliseconds 300
    if(Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object {$_.CommandLine -and $_.CommandLine.Contains($taskServer)}){throw 'Old server process still running'}
}
$taskStopped=$false
$taskInstalled=$false
$taskFailure=$null
try {
    Invoke-TaskCommand -TaskArguments @('/Change','/TN','SongNoteBackup','/DISABLE')
    Invoke-TaskCommand -TaskArguments @('/Change','/TN','SongNoteServer','/DISABLE')
    $taskStopped=$true; Stop-NoteServer
    & $taskNode $taskHelper backup $taskConfig.database (Join-Path $taskBefore 'notes.sqlite')
    if($LASTEXITCODE -ne 0){throw 'Pre-upgrade database backup failed'}
    $taskInstalled=$true
    foreach($taskFile in $taskFiles){Copy-Item -LiteralPath (Join-Path $taskCandidate $taskFile) -Destination (Join-Path $taskRoot $taskFile) -Force}
    foreach($taskFile in $taskFiles){
        if((Get-FileHash -LiteralPath (Join-Path $taskRoot $taskFile) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $taskManifest.files.($taskFile.Replace('\','/'))){throw 'Installed file hash mismatch'}
    }
    Invoke-TaskCommand -TaskArguments @('/Change','/TN','SongNoteServer','/ENABLE')
    Invoke-TaskCommand -TaskArguments @('/Run','/TN','SongNoteServer')
    $taskHealth=$null
    for($taskAttempt=0;$taskAttempt -lt 20;$taskAttempt++){
        try {$taskHealth=Invoke-RestMethod 'http://127.0.0.1:18084/health' -TimeoutSec 3; break} catch {Start-Sleep -Milliseconds 500}
    }
    if(-not $taskHealth.ok -or $taskHealth.version -ne $taskVersion -or $taskHealth.features -notcontains 'attachments' -or $taskHealth.max_file_bytes -ne 20971520){throw 'New server health/capability check failed'}
    $taskReceipt=[ordered]@{version=$taskVersion;commit=$ExpectedCommit;deployed_at_utc=[DateTime]::UtcNow.ToString('O');files=$taskManifest.files;database_backup=(Join-Path $taskBefore 'notes.sqlite');health=$taskHealth}
    $taskReceipt | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $taskCandidate 'receipt.json') -Encoding UTF8
    $taskReceipt | ConvertTo-Json -Depth 6
} catch {
    $taskFailure=$_.Exception.Message
    $taskRecoveryErrors=New-Object 'System.Collections.Generic.List[string]'
    if($taskInstalled){
        try {Stop-NoteServer} catch {$taskRecoveryErrors.Add('Rollback stop: '+$_.Exception.Message)}
        try {
            Copy-Item -LiteralPath (Join-Path $taskBefore 'server.rollback.mjs') -Destination $taskServer -Force
            if($taskHadVersion){Copy-Item -LiteralPath (Join-Path $taskBefore 'VERSION') -Destination (Join-Path $taskRoot 'VERSION') -Force}
            else {Remove-Item -LiteralPath (Join-Path $taskRoot 'VERSION') -ErrorAction SilentlyContinue}
        } catch {$taskRecoveryErrors.Add('Rollback files: '+$_.Exception.Message)}
    }
    try {Invoke-TaskCommand -TaskArguments @('/Change','/TN','SongNoteServer','/ENABLE')}
    catch {$taskRecoveryErrors.Add('Server enable: '+$_.Exception.Message)}
    if($taskStopped){
        try {Invoke-TaskCommand -TaskArguments @('/Run','/TN','SongNoteServer')}
        catch {$taskRecoveryErrors.Add('Server restart: '+$_.Exception.Message)}
        $taskRecovered=$false
        for($taskAttempt=0;$taskAttempt -lt 20;$taskAttempt++){
            try {$taskRecovered=(Invoke-RestMethod 'http://127.0.0.1:18084/health' -TimeoutSec 3).ok; if($taskRecovered){break}}
            catch {Start-Sleep -Milliseconds 500}
        }
        if(-not $taskRecovered){$taskRecoveryErrors.Add('Recovery health check failed')}
    }
    if($taskRecoveryErrors.Count){$taskFailure+='; recovery errors: '+($taskRecoveryErrors -join '; ')}
} finally {
    try {Invoke-TaskCommand -TaskArguments @('/Change','/TN','SongNoteBackup','/ENABLE')}
    catch {$taskFailure+='; backup task restore: '+$_.Exception.Message}
}
if($taskFailure){throw ('Deployment failed; existing database retained: '+$taskFailure)}
