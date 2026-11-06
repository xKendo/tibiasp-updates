$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$launcher = Join-Path $repoRoot 'packages/v0.5.7/source/payload/TibiaSP_Launcher.ps1'
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
# Load function declarations only: do not initialize WPF, start timers or invoke GUI code.
foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
 . ([scriptblock]::Create($definition.Extent.Text))
}
$script:assertions = 0
function Assert($Condition, [string]$Message) {
 $script:assertions++
 if (-not $Condition) { throw ('FAIL: ' + $Message) }
}
function Container([string]$State, [bool]$Running = $false, [bool]$Restarting = $false, [bool]$Paused = $false, [bool]$Dead = $false, [int]$ExitCode = 0) {
 return [pscustomobject]@{Project='tibiasp-real860'; Service='server'; Oneoff='False'; Status=$State; Running=$Running; Restarting=$Restarting; Paused=$Paused; Dead=$Dead; ExitCode=$ExitCode; OOMKilled=$false}
}
$script:docker = Join-Path $PSHOME 'pwsh'
$text = Invoke-LauncherDocker @('-NoProfile','-NonInteractive','-Command','Write-Output "native-ok"; exit 0')
Assert ($text -eq 'native-ok') 'native stdout is captured'
$failed = $false
try { $null = Invoke-LauncherDocker @('-NoProfile','-NonInteractive','-Command','exit 7') } catch { $failed = $true }
Assert $failed 'nonzero native exit code is rejected'

Assert ((Convert-ContainerStatus (Container 'running' $true)).State -eq 'running') 'running status'
Assert ((Convert-ContainerStatus (Container 'restarting' $true $true)).State -eq 'restarting') 'restarting is not running'
Assert ((Convert-ContainerStatus (Container 'paused' $true $false $true)).State -eq 'paused') 'paused is not running'
Assert ((Convert-ContainerStatus (Container 'dead' $false $false $false $true)).State -eq 'dead') 'dead state'
Assert ((Convert-ContainerStatus (Container 'exited')).ExitCode -eq 0) 'stopped keeps exit code'
Assert ((Convert-ContainerStatus (Container 'created')).State -eq 'created') 'created state stays distinct'
Assert (-not (Convert-ContainerStatus (Container 'running')).Known) 'inconsistent flags never imply running'
$foreign = Container 'running' $true; $foreign.Project = 'other-project'
$failed = $false; try { $null = Convert-ContainerStatus $foreign } catch { $failed = $true }
Assert $failed 'wrong project is rejected'

$script:fixtureIds = '0123456789ab'
$script:fixtureContainer = Container 'running' $true
$script:dockerFailure = $false
$script:dockerCalls = [System.Collections.Generic.List[object]]::new()
function Invoke-LauncherDocker([string[]]$Arguments) {
 $script:dockerCalls.Add($Arguments)
 if ($script:dockerFailure) { throw 'Docker unavailable' }
 if ($Arguments[0] -eq 'ps') { return $script:fixtureIds }
 if ($Arguments[0] -eq 'inspect') {
  $c = $script:fixtureContainer
  return (ConvertTo-Json -InputObject @($c.Project,$c.Service,$c.Oneoff,$c.Status,$c.Running,$c.Restarting,$c.Paused,$c.Dead,$c.ExitCode,$c.OOMKilled) -Compress)
 }
 throw 'Unexpected docker command'
}
Assert ((Get-ServiceStatus 'server').State -eq 'running') 'service lookup reads selected fields'
$psCall = $script:dockerCalls[0]
Assert ($psCall -contains 'label=com.docker.compose.project=tibiasp-real860') 'lookup selects exact project label'
Assert ($psCall -contains 'label=com.docker.compose.service=server') 'lookup selects exact service label'
Assert ($psCall -contains '-aq') 'lookup includes exited containers'
Assert ($script:dockerCalls[1][2] -notmatch 'json \.Config\}\}|json \.\}\}') 'inspect template does not dump configuration or entire container'
Assert (-not $script:dockerCalls[1][2].Contains('"')) 'inspect template avoids legacy native doublequote stripping'
$script:fixtureIds = ''
Assert ((Get-ServiceStatus 'server').State -eq 'missing') 'missing container is explicit'
$script:fixtureIds = 'untrusted-name'
Assert ((Get-ServiceStatus 'server').State -eq 'error') 'invalid container id is an error'
$script:fixtureIds = "0123456789ab`nabcdef012345"
Assert ((Get-ServiceStatus 'server').State -eq 'unknown') 'ambiguous service is never selected arbitrarily'
$script:fixtureIds = '0123456789ab'; $script:fixtureContainer.Oneoff = 'True'
Assert ((Get-ServiceStatus 'server').State -eq 'missing') 'oneoff container cannot masquerade as service'
$script:fixtureContainer.Oneoff = 'False'; $script:fixtureContainer.Service = 'database'
Assert ((Get-ServiceStatus 'server').State -eq 'error') 'inspect identity is verified again'
$script:dockerFailure = $true
Assert ((Get-ServiceStatus 'server').State -eq 'error') 'docker query error is not stopped'

$sandbox = Join-Path $PSScriptRoot ('launcher-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null
try {
 $id = '0123456789abcdef0123456789abcdef'
 $resultPath = Join-Path $sandbox 'result.json'
 $result = [ordered]@{schema=1; operationId=$id; action='save'; success=$true; saveConfirmed=$true; stopConfirmed=$false; message='Saved'}
 $result | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
 $check = Read-OperationResult $resultPath $id 'save'
 Assert $check.Valid 'structured result roundtrip'
 Assert (-not (Read-OperationResult $resultPath ('f' * 32) 'save').Valid) 'result of a different operation rejected'
 Assert (-not (Read-OperationResult $resultPath $id 'safestop').Valid) 'result of a different action rejected'
 $result.success = 'true'; $result | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
 Assert (-not (Read-OperationResult $resultPath $id 'save').Valid) 'string boolean rejected'
 $result.success = $true; $result.schema = 2; $result | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
 Assert (-not (Read-OperationResult $resultPath $id 'save').Valid) 'unsupported schema rejected'
 $result.schema = 1; $result.Remove('saveConfirmed'); $result | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
 Assert (-not (Read-OperationResult $resultPath $id 'save').Valid) 'missing acknowledgment property rejected'
 Assert (-not (Read-OperationResult (Join-Path $sandbox 'missing.json') $id 'save').Valid) 'no result never means success'

 $running = [pscustomobject]@{DockerReady=$true; Server=(New-ServiceStatus 'running' $true); Database=(New-ServiceStatus 'running' $true)}
 Assert (Get-OperationOutcome $check 0 $running).Success 'save with matching acknowledgment and running game succeeds'
 Assert (Get-OperationOutcome $check $null $running).Success 'unavailable process exit code needs valid result and actual state'
 Assert (-not (Get-OperationOutcome $check 5 $running).Success) 'nonzero exit vetoes even a positive structured result'
 $check.Result.saveConfirmed = $false
 Assert (-not (Get-OperationOutcome $check 0 $running).Success) 'save requires actual acknowledgment'
 $check.Result.saveConfirmed = $true; $check.Result.action = 'safestop'; $check.Result.stopConfirmed = $true
 $stopped = [pscustomobject]@{DockerReady=$true; Server=(New-ServiceStatus 'exited' $true '' 0); Database=(New-ServiceStatus 'running' $true)}
 Assert (Get-OperationOutcome $check 0 $stopped).Success 'running database does not prevent confirmed game shutdown'
 foreach ($state in @('missing','created','dead','restarting','paused','running','unknown','error')) {
  $stopped.Server = New-ServiceStatus $state ($state -notin @('unknown','error'))
  Assert (-not (Get-OperationOutcome $check 0 $stopped).Success) ('safestop cannot succeed in state ' + $state)
 }
 $stopped.Server = New-ServiceStatus 'exited' $true '' 1
 Assert (-not (Get-OperationOutcome $check 0 $stopped).Success) 'nonzero container exit is not clean shutdown'
 $stopped.Server = New-ServiceStatus 'exited' $true '' 0 $true
 Assert (-not (Get-OperationOutcome $check 0 $stopped).Success) 'OOM termination is never a clean shutdown'
 $check.Result.action = 'start'
 Assert (Get-OperationOutcome $check 0 $running).Success 'start requires helper readiness and running state'
 $running.Server = New-ServiceStatus 'restarting' $true
 Assert (-not (Get-OperationOutcome $check 0 $running).Success) 'restarting never passes start validation'
 $running.DockerReady = $false
 Assert (-not (Get-OperationOutcome $check 0 $running).Success) 'Docker unavailability blocks success'

 $out = Join-Path $sandbox 'out.log'; $err = Join-Path $sandbox 'err.log'
 [IO.File]::WriteAllText($out, 'Odpowiedz Lua: SA')
 [IO.File]::WriteAllText($err, 'blad bez konca linii')
 $op = [pscustomobject]@{Action='save'; Out=$out; Err=$err; OutLength=0; ErrLength=0; OutPending=''; ErrPending=''}
 $script:logLines = [System.Collections.Generic.List[string]]::new()
 function Log([string]$Message) { $script:logLines.Add($Message) }
 Read-OperationLogs $op $false
 Assert ($script:logLines.Count -eq 0) 'partial stdout and stderr are buffered'
 [IO.File]::AppendAllText($out, "VE_DONE`r")
 Read-OperationLogs $op $false
 Assert ($script:logLines.Count -eq 0) 'CR in incomplete CRLF is buffered'
 [IO.File]::AppendAllText($out, "`nostatnia linia")
 Read-OperationLogs $op $false
 Assert ($script:logLines.Count -eq 1 -and $script:logLines[0] -eq '[save] Odpowiedz Lua: SAVE_DONE') 'line split across three writes is reconstructed'
 Read-OperationLogs $op $true
 Assert ($script:logLines.Count -eq 3) 'final unterminated stdout and stderr tails are flushed once'
 Assert ($script:logLines[1] -eq '[save] ostatnia linia') 'final stdout tail is retained'
 Assert ($script:logLines[2] -eq '[save] blad bez konca linii') 'final stderr tail is retained'
 Read-OperationLogs $op $true
 Assert ($script:logLines.Count -eq 3) 'reading completed log does not duplicate tails'

 $utfPath = Join-Path $sandbox 'utf8.log'
 $utfBytes = [Text.Encoding]::UTF8.GetBytes("Zażółć`n")
 [IO.File]::WriteAllBytes($utfPath, $utfBytes[0..($utfBytes.Length - 3)])
 $op = [pscustomobject]@{Action='save'; Out=$utfPath; Err=(Join-Path $sandbox 'no-stderr.log'); OutLength=0; ErrLength=0; OutPending=''; ErrPending=''}
 Read-OperationLogs $op $false
 Assert ($script:logLines.Count -eq 3) 'partial UTF8 character is not emitted early'
 $append = [IO.File]::Open($utfPath, [IO.FileMode]::Append)
 try { $append.Write($utfBytes, $utfBytes.Length - 2, 2) } finally { $append.Dispose() }
 Read-OperationLogs $op $false
 Assert ($script:logLines.Count -eq 4 -and $script:logLines[3] -eq '[save] Zażółć') 'reread log tail repairs an incomplete multibyte UTF8 character'
} finally { Remove-Item -LiteralPath $sandbox -Recurse -Force }

$bytes = [IO.File]::ReadAllBytes($launcher)
Assert ($bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf -and $bytes[3] -ne 0xef) 'one UTF8 BOM for Windows PowerShell 5.1'
Assert (-not ([IO.File]::ReadAllText($launcher) -match 'ServerStatus\.Text\s+-eq')) 'control flow never reads a UI label as state'
Write-Output ('PASS: launcher AST and ' + $script:assertions + ' assertions; no GUI or Docker started')
