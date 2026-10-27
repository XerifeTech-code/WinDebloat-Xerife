#Requires -Version 5.1
<#
    WinDebloat Xerife Tech
    - Aba Debloat    : remove apps nativos/patrocinados do Windows 11, PRESERVANDO a Microsoft Store e componentes
    - Aba Limpeza    : analisa e limpa temporarios, caches, dumps, logs, Windows Update, WinSxS etc.
    - Aba Otimizacao : tweaks de desempenho, privacidade, interface e servicos (com opcao de reverter)
    - Aba Manutencao : SFC, DISM, TRIM/Defrag, reset de rede, restaurar apps, ponto de restauracao
    Execute como Administrador (o script se auto-eleva).
#>

# ---------------------------------------------------------------- Auto-elevacao
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$PSCommandPath`""
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

trap {
    try { [void][System.Windows.Forms.MessageBox]::Show(("Erro inesperado:`n`n" + $_.Exception.Message + "`n`n" + $_.ScriptStackTrace), 'WinDebloat Xerife Tech', 'OK', 'Error') } catch {}
    exit 1
}

$script:AppDir  = Join-Path $env:LOCALAPPDATA 'WinDebloatXerifeTech'
New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
$script:LogFile = Join-Path $script:AppDir ("log_{0}.txt" -f (Get-Date -Format 'yyyyMMdd'))
$script:IsLaptop = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)

# ---------------------------------------------------------------- Utilitarios
function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message
    if ($script:txtLog) { $script:txtLog.AppendText($line + "`r`n") }
    try { Add-Content -Path $script:LogFile -Value $line -ErrorAction SilentlyContinue } catch {}
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-Progress { param([int]$Value) if ($script:pb) { $script:pb.Value = [math]::Max(0,[math]::Min(100,$Value)); [System.Windows.Forms.Application]::DoEvents() } }

function Format-Size {
    param([double]$Bytes)
    if     ($Bytes -ge 1GB) { '{0:N2} GB' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N1} MB' -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { '{0:N0} KB' -f ($Bytes / 1KB) }
    else   { '{0} B' -f [int]$Bytes }
}

function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    } catch { Write-Log "  ! Falha ao gravar $Path\$Name : $($_.Exception.Message)" }
}

function Remove-Reg {
    param([string]$Path, [string]$Name)
    try {
        if (Test-Path -LiteralPath $Path) {
            if ($Name) { Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue }
            else       { Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue }
        }
    } catch {}
}

function Set-Svc {
    param([string]$Name, [string]$Mode, [bool]$Stop = $false)
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $s) { return }
    try {
        if ($Stop -and $s.Status -eq 'Running') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
        Set-Service -Name $Name -StartupType $Mode -ErrorAction Stop
    } catch { Write-Log "  ! Servico ${Name}: $($_.Exception.Message)" }
}

function Invoke-External {
    param([string]$File, [string]$Arguments, [bool]$Visible = $false)
    Write-Log "  > $File $Arguments"
    $style = if ($Visible) { 'Normal' } else { 'Hidden' }
    try {
        $p = Start-Process -FilePath $File -ArgumentList $Arguments -WindowStyle $style -PassThru
        while (-not $p.HasExited) { Start-Sleep -Milliseconds 150; [System.Windows.Forms.Application]::DoEvents() }
        return $p.ExitCode
    } catch { Write-Log "  ! Erro ao executar: $($_.Exception.Message)"; return -1 }
}

function New-RestorePoint {
    Write-Log 'Criando ponto de restauracao do sistema...'
    try {
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description 'WinDebloat Xerife Tech' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Log '  Ponto de restauracao criado.'
    } catch { Write-Log "  ! Nao foi possivel criar o ponto de restauracao: $($_.Exception.Message)" }
}

function Restart-Explorer {
    Write-Log 'Reiniciando o Explorer...'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
}

function Set-AllChecked { param($ListView, [bool]$Value) foreach ($i in $ListView.Items) { $i.Checked = $Value } }

# ================================================================ DEBLOAT
# Pacotes PROTEGIDOS: Microsoft Store + componentes + nucleo do sistema. Nunca aparecem na lista.
$script:ProtectedPatterns = @(
    '^Microsoft\.WindowsStore$',
    '^Microsoft\.StorePurchaseApp$',
    '^Microsoft\.DesktopAppInstaller$',          # App Installer / winget (componente da Store)
    '^Microsoft\.Services\.Store\.Engagement',
    '^Microsoft\.VCLibs',
    '^Microsoft\.NET\.Native',
    '^Microsoft\.UI\.Xaml',
    '^Microsoft\.WindowsAppRuntime',
    '^Microsoft\.WinAppRuntime',
    '^MicrosoftCorporationII\.WinAppRuntime',
    '^MicrosoftWindows\.Client\.',
    '^Microsoft\.Windows\.(ShellExperienceHost|StartMenuExperienceHost|CloudExperienceHost|ContentDeliveryManager|OOBE|PeopleExperienceHost|PinningConfirmationDialog|SecureAssessmentBrowser|XGpuEjectDialog|Apprep|AssignedAccess|CapturePicker|NarratorQuickStart|ParentalControls|Search|Client|AugLoop)',
    '^Microsoft\.SecHealthUI$',                  # Seguranca do Windows
    '^Microsoft\.AAD\.BrokerPlugin$',
    '^Microsoft\.AccountsControl$',
    '^Microsoft\.LockApp$',
    '^Microsoft\.Win32WebViewHost$',
    '^Microsoft\.CredDialogHost$',
    '^Microsoft\.BioEnrollment$',
    '^Microsoft\.AsyncTextService$',
    '^Microsoft\.ECApp$',
    '^Microsoft\.XboxGameCallableUI$',
    '^Microsoft\.MicrosoftEdge',
    '^Microsoft\.Edge',
    '^NcsiUwpApp$',
    '^windows\.immersivecontrolpanel$',
    '^Windows\.',
    '^c5e2524a-ea46-4f67-841f-6a9465d9d515$',
    '^1527c705-839a-4832-9118-54d4bd6a0c89$',
    '^E2A4F912-2574-4A75-9BB0-0D023378592B$',
    '^F46D4000-FD22-4DB4-AC8E-4E1DDDE828FE$'
)

# Pacotes marcados por padrao (bloatware conhecido). Aceita curingas.
$script:BloatPatterns = @(
    'Clipchamp.Clipchamp','Microsoft.549981C3F5F10','Microsoft.BingNews','Microsoft.BingWeather','Microsoft.BingSearch',
    'Microsoft.BingFinance','Microsoft.BingSports','Microsoft.BingTranslator','Microsoft.BingFoodAndDrink',
    'Microsoft.BingHealthAndFitness','Microsoft.BingTravel','Microsoft.GetHelp','Microsoft.Getstarted',
    'Microsoft.MicrosoftOfficeHub','Microsoft.Office.OneNote','Microsoft.Office.Sway','Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.MicrosoftStickyNotes','Microsoft.OutlookForWindows','Microsoft.People','Microsoft.PowerAutomateDesktop',
    'Microsoft.Todos','Microsoft.WindowsFeedbackHub','Microsoft.WindowsMaps','Microsoft.YourPhone','Microsoft.ZuneMusic',
    'Microsoft.ZuneVideo','MicrosoftCorporationII.QuickAssist','MicrosoftCorporationII.MicrosoftFamily','MicrosoftTeams',
    'MSTeams','Microsoft.MixedReality.Portal','Microsoft.Microsoft3DViewer','Microsoft.3DBuilder','Microsoft.Print3D',
    'Microsoft.MSPaint','Microsoft.SkypeApp','Microsoft.Wallet','Microsoft.WindowsAlarms','microsoft.windowscommunicationsapps',
    'Microsoft.WindowsSoundRecorder','Microsoft.Xbox*','Microsoft.GamingApp','Microsoft.Copilot','Microsoft.Windows.DevHome',
    'Microsoft.DevHome','MicrosoftWindows.CrossDevice','Microsoft.MicrosoftJournal','Microsoft.Whiteboard','Microsoft.Messaging',
    'Microsoft.OneConnect','Microsoft.NetworkSpeedTest','Microsoft.News','Microsoft.Advertising.Xaml',
    '*Disney*','*Spotify*','*Netflix*','*TikTok*','*Instagram*','*Facebook*','*Twitter*','*LinkedIn*','*Amazon*',
    '*CandyCrush*','*king.com*','*Hulu*','*PrimeVideo*','*Duolingo*','*Evernote*','*Flipboard*','*Pandora*','*Plex*',
    '*Shazam*','*Viber*','*McAfee*','*ActiproSoftware*','*AdobePhotoshopExpress*','*AdobeExpress*','*EclipseManager*',
    '*PicsArt*','*RoyalRevolt*','*Asphalt*','*FarmVille*','*BubbleWitch*','*Minecraft*','*Dropbox*','*WinZip*',
    '*Roblox*','AD2F1837.*'
)

function Test-Protected { param([string]$Name) foreach ($p in $script:ProtectedPatterns) { if ($Name -match $p) { return $true } } return $false }
function Test-Recommended { param([string]$Name) foreach ($p in $script:BloatPatterns) { if ($Name -like $p) { return $true } } return $false }

function Remove-AppByName {
    param([string]$Name, [bool]$RemoveProvisioned)
    if (Test-Protected $Name) { Write-Log "  (protegido, ignorado) $Name"; return }
    Write-Log "Removendo: $Name"
    try {
        $pk = Get-AppxPackage -AllUsers -Name $Name -ErrorAction SilentlyContinue
        foreach ($p in $pk) {
            try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop }
            catch { Write-Log "  ! $($p.PackageFullName): $($_.Exception.Message)" }
        }
    } catch { Write-Log "  ! $($_.Exception.Message)" }
    if ($RemoveProvisioned) {
        try {
            Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq $Name } |
                ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null }
        } catch {}
    }
}

# ================================================================ LIMPEZA
$script:CleanItems = @(
    [pscustomobject]@{ Id='tempuser';  Name='Temporarios do usuario';          Desc='Pasta %TEMP% do usuario atual';                         Default=$true;  Paths=@($env:TEMP) },
    [pscustomobject]@{ Id='tempwin';   Name='Temporarios do Windows';          Desc='C:\Windows\Temp';                                       Default=$true;  Paths=@("$env:WINDIR\Temp") },
    [pscustomobject]@{ Id='wucache';   Name='Cache do Windows Update';         Desc='Arquivos baixados de atualizacoes ja instaladas (SoftwareDistribution\Download)'; Default=$true; Paths=@("$env:WINDIR\SoftwareDistribution\Download") },
    [pscustomobject]@{ Id='deliveryopt'; Name='Otimizacao de Entrega';         Desc='Cache do Delivery Optimization';                        Default=$true;  Paths=@("$env:WINDIR\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache") },
    [pscustomobject]@{ Id='thumbs';    Name='Cache de miniaturas';             Desc='thumbcache_*.db do Explorer (recriado automaticamente)'; Default=$true;  Paths=@("$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*.db") },
    [pscustomobject]@{ Id='wer';       Name='Relatorios de erro (WER)';        Desc='Relatorios de falhas do Windows';                       Default=$true;  Paths=@("$env:ProgramData\Microsoft\Windows\WER\ReportArchive","$env:ProgramData\Microsoft\Windows\WER\ReportQueue","$env:LOCALAPPDATA\Microsoft\Windows\WER") },
    [pscustomobject]@{ Id='dumps';     Name='Dumps de memoria';                Desc='Minidump, MEMORY.DMP e LiveKernelReports';              Default=$true;  Paths=@("$env:WINDIR\Minidump","$env:WINDIR\MEMORY.DMP","$env:WINDIR\LiveKernelReports") },
    [pscustomobject]@{ Id='logs';      Name='Logs do sistema';                 Desc='Logs CBS e DISM em C:\Windows\Logs';                    Default=$true;  Paths=@("$env:WINDIR\Logs\CBS","$env:WINDIR\Logs\DISM") },
    [pscustomobject]@{ Id='chrome';    Name='Cache do Google Chrome';          Desc='Cache, Code Cache e GPUCache (nao apaga senhas/historico)'; Default=$true; Paths=@("$env:LOCALAPPDATA\Google\Chrome\User Data\*\Cache","$env:LOCALAPPDATA\Google\Chrome\User Data\*\Code Cache","$env:LOCALAPPDATA\Google\Chrome\User Data\*\GPUCache") },
    [pscustomobject]@{ Id='edge';      Name='Cache do Microsoft Edge';         Desc='Cache, Code Cache e GPUCache';                          Default=$true;  Paths=@("$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\Cache","$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\Code Cache","$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\GPUCache") },
    [pscustomobject]@{ Id='firefox';   Name='Cache do Firefox';                Desc='cache2 de todos os perfis';                             Default=$true;  Paths=@("$env:LOCALAPPDATA\Mozilla\Firefox\Profiles\*\cache2") },
    [pscustomobject]@{ Id='d3d';       Name='Cache de shaders (DirectX)';      Desc='D3DSCache - recriado pelos jogos na proxima execucao';  Default=$false; Paths=@("$env:LOCALAPPDATA\D3DSCache") },
    [pscustomobject]@{ Id='prefetch';  Name='Prefetch';                        Desc='C:\Windows\Prefetch (primeiros acessos ficam um pouco mais lentos)'; Default=$false; Paths=@("$env:WINDIR\Prefetch") },
    [pscustomobject]@{ Id='recent';    Name='Itens recentes';                  Desc='Lista de arquivos recentes e jump lists';               Default=$false; Paths=@("$env:APPDATA\Microsoft\Windows\Recent") },
    [pscustomobject]@{ Id='recycle';   Name='Lixeira';                         Desc='Esvazia a Lixeira de todas as unidades';                Default=$true;  Paths=@() },
    [pscustomobject]@{ Id='dns';       Name='Cache DNS';                       Desc='ipconfig /flushdns';                                    Default=$true;  Paths=@() },
    [pscustomobject]@{ Id='winsxs';    Name='Componentes antigos (WinSxS)';    Desc='DISM /StartComponentCleanup - pode demorar varios minutos'; Default=$false; Paths=@() },
    [pscustomobject]@{ Id='winold';    Name='Windows.old';                     Desc='Instalacao anterior do Windows. ATENCAO: impede voltar a versao anterior'; Default=$false; Paths=@("$env:SystemDrive\Windows.old") }
)

function Get-CleanTargets {
    param([string[]]$Paths)
    foreach ($p in $Paths) {
        foreach ($item in @(Get-Item -Path $p -Force -ErrorAction SilentlyContinue)) {
            if ($item.PSIsContainer) { Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue }
            else { $item }
        }
    }
}

function Get-TargetsSize {
    param($Targets)
    $sum = [double]0
    foreach ($t in $Targets) {
        if ($t.PSIsContainer) {
            $m = Get-ChildItem -LiteralPath $t.FullName -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
            if ($m.Sum) { $sum += $m.Sum }
        } else { $sum += $t.Length }
    }
    return $sum
}

function Get-CleanItemSize {
    param($It)
    switch ($It.Id) {
        'recycle' {
            try { $sh = New-Object -ComObject Shell.Application; $sum = [double]0
                  foreach ($i in $sh.NameSpace(0xA).Items()) { $sum += [double]$i.Size }; return $sum } catch { return 0 }
        }
        'dns'    { return -1 }
        'winsxs' { return -1 }
        'winold' { $p = "$env:SystemDrive\Windows.old"
                   if (Test-Path $p) { $m = Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum; if ($m.Sum) { return [double]$m.Sum } }
                   return 0 }
        default  { return (Get-TargetsSize (Get-CleanTargets $It.Paths)) }
    }
}

function Invoke-Clean {
    param($It)
    Write-Log "Limpando: $($It.Name)"
    switch ($It.Id) {
        'recycle' { try { Clear-RecycleBin -Force -ErrorAction Stop } catch { Write-Log "  (Lixeira ja vazia ou erro: $($_.Exception.Message))" } return }
        'dns'     { ipconfig /flushdns | Out-Null; return }
        'winsxs'  { [void](Invoke-External 'dism.exe' '/Online /Cleanup-Image /StartComponentCleanup' $true); return }
        'winold'  {
            $p = "$env:SystemDrive\Windows.old"
            if (Test-Path $p) {
                [void](Invoke-External 'takeown.exe' "/F `"$p`" /R /A /D Y")
                [void](Invoke-External 'icacls.exe' "`"$p`" /grant *S-1-5-32-544:F /T /C /Q")
                [void](Invoke-External 'cmd.exe' "/c rd /s /q `"$p`"")
            }
            return
        }
    }
    $svcs = @()
    if ($It.Id -eq 'wucache') { $svcs = @('wuauserv','bits','dosvc'); foreach ($s in $svcs) { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue } }
    $before = Get-TargetsSize (Get-CleanTargets $It.Paths)
    foreach ($t in @(Get-CleanTargets $It.Paths)) { Remove-Item -LiteralPath $t.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    $after = Get-TargetsSize (Get-CleanTargets $It.Paths)
    if ($It.Id -eq 'wucache') { foreach ($s in $svcs) { Start-Service -Name $s -ErrorAction SilentlyContinue } }
    Write-Log ("  Liberado: {0}" -f (Format-Size ([math]::Max(0, $before - $after))))
}

# ================================================================ OTIMIZACAO (tweaks)
$script:Tweaks = New-Object System.Collections.ArrayList
function Add-Tweak {
    param([string]$Id, [string]$Group, [string]$Name, [string]$Desc, [bool]$Default, [scriptblock]$Apply, [scriptblock]$Undo, [bool]$Explorer = $false)
    [void]$script:Tweaks.Add([pscustomobject]@{ Id=$Id; Group=$Group; Name=$Name; Desc=$Desc; Default=$Default; Apply=$Apply; Undo=$Undo; Explorer=$Explorer })
}

$CDM = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$ADV = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

# ---- Desempenho
Add-Tweak 'power' 'Desempenho' 'Plano de energia: Desempenho maximo' 'Ativa o plano Ultimate Performance (ou Alto Desempenho). Em notebooks aumenta o consumo de bateria.' (-not $script:IsLaptop) {
    $o = powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>&1 | Out-String
    if ($o -match '([0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})') { powercfg /setactive $Matches[1] | Out-Null; Write-Log '  Plano Ultimate Performance ativado.' }
    else { powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c | Out-Null; Write-Log '  Plano Alto Desempenho ativado.' }
} { powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e | Out-Null; Write-Log '  Plano Equilibrado restaurado.' }

Add-Tweak 'visualfx' 'Desempenho' 'Efeitos visuais para desempenho' 'Desativa animacoes, sombras e efeitos de janela. Aplica por completo apos sair e entrar na conta.' $true {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2
    Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
    Set-Reg $ADV 'TaskbarAnimations' 0
    Set-Reg $ADV 'ListviewAlphaSelect' 0
    Set-Reg $ADV 'ListviewShadow' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0
    Set-Reg 'HKCU:\Control Panel\Desktop' 'UserPreferencesMask' ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) 'Binary'
} {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 0
    Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '1' 'String'
    Set-Reg $ADV 'TaskbarAnimations' 1
    Set-Reg $ADV 'ListviewAlphaSelect' 1
    Set-Reg $ADV 'ListviewShadow' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 1
    Set-Reg 'HKCU:\Control Panel\Desktop' 'UserPreferencesMask' ([byte[]](0x9E,0x3E,0x07,0x80,0x12,0x00,0x00,0x00)) 'Binary'
} $true

Add-Tweak 'transp' 'Desempenho' 'Desativar transparencia' 'Remove o efeito de transparencia (Mica/acrilico) - leve ganho de GPU.' $true {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
} { Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 1 }

Add-Tweak 'menudelay' 'Desempenho' 'Menus instantaneos' 'MenuShowDelay = 0 ms (padrao 400 ms).' $true {
    Set-Reg 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '0' 'String'
} { Set-Reg 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '400' 'String' }

Add-Tweak 'killtimeout' 'Desempenho' 'Desligamento mais rapido' 'Reduz o tempo de espera para encerrar servicos (5000 -> 2000 ms).' $true {
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control' 'WaitToKillServiceTimeout' '2000' 'String'
} { Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control' 'WaitToKillServiceTimeout' '5000' 'String' }

Add-Tweak 'prio' 'Desempenho' 'Prioridade para programas em primeiro plano' 'Win32PrioritySeparation = 38 (resposta mais agil do app ativo).' $false {
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38
} { Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 2 }

Add-Tweak 'gamedvr' 'Desempenho' 'Desativar Game DVR / captura em segundo plano' 'Evita gravacao em segundo plano da Xbox Game Bar (mais FPS).' $true {
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
} {
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 1
    Remove-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR'
}

Add-Tweak 'hibernate' 'Desempenho' 'Desativar hibernacao' 'Remove hiberfil.sys (libera varios GB) e desativa Inicializacao Rapida. Nao use em notebook se hiberna.' $false {
    powercfg /hibernate off | Out-Null
} { powercfg /hibernate on | Out-Null }

Add-Tweak 'faststartup' 'Desempenho' 'Desativar Inicializacao Rapida' 'Faz o desligamento ser completo (evita problemas de drivers/atualizacoes).' $false {
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0
} { Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 1 }

Add-Tweak 'reserved' 'Desempenho' 'Desativar Armazenamento Reservado' 'Libera ~7 GB reservados para atualizacoes (DISM).' $false {
    [void](Invoke-External 'dism.exe' '/Online /Set-ReservedStorageState /State:Disabled')
} { [void](Invoke-External 'dism.exe' '/Online /Set-ReservedStorageState /State:Enabled') }

Add-Tweak 'delivopt' 'Desempenho' 'Desativar compartilhamento P2P de atualizacoes' 'Impede o PC de enviar atualizacoes para outros computadores (economiza banda e CPU).' $true {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0
} { Remove-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' }

Add-Tweak 'bgapps' 'Desempenho' 'Bloquear apps em segundo plano' 'Impede apps UWP de rodarem em segundo plano. Pode reduzir notificacoes de apps.' $false {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground' 2
} {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 0
    Remove-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground'
}

Add-Tweak 'edgeboost' 'Desempenho' 'Edge: sem inicializacao antecipada' 'Desativa Startup Boost e execucao em segundo plano do Edge (o Edge continua instalado).' $true {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0
} {
    Remove-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled'
    Remove-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled'
}

# ---- Privacidade
Add-Tweak 'telemetry' 'Privacidade' 'Telemetria minima' 'Politica AllowTelemetry=0 e desativa DiagTrack/dmwappushservice (Home aplica o nivel minimo permitido).' $true {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
    Set-Svc 'DiagTrack' 'Disabled' $true
    Set-Svc 'dmwappushservice' 'Disabled' $true
} {
    Remove-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry'
    Set-Svc 'DiagTrack' 'Automatic'
    Set-Svc 'dmwappushservice' 'Manual'
}

$script:TelemetryTasks = @(
    @('\Microsoft\Windows\Application Experience\','Microsoft Compatibility Appraiser'),
    @('\Microsoft\Windows\Application Experience\','ProgramDataUpdater'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\','Consolidator'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\','UsbCeip'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\','KernelCeipTask'),
    @('\Microsoft\Windows\Feedback\Siuf\','DmClient'),
    @('\Microsoft\Windows\Feedback\Siuf\','DmClientOnScenarioDownload'),
    @('\Microsoft\Windows\Windows Error Reporting\','QueueReporting')
)
Add-Tweak 'tasks' 'Privacidade' 'Desativar tarefas agendadas de telemetria' 'Compatibility Appraiser, CEIP, Feedback e relatorios de erro.' $true {
    foreach ($t in $script:TelemetryTasks) { Disable-ScheduledTask -TaskPath $t[0] -TaskName $t[1] -ErrorAction SilentlyContinue | Out-Null }
} {
    foreach ($t in $script:TelemetryTasks) { Enable-ScheduledTask -TaskPath $t[0] -TaskName $t[1] -ErrorAction SilentlyContinue | Out-Null }
}

Add-Tweak 'wer' 'Privacidade' 'Desativar Relatorio de Erros do Windows' 'Desativa o WER e o servico WerSvc.' $true {
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1
    Set-Svc 'WerSvc' 'Disabled' $true
} {
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 0
    Set-Svc 'WerSvc' 'Manual'
}

Add-Tweak 'adid' 'Privacidade' 'Desativar ID de publicidade' 'Impede apps de usarem o ID de publicidade.' $true {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
} { Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 1 }

Add-Tweak 'suggestions' 'Privacidade' 'Desativar anuncios, sugestoes e instalacao automatica de apps' 'Sugestoes no Iniciar/Configuracoes, dicas, apps patrocinados e "Consumer Features" (impede reinstalar bloatware).' $true {
    foreach ($n in 'SubscribedContent-338387Enabled','SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-338393Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled','SubscribedContent-310093Enabled','SubscribedContent-88000326Enabled','SystemPaneSuggestionsEnabled','SoftLandingEnabled','OemPreInstalledAppsEnabled','PreInstalledAppsEnabled','PreInstalledAppsEverEnabled','SilentInstalledAppsEnabled','ContentDeliveryAllowed','RotatingLockScreenOverlayEnabled') { Set-Reg $CDM $n 0 }
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableSoftLanding' 1
} {
    foreach ($n in 'SubscribedContent-338387Enabled','SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-338393Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled','SubscribedContent-310093Enabled','SubscribedContent-88000326Enabled','SystemPaneSuggestionsEnabled','SoftLandingEnabled','ContentDeliveryAllowed','RotatingLockScreenOverlayEnabled') { Set-Reg $CDM $n 1 }
    Remove-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures'
    Remove-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableSoftLanding'
}

Add-Tweak 'bingsearch' 'Privacidade' 'Desativar pesquisa web (Bing) no Iniciar' 'A pesquisa do Iniciar fica apenas local.' $true {
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
} {
    Remove-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 1
}

Add-Tweak 'copilot' 'Privacidade' 'Desativar Copilot e Recall' 'Politicas que desligam o Windows Copilot e a analise de dados de IA (Recall).' $true {
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
} {
    Remove-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot'
    Remove-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot'
    Remove-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis'
}

Add-Tweak 'activity' 'Privacidade' 'Desativar historico de atividades' 'Impede coleta e envio do historico de atividades (Timeline).' $true {
    foreach ($n in 'EnableActivityFeed','PublishUserActivities','UploadUserActivities') { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' $n 0 }
} { foreach ($n in 'EnableActivityFeed','PublishUserActivities','UploadUserActivities') { Remove-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' $n } }

# ---- Interface
Add-Tweak 'taskbar' 'Interface' 'Barra de tarefas limpa' 'Remove Widgets, Chat/Teams, botao Visao de Tarefas e caixa de pesquisa.' $true {
    Set-Reg $ADV 'TaskbarDa' 0
    Set-Reg $ADV 'TaskbarMn' 0
    Set-Reg $ADV 'ShowTaskViewButton' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 0
} {
    Set-Reg $ADV 'TaskbarDa' 1
    Set-Reg $ADV 'TaskbarMn' 1
    Set-Reg $ADV 'ShowTaskViewButton' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 1
} $true

Add-Tweak 'widgetspol' 'Interface' 'Desativar Widgets (politica)' 'Desliga o painel de Widgets/Noticias via politica do sistema.' $true {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
} { Remove-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' } 

Add-Tweak 'classicmenu' 'Interface' 'Menu de contexto classico' 'Restaura o menu de clique direito completo do Windows 10 (sem "Mostrar mais opcoes").' $true {
    Set-Reg 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '(default)' '' 'String'
} { Remove-Reg 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}' $null } $true

Add-Tweak 'fileext' 'Interface' 'Mostrar extensoes e arquivos ocultos' 'Exibe extensoes de arquivos e itens ocultos no Explorer.' $true {
    Set-Reg $ADV 'HideFileExt' 0
    Set-Reg $ADV 'Hidden' 1
} {
    Set-Reg $ADV 'HideFileExt' 1
    Set-Reg $ADV 'Hidden' 2
} $true

Add-Tweak 'thispc' 'Interface' 'Explorer abre em "Este Computador"' 'Em vez de Inicio/Acesso rapido.' $false {
    Set-Reg $ADV 'LaunchTo' 1
} { Set-Reg $ADV 'LaunchTo' 2 } $true

# ---- Servicos
Add-Tweak 'svcmisc' 'Servicos' 'Desativar servicos raramente usados' 'Fax, MapsBroker (mapas offline), RetailDemo, WpcMonSvc (controle parental), PhoneSvc, wisvc (Insider), WMPNetworkSvc.' $true {
    foreach ($s in 'Fax','MapsBroker','RetailDemo','WpcMonSvc','PhoneSvc','wisvc','WMPNetworkSvc') { Set-Svc $s 'Disabled' $true }
} { foreach ($s in 'Fax','MapsBroker','RetailDemo','WpcMonSvc','PhoneSvc','wisvc','WMPNetworkSvc') { Set-Svc $s 'Manual' } }

Add-Tweak 'sysmain' 'Servicos' 'Desativar SysMain (Superfetch)' 'Recomendado apenas em SSD. Em HDD pode piorar o carregamento de programas.' $false {
    Set-Svc 'SysMain' 'Disabled' $true
} { Set-Svc 'SysMain' 'Automatic' }

Add-Tweak 'wsearch' 'Servicos' 'Desativar indexacao de pesquisa (WSearch)' 'Reduz uso de disco/CPU, mas a pesquisa de arquivos fica mais lenta.' $false {
    Set-Svc 'WSearch' 'Disabled' $true
} { Set-Svc 'WSearch' 'Automatic' }

Add-Tweak 'xboxsvc' 'Servicos' 'Desativar servicos Xbox' 'XblAuthManager, XblGameSave, XboxGipSvc, XboxNetApiSvc. NAO use se joga Game Pass/Xbox Live.' $false {
    foreach ($s in 'XblAuthManager','XblGameSave','XboxGipSvc','XboxNetApiSvc') { Set-Svc $s 'Disabled' $true }
} { foreach ($s in 'XblAuthManager','XblGameSave','XboxGipSvc','XboxNetApiSvc') { Set-Svc $s 'Manual' } }

Add-Tweak 'onedrive' 'Servicos' 'Desinstalar o OneDrive' 'Remove o cliente OneDrive (seus arquivos locais permanecem).' $false {
    Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
    $exe = if (Test-Path "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") { "$env:SystemRoot\SysWOW64\OneDriveSetup.exe" } else { "$env:SystemRoot\System32\OneDriveSetup.exe" }
    if (Test-Path $exe) { [void](Invoke-External $exe '/uninstall') } else { Write-Log '  OneDriveSetup.exe nao encontrado.' }
} {
    $exe = if (Test-Path "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") { "$env:SystemRoot\SysWOW64\OneDriveSetup.exe" } else { "$env:SystemRoot\System32\OneDriveSetup.exe" }
    if (Test-Path $exe) { [void](Invoke-External $exe '') } else { Write-Log '  Reinstale o OneDrive pela Microsoft Store/site oficial.' }
}

# ================================================================ AJUSTES DE JOGOS (dados)
$script:GameTweaks = New-Object System.Collections.ArrayList
function Add-GameTweak {
    param([string]$Id, [string]$Group, [string]$Name, [string]$Desc, [bool]$Default, [scriptblock]$Apply, [scriptblock]$Undo, [bool]$Explorer = $false)
    [void]$script:GameTweaks.Add([pscustomobject]@{ Id = $Id; Group = $Group; Name = $Name; Desc = $Desc; Default = $Default; Apply = $Apply; Undo = $Undo; Explorer = $Explorer })
}
function Copy-Tweak {
    param([string]$Id, [string]$Group, $Default = $null)
    $t = $script:Tweaks | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $t) { return }
    $def = $t.Default
    if ($null -ne $Default) { $def = [bool]$Default }
    [void]$script:GameTweaks.Add([pscustomobject]@{ Id = $t.Id; Group = $Group; Name = $t.Name; Desc = $t.Desc; Default = $def; Apply = $t.Apply; Undo = $t.Undo; Explorer = $t.Explorer })
}

# --- Registro HKCU via .NET (nomes com caracteres especiais, como caminhos de executaveis)
function Set-HkcuString { param([string]$Sub, [string]$Name, [string]$Value) $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($Sub); $k.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::String); $k.Close() }
function Get-HkcuValue { param([string]$Sub, [string]$Name) $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Sub); if ($k) { $v = $k.GetValue($Name, $null); $k.Close(); return $v }; return $null }
function Remove-HkcuValue { param([string]$Sub, [string]$Name) $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Sub, $true); if ($k) { $k.DeleteValue($Name, $false); $k.Close() } }
function Get-HkcuValueNames { param([string]$Sub) $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Sub); if ($k) { $n = $k.GetValueNames(); $k.Close(); return $n }; return @() }

$script:SubGpu    = 'Software\Microsoft\DirectX\UserGpuPreferences'
$script:SubLayers = 'Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
$script:FsoToken  = 'DISABLEDXMAXIMIZEDWINDOWEDMODE'

function Set-GameExeTweaks {
    param([string]$Exe, [bool]$Gpu, [bool]$Fso)
    if ($Gpu) { Set-HkcuString $script:SubGpu $Exe 'GpuPreference=2;'; Write-Log "  GPU de alto desempenho definida para: $Exe" }
    if ($Fso) {
        $cur = [string](Get-HkcuValue $script:SubLayers $Exe)
        if ($cur -notmatch $script:FsoToken) {
            if ([string]::IsNullOrWhiteSpace($cur)) { $new = "~ $($script:FsoToken)" }
            else { $new = ($cur.Trim() + " $($script:FsoToken)") }
            Set-HkcuString $script:SubLayers $Exe $new
        }
        Write-Log "  Otimizações de tela cheia desativadas para: $Exe"
    }
}
function Clear-GameExeTweaks {
    param([string]$Exe)
    Remove-HkcuValue $script:SubGpu $Exe
    $cur = [string](Get-HkcuValue $script:SubLayers $Exe)
    if ($cur -match $script:FsoToken) {
        $new = ($cur -replace ('\s*' + $script:FsoToken), '').Trim()
        if ($new -eq '~' -or $new -eq '') { Remove-HkcuValue $script:SubLayers $Exe } else { Set-HkcuString $script:SubLayers $Exe $new }
    }
    Write-Log "  Ajustes removidos de: $Exe"
}
function Get-ConfiguredGames {
    $map = @{}
    foreach ($n in @(Get-HkcuValueNames $script:SubGpu)) {
        if ($n -and $n -ne 'DirectXUserGlobalSettings') {
            if ([string](Get-HkcuValue $script:SubGpu $n) -match 'GpuPreference=2') { $map[$n] = @('GPU dedicada') }
        }
    }
    foreach ($n in @(Get-HkcuValueNames $script:SubLayers)) {
        if ($n -and ([string](Get-HkcuValue $script:SubLayers $n) -match $script:FsoToken)) {
            if ($map.ContainsKey($n)) { $map[$n] += 'Sem otim. tela cheia' } else { $map[$n] = @('Sem otim. tela cheia') }
        }
    }
    return $map
}

# ---- Desempenho em jogos
Add-GameTweak 'g_mode' 'Desempenho em jogos' 'Modo de Jogo do Windows' 'Garante que o Modo de Jogo esteja ativo: o Windows prioriza o jogo e evita atualizações/drivers em segundo plano durante a partida.' $true {
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
} {
    Remove-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
    Remove-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode'
}
Add-GameTweak 'g_hags' 'Desempenho em jogos' 'Agendamento de GPU acelerado por hardware (HAGS)' 'Reduz a latência e a carga da CPU em GPUs compatíveis (NVIDIA GTX 1000+, AMD RX 5000+, Intel Arc). Requer reiniciar.' $true {
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
} { Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 1 }
Add-GameTweak 'g_bar' 'Desempenho em jogos' 'Desativar Xbox Game Bar (atalhos e pop-ups)' 'Impede pop-ups e atalhos da Game Bar durante os jogos. A captura em segundo plano é desativada no ajuste de Game DVR.' $true {
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'ShowStartupPanel' 0
} {
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 1
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'ShowStartupPanel' 1
}
Add-GameTweak 'g_windowed' 'Desempenho em jogos' 'Otimizações para jogos em janela' 'Ativa o "SwapEffectUpgrade": jogos DX10/11 em janela ou sem borda usam o modo de apresentação moderno (menos latência).' $true {
    $cur = [string](Get-HkcuValue $script:SubGpu 'DirectXUserGlobalSettings')
    if ($cur -match 'SwapEffectUpgradeEnable=\d;') { $new = $cur -replace 'SwapEffectUpgradeEnable=\d;', 'SwapEffectUpgradeEnable=1;' } else { $new = $cur + 'SwapEffectUpgradeEnable=1;' }
    Set-HkcuString $script:SubGpu 'DirectXUserGlobalSettings' $new
} {
    $cur = [string](Get-HkcuValue $script:SubGpu 'DirectXUserGlobalSettings')
    $new = $cur -replace 'SwapEffectUpgradeEnable=\d;', ''
    if ($new) { Set-HkcuString $script:SubGpu 'DirectXUserGlobalSettings' $new } else { Remove-HkcuValue $script:SubGpu 'DirectXUserGlobalSettings' }
}
Add-GameTweak 'g_mmcss' 'Desempenho em jogos' 'Prioridade multimídia para jogos (MMCSS)' 'SystemResponsiveness = 0 e perfil "Games" com prioridade de CPU/GPU/disco alta.' $true {
    $sp = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    Set-Reg $sp 'SystemResponsiveness' 0
    $g = "$sp\Tasks\Games"
    Set-Reg $g 'GPU Priority' 8
    Set-Reg $g 'Priority' 6
    Set-Reg $g 'Scheduling Category' 'High' 'String'
    Set-Reg $g 'SFIO Priority' 'High' 'String'
} {
    $sp = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    Set-Reg $sp 'SystemResponsiveness' 20
    $g = "$sp\Tasks\Games"
    Set-Reg $g 'GPU Priority' 8
    Set-Reg $g 'Priority' 2
    Set-Reg $g 'Scheduling Category' 'Medium' 'String'
    Set-Reg $g 'SFIO Priority' 'Normal' 'String'
}
Add-GameTweak 'g_throttle' 'Desempenho em jogos' 'Desativar Power Throttling' 'Impede o Windows de reduzir a velocidade da CPU para processos em segundo plano (jogos e launchers).' $true {
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1
} { Remove-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' }
Add-GameTweak 'g_timer' 'Desempenho em jogos' 'Resolução de timer global (Windows 11 22H2+)' 'Restaura o comportamento global da resolução do timer: frametimes mais estáveis em alguns jogos. Aumenta um pouco o consumo de energia.' (-not $script:IsLaptop) {
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 1
} { Remove-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' }
Copy-Tweak 'power'  'Desempenho em jogos'
Copy-Tweak 'prio'   'Desempenho em jogos' $true
Copy-Tweak 'gamedvr' 'Desempenho em jogos'
Copy-Tweak 'bgapps' 'Desempenho em jogos'

# ---- Rede e latencia
Add-GameTweak 'g_nethrottle' 'Rede e latência' 'Remover limitação de rede multimídia' 'NetworkThrottlingIndex desativado: o Windows deixa de limitar pacotes de rede enquanto há multimídia/jogo em execução.' $true {
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' 0xFFFFFFFF
} { Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' 10 }
Add-GameTweak 'g_nagle' 'Rede e latência' 'Desativar algoritmo de Nagle (menor ping em jogos online)' 'TcpAckFrequency = 1 e TCPNoDelay = 1 em todas as interfaces de rede: envia pacotes pequenos imediatamente.' $true {
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
    foreach ($k in @(Get-ChildItem $base -ErrorAction SilentlyContinue)) { Set-Reg $k.PSPath 'TcpAckFrequency' 1; Set-Reg $k.PSPath 'TCPNoDelay' 1 }
} {
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
    foreach ($k in @(Get-ChildItem $base -ErrorAction SilentlyContinue)) { Remove-Reg $k.PSPath 'TcpAckFrequency'; Remove-Reg $k.PSPath 'TCPNoDelay' }
}
Copy-Tweak 'delivopt' 'Rede e latência'

# ---- CPU, energia e perifericos
Add-GameTweak 'g_park' 'CPU, energia e periféricos' 'Desativar estacionamento de núcleos da CPU' 'Mantém todos os núcleos ativos no plano de energia atual (CPMINCORES = 100%). Aumenta calor/consumo - evite em notebook.' (-not $script:IsLaptop) {
    powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR CPMINCORES 100 | Out-Null
    powercfg /setactive SCHEME_CURRENT | Out-Null
} {
    powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR CPMINCORES 10 | Out-Null
    powercfg /setactive SCHEME_CURRENT | Out-Null
}
Add-GameTweak 'g_usb' 'CPU, energia e periféricos' 'Desativar suspensão seletiva de USB' 'Evita que mouse, teclado e controles USB "adormeçam" (travadinhas e desconexões).' (-not $script:IsLaptop) {
    powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 | Out-Null
    powercfg /setactive SCHEME_CURRENT | Out-Null
} {
    powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 1 | Out-Null
    powercfg /setactive SCHEME_CURRENT | Out-Null
}
Add-GameTweak 'g_mouse' 'CPU, energia e periféricos' 'Desativar aceleração do mouse (precisão do ponteiro)' 'Movimento 1:1 do mouse, essencial em FPS. Aplica por completo após sair e entrar na conta.' $true {
    Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
    Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
    Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String'
} {
    Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '1' 'String'
    Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '6' 'String'
    Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '10' 'String'
}
Add-GameTweak 'g_sticky' 'CPU, energia e periféricos' 'Desativar atalhos de Teclas de Aderência/Filtro' 'Acaba com o pop-up que aparece ao apertar Shift 5x ou segurar Shift no meio do jogo.' $true {
    Set-Reg 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String'
    Set-Reg 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '122' 'String'
    Set-Reg 'HKCU:\Control Panel\Accessibility\ToggleKeys' 'Flags' '58' 'String'
} {
    Set-Reg 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '510' 'String'
    Set-Reg 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '126' 'String'
    Set-Reg 'HKCU:\Control Panel\Accessibility\ToggleKeys' 'Flags' '62' 'String'
}

# ---- Avancado
Add-GameTweak 'g_fso' 'Avançado (leia antes de ativar)' 'Desativar otimizações de tela cheia (global)' 'Força o modo tela cheia exclusiva em todos os jogos. Alguns jogos funcionam melhor com a otimização padrão - prefira o ajuste por jogo.' $false {
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 2
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_HonorUserFSEBehaviorMode' 1
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehavior' 2
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible' 1
} {
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 0
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_HonorUserFSEBehaviorMode' 0
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehavior' 0
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible' 0
}
Add-GameTweak 'g_vbs' 'Avançado (leia antes de ativar)' 'Desativar Integridade de Memória (VBS/HVCI)' 'Pode render mais FPS em CPUs antigas, mas REDUZ a segurança do sistema contra malware de kernel. Requer reiniciar.' $false {
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0
} { Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 1 }

# ================================================================ TEMA / UI  -  WinDebloat Xerife Tech
$script:AppName    = 'WinDebloat Xerife Tech'
$script:AppVersion = '2.0'

function Get-Col { param([string]$Hex) [System.Drawing.ColorTranslator]::FromHtml($Hex) }
$script:Pal = @{
    Bg        = Get-Col '#F2F7FD'
    Side      = Get-Col '#E8F1FC'
    SideHover = Get-Col '#D6E7FB'
    Card      = Get-Col '#FFFFFF'
    Border    = Get-Col '#D3E2F5'
    Accent    = Get-Col '#2F8CFF'
    AccentDk  = Get-Col '#1A6FE0'
    AccentLt  = Get-Col '#E2EFFF'
    AccentHv  = Get-Col '#CFE3FF'
    Cyan      = Get-Col '#22C1F1'
    Text      = Get-Col '#1B2B41'
    NavText   = Get-Col '#3C5675'
    Muted     = Get-Col '#6A7E98'
    Ok        = Get-Col '#14855C'
    OkLt      = Get-Col '#E1F6EC'
    Danger    = Get-Col '#E5484D'
    DangerHv  = Get-Col '#C93A3F'
    GroupBg   = Get-Col '#F0F6FE'
}
$script:FontUI       = New-Object System.Drawing.Font('Segoe UI', 9.5)
$script:FontSemi     = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$script:FontSmall    = New-Object System.Drawing.Font('Segoe UI', 8.75)
$script:FontTitle    = New-Object System.Drawing.Font('Segoe UI Semibold', 18)
$script:FontBrand    = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
$script:FontBrandSub = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
$script:FontIcon     = New-Object System.Drawing.Font('Segoe MDL2 Assets', 13)
$script:FontMono     = New-Object System.Drawing.Font('Consolas', 9)
$script:Tip = New-Object System.Windows.Forms.ToolTip
$script:SearchBoxes = New-Object System.Collections.ArrayList

try {
    Add-Type -Namespace XT -Name Native -MemberDefinition '[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);'
} catch {}

# ---------------------------------------------------------------- helpers visuais
function Set-DoubleBuffer {
    param($Ctrl)
    try { $Ctrl.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($Ctrl, $true, $null) } catch {}
}
function Set-Focusable {
    param($Ctrl)
    try { [void]$Ctrl.GetType().GetMethod('SetStyle', [System.Reflection.BindingFlags]'Instance,NonPublic').Invoke($Ctrl, @([System.Windows.Forms.ControlStyles]::Selectable, $true)) } catch {}
}

$script:RoundHandler = {
    param($s, $e)
    if ($s.Width -lt 20 -or $s.Height -lt 20) { return }
    $d = 16
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc(0, 0, $d, $d, 180, 90)
    $p.AddArc($s.Width - $d, 0, $d, $d, 270, 90)
    $p.AddArc($s.Width - $d, $s.Height - $d, $d, $d, 0, 90)
    $p.AddArc(0, $s.Height - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    $s.Region = New-Object System.Drawing.Region($p)
    $p.Dispose()
}
function Set-Rounded { param($Ctrl) $Ctrl.Add_SizeChanged($script:RoundHandler); & $script:RoundHandler $Ctrl $null }

$script:CardPaint = {
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $d = 16; $w = $s.Width - 1; $h = $s.Height - 1
    if ($w -lt 20 -or $h -lt 20) { return }
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc(0, 0, $d, $d, 180, 90)
    $p.AddArc($w - $d, 0, $d, $d, 270, 90)
    $p.AddArc($w - $d, $h - $d, $d, $d, 0, 90)
    $p.AddArc(0, $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    $pen = New-Object System.Drawing.Pen($script:Pal.Border, 1)
    $g.DrawPath($pen, $p)
    $pen.Dispose(); $p.Dispose()
}
function Set-Card { param($Ctrl) Set-Rounded $Ctrl; $Ctrl.Add_Paint($script:CardPaint) }

$script:LineBottomPaint = {
    param($s, $e)
    $pen = New-Object System.Drawing.Pen($script:Pal.Border, 1)
    $e.Graphics.DrawLine($pen, 0, $s.Height - 1, $s.Width, $s.Height - 1)
    $pen.Dispose()
}
$script:LineRightPaint = {
    param($s, $e)
    $pen = New-Object System.Drawing.Pen($script:Pal.Border, 1)
    $e.Graphics.DrawLine($pen, $s.Width - 1, 0, $s.Width - 1, $s.Height)
    $pen.Dispose()
}

function New-LogoBitmap {
    param([int]$Size = 64)
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $rect = New-Object System.Drawing.Rectangle(0, 0, $Size, $Size)
    $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $script:Pal.Cyan, $script:Pal.AccentDk, [single]45)
    $g.FillEllipse($br, 1, 1, ($Size - 2), ($Size - 2))
    $cx = $Size / 2.0; $cy = $Size / 2.0
    $ro = $Size * 0.33; $ri = $Size * 0.15
    $pts = New-Object 'System.Drawing.PointF[]' 12
    for ($i = 0; $i -lt 12; $i++) {
        $a = [math]::PI * $i / 6 - [math]::PI / 2
        $r = $ri
        if ($i % 2 -eq 0) { $r = $ro }
        $pts[$i] = New-Object System.Drawing.PointF([single]($cx + $r * [math]::Cos($a)), [single]($cy + $r * [math]::Sin($a)))
    }
    $g.FillPolygon([System.Drawing.Brushes]::White, $pts)
    $dot = [math]::Max(2.0, $Size * 0.055)
    for ($i = 0; $i -lt 12; $i += 2) {
        $a = [math]::PI * $i / 6 - [math]::PI / 2
        $x = $cx + $ro * [math]::Cos($a); $y = $cy + $ro * [math]::Sin($a)
        $g.FillEllipse([System.Drawing.Brushes]::White, [single]($x - $dot), [single]($y - $dot), [single](2 * $dot), [single](2 * $dot))
    }
    $g.Dispose(); $br.Dispose()
    return $bmp
}

function New-Btn {
    param([string]$Text, [string]$Kind = 'ghost', [int]$Width = 150, [int]$Height = 36)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Width = $Width; $b.Height = $Height
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
    $b.UseVisualStyleBackColor = $false
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Font = $script:FontSemi
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
    switch ($Kind) {
        'primary' { $b.BackColor = $script:Pal.Accent;   $b.ForeColor = [System.Drawing.Color]::White; $b.FlatAppearance.MouseOverBackColor = $script:Pal.AccentDk; $b.FlatAppearance.MouseDownBackColor = $script:Pal.AccentDk }
        'danger'  { $b.BackColor = $script:Pal.Danger;   $b.ForeColor = [System.Drawing.Color]::White; $b.FlatAppearance.MouseOverBackColor = $script:Pal.DangerHv; $b.FlatAppearance.MouseDownBackColor = $script:Pal.DangerHv }
        default   { $b.BackColor = $script:Pal.AccentLt; $b.ForeColor = $script:Pal.AccentDk;          $b.FlatAppearance.MouseOverBackColor = $script:Pal.AccentHv; $b.FlatAppearance.MouseDownBackColor = $script:Pal.AccentHv }
    }
    Set-Rounded $b
    return $b
}

# Botao que executa a acao com a interface bloqueada (Invoke-Busy)
$script:ActionClick = { param($s, $e) Invoke-Busy $s.Tag }
function Invoke-Busy {
    param([scriptblock]$Action)
    $script:Content.Enabled = $false; $script:Side.Enabled = $false
    try { & $Action }
    catch { Write-Log "  ! Erro: $($_.Exception.Message)" }
    finally { Set-Progress 0; $script:Content.Enabled = $true; $script:Side.Enabled = $true }
}
function New-ActBtn {
    param([string]$Text, [string]$Kind, [int]$Width, [scriptblock]$Handler)
    $b = New-Btn $Text $Kind $Width
    $b.Tag = $Handler
    $b.Add_Click($script:ActionClick)
    return $b
}

function Set-Progress {
    param([int]$Value)
    if ($script:pbFill -and $script:pbTrack) {
        $v = [math]::Max(0, [math]::Min(100, $Value))
        $script:pbFill.Width = [int]($script:pbTrack.Width * $v / 100)
        [System.Windows.Forms.Application]::DoEvents()
    }
}

# ---------------------------------------------------------------- lista de itens com checkbox (cards)
$script:RowPaint = {
    param($s, $e)
    $pen = New-Object System.Drawing.Pen($script:Pal.Border, 1)
    $e.Graphics.DrawLine($pen, 0, $s.Height - 1, $s.Width, $s.Height - 1)
    $pen.Dispose()
}
$script:LabelToggle = { param($s, $e) $s.Tag.Checked = -not $s.Tag.Checked }
$script:ListEnter = {
    param($s, $e)
    if (-not ($script:Form.ActiveControl -is [System.Windows.Forms.TextBox])) { [void]$s.Focus() }
}

function New-CheckList {
    $card = New-Object System.Windows.Forms.Panel
    $card.Dock = 'Fill'; $card.BackColor = $script:Pal.Card
    $card.Padding = New-Object System.Windows.Forms.Padding(2)
    Set-Card $card
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = 'Fill'; $panel.AutoScroll = $true; $panel.BackColor = $script:Pal.Card
    Set-DoubleBuffer $panel
    Set-Focusable $panel
    $panel.Add_MouseEnter($script:ListEnter)
    $card.Controls.Add($panel)
    return @{ Card = $card; Panel = $panel; Rows = (New-Object System.Collections.ArrayList); Filter = '' }
}

function Add-GroupHeader {
    param($List, [string]$Text)
    $row = New-Object System.Windows.Forms.Panel
    $row.Dock = 'Top'; $row.Height = 34; $row.BackColor = $script:Pal.GroupBg
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Dock = 'Fill'; $lbl.Text = $Text.ToUpper(); $lbl.UseMnemonic = $false
    $lbl.Font = $script:FontBrandSub; $lbl.ForeColor = $script:Pal.AccentDk
    $lbl.Padding = New-Object System.Windows.Forms.Padding(16, 0, 0, 0); $lbl.TextAlign = 'MiddleLeft'
    $row.Controls.Add($lbl)
    $List.Panel.Controls.Add($row); $row.BringToFront()
    [void]$List.Rows.Add([pscustomobject]@{ Header = $true; Row = $row; Check = $null; Title = $Text; Desc = ''; Data = $null; Right = $null; Shown = $true })
}

function Add-CheckRow {
    param($List, [string]$Title, [string]$Desc, [bool]$Checked, $Data, [string]$Right = '', $RightColor = $null)
    $row = New-Object System.Windows.Forms.Panel
    $row.Dock = 'Top'; $row.Height = 54; $row.BackColor = $script:Pal.Card
    $row.Padding = New-Object System.Windows.Forms.Padding(0, 0, 0, 1)
    $row.Add_Paint($script:RowPaint)

    $body = New-Object System.Windows.Forms.Panel
    $body.Dock = 'Fill'; $body.BackColor = $script:Pal.Card
    $body.Padding = New-Object System.Windows.Forms.Padding(14, 6, 0, 0)

    $lblDesc = New-Object System.Windows.Forms.Label
    $lblDesc.Dock = 'Fill'; $lblDesc.Text = $Desc; $lblDesc.UseMnemonic = $false
    $lblDesc.Font = $script:FontSmall; $lblDesc.ForeColor = $script:Pal.Muted
    $lblDesc.Padding = New-Object System.Windows.Forms.Padding(22, 0, 8, 0)
    $lblDesc.AutoEllipsis = $true; $lblDesc.TextAlign = 'TopLeft'

    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Dock = 'Top'; $chk.Height = 24; $chk.Text = $Title.Replace('&', '&&')
    $chk.Font = $script:FontSemi; $chk.ForeColor = $script:Pal.Text
    $chk.Checked = $Checked; $chk.Cursor = [System.Windows.Forms.Cursors]::Hand

    $lblRight = New-Object System.Windows.Forms.Label
    $lblRight.Dock = 'Right'; $lblRight.Width = 190; $lblRight.Text = $Right; $lblRight.UseMnemonic = $false
    $lblRight.Font = $script:FontSemi; $lblRight.TextAlign = 'MiddleRight'
    $lblRight.Padding = New-Object System.Windows.Forms.Padding(0, 0, 16, 0)
    if ($RightColor) { $lblRight.ForeColor = $RightColor } else { $lblRight.ForeColor = $script:Pal.Muted }

    $lblDesc.Tag = $chk; $lblDesc.Add_Click($script:LabelToggle)
    $lblRight.Tag = $chk; $lblRight.Add_Click($script:LabelToggle)
    $script:Tip.SetToolTip($lblDesc, $Desc)

    $body.Controls.Add($lblDesc)
    $body.Controls.Add($chk)
    $row.Controls.Add($body)
    $row.Controls.Add($lblRight)
    $List.Panel.Controls.Add($row); $row.BringToFront()
    [void]$List.Rows.Add([pscustomobject]@{ Header = $false; Row = $row; Check = $chk; Title = $Title; Desc = $Desc; Data = $Data; Right = $lblRight; Shown = $true })
}

function Clear-List {
    param($List)
    $List.Panel.SuspendLayout()
    foreach ($r in @($List.Rows)) { $List.Panel.Controls.Remove($r.Row); $r.Row.Dispose() }
    $List.Rows.Clear()
    $List.Panel.ResumeLayout($true)
}

function Update-ListLayout {
    param($List, [string]$Filter = '')
    $List.Filter = $Filter
    $List.Panel.SuspendLayout()
    $hdr = $null; $hdrShown = $false
    foreach ($r in $List.Rows) {
        if ($r.Header) { $hdr = $r; $hdrShown = $false; $r.Shown = $false; $r.Row.Visible = $false; continue }
        $show = ($Filter -eq '') -or ($r.Title.IndexOf($Filter, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or ($r.Desc.IndexOf($Filter, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
        $r.Shown = $show
        $r.Row.Visible = $show
        if ($show -and $hdr -and -not $hdrShown) { $hdr.Row.Visible = $true; $hdr.Shown = $true; $hdrShown = $true }
    }
    $List.Panel.ResumeLayout($true)
}
function Set-ListChecked { param($List, [bool]$Value) foreach ($r in $List.Rows) { if (-not $r.Header -and $r.Shown) { $r.Check.Checked = $Value } } }
function Get-CheckedRows { param($List) @($List.Rows | Where-Object { (-not $_.Header) -and $_.Shown -and $_.Check.Checked }) }

# ---------------------------------------------------------------- blocos de pagina
function New-PageHost {
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = 'Fill'; $p.Visible = $false; $p.BackColor = $script:Pal.Bg
    return $p
}
function New-Banner {
    param([string]$Text, [int]$Height = 62)
    $wrap = New-Object System.Windows.Forms.Panel
    $wrap.Dock = 'Top'; $wrap.Height = $Height + 12; $wrap.Padding = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Dock = 'Fill'; $lbl.Text = $Text; $lbl.UseMnemonic = $false
    $lbl.BackColor = $script:Pal.AccentLt; $lbl.ForeColor = $script:Pal.AccentDk; $lbl.Font = $script:FontUI
    $lbl.Padding = New-Object System.Windows.Forms.Padding(16, 0, 16, 0); $lbl.TextAlign = 'MiddleLeft'
    Set-Rounded $lbl
    $wrap.Controls.Add($lbl)
    return @{ Wrap = $wrap; Label = $lbl }
}
function New-Toolbar {
    $f = New-Object System.Windows.Forms.FlowLayoutPanel
    $f.Dock = 'Top'; $f.Height = 48; $f.WrapContents = $false; $f.FlowDirection = 'LeftToRight'; $f.AutoScroll = $false
    $f.BackColor = $script:Pal.Bg; $f.Padding = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
    return $f
}
function New-SearchBox {
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Width = 220; $tb.Font = $script:FontUI; $tb.BorderStyle = 'FixedSingle'
    $tb.Margin = New-Object System.Windows.Forms.Padding(0, 4, 14, 0)
    [void]$script:SearchBoxes.Add($tb)
    return $tb
}
function New-Footer {
    param([string]$PrimaryText, [scriptblock]$Handler, [int]$PrimaryWidth = 230)
    $foot = New-Object System.Windows.Forms.Panel
    $foot.Dock = 'Bottom'; $foot.Height = 62; $foot.BackColor = $script:Pal.Bg
    $left = New-Object System.Windows.Forms.FlowLayoutPanel
    $left.Dock = 'Fill'; $left.WrapContents = $false; $left.Padding = New-Object System.Windows.Forms.Padding(0, 13, 0, 0)
    $wrap = New-Object System.Windows.Forms.Panel
    $wrap.Dock = 'Right'; $wrap.Width = $PrimaryWidth + 10; $wrap.Padding = New-Object System.Windows.Forms.Padding(10, 10, 0, 10)
    $btn = New-ActBtn $PrimaryText 'primary' $PrimaryWidth $Handler
    $btn.Dock = 'Fill'
    $wrap.Controls.Add($btn)
    $foot.Controls.Add($left)
    $foot.Controls.Add($wrap)
    return @{ Foot = $foot; Left = $left; Button = $btn }
}
function New-FootCheck {
    param([string]$Text, [bool]$Checked)
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $Text; $c.Checked = $Checked; $c.AutoSize = $true; $c.Font = $script:FontUI; $c.ForeColor = $script:Pal.Text
    $c.Margin = New-Object System.Windows.Forms.Padding(0, 7, 22, 0)
    return $c
}

function Add-ActionCard {
    param($Parent, [string]$Title, [string]$Desc, [string]$BtnText, [scriptblock]$Handler)
    $wrap = New-Object System.Windows.Forms.Panel
    $wrap.Dock = 'Top'; $wrap.Height = 82; $wrap.Padding = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $card = New-Object System.Windows.Forms.Panel
    $card.Dock = 'Fill'; $card.BackColor = $script:Pal.Card
    Set-Card $card
    $bw = New-Object System.Windows.Forms.Panel
    $bw.Dock = 'Right'; $bw.Width = 200; $bw.BackColor = $script:Pal.Card; $bw.Padding = New-Object System.Windows.Forms.Padding(0, 17, 20, 17)
    $btn = New-ActBtn $BtnText 'ghost' 170 $Handler
    $btn.Dock = 'Fill'
    $bw.Controls.Add($btn)
    $lblT = New-Object System.Windows.Forms.Label
    $lblT.AutoSize = $true; $lblT.Location = New-Object System.Drawing.Point(20, 14); $lblT.Text = $Title; $lblT.UseMnemonic = $false
    $lblT.Font = $script:FontSemi; $lblT.ForeColor = $script:Pal.Text
    $lblD = New-Object System.Windows.Forms.Label
    $lblD.AutoSize = $true; $lblD.Location = New-Object System.Drawing.Point(20, 38); $lblD.Text = $Desc; $lblD.UseMnemonic = $false
    $lblD.Font = $script:FontSmall; $lblD.ForeColor = $script:Pal.Muted
    $card.Controls.Add($lblT); $card.Controls.Add($lblD); $card.Controls.Add($bw)
    $wrap.Controls.Add($card)
    $Parent.Controls.Add($wrap); $wrap.BringToFront()
}

# ---------------------------------------------------------------- execucao de ajustes (Otimizacao / Jogos)
function Invoke-TweakList {
    param($List, [string]$Mode)
    $sel = @(Get-CheckedRows $List)
    if ($sel.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Nenhum ajuste marcado.', $script:AppName, 'OK', 'Information'); return }
    if ($Mode -eq 'Aplicar') { New-RestorePoint }
    $needExplorer = $false; $i = 0
    foreach ($row in $sel) {
        $t = $row.Data
        Write-Log ("{0}: {1}" -f $Mode, $t.Name)
        try {
            if ($Mode -eq 'Aplicar') { & $t.Apply } else { & $t.Undo }
            if ($t.Explorer) { $needExplorer = $true }
        } catch { Write-Log "  ! Erro: $($_.Exception.Message)" }
        $i++; Set-Progress ([int](100 * $i / $sel.Count))
    }
    Write-Log "$Mode concluído ($($sel.Count) ajuste(s))."
    if ($needExplorer) {
        $r = [System.Windows.Forms.MessageBox]::Show('Alguns ajustes exigem reiniciar o Explorer (a barra de tarefas pisca rapidamente). Reiniciar agora?', $script:AppName, 'YesNo', 'Question')
        if ($r -eq 'Yes') { Restart-Explorer }
    }
    [void][System.Windows.Forms.MessageBox]::Show('Concluído! Reinicie o computador para aplicar tudo por completo.', $script:AppName, 'OK', 'Information')
}

# ================================================================ CONSTRUCAO DA JANELA
$script:LogoSmall = New-LogoBitmap 92

$form = New-Object System.Windows.Forms.Form
$script:Form = $form
$form.Text = $script:AppName
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(1160, 820)
$form.MinimumSize = New-Object System.Drawing.Size(1060, 740)
$form.BackColor = $script:Pal.Bg
$form.Font = $script:FontUI
try { $form.Icon = [System.Drawing.Icon]::FromHandle((New-LogoBitmap 48).GetHicon()) } catch {}

# ---------- Barra lateral
$script:Side = New-Object System.Windows.Forms.Panel
$script:Side.Dock = 'Left'; $script:Side.Width = 236; $script:Side.BackColor = $script:Pal.Side; $script:Side.Padding = New-Object System.Windows.Forms.Padding(0, 0, 1, 0)
$script:Side.Add_Paint($script:LineRightPaint)

$navHost = New-Object System.Windows.Forms.Panel
$navHost.Dock = 'Fill'; $navHost.BackColor = $script:Pal.Side; $navHost.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)

$sideBottom = New-Object System.Windows.Forms.Panel
$sideBottom.Dock = 'Bottom'; $sideBottom.Height = 84; $sideBottom.BackColor = $script:Pal.Side
$script:lblSys = New-Object System.Windows.Forms.Label
$script:lblSys.Dock = 'Fill'; $script:lblSys.Font = $script:FontSmall; $script:lblSys.ForeColor = $script:Pal.Muted
$script:lblSys.Padding = New-Object System.Windows.Forms.Padding(20, 10, 8, 8); $script:lblSys.TextAlign = 'BottomLeft'; $script:lblSys.UseMnemonic = $false
$script:lblSys.Text = "Xerife Tech  |  v$($script:AppVersion)"
$sideBottom.Controls.Add($script:lblSys)

$brand = New-Object System.Windows.Forms.Panel
$brand.Dock = 'Top'; $brand.Height = 100; $brand.BackColor = $script:Pal.Side
$brand.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.TextRenderingHint = 'ClearTypeGridFit'
    $g.DrawImage($script:LogoSmall, 18, 26, 46, 46)
    $b1 = New-Object System.Drawing.SolidBrush($script:Pal.Text)
    $b2 = New-Object System.Drawing.SolidBrush($script:Pal.AccentDk)
    $g.DrawString('WinDebloat', $script:FontBrand, $b1, 70, 26)
    $g.DrawString('XERIFE TECH', $script:FontBrandSub, $b2, 72, 52)
    $b1.Dispose(); $b2.Dispose()
})

$script:PageMeta = @(
    @{ Nav = 'Debloat';      Glyph = [string][char]0xE74D; Title = 'Debloat';                 Sub = 'Remova aplicativos desnecessários do Windows 11. A Microsoft Store e seus componentes são preservados.' },
    @{ Nav = 'Limpeza';      Glyph = [string][char]0xE72C; Title = 'Limpeza do Windows';      Sub = 'Libere espaço removendo arquivos temporários, caches e restos de atualizações.' },
    @{ Nav = 'Otimização';   Glyph = [string][char]0xE713; Title = 'Otimização do sistema';   Sub = 'Ajustes de desempenho, privacidade, interface e serviços. Todos podem ser revertidos.' },
    @{ Nav = 'Jogos';        Glyph = [string][char]0xE7FC; Title = 'Modo Gamer';              Sub = 'Reduza a latência e ganhe FPS com ajustes de sistema voltados para jogos.' },
    @{ Nav = 'Por jogo';     Glyph = [string][char]0xE7F4; Title = 'Perfil por jogo';         Sub = 'Aplique GPU dedicada e desative a otimização de tela cheia em executáveis específicos.' },
    @{ Nav = 'Manutenção';   Glyph = [string][char]0xE9D9; Title = 'Manutenção';              Sub = 'Ferramentas de reparo e manutenção do Windows.' }
)
$script:NavPills = New-Object System.Collections.ArrayList
$script:ActivePage = -1
$script:NavClick = { param($s, $e) Show-Page ([int]$s.Tag) }
$script:NavEnter = { param($s, $e) if ($script:ActivePage -ne [int]$s.Tag) { $script:NavPills[[int]$s.Tag].BackColor = $script:Pal.SideHover } }
$script:NavLeave = { param($s, $e) if ($script:ActivePage -ne [int]$s.Tag) { $script:NavPills[[int]$s.Tag].BackColor = $script:Pal.Side } }

for ($i = 0; $i -lt $script:PageMeta.Count; $i++) {
    $meta = $script:PageMeta[$i]
    $navRow = New-Object System.Windows.Forms.Panel
    $navRow.Dock = 'Top'; $navRow.Height = 52; $navRow.Padding = New-Object System.Windows.Forms.Padding(14, 3, 14, 3); $navRow.BackColor = $script:Pal.Side
    $pill = New-Object System.Windows.Forms.Panel
    $pill.Dock = 'Fill'; $pill.BackColor = $script:Pal.Side; $pill.Tag = $i
    Set-Rounded $pill
    $icon = New-Object System.Windows.Forms.Label
    $icon.AutoSize = $false; $icon.Width = 34; $icon.Height = 26; $icon.Location = New-Object System.Drawing.Point(14, 11)
    $icon.Font = $script:FontIcon; $icon.Text = $meta.Glyph; $icon.TextAlign = 'MiddleCenter'; $icon.ForeColor = $script:Pal.NavText; $icon.Tag = $i
    $txt = New-Object System.Windows.Forms.Label
    $txt.AutoSize = $true; $txt.Location = New-Object System.Drawing.Point(54, 13); $txt.Font = $script:FontSemi
    $txt.Text = $meta.Nav; $txt.ForeColor = $script:Pal.NavText; $txt.Tag = $i; $txt.UseMnemonic = $false
    $pill.Controls.Add($icon); $pill.Controls.Add($txt)
    foreach ($c in @($pill, $icon, $txt)) {
        $c.Cursor = [System.Windows.Forms.Cursors]::Hand
        $c.Add_Click($script:NavClick); $c.Add_MouseEnter($script:NavEnter); $c.Add_MouseLeave($script:NavLeave)
    }
    $navRow.Controls.Add($pill)
    $navHost.Controls.Add($navRow); $navRow.BringToFront()
    [void]$script:NavPills.Add($pill)
}

$script:Side.Controls.Add($navHost)
$script:Side.Controls.Add($sideBottom)
$script:Side.Controls.Add($brand)

# ---------- Cabecalho
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'; $header.Height = 82; $header.BackColor = $script:Pal.Card; $header.Padding = New-Object System.Windows.Forms.Padding(0, 0, 0, 1)
$header.Add_Paint($script:LineBottomPaint)
$hdrText = New-Object System.Windows.Forms.Panel
$hdrText.Dock = 'Fill'; $hdrText.BackColor = $script:Pal.Card
$script:lblTitle = New-Object System.Windows.Forms.Label
$script:lblTitle.AutoSize = $true; $script:lblTitle.Location = New-Object System.Drawing.Point(28, 10); $script:lblTitle.Font = $script:FontTitle; $script:lblTitle.ForeColor = $script:Pal.Text; $script:lblTitle.UseMnemonic = $false
$script:lblSub = New-Object System.Windows.Forms.Label
$script:lblSub.AutoSize = $true; $script:lblSub.Location = New-Object System.Drawing.Point(30, 50); $script:lblSub.Font = $script:FontUI; $script:lblSub.ForeColor = $script:Pal.Muted; $script:lblSub.UseMnemonic = $false
$hdrText.Controls.Add($script:lblTitle); $hdrText.Controls.Add($script:lblSub)
$hdrPillWrap = New-Object System.Windows.Forms.Panel
$hdrPillWrap.Dock = 'Right'; $hdrPillWrap.Width = 200; $hdrPillWrap.BackColor = $script:Pal.Card; $hdrPillWrap.Padding = New-Object System.Windows.Forms.Padding(0, 26, 24, 28)
$hdrPill = New-Object System.Windows.Forms.Label
$hdrPill.Dock = 'Fill'; $hdrPill.Text = [string][char]0x25CF + ' Administrador'; $hdrPill.TextAlign = 'MiddleCenter'; $hdrPill.UseMnemonic = $false
$hdrPill.BackColor = $script:Pal.OkLt; $hdrPill.ForeColor = $script:Pal.Ok; $hdrPill.Font = $script:FontBrandSub
Set-Rounded $hdrPill
$hdrPillWrap.Controls.Add($hdrPill)
$header.Controls.Add($hdrText); $header.Controls.Add($hdrPillWrap)

# ---------- Log e progresso
$progHost = New-Object System.Windows.Forms.Panel
$progHost.Dock = 'Bottom'; $progHost.Height = 16; $progHost.BackColor = $script:Pal.Bg; $progHost.Padding = New-Object System.Windows.Forms.Padding(24, 5, 24, 5)
$script:pbTrack = New-Object System.Windows.Forms.Panel
$script:pbTrack.Dock = 'Fill'; $script:pbTrack.BackColor = $script:Pal.Border
$script:pbFill = New-Object System.Windows.Forms.Panel
$script:pbFill.Dock = 'Left'; $script:pbFill.Width = 0; $script:pbFill.BackColor = $script:Pal.Accent
$script:pbTrack.Controls.Add($script:pbFill)
$progHost.Controls.Add($script:pbTrack)

$logPanel = New-Object System.Windows.Forms.Panel
$logPanel.Dock = 'Bottom'; $logPanel.Height = 138; $logPanel.BackColor = $script:Pal.Bg; $logPanel.Padding = New-Object System.Windows.Forms.Padding(24, 0, 24, 16)
$logCard = New-Object System.Windows.Forms.Panel
$logCard.Dock = 'Fill'; $logCard.BackColor = $script:Pal.Card; $logCard.Padding = New-Object System.Windows.Forms.Padding(14, 6, 10, 10)
Set-Card $logCard
$logTitle = New-Object System.Windows.Forms.Label
$logTitle.Dock = 'Top'; $logTitle.Height = 22; $logTitle.Text = 'Registro de atividades'; $logTitle.Font = $script:FontBrandSub; $logTitle.ForeColor = $script:Pal.AccentDk; $logTitle.UseMnemonic = $false
$script:txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog.Multiline = $true; $script:txtLog.ReadOnly = $true; $script:txtLog.ScrollBars = 'Vertical'; $script:txtLog.BorderStyle = 'None'
$script:txtLog.Dock = 'Fill'; $script:txtLog.Font = $script:FontMono; $script:txtLog.BackColor = $script:Pal.Card; $script:txtLog.ForeColor = $script:Pal.Text
$logCard.Controls.Add($script:txtLog); $logCard.Controls.Add($logTitle)
$logPanel.Controls.Add($logCard)

# ---------- Conteudo
$script:Content = New-Object System.Windows.Forms.Panel
$script:Content.Dock = 'Fill'; $script:Content.BackColor = $script:Pal.Bg; $script:Content.Padding = New-Object System.Windows.Forms.Padding(24, 18, 24, 2)

# =============== Pagina 0 - DEBLOAT
$pgDebloat = New-PageHost
$script:AppList = New-CheckList
$bnDeb = New-Banner 'A Microsoft Store e seus componentes (App Installer/winget, VCLibs, .NET Native, UI.Xaml, WindowsAppRuntime), a Segurança do Windows, o Edge/WebView2 e o núcleo do sistema são PROTEGIDOS e nem aparecem na lista. Itens marcados = bloatware conhecido; apps úteis vêm desmarcados.' 64
$tbDeb = New-Toolbar
$script:tbApps = New-SearchBox
$script:tbApps.Add_TextChanged({ param($s, $e) Update-ListLayout $script:AppList $s.Text.Trim() })
$btnAppRec = New-Btn 'Recomendados' 'ghost' 130
$btnAppRec.Add_Click({ foreach ($r in $script:AppList.Rows) { if (-not $r.Header -and $r.Shown) { $r.Check.Checked = (Test-Recommended $r.Data) } } })
$btnAppAll = New-Btn 'Todos' 'ghost' 80
$btnAppAll.Add_Click({ Set-ListChecked $script:AppList $true })
$btnAppNone = New-Btn 'Nenhum' 'ghost' 90
$btnAppNone.Add_Click({ Set-ListChecked $script:AppList $false })
$btnAppReload = New-ActBtn 'Atualizar lista' 'ghost' 130 { Load-Apps }
$tbDeb.Controls.AddRange(@($script:tbApps, $btnAppRec, $btnAppAll, $btnAppNone, $btnAppReload))
$script:chkProv = New-FootCheck 'Remover também do provisionamento' $true
$script:chkRestore = New-FootCheck 'Criar ponto de restauração' $true
$footDeb = New-Footer 'Remover selecionados' {
    $sel = @(Get-CheckedRows $script:AppList)
    if ($sel.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Nenhum aplicativo marcado.', $script:AppName, 'OK', 'Information'); return }
    $r = [System.Windows.Forms.MessageBox]::Show("Remover $($sel.Count) aplicativo(s) para todos os usuários?`n`nA Microsoft Store e seus componentes serão preservados.", $script:AppName, 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    if ($script:chkRestore.Checked) { New-RestorePoint }
    $n = 0
    foreach ($row in $sel) {
        Remove-AppByName -Name $row.Data -RemoveProvisioned $script:chkProv.Checked
        $n++; Set-Progress ([int](100 * $n / $sel.Count))
    }
    Write-Log "Concluído: $n aplicativo(s) processado(s)."
    Load-Apps
}
$footDeb.Left.Controls.Add($script:chkProv); $footDeb.Left.Controls.Add($script:chkRestore)
$pgDebloat.Controls.Add($script:AppList.Card)
$pgDebloat.Controls.Add($footDeb.Foot)
$pgDebloat.Controls.Add($tbDeb)
$pgDebloat.Controls.Add($bnDeb.Wrap)

function Load-Apps {
    Write-Log 'Carregando lista de aplicativos instalados...'
    [System.Windows.Forms.Application]::DoEvents()
    $pk = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
            Where-Object { -not $_.IsFramework -and -not $_.NonRemovable -and $_.SignatureKind -ne 'System' } |
            Sort-Object Name -Unique)
    Clear-List $script:AppList
    $rec = @(); $opt = @()
    foreach ($p in $pk) {
        if (Test-Protected $p.Name) { continue }
        if (Test-Recommended $p.Name) { $rec += $p } else { $opt += $p }
    }
    $script:AppList.Panel.SuspendLayout()
    if ($rec.Count -gt 0) {
        Add-GroupHeader $script:AppList "Bloatware recomendado para remover ($($rec.Count))"
        foreach ($p in $rec) { Add-CheckRow -List $script:AppList -Title $p.Name -Desc $p.PackageFullName -Checked $true -Data $p.Name -Right 'Recomendado' -RightColor $script:Pal.AccentDk }
    }
    if ($opt.Count -gt 0) {
        Add-GroupHeader $script:AppList "Opcionais - podem ser úteis ($($opt.Count))"
        foreach ($p in $opt) { Add-CheckRow -List $script:AppList -Title $p.Name -Desc $p.PackageFullName -Checked $false -Data $p.Name -Right 'Opcional' -RightColor $script:Pal.Muted }
    }
    $script:AppList.Panel.ResumeLayout($true)
    Update-ListLayout $script:AppList $script:tbApps.Text.Trim()
    Write-Log "$($rec.Count + $opt.Count) aplicativos removíveis listados (protegidos ocultos)."
}

# =============== Pagina 1 - LIMPEZA
$pgClean = New-PageHost
$script:CleanList = New-CheckList
$bnClean = New-Banner 'Clique em "Analisar" para calcular quanto espaço pode ser recuperado. Itens que mudam o comportamento do Windows (Prefetch, itens recentes, Windows.old, WinSxS) vêm desmarcados.' 46
$script:lblClean = $bnClean.Label
$tbClean = New-Toolbar
$btnCleanAnalyze = New-ActBtn 'Analisar' 'ghost' 120 {
    $total = [double]0; $i = 0; $n = $script:CleanList.Rows.Count
    Write-Log 'Analisando espaço recuperável...'
    foreach ($r in $script:CleanList.Rows) {
        $i++
        if ($r.Header) { continue }
        $sz = Get-CleanItemSize $r.Data
        if ($sz -lt 0) { $r.Right.Text = 'variável' } else { $r.Right.Text = (Format-Size $sz); $total += $sz }
        Set-Progress ([int](100 * $i / $n))
    }
    $script:lblClean.Text = "Espaço recuperável estimado (itens medidos): $(Format-Size $total)"
    Write-Log "Análise concluída: $(Format-Size $total)"
}
$btnCleanAll = New-Btn 'Todos' 'ghost' 80
$btnCleanAll.Add_Click({ Set-ListChecked $script:CleanList $true })
$btnCleanNone = New-Btn 'Nenhum' 'ghost' 90
$btnCleanNone.Add_Click({ Set-ListChecked $script:CleanList $false })
$tbClean.Controls.AddRange(@($btnCleanAnalyze, $btnCleanAll, $btnCleanNone))
$footClean = New-Footer 'Limpar selecionados' {
    $sel = @(Get-CheckedRows $script:CleanList)
    if ($sel.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Nenhum item marcado.', $script:AppName, 'OK', 'Information'); return }
    if (@($sel | Where-Object { $_.Data.Id -eq 'winold' }).Count -gt 0) {
        $r = [System.Windows.Forms.MessageBox]::Show('Você marcou Windows.old. Depois disso NÃO será possível voltar para a versão anterior do Windows. Continuar?', $script:AppName, 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
    }
    $drive = $env:SystemDrive.TrimEnd(':')
    $freeBefore = (Get-PSDrive -Name $drive -ErrorAction SilentlyContinue).Free
    $i = 0
    foreach ($row in $sel) { Invoke-Clean $row.Data; $i++; Set-Progress ([int](100 * $i / $sel.Count)); $row.Right.Text = '-' }
    $freeAfter = (Get-PSDrive -Name $drive -ErrorAction SilentlyContinue).Free
    if ($freeBefore -and $freeAfter) { Write-Log ("Espaço livre ganho em {0}: {1}" -f $env:SystemDrive, (Format-Size ([math]::Max(0, $freeAfter - $freeBefore)))) }
    Write-Log 'Limpeza concluída.'
    $script:lblClean.Text = 'Limpeza concluída. Clique em "Analisar" para recalcular o espaço.'
}
$pgClean.Controls.Add($script:CleanList.Card)
$pgClean.Controls.Add($footClean.Foot)
$pgClean.Controls.Add($tbClean)
$pgClean.Controls.Add($bnClean.Wrap)
foreach ($c in $script:CleanItems) { Add-CheckRow -List $script:CleanList -Title $c.Name -Desc $c.Desc -Checked $c.Default -Data $c -Right '-' -RightColor $script:Pal.AccentDk }

# =============== Pagina 2 - OTIMIZACAO
$pgOpt = New-PageHost
$script:OptList = New-CheckList
$bnOpt = New-Banner 'Cada ajuste tem um botão de reverter. Um ponto de restauração é criado automaticamente antes de aplicar. Os itens marcados por padrão são os mais seguros para a maioria dos PCs.' 46
$tbOpt = New-Toolbar
$btnOptRec = New-Btn 'Recomendados' 'ghost' 130
$btnOptRec.Add_Click({ foreach ($r in $script:OptList.Rows) { if (-not $r.Header) { $r.Check.Checked = [bool]$r.Data.Default } } })
$btnOptAll = New-Btn 'Todos' 'ghost' 80
$btnOptAll.Add_Click({ Set-ListChecked $script:OptList $true })
$btnOptNone = New-Btn 'Nenhum' 'ghost' 90
$btnOptNone.Add_Click({ Set-ListChecked $script:OptList $false })
$tbOpt.Controls.AddRange(@($btnOptRec, $btnOptAll, $btnOptNone))
$footOpt = New-Footer 'Aplicar selecionados' { Invoke-TweakList $script:OptList 'Aplicar' }
$btnOptUndo = New-ActBtn 'Reverter selecionados' 'ghost' 190 { Invoke-TweakList $script:OptList 'Reverter' }
$btnOptUndo.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
$footOpt.Left.Padding = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
$footOpt.Left.Controls.Add($btnOptUndo)
$pgOpt.Controls.Add($script:OptList.Card)
$pgOpt.Controls.Add($footOpt.Foot)
$pgOpt.Controls.Add($tbOpt)
$pgOpt.Controls.Add($bnOpt.Wrap)
foreach ($g in 'Desempenho', 'Privacidade', 'Interface', 'Servicos') {
    $label = $g; if ($g -eq 'Servicos') { $label = 'Serviços' }
    Add-GroupHeader $script:OptList $label
    foreach ($t in @($script:Tweaks | Where-Object { $_.Group -eq $g })) {
        Add-CheckRow -List $script:OptList -Title $t.Name -Desc $t.Desc -Checked $t.Default -Data $t
    }
}

# =============== Pagina 3 - JOGOS (sistema)
$pgGame = New-PageHost
$script:GameList = New-CheckList
$gpuNames = ''
try { $gpuNames = (@(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join '  |  ') } catch {}
if (-not $gpuNames) { $gpuNames = 'não identificada' }
$bnGame = New-Banner ("GPU detectada: $gpuNames`nOs ajustes são reversíveis e criam um ponto de restauração antes de aplicar. Reinicie o PC depois para valer por completo. Em notebooks, alguns itens vêm desmarcados para poupar bateria.") 64
$tbGame = New-Toolbar
$btnGameRec = New-Btn 'Recomendados' 'ghost' 130
$btnGameRec.Add_Click({ foreach ($r in $script:GameList.Rows) { if (-not $r.Header) { $r.Check.Checked = [bool]$r.Data.Default } } })
$btnGameAll = New-Btn 'Todos' 'ghost' 80
$btnGameAll.Add_Click({ Set-ListChecked $script:GameList $true })
$btnGameNone = New-Btn 'Nenhum' 'ghost' 90
$btnGameNone.Add_Click({ Set-ListChecked $script:GameList $false })
$tbGame.Controls.AddRange(@($btnGameRec, $btnGameAll, $btnGameNone))
$footGame = New-Footer 'Ativar Modo Gamer' { Invoke-TweakList $script:GameList 'Aplicar' }
$btnGameUndo = New-ActBtn 'Reverter selecionados' 'ghost' 190 { Invoke-TweakList $script:GameList 'Reverter' }
$footGame.Left.Padding = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
$footGame.Left.Controls.Add($btnGameUndo)
$pgGame.Controls.Add($script:GameList.Card)
$pgGame.Controls.Add($footGame.Foot)
$pgGame.Controls.Add($tbGame)
$pgGame.Controls.Add($bnGame.Wrap)
foreach ($g in 'Desempenho em jogos', 'Rede e latência', 'CPU, energia e periféricos', 'Avançado (leia antes de ativar)') {
    Add-GroupHeader $script:GameList $g
    foreach ($t in @($script:GameTweaks | Where-Object { $_.Group -eq $g })) {
        Add-CheckRow -List $script:GameList -Title $t.Name -Desc $t.Desc -Checked $t.Default -Data $t
    }
}

# =============== Pagina 4 - POR JOGO
$pgExe = New-PageHost
$script:ExeList = New-CheckList
$bnExe = New-Banner 'Escolha o .exe do jogo e defina: usar a GPU dedicada (notebooks e PCs com 2 GPUs) e/ou desativar as otimizações de tela cheia do Windows (corrige quedas de FPS e travadas em alguns jogos).' 46
$exeCardWrap = New-Object System.Windows.Forms.Panel
$exeCardWrap.Dock = 'Top'; $exeCardWrap.Height = 202; $exeCardWrap.Padding = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
$exeCard = New-Object System.Windows.Forms.Panel
$exeCard.Dock = 'Fill'; $exeCard.BackColor = $script:Pal.Card; $exeCard.Padding = New-Object System.Windows.Forms.Padding(20, 14, 20, 10)
Set-Card $exeCard

$exeOpts = New-Object System.Windows.Forms.FlowLayoutPanel
$exeOpts.Dock = 'Top'; $exeOpts.Height = 86; $exeOpts.WrapContents = $true; $exeOpts.BackColor = $script:Pal.Card
$script:chkExeGpu = New-FootCheck 'GPU dedicada (alto desempenho)' $true
$script:chkExeFso = New-FootCheck 'Sem otimização de tela cheia' $true
$btnExeApply = New-ActBtn 'Aplicar ao jogo' 'primary' 150 {
    $exe = $script:tbExe.Text.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf) -or -not $exe.ToLower().EndsWith('.exe')) { [void][System.Windows.Forms.MessageBox]::Show('Selecione um arquivo .exe válido.', $script:AppName, 'OK', 'Warning'); return }
    if (-not $script:chkExeGpu.Checked -and -not $script:chkExeFso.Checked) { [void][System.Windows.Forms.MessageBox]::Show('Marque ao menos uma opção.', $script:AppName, 'OK', 'Information'); return }
    Write-Log "Aplicando ajustes ao jogo: $exe"
    Set-GameExeTweaks -Exe $exe -Gpu $script:chkExeGpu.Checked -Fso $script:chkExeFso.Checked
    Load-Games
}
$btnExeClear = New-ActBtn 'Remover ajustes' 'ghost' 150 {
    $exe = $script:tbExe.Text.Trim().Trim('"')
    if (-not $exe) { [void][System.Windows.Forms.MessageBox]::Show('Informe o caminho do .exe (ou marque jogos na lista abaixo).', $script:AppName, 'OK', 'Information'); return }
    Clear-GameExeTweaks -Exe $exe
    Load-Games
}
$exeOpts.Controls.AddRange(@($script:chkExeGpu, $script:chkExeFso, $btnExeApply, $btnExeClear))
$exeOpts.Controls[2].Margin = New-Object System.Windows.Forms.Padding(0, 4, 10, 0)
$exeOpts.Controls[3].Margin = New-Object System.Windows.Forms.Padding(0, 4, 10, 0)

$exePath = New-Object System.Windows.Forms.Panel
$exePath.Dock = 'Top'; $exePath.Height = 44; $exePath.BackColor = $script:Pal.Card; $exePath.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 4)
$script:tbExe = New-Object System.Windows.Forms.TextBox
$script:tbExe.Dock = 'Fill'; $script:tbExe.Font = New-Object System.Drawing.Font('Segoe UI', 11); $script:tbExe.BorderStyle = 'FixedSingle'
$exeBrowseWrap = New-Object System.Windows.Forms.Panel
$exeBrowseWrap.Dock = 'Right'; $exeBrowseWrap.Width = 150; $exeBrowseWrap.BackColor = $script:Pal.Card; $exeBrowseWrap.Padding = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
$btnExeBrowse = New-Btn 'Procurar .exe...' 'ghost' 140
$btnExeBrowse.Dock = 'Fill'
$btnExeBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Executáveis (*.exe)|*.exe'; $dlg.Title = 'Selecione o executável do jogo'
    if ($dlg.ShowDialog() -eq 'OK') { $script:tbExe.Text = $dlg.FileName }
})
$exeBrowseWrap.Controls.Add($btnExeBrowse)
$exePath.Controls.Add($script:tbExe); $exePath.Controls.Add($exeBrowseWrap)

$exeTitle = New-Object System.Windows.Forms.Label
$exeTitle.Dock = 'Top'; $exeTitle.Height = 26; $exeTitle.Text = 'Adicionar jogo'; $exeTitle.Font = $script:FontSemi; $exeTitle.ForeColor = $script:Pal.Text; $exeTitle.UseMnemonic = $false
$exeCard.Controls.Add($exeOpts); $exeCard.Controls.Add($exePath); $exeCard.Controls.Add($exeTitle)
$exeCardWrap.Controls.Add($exeCard)

$footExe = New-Footer 'Remover ajustes dos marcados' {
    $sel = @(Get-CheckedRows $script:ExeList)
    if ($sel.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Marque jogos na lista para remover os ajustes.', $script:AppName, 'OK', 'Information'); return }
    foreach ($row in $sel) { Clear-GameExeTweaks -Exe $row.Data }
    Load-Games
} 260
$btnExeReload = New-ActBtn 'Atualizar lista' 'ghost' 140 { Load-Games }
$footExe.Left.Padding = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
$footExe.Left.Controls.Add($btnExeReload)
$pgExe.Controls.Add($script:ExeList.Card)
$pgExe.Controls.Add($footExe.Foot)
$pgExe.Controls.Add($exeCardWrap)
$pgExe.Controls.Add($bnExe.Wrap)

function Load-Games {
    Clear-List $script:ExeList
    $map = Get-ConfiguredGames
    $script:ExeList.Panel.SuspendLayout()
    Add-GroupHeader $script:ExeList "Jogos com ajustes ativos ($($map.Count))"
    foreach ($k in ($map.Keys | Sort-Object)) {
        $name = [System.IO.Path]::GetFileName($k)
        Add-CheckRow -List $script:ExeList -Title $name -Desc $k -Checked $false -Data $k -Right ($map[$k] -join ' + ') -RightColor $script:Pal.AccentDk
    }
    $script:ExeList.Panel.ResumeLayout($true)
}

# =============== Pagina 5 - MANUTENCAO
$pgMaint = New-PageHost
$maintScroll = New-Object System.Windows.Forms.Panel
$maintScroll.Dock = 'Fill'; $maintScroll.AutoScroll = $true; $maintScroll.BackColor = $script:Pal.Bg
Set-DoubleBuffer $maintScroll
Set-Focusable $maintScroll
$maintScroll.Add_MouseEnter($script:ListEnter)
$pgMaint.Controls.Add($maintScroll)

Add-ActionCard $maintScroll 'Criar ponto de restauração' 'Salva um snapshot do sistema antes de mudanças.' 'Criar agora' { New-RestorePoint }
Add-ActionCard $maintScroll 'Verificar arquivos do sistema (SFC)' 'sfc /scannow - repara arquivos de sistema corrompidos.' 'Executar SFC' { Write-Log 'Executando SFC...'; [void](Invoke-External 'sfc.exe' '/scannow' $true); Write-Log 'SFC finalizado.' }
Add-ActionCard $maintScroll 'Reparar imagem do Windows (DISM)' 'DISM /RestoreHealth - repara o repositório de componentes.' 'Executar DISM' { Write-Log 'Executando DISM RestoreHealth...'; [void](Invoke-External 'dism.exe' '/Online /Cleanup-Image /RestoreHealth' $true); Write-Log 'DISM finalizado.' }
Add-ActionCard $maintScroll 'Otimizar unidade do sistema' 'SSD: TRIM  |  HDD: desfragmentação automática.' 'Otimizar' {
    $dl = $env:SystemDrive.TrimEnd(':'); Write-Log "Otimizando $dl : ..."
    [void](Invoke-External 'powershell.exe' "-NoProfile -Command `"Optimize-Volume -DriveLetter $dl -Verbose`"" $true); Write-Log 'Otimização finalizada.'
}
Add-ActionCard $maintScroll 'Resetar rede' 'Limpa DNS, redefine Winsock e a pilha IP (requer reiniciar o PC).' 'Resetar rede' {
    Write-Log 'Resetando rede...'; ipconfig /flushdns | Out-Null; netsh winsock reset | Out-Null; netsh int ip reset | Out-Null; Write-Log 'Rede resetada. Reinicie o PC.'
}
Add-ActionCard $maintScroll 'Reiniciar o Explorer' 'Recarrega a barra de tarefas e o shell do Windows.' 'Reiniciar Explorer' { Restart-Explorer }
Add-ActionCard $maintScroll 'Restaurar apps nativos' 'Re-registra apps ainda presentes no sistema. Apps removidos de vez: reinstale pela Microsoft Store.' 'Restaurar apps' {
    Write-Log 'Re-registrando apps do sistema...'
    [void](Invoke-External 'powershell.exe' "-NoProfile -Command `"Get-AppxPackage -AllUsers | ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register (Join-Path `$_.InstallLocation 'AppxManifest.xml') -ErrorAction SilentlyContinue }`"" $true)
    Write-Log 'Concluído.'
}
Add-ActionCard $maintScroll 'Abrir pasta de logs' 'Mostra o arquivo de registro desta e de outras sessões.' 'Abrir pasta' { Start-Process explorer.exe $script:AppDir }
Add-ActionCard $maintScroll 'Reiniciar o computador' 'Necessário para concluir vários ajustes (HAGS, serviços, rede).' 'Reiniciar PC' {
    $r = [System.Windows.Forms.MessageBox]::Show('Reiniciar o computador agora? Salve seus trabalhos antes.', $script:AppName, 'YesNo', 'Question')
    if ($r -eq 'Yes') { Start-Process shutdown.exe -ArgumentList '/r /t 5' -WindowStyle Hidden }
}

# ---------- Montagem final
$script:Pages = @($pgDebloat, $pgClean, $pgOpt, $pgGame, $pgExe, $pgMaint)
foreach ($p in $script:Pages) { $script:Content.Controls.Add($p) }

function Show-Page {
    param([int]$Index)
    $script:ActivePage = $Index
    for ($k = 0; $k -lt $script:Pages.Count; $k++) {
        $active = ($k -eq $Index)
        $script:Pages[$k].Visible = $active
        $pill = $script:NavPills[$k]
        if ($active) { $pill.BackColor = $script:Pal.Accent } else { $pill.BackColor = $script:Pal.Side }
        foreach ($c in $pill.Controls) { if ($active) { $c.ForeColor = [System.Drawing.Color]::White } else { $c.ForeColor = $script:Pal.NavText } }
    }
    $script:lblTitle.Text = $script:PageMeta[$Index].Title
    $script:lblSub.Text = $script:PageMeta[$Index].Sub
}

$main = New-Object System.Windows.Forms.Panel
$main.Dock = 'Fill'; $main.BackColor = $script:Pal.Bg
$main.Controls.Add($script:Content)
$main.Controls.Add($header)
$main.Controls.Add($progHost)
$main.Controls.Add($logPanel)

$form.Controls.Add($main)
$form.Controls.Add($script:Side)

$form.Add_Shown({
    Show-Page 0
    foreach ($tb in $script:SearchBoxes) { try { [void][XT.Native]::SendMessage($tb.Handle, 0x1501, [IntPtr]1, 'Buscar...') } catch {} }
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $disk = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
    $free = '?'; if ($disk) { $free = Format-Size $disk.Free }
    $build = '?'; if ($os) { $build = $os.BuildNumber }
    $script:lblSys.Text = "Windows build $build`nLivre em $($env:SystemDrive) $free`nXerife Tech  |  v$($script:AppVersion)"
    Write-Log "$($script:AppName) v$($script:AppVersion) | build $build | livre em $($env:SystemDrive): $free"
    Write-Log "Log salvo em: $script:LogFile"
    if ($os -and [int]$os.BuildNumber -lt 22000) { Write-Log 'AVISO: esta ferramenta foi feita para Windows 11 (build 22000+).' }
    Load-Games
    Load-Apps
})

[void]$form.ShowDialog()
