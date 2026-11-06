# Read-only production audit. Only AST-selected functions/statements execute.
# All writes/process substitutes are confined to a new fixture directory.
param(
 [Parameter(Mandatory=$true)][string]$WorkerPath,
 [Parameter(Mandatory=$true)][string]$PackageZip,
 [ValidatePattern('^\d+\.\d+\.\d+$')][string]$ExpectedVersion = '0.5.7'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($WorkerPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Worker parser failure' }
# Deliberately do NOT dot-source the worker: that would execute its Main body.
foreach ($definition in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $true)) {
 . ([scriptblock]::Create($definition.Extent.Text))
}
$script:checks = 0
function Assert([bool]$Condition,[string]$Message) { $script:checks++; if (-not $Condition) { throw ('FAIL: ' + $Message) } }
function AssertRejected([scriptblock]$Body,[string]$Message) { $rejected=$false; try { & $Body } catch { $rejected=$true }; Assert $rejected $Message }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('tibiasp-worker-fixture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$script:base = Join-Path $fixture 'updates'
$script:cache = Join-Path $base 'cache'
$script:logFile = Join-Path $base 'worker.log'
$script:statusFile = Join-Path $base 'status.json'
$script:installedFile = Join-Path $base 'installed.json'
New-Item -ItemType Directory -Path $base,$cache | Out-Null
$oldPath = $env:PATH
$oldFixture = $env:TIBIASP_WORKER_FIXTURE
try {
 $manifestPath = Join-Path (Split-Path -Parent $PackageZip) 'latest.json'
 $script:manifest = ReadJson $manifestPath
 ValidateManifest $manifest
 Assert ((Get-FileHash -LiteralPath $PackageZip -Algorithm SHA256).Hash -ieq $manifest.sha256) 'actual release ZIP matches latest.json SHA-256'
 Assert ($manifest.version -eq $ExpectedVersion) 'actual release has intended version'
 foreach ($bad in @(
  @{version='0.5.7';url='http://example.invalid/update.zip';sha256=('a'*64)},
  @{version='../0.5.7';url='https://example.invalid/update.zip';sha256=('a'*64)},
  @{version='0.5.7';url='https://example.invalid/update.zip';sha256='bad'}
 )) { AssertRejected { ValidateManifest ([pscustomobject]$bad) } 'invalid manifest rejected by real worker' }
 foreach ($badPath in @('../escape.ps1','a/../../escape.ps1','C:\escape.ps1','a:b.ps1')) {
  AssertRejected { SafeRelative $badPath } ('unsafe relative path rejected: ' + $badPath)
 }
 $archive = [IO.Compression.ZipFile]::OpenRead($PackageZip)
 try {
  foreach ($entry in $archive.Entries) {
   $relative = SafeRelative $entry.FullName
   Assert (-not [string]::IsNullOrWhiteSpace($relative)) 'real package entry accepted by worker path validator'
  }
  $packageEntry = $archive.GetEntry('update-package.json')
  $reader = [IO.StreamReader]::new($packageEntry.Open(),[Text.Encoding]::UTF8,$true)
  try { $package = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
 } finally { $archive.Dispose() }
 Assert ($package.version -eq $manifest.version) 'package version matches release manifest'
 Assert ((SafeRelative $package.entrypoint) -eq 'install.ps1') 'entrypoint is supported'
 Assert (@($package.backupFiles).Count -eq 3) 'three intended backup targets'
 foreach ($file in $package.backupFiles) { $null = SafeRelative $file }
 # Execute actual extractor on malicious ZIP: validation must reject it before IO.
 $maliciousZip = Join-Path $fixture 'traversal.zip'
 $writeZip = [IO.Compression.ZipFile]::Open($maliciousZip,[IO.Compression.ZipArchiveMode]::Create)
 try { $null = $writeZip.CreateEntry('../escape.ps1') } finally { $writeZip.Dispose() }
 $stage = Join-Path $fixture 'stage-malicious'; New-Item -ItemType Directory -Path $stage | Out-Null
 AssertRejected { ExtractSafe $maliciousZip $stage } 'real extractor rejects traversal ZIP'
 Assert (-not (Test-Path -LiteralPath (Join-Path $fixture 'escape.ps1'))) 'traversal created no escaped file'
 $safeStage = Join-Path $fixture 'stage-real'; New-Item -ItemType Directory -Path $safeStage | Out-Null
 if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
  ExtractSafe $PackageZip $safeStage
  Assert (Test-Path -LiteralPath (Join-Path $safeStage 'install.ps1')) 'Windows real extraction succeeded'
 } else {
  $platformFailure = ''
  try { ExtractSafe $PackageZip $safeStage } catch { $platformFailure=$_.Exception.Message }
  Assert ($platformFailure -like '*probe wyjscia poza folder aktualizacji*') 'unmodified Windows prefix guard blocks Linux extraction'
  Write-Output 'PLATFORM LIMITATION: safe ZIP extraction/full worker install needs Windows; no containment check was bypassed.'
 }
 # Supply a fake Docker executable, with guard files, never a Docker daemon.
 if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
  $bin=Join-Path $fixture 'bin'; New-Item -ItemType Directory -Path $bin | Out-Null
  $fakeDocker=Join-Path $bin 'docker.exe'
  $fake=@'
#!/bin/sh
set -eu
[ -n "${TIBIASP_WORKER_FIXTURE:-}" ] || exit 81
[ -f "$TIBIASP_WORKER_FIXTURE/FIXTURE_ONLY" ] || exit 82
[ "$*" = "ps --filter label=com.docker.compose.project=tibiasp-real860 --format {{.Names}}" ] || exit 83
cat "$TIBIASP_WORKER_FIXTURE/docker-names.txt"
exit "$(cat "$TIBIASP_WORKER_FIXTURE/docker-exit.txt")"
'@
  [IO.File]::WriteAllText($fakeDocker,$fake,[Text.UTF8Encoding]::new($false))
  [IO.File]::SetUnixFileMode($fakeDocker,([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute))
  [IO.File]::WriteAllText((Join-Path $fixture 'FIXTURE_ONLY'),'fixture')
  $env:PATH=$bin + [IO.Path]::PathSeparator + $oldPath; $env:TIBIASP_WORKER_FIXTURE=$fixture
  [IO.File]::WriteAllText((Join-Path $fixture 'docker-exit.txt'),'0')
  [IO.File]::WriteAllText((Join-Path $fixture 'docker-names.txt'),'tibiasp-real860-db-1')
  CheckServerStopped
  Assert $true 'stopped server/remaining database accepted'
  [IO.File]::WriteAllText((Join-Path $fixture 'docker-names.txt'),'tibiasp-real860-server-1')
  AssertRejected { CheckServerStopped } 'running conventionally named game refused'
  [IO.File]::WriteAllText((Join-Path $fixture 'docker-exit.txt'),'7')
  AssertRejected { CheckServerStopped } 'Docker query error refused'
  [IO.File]::WriteAllText((Join-Path $fixture 'docker-exit.txt'),'0')
  [IO.File]::WriteAllText((Join-Path $fixture 'docker-names.txt'),'custom-game-name')
  CheckServerStopped
  Write-Output 'KNOWN WORKER DEFECT REPRODUCED: custom running container name evades old name filter. v0.5.7 installer separately rejects running containers by labels/state.'
 }
 # Select only the install branch's real process-launch and completion statements.
 # No Main body, network/download, extraction, or backup control flow is invoked.
 $installIf = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$Action -eq ''install'''}, $true))[0]
 Assert ($null -ne $installIf) 'actual worker install branch located'
 $statements = @($installIf.Clauses[0].Item2.Statements)
 $launchStatements = @($statements | Where-Object {
  $_.Extent.Text.StartsWith('$ps = Join-Path $PSHOME') -or $_.Extent.Text.StartsWith('$arguments = ') -or $_.Extent.Text.StartsWith('$proc = Start-Process')
 })
 Assert ($launchStatements.Count -eq 3) 'actual child process handoff statements selected'
 $script:installer = Join-Path $fixture 'stage with spaces/install.ps1'
 $script:TargetRoot = Join-Path $fixture 'TibiaSP folder'
 $script:stage = Split-Path -Parent $installer
 $script:out=Join-Path $base 'install-out.log'; $script:err=Join-Path $base 'install-err.log'
 $script:capturedLaunch=$null
 function Start-Process {
  param([string]$FilePath,[string]$ArgumentList,[string]$WorkingDirectory,[string]$WindowStyle,[string]$RedirectStandardOutput,[string]$RedirectStandardError,[switch]$PassThru)
  $script:capturedLaunch=$PSBoundParameters
  return [pscustomobject]@{ ExitCode=0 }
 }
 . ([scriptblock]::Create(($launchStatements.Extent.Text -join "`n")))
 Assert ($capturedLaunch.ArgumentList -eq ('-NoProfile -ExecutionPolicy Bypass -File "' + $installer + '" -TargetRoot "' + $TargetRoot + '"')) 'worker passes exact quoted installer entrypoint and TargetRoot'
 Assert ($capturedLaunch.WorkingDirectory -eq $stage -and $capturedLaunch.RedirectStandardOutput -eq $out -and $capturedLaunch.RedirectStandardError -eq $err) 'worker sets installer cwd and both output captures'
 $finish=@(); $capturing=$false
 foreach ($statement in $statements) {
  if ($statement.Extent.Text.StartsWith('$allOut = Read-Shared')) { $capturing=$true }
  if ($capturing) { $finish += $statement.Extent.Text }
  if ($capturing -and $statement.Extent.Text.StartsWith('Status ''installed''')) { break }
 }
 Assert ($finish.Count -gt 5) 'actual completion checks/status statements selected'
 $completion=[scriptblock]::Create(($finish -join "`n"))
 foreach ($case in @(
  @{exit=0;text='TIBIASP_UPDATE_OK';accepted=$true},
  @{exit=9;text='TIBIASP_UPDATE_OK';accepted=$false},
  @{exit=0;text='no completion marker';accepted=$false},
  @{exit=$null;text='TIBIASP_UPDATE_OK';accepted=$true}
 )) {
  if (Test-Path -LiteralPath $installedFile) { Remove-Item -LiteralPath $installedFile -Force }
  [IO.File]::WriteAllText($out,$case.text,[Text.UTF8Encoding]::new($true))
  $script:proc=[pscustomobject]@{ExitCode=$case.exit}
  $accepted=$true; try { . $completion } catch { $accepted=$false }
  Assert ($accepted -eq $case.accepted) 'actual worker completion requires marker and rejects known nonzero exit'
  Assert ((Test-Path -LiteralPath $installedFile) -eq $case.accepted) 'installed version is written only on accepted completion'
  if ($case.accepted) {
   Assert ((ReadJson $installedFile).version -eq $ExpectedVersion) 'installed.json records intended version'
   Assert ((ReadJson $statusFile).state -eq 'installed') 'GUI status records installed state'
  }
 }
 Write-Output ('PASS: ' + $script:checks + ' actual-worker function/contract assertions; no live worker Main, WPF, network or Docker services executed.')
} finally {
 $env:PATH=$oldPath; $env:TIBIASP_WORKER_FIXTURE=$oldFixture
 if ($fixture -and (Split-Path -Leaf $fixture).StartsWith('tibiasp-worker-fixture-')) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
