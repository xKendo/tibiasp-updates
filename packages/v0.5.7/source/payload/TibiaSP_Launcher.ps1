Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$logFile = Join-Path $env:LOCALAPPDATA 'TibiaSP\Launcher\launcher.log'
$script:operationLogDir = Join-Path $env:LOCALAPPDATA 'TibiaSP\Launcher\logs'
New-Item -ItemType Directory -Path $script:operationLogDir -Force | Out-Null
$serverScript = Join-Path $root 'TIBIA_REAL860.ps1'
$projectCompose = Join-Path $root 'silnik-8.60\server\compose.yaml'
$clientPathFile = Join-Path $root 'otclient-path.txt'
$dockerCandidates = @(
 (Get-Command docker.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
 'C:\Program Files\Docker\Docker\resources\bin\docker.exe',
 (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\resources\bin\docker.exe'),
 (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\resources\docker.exe')
)
$script:docker = $dockerCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
$xml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="TibiaSP Launcher | Real 8.60" Width="1100" Height="730" MinWidth="900" MinHeight="620" WindowStartupLocation="CenterScreen" Background="#101B20" FontFamily="Segoe UI" Foreground="#E9E2CE">
 <Window.Resources>
  <Style TargetType="Button"><Setter Property="Background" Value="#273A3B"/><Setter Property="Foreground" Value="#F2E4C7"/><Setter Property="BorderBrush" Value="#6B5C3A"/><Setter Property="Padding" Value="13,10"/><Setter Property="Margin" Value="5"/><Setter Property="FontSize" Value="14"/><Setter Property="Cursor" Value="Hand"/></Style>
  <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#E9E2CE"/></Style>
 </Window.Resources>
 <Grid>
  <Grid.ColumnDefinitions><ColumnDefinition Width="220"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
  <Border Background="#0B1418" BorderBrush="#645334" BorderThickness="0,0,1,0">
   <StackPanel Margin="16,24">
    <TextBlock Text="TIBIASP" Foreground="#E5BD72" FontFamily="Georgia" FontSize="32" FontWeight="Bold"/>
    <TextBlock Text="REAL 8.60  |  AI WORLD" Foreground="#B4B0A3" FontSize="11" Margin="2,0,0,30"/>
    <Button Name="NavHome" Content="01  Pulpit" HorizontalContentAlignment="Left"/>
    <Button Name="NavBots" Content="02  Swiat i boty" HorizontalContentAlignment="Left"/>
    <Button Name="NavCoop" Content="03  COOP" HorizontalContentAlignment="Left"/>
    <Button Name="NavDb" Content="04  Baza danych" HorizontalContentAlignment="Left"/>
    <Button Name="NavLogs" Content="05  Logi i diagnostyka" HorizontalContentAlignment="Left"/>
    <Button Name="NavUpdates" Content="06  Aktualizacje" HorizontalContentAlignment="Left" Background="#24614B"/>
    <TextBlock Text="TIBIA 8.60 / OTCLIENTV8" Foreground="#BBA77D" Margin="7,36,0,0" FontSize="11"/>
    <TextBlock Text="Serwer dziala niezaleznie od launchera" TextWrapping="Wrap" Foreground="#87979A" Margin="7,8,0,0" FontSize="11"/>
   </StackPanel>
  </Border>
  <Grid Grid.Column="1" Margin="24,20,24,18">
   <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="160"/></Grid.RowDefinitions>
   <TextBlock Text="TIBIASP  |  TWOJ SWIAT" FontFamily="Georgia" FontSize="29" Foreground="#E5BD72" Margin="0,0,0,15"/>
   <Grid Grid.Row="1" Margin="0,0,0,20"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Border Background="#1D2B2F" Padding="13" Margin="0,0,5,0"><TextBlock Name="DockerStatus" Text="Docker: sprawdzanie..." Foreground="#A5C6B3"/></Border>
    <Border Grid.Column="1" Background="#1D2B2F" Padding="13" Margin="5,0,0,0"><TextBlock Name="ServerStatus" Text="Serwer: sprawdzanie..." Foreground="#E5BD72"/></Border>
   </Grid>
   <Grid Grid.Row="2">
    <StackPanel Name="PageHome">
     <TextBlock Text="Wroc do swojego swiata" FontFamily="Georgia" FontSize="27" Foreground="#E5BD72" Margin="0,0,0,5"/>
     <TextBlock Text="Uruchom rozgrywke lub zarzadzaj serwerem TibiaSP." Foreground="#A6B0B0" Margin="0,0,0,20"/>
     <UniformGrid Columns="2" Rows="3">
      <Button Name="StartBtn" Content="URUCHOM SERWER" Background="#24614B" Height="66"/>
      <Button Name="StopBtn" Content="ZATRZYMAJ SERWER" Background="#653D39" Height="66"/>
      <Button Name="ClientBtn" Content="URUCHOM OTCLIENTV8" Height="66"/>
      <Button Name="SaveBtn" Content="ZAPISZ SWIAT" Height="66" Background="#24614B"/>
      <Button Name="WebBtn" Content="OTWORZ PANEL WWW (POZNIEJ)" Height="66" IsEnabled="False"/>
      <Button Name="RefreshBtn" Content="ODSWIEZ STATUS" Height="66"/>
     </UniformGrid>
     <TextBlock Text="Zamkniecie tego okna nie zatrzymuje kontenerow Docker." Foreground="#9FAEA7" Margin="7,20,0,0"/>
    </StackPanel>
    <StackPanel Name="PageOther" Visibility="Collapsed">
     <TextBlock Name="OtherTitle" FontFamily="Georgia" FontSize="28" Foreground="#E5BD72" Margin="0,0,0,18"/>
     <TextBlock Name="OtherDesc" TextWrapping="Wrap" FontSize="16" Foreground="#C6CBC6"/>
    </StackPanel>
   </Grid>
   <Grid Grid.Row="3" Margin="0,12,0,0"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
    <TextBlock Text="DZIENNIK LAUNCHERA" Foreground="#E5BD72" Margin="0,0,0,7"/>
    <TextBox Grid.Row="1" Name="LogBox" Background="#091115" Foreground="#A7D6B4" BorderBrush="#48544A" FontFamily="Consolas" FontSize="12" IsReadOnly="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>
   </Grid>
  </Grid>
 </Grid>
</Window>
'@
$reader = New-Object System.Xml.XmlNodeReader ([xml]$xml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$names = 'DockerStatus','ServerStatus','LogBox','PageHome','PageOther','OtherTitle','OtherDesc','StartBtn','StopBtn','ClientBtn','SaveBtn','WebBtn','RefreshBtn','NavHome','NavBots','NavCoop','NavDb','NavLogs','NavUpdates'
foreach ($n in $names) { Set-Variable -Name $n -Value $window.FindName($n) -Scope Script }
function Log([string]$msg) {
 $line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $msg)
 $LogBox.AppendText($line + [Environment]::NewLine); $LogBox.ScrollToEnd()
 try { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 } catch {}
}
# Only selected inspect fields are read; configuration and environment values stay private.
function Invoke-LauncherDocker([string[]]$Arguments) {
 if (-not $script:docker) { throw 'Nie znaleziono docker.exe.' }
 $previousPreference = $ErrorActionPreference
 try {
  $ErrorActionPreference = 'Continue'
  $output = @(& $script:docker @Arguments 2>$null)
  $nativeCode = $LASTEXITCODE
 } finally { $ErrorActionPreference = $previousPreference }
 if ($nativeCode -ne 0) { throw ('Docker zakonczyl polecenie kodem ' + $nativeCode + '.') }
 return ($output -join "`n")
}
function New-ServiceStatus([string]$State, [bool]$Known, [string]$Message = '', $ExitCode = $null, [bool]$OOMKilled = $false) {
 return [pscustomobject]@{State=$State; Known=$Known; Message=$Message; ExitCode=$ExitCode; OOMKilled=$OOMKilled}
}
function Convert-ContainerStatus($Container) {
 if ($Container.Project -cne 'tibiasp-real860' -or $Container.Service -cne 'server') {
  throw 'Nieprawidlowa tozsamosc kontenera serwera.'
 }
 return Convert-ServiceContainerStatus $Container
}
function Convert-ServiceContainerStatus($Container) {
 foreach ($field in @('Running','Restarting','Paused','Dead','OOMKilled')) {
  if ($Container.$field -isnot [bool]) { throw 'Niepelny stan kontenera.' }
 }
 if ($Container.Restarting -or $Container.Status -eq 'restarting') { return New-ServiceStatus 'restarting' $true }
 if ($Container.Paused -or $Container.Status -eq 'paused') { return New-ServiceStatus 'paused' $true }
 if ($Container.Dead -or $Container.Status -eq 'dead') { return New-ServiceStatus 'dead' $true }
 if ($Container.Status -eq 'running' -and $Container.Running) { return New-ServiceStatus 'running' $true }
 if ($Container.Status -eq 'exited' -and -not $Container.Running) {
  if ($Container.ExitCode -isnot [int] -and $Container.ExitCode -isnot [long]) { throw 'Brak kodu wyjscia kontenera.' }
  return New-ServiceStatus 'exited' $true '' $Container.ExitCode $Container.OOMKilled
 }
 if ($Container.Status -eq 'created' -and -not $Container.Running) { return New-ServiceStatus 'created' $true }
 return New-ServiceStatus 'unknown' $false 'Nieznany lub niespojny stan kontenera.'
}
function Get-ServiceStatus([string]$Service) {
 try {
  $raw = Invoke-LauncherDocker @('ps','-aq','--filter','label=com.docker.compose.project=tibiasp-real860','--filter',('label=com.docker.compose.service=' + $Service))
  $ids = @($raw -split '\r?\n' | Where-Object { $_.Trim() })
  if ($ids.Count -eq 0) { return New-ServiceStatus 'missing' $true }
  $containers = @()
  # Go raw strings avoid embedded double quotes, which legacy PowerShell can strip.
  $format = '[{{json (index .Config.Labels `com.docker.compose.project`)}},{{json (index .Config.Labels `com.docker.compose.service`)}},{{json (index .Config.Labels `com.docker.compose.oneoff`)}},{{json .State.Status}},{{json .State.Running}},{{json .State.Restarting}},{{json .State.Paused}},{{json .State.Dead}},{{json .State.ExitCode}},{{json .State.OOMKilled}}]'
  foreach ($id in $ids) {
   if ($id -notmatch '^[a-f0-9]{12,64}$') { throw 'Nieprawidlowy identyfikator kontenera.' }
   $fields = (Invoke-LauncherDocker @('inspect','--format',$format,$id)) | ConvertFrom-Json -ErrorAction Stop
   if ($fields -isnot [array] -or $fields.Count -ne 10) { throw 'Niepelny wynik inspekcji Docker.' }
   $container = [pscustomobject]@{Project=$fields[0]; Service=$fields[1]; Oneoff=$fields[2]; Status=$fields[3]; Running=$fields[4]; Restarting=$fields[5]; Paused=$fields[6]; Dead=$fields[7]; ExitCode=$fields[8]; OOMKilled=$fields[9]}
   if ($container.Project -cne 'tibiasp-real860' -or $container.Service -cne $Service) { throw 'Niezgodna tozsamosc uslugi Docker.' }
   if ([string]$container.Oneoff -ieq 'true') { continue }
   $containers += $container
  }
  if ($containers.Count -eq 0) { return New-ServiceStatus 'missing' $true }
  if ($containers.Count -ne 1) { return New-ServiceStatus 'unknown' $false 'Wiele kontenerow tej samej uslugi.' }
  if ($Service -eq 'server') { return Convert-ContainerStatus $containers[0] }
  return Convert-ServiceContainerStatus $containers[0]
 } catch { return New-ServiceStatus 'error' $false 'Blad odczytu uslugi Docker.' }
}
function DockerReady {
 try { $null = Invoke-LauncherDocker @('info','--format','{{.ServerVersion}}'); return $true } catch { return $false }
}
function Get-TibiaStatus {
 if (-not (DockerReady)) {
  return [pscustomobject]@{DockerReady=$false; Server=(New-ServiceStatus 'error' $false); Database=(New-ServiceStatus 'error' $false)}
 }
 return [pscustomobject]@{DockerReady=$true; Server=(Get-ServiceStatus 'server'); Database=(Get-ServiceStatus 'database')}
}
function Get-ServiceStatusCaption($Status) {
 switch ($Status.State) {
  'running' { return 'KONTENER URUCHOMIONY' }
  'restarting' { return 'RESTARTOWANIE' }
  'exited' { return ('ZATRZYMANY (kod ' + $Status.ExitCode + ')') }
  'created' { return 'UTWORZONY / NIEURUCHOMIONY' }
  'paused' { return 'WSTRZYMANY' }
  'dead' { return 'USZKODZONY (dead)' }
  'missing' { return 'BRAK KONTENERA' }
  'error' { return 'BLAD ODCZYTU' }
  default { return 'STAN NIEZNANY' }
 }
}
function EnsureDockerDesktop {
 if (DockerReady) { Log 'Docker Desktop jest juz gotowy.'; return }
 $desktopCandidates = @(
 (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\Docker Desktop.exe'),
 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
)
$desktop = $desktopCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
 $running = @(Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)
 if ($running.Count -gt 0) {
  Log 'Docker Desktop juz sie uruchamia. Czekam na silnik Docker (moze to potrwac chwile).'
  return
 }
 if (-not $desktop) {
  Log 'Nie znaleziono Docker Desktop.exe. Sprawdz instalacje Docker Desktop.'
  return
 }
 try {
  Start-Process -FilePath $desktop | Out-Null
  Log 'Uruchamiam Docker Desktop automatycznie. Serwer pozostaje zatrzymany do klikniecia URUCHOM SERWER.'
 } catch { Log ('Nie udalo sie uruchomic Docker Desktop: ' + $_.Exception.Message) }
}
function Refresh {
 $script:status = Get-TibiaStatus
 if (-not $script:status.DockerReady) {
  $DockerStatus.Text='Docker: NIEGOTOWY / BLAD POLACZENIA'
  $ServerStatus.Text='Serwer: stan nieznany'
  return
 }
 $databaseCaption = switch ($script:status.Database.State) {
  'running' { 'dziala' }
  'exited' { 'zatrzymana' }
  'restarting' { 'restart' }
  'missing' { 'brak' }
  default { 'sprawdz stan' }
 }
 $DockerStatus.Text='Docker: GOTOWY | Baza: ' + $databaseCaption
 $ServerStatus.Text='Serwer: ' + (Get-ServiceStatusCaption $script:status.Server)
}
# Read redirected output while the child process is still writing to it.
function Read-SharedLog([string]$path) {
 $file = $null
 $reader = $null
 try {
  $file = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  $reader = New-Object System.IO.StreamReader($file, [System.Text.Encoding]::UTF8, $true)
  return $reader.ReadToEnd()
 } catch [System.IO.IOException] {
  # A brief sharing conflict is normal while PowerShell writes redirected output.
  return $null
 } finally {
  if ($null -ne $reader) { $reader.Dispose() }
  elseif ($null -ne $file) { $file.Dispose() }
 }
}
# Keep partial lines between reads; a line can be split across writes by the helper.
function Split-OperationLog([string]$Pending, [string]$Delta, [bool]$Final) {
 $parts = @([regex]::Split(($Pending + $Delta), '\r?\n'))
 $lines = @()
 if ($parts.Count -gt 1) { $lines = @($parts[0..($parts.Count - 2)]) }
 $tail = $parts[$parts.Count - 1]
 if ($Final) { if ($tail.Length -gt 0) { $lines += $tail }; $tail = '' }
 return [pscustomobject]@{Lines=[string[]]$lines; Pending=$tail}
}
function Read-OperationLogs($Operation, [bool]$Final) {
 foreach ($stream in @('Out','Err')) {
  $path = $Operation.$stream
  if (-not (Test-Path -LiteralPath $path)) { continue }
  $content = Read-SharedLog $path
  if ($null -eq $content) { continue }
  $lengthName = $stream + 'Length'
  $pendingName = $stream + 'Pending'
  $old = $Operation.$lengthName
  if ($content.Length -lt $old) { $old = 0; $Operation.$pendingName = '' }
  # Advance only past complete lines. Rereading the tail also repairs a UTF-8
  # character that was incomplete at the preceding read boundary.
  $result = Split-OperationLog '' $content.Substring($old) $Final
  $Operation.$lengthName = $content.Length - $result.Pending.Length
  $Operation.$pendingName = $result.Pending
  foreach ($line in $result.Lines) {
   if ($line.Trim()) { Log ('[' + $Operation.Action + '] ' + $line.Trim()) }
  }
 }
}
# Human-readable logs never authorize success. Each child must return its own result.
function Read-OperationResult([string]$Path, [string]$OperationId, [string]$Action) {
 try {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Brak pliku wyniku operacji.' }
  if ((Get-Item -LiteralPath $Path).Length -gt 65536) { throw 'Nieprawidlowy rozmiar wyniku.' }
  $result = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  foreach ($name in @('schema','operationId','action','success','saveConfirmed','stopConfirmed','message')) {
   if ($null -eq $result.PSObject.Properties[$name]) { throw 'Niepelny wynik operacji.' }
  }
  if (($result.schema -isnot [int] -and $result.schema -isnot [long]) -or $result.schema -ne 1) { throw 'Nieznany format wyniku.' }
  if ($result.operationId -isnot [string] -or $result.operationId -cne $OperationId -or $OperationId -cnotmatch '^[a-f0-9]{32}$') { throw 'Wynik innej operacji.' }
  if ($result.action -isnot [string] -or $result.action -cne $Action -or $Action -notin @('start','save','safestop')) { throw 'Wynik innego polecenia.' }
  foreach ($name in @('success','saveConfirmed','stopConfirmed')) {
   if ($result.$name -isnot [bool]) { throw 'Nieprawidlowy typ potwierdzenia.' }
  }
  if ($result.message -isnot [string] -or $result.message.Length -gt 4096) { throw 'Nieprawidlowy komunikat wyniku.' }
  return [pscustomobject]@{Valid=$true; Result=$result; Error=''}
 } catch { return [pscustomobject]@{Valid=$false; Result=$null; Error=$_.Exception.Message} }
}
function Get-OperationOutcome($ResultCheck, $ExitCode, $Status) {
 if ($null -ne $ExitCode -and $ExitCode -ne 0) { return [pscustomobject]@{Success=$false; Message=('Proces zakonczyl sie kodem ' + $ExitCode + '.')} }
 if (-not $ResultCheck.Valid) { return [pscustomobject]@{Success=$false; Message=$ResultCheck.Error} }
 $result = $ResultCheck.Result
 if (-not $result.success) { return [pscustomobject]@{Success=$false; Message=$result.message} }
 if (-not $Status.DockerReady -or -not $Status.Server.Known) { return [pscustomobject]@{Success=$false; Message='Nie mozna potwierdzic aktualnego stanu serwera w Dockerze.'} }
 switch ($result.action) {
  'start' {
   if ($Status.Server.State -eq 'running') { return [pscustomobject]@{Success=$true; Message='Serwer odpowiedzial na probe gotowosci; kontener dziala.'} }
  }
  'save' {
   if ($result.saveConfirmed -and $Status.Server.State -eq 'running') { return [pscustomobject]@{Success=$true; Message='Zapis swiata potwierdzony przez Lua dla tego zadania.'} }
  }
  'safestop' {
   if ($result.saveConfirmed -and $result.stopConfirmed -and $Status.Server.State -eq 'exited' -and $Status.Server.ExitCode -eq 0 -and -not $Status.Server.OOMKilled) {
    return [pscustomobject]@{Success=$true; Message='Zapis potwierdzony; kontener serwera zatrzymany. Stan bazy pokazano osobno.'}
   }
  }
 }
 return [pscustomobject]@{Success=$false; Message='Wynik operacji nie zgadza sie z wymaganymi potwierdzeniami lub stanem kontenera.'}
}
# Monitor one operation at a time, without opening a console window.
$script:activeOperation = $null
$script:operationTimer = New-Object Windows.Threading.DispatcherTimer
$script:operationTimer.Interval = [TimeSpan]::FromMilliseconds(600)
$script:operationTimer.Add_Tick({
 if (-not $script:activeOperation) { return }
 $op = $script:activeOperation
 try {
  Read-OperationLogs $op $false
  $op.Process.Refresh()
  if ($op.Process.HasExited) {
   $op.Process.WaitForExit()
   if (-not $op.ExitSeen) { $op.ExitSeen = $true; return }
   Read-OperationLogs $op $true
   $code = $null
   try { $code = $op.Process.ExitCode } catch {}
   $result = Read-OperationResult $op.ResultFile $op.OperationId $op.Action
   Refresh
   $outcome = Get-OperationOutcome $result $code $script:status
   $prefix = if ($outcome.Success) { 'SUKCES: ' } else { 'BLAD: ' }
   Log ('[' + $op.Action + '] ' + $prefix + $outcome.Message)
   $script:activeOperation = $null
   $SaveBtn.IsEnabled = $true; $StopBtn.IsEnabled = $true; $StartBtn.IsEnabled = $true
  }
 } catch { Log ('Blad monitorowania: ' + $_.Exception.Message) }
})
$script:operationTimer.Start()
function InvokeServer([ValidateSet('start','save','safestop')][string]$action) {
 if ($script:activeOperation) { Log ('Poczekaj: trwa ' + $script:activeOperation.Action); return }
 if (-not (Test-Path -LiteralPath $serverScript)) { Log 'BRAK TIBIA_REAL860.ps1 obok launchera.'; return }
 if (-not (Test-Path -LiteralPath $projectCompose)) { Log 'BRAK silnik-8.60\server\compose.yaml.'; return }
 $ps = Join-Path $PSHOME 'powershell.exe'
 $operationId = [Guid]::NewGuid().ToString('N')
 $base = Join-Path $script:operationLogDir ('operacja-' + $operationId)
 $out = $base + '-out.log'
 $err = $base + '-err.log'
 $resultFile = $base + '-result.json'
 $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $serverScript + '" -Action ' + $action + ' -OperationId ' + $operationId + ' -ResultFile "' + $resultFile + '"'
 try {
  $proc = Start-Process -FilePath $ps -ArgumentList $arguments -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
  $script:activeOperation = [pscustomobject]@{Action=$action; OperationId=$operationId; ResultFile=$resultFile; Process=$proc; Out=$out; Err=$err; OutLength=0; ErrLength=0; OutPending=''; ErrPending=''; ExitSeen=$false}
  $SaveBtn.IsEnabled = $false; $StopBtn.IsEnabled = $false; $StartBtn.IsEnabled = $false
  Log ('[' + $action + '] Uruchomiono operacje. Czekam na odpowiedz serwera...')
 } catch { Log ('BLAD: ' + $_.Exception.Message) }
}
$StartBtn.Add_Click({
 if (-not (DockerReady)) {
  EnsureDockerDesktop
  Log 'Docker jeszcze nie jest gotowy. Poczekaj na status Docker: GOTOWY, potem ponownie kliknij URUCHOM SERWER.'
  return
 }
 InvokeServer 'start'
})
$StopBtn.Content='ZATRZYMAJ I ZAPISZ'
$StopBtn.Add_Click({
 $answer = [System.Windows.MessageBox]::Show('Zapisac swiat i bezpiecznie zamknac serwer?', 'TibiaSP', 'YesNo', 'Question')
 if ($answer -eq 'Yes') { InvokeServer 'safestop' }
})
$SaveBtn.Add_Click({ InvokeServer 'save' })
$RefreshBtn.Add_Click({ Refresh; Log 'Odswiezono status.' })
$ClientBtn.Add_Click({
 $client = if (Test-Path $clientPathFile) { (Get-Content -LiteralPath $clientPathFile -Raw).Trim().Trim('"') } else { '' }
 if (-not $client -or -not (Test-Path $client)) {
  $dlg = New-Object Microsoft.Win32.OpenFileDialog
  $dlg.Title='Wybierz otclient_dx.exe lub otclient_gl.exe'; $dlg.Filter='OTClient (*.exe)|*.exe'
  if ($dlg.ShowDialog() -ne $true) { return }
  $client = $dlg.FileName
  Set-Content -LiteralPath $clientPathFile -Value $client -Encoding UTF8
 }
 try { Start-Process -FilePath $client -WorkingDirectory (Split-Path $client -Parent); Log 'Uruchomiono OTClientV8.' } catch { Log ('Blad OTClient: ' + $_.Exception.Message) }
})
function Page([string]$title,[string]$desc) { $PageHome.Visibility='Collapsed'; $PageOther.Visibility='Visible'; $OtherTitle.Text=$title; $OtherDesc.Text=$desc }
$NavHome.Add_Click({ $PageOther.Visibility='Collapsed'; $PageHome.Visibility='Visible' })
$NavBots.Add_Click({ Page 'Swiat i boty' 'W przygotowaniu: konfiguracja botow AI, zachowania, limity, statystyki. Ta wersja nie modyfikuje jeszcze silnika.' })
$NavCoop.Add_Click({ Page 'COOP' 'W przygotowaniu: wspolna gra przez VPN. Nie udostepniaj portow do Internetu bez zabezpieczen.' })
$NavDb.Add_Click({ Page 'Baza danych' 'W przygotowaniu: konta, postacie i bezpieczne kopie zapasowe. Baza MariaDB pozostaje nietknieta.' })
$NavLogs.Add_Click({ Page 'Logi i diagnostyka' 'Postep operacji jest widoczny w dzienniku na dole. Szczegolowe logi sa teraz w LocalAppData\TibiaSP\Launcher\logs (poza folderem serwera).' })
$NavUpdates.Add_Click({
 $updater = Join-Path $root 'TibiaSP_Aktualizacje.ps1'
 if (-not (Test-Path -LiteralPath $updater)) { Log 'BRAK pliku TibiaSP_Aktualizacje.ps1 obok launchera.'; return }
 try {
  $ps = Join-Path $PSHOME 'powershell.exe'
  Start-Process -FilePath $ps -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $updater + '"') -WorkingDirectory $root -WindowStyle Hidden | Out-Null
  Log 'Otwarto okno aktualizacji. Pliki pobrane beda poza folderem serwera.'
 } catch { Log ('BLAD uruchomienia aktualizatora: ' + $_.Exception.Message) }
})
Log 'TibiaSP Launcher uruchomiony. Panel WWW pozostaje do wdrozenia.'
EnsureDockerDesktop
Refresh
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(15)
$timer.Add_Tick({ Refresh })
$timer.Start()
$window.ShowDialog() | Out-Null
