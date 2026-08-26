<#
    ProvisioningTool.ps1
    Interface grafica para provisionamento de maquinas Windows.
    Pode ser executado localmente ou via: irm <RAW_URL> | iex.

    Coluna esquerda: etapas gerais de provisionamento (roda tudo junto em "Executar").
    Coluna direita:  instalar programas individuais (lista hardcoded) ou remover programas
                      ja instalados na maquina, um a um.

    Logs salvos em: logs\provisionamento_<data>.log  e relatorio_<data>.txt
#>

# ============================================================
#  EXECUCAO LOCAL OU VIA "irm ... | iex"
# ============================================================
$scriptPath = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($scriptPath)) {
    $bootstrapDir = Join-Path $env:TEMP "MCNTVInstaller"
    if (-not (Test-Path $bootstrapDir)) { New-Item -Path $bootstrapDir -ItemType Directory -Force | Out-Null }
    $scriptPath = Join-Path $bootstrapDir "ProvisioningTool.ps1"
    $scriptContent = $MyInvocation.MyCommand.Definition
    [System.IO.File]::WriteAllText($scriptPath, $scriptContent, (New-Object System.Text.UTF8Encoding($false)))
}

# ============================================================
#  AUTO-ELEVACAO (garante execucao como Administrador)
# ============================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    $psi.Verb = "runas"
    try { [System.Diagnostics.Process]::Start($psi) | Out-Null } catch { Write-Host "Elevacao cancelada pelo usuario." }
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================
#  BOTAO PERSONALIZADO (script externo do GitHub)
#  Edite as duas linhas abaixo: link raw do script e o texto do botao.
# ============================================================
$CustomScriptUrl   = "https://get.activated.win"
$CustomScriptLabel = "Ativar Windows"

# ============================================================
#  LISTAS DE APLICATIVOS (hardcoded, sem JSON)
#  Edite aqui para adicionar/remover programas.
# ============================================================
$ChocoApps = @(
    "googlechrome"
)

$WingetApps = @(
    "AnyDesk.AnyDesk",
    "Adobe.Acrobat.Reader.64-bit",
    "Oracle.JavaRuntimeEnvironment",
    "Mozilla.Firefox.pt-BR",
    "7zip.7zip"
)

$WingetStoreApps = @(
    "9WZDNCRFJBMP"   # Microsoft Store app exemplo
)

# ============================================================
#  DIRETORIOS DE LOG
# ============================================================
$ScriptDir = Split-Path -Parent $scriptPath
$LogsDir   = Join-Path $ScriptDir "logs"
if (-not (Test-Path $LogsDir)) { New-Item -Path $LogsDir -ItemType Directory -Force | Out-Null }

$Timestamp   = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$LogFilePath = Join-Path $LogsDir "provisionamento_$Timestamp.log"
$ReportPath  = Join-Path $LogsDir "relatorio_$Timestamp.txt"

$script:Results = [ordered]@{}
$script:CancelRequested = $false

# ============================================================
#  FUNCOES DE CADA ETAPA
# ============================================================

function Step-RestorePoint {
    param($Log, [bool]$DryRun)
    $Log.Invoke("== Ponto de restauracao ==")
    if ($DryRun) { $Log.Invoke("[SIMULACAO] Criaria um ponto de restauracao antes das alteracoes."); return }
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "Antes do provisionamento" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
        $Log.Invoke("Ponto de restauracao criado.")
    } catch {
        $Log.Invoke("Aviso: nao foi possivel criar ponto de restauracao (pode ja existir um nas ultimas 24h, ou System Restore estar desativado). $($_.Exception.Message)")
    }
}

function Step-VersoesAnteriores {
    param($Log, [bool]$DryRun)
    $drive = $env:SystemDrive
    $Log.Invoke("== Habilitar Versoes Anteriores (Shadow Copies) em $drive ==")
    if ($DryRun) {
        $Log.Invoke("[SIMULACAO] Ativaria System Restore em $drive, reservaria 10% do volume para copias de sombra e agendaria snapshots a cada 4h.")
        return
    }
    try {
        Enable-ComputerRestore -Drive "$drive\" -ErrorAction Stop
        $Log.Invoke("System Restore ativado em $drive")
    } catch {
        $Log.Invoke("Aviso ao ativar System Restore: $($_.Exception.Message)")
    }

    $Log.Invoke("Reservando espaco para copias de sombra (10% do volume)...")
    vssadmin resize shadowstorage /for="$drive" /on="$drive" /maxsize=10% 2>&1 | ForEach-Object { $Log.Invoke($_) }

    $Log.Invoke("Criando snapshot inicial...")
    vssadmin create shadow /for="$drive" 2>&1 | ForEach-Object { $Log.Invoke($_) }

    schtasks /create /tn "VersoesAnteriores_ShadowCopy" /tr "vssadmin create shadow /for=$drive" /sc hourly /mo 4 /ru "SYSTEM" /rl highest /f | Out-Null
    $Log.Invoke("Tarefa agendada 'VersoesAnteriores_ShadowCopy' criada (snapshot a cada 4h).")
    $Log.Invoke("A partir do proximo snapshot, a aba 'Versoes Anteriores' nas propriedades de pastas em $drive vai mostrar as copias.")
}

function Step-IconesAreaTrabalho {
    param($Log, [bool]$DryRun)
    $Log.Invoke("== Icones Este Computador / Pasta do Usuario ==")
    if ($DryRun) { $Log.Invoke("[SIMULACAO] Ativaria os icones e reiniciaria o Explorer."); return }
    $path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
    New-Item -Path $path -Force | Out-Null
    New-ItemProperty -Path $path -Name "{20D04FE0-3AEA-1069-A2D8-08002B30309D}" -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path $path -Name "{59031a47-3f72-44a7-89c5-5595fe6b30ee}" -PropertyType DWord -Value 0 -Force | Out-Null
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Process explorer
    $Log.Invoke("Icones configurados e Explorer reiniciado.")
}

function Step-Telemetria {
    param($Log, [bool]$DryRun)
    $Log.Invoke("== Telemetria ==")
    if ($DryRun) { $Log.Invoke("[SIMULACAO] Desativaria a telemetria via GPO local."); return }
    $path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"
    New-Item -Path $path -Force | Out-Null
    Set-ItemProperty -Path $path -Name "AllowTelemetry" -Value 0 -Force
    $Log.Invoke("Telemetria desativada.")
}

function Step-Energia {
    param($Log, [bool]$DryRun)
    $Log.Invoke("== Plano de energia ==")
    if ($DryRun) { $Log.Invoke("[SIMULACAO] Ajustaria monitor/disco/suspensao/hibernacao para nunca desligar."); return }
    powercfg /change monitor-timeout-ac 0
    powercfg /change monitor-timeout-dc 0
    powercfg /change standby-timeout-ac 0
    powercfg /change standby-timeout-dc 0
    powercfg /change hibernate-timeout-ac 0
    powercfg /change hibernate-timeout-dc 0
    powercfg /change disk-timeout-ac 0
    powercfg /change disk-timeout-dc 0
    $Log.Invoke("Plano de energia ajustado.")
}

function Step-RegiaoIdioma {
    param($Log, [bool]$DryRun)
    $Log.Invoke("== Fuso horario e localizacao (Brasil) ==")
    if ($DryRun) { $Log.Invoke("[SIMULACAO] Definiria fuso horario de Brasilia e localizacao Brasil."); return }
    try {
        Set-TimeZone -Id "E. South America Standard Time" -ErrorAction Stop
        Set-WinHomeLocation -GeoId 76
        $Log.Invoke("Fuso horario (Brasilia) e localizacao (Brasil) definidos. Layout de teclado/idioma completo pode exigir reinicio.")
    } catch {
        $Log.Invoke("Aviso ao ajustar regiao/idioma: $($_.Exception.Message)")
    }
}

function Step-Debloat {
    param($Log, [bool]$DryRun)
    $Log.Invoke("== Remover apps padrao (usuario atual + provisionamento) ==")
    $apps = @("3dbuilder","bingweather","xboxapp","zunemusic","officehub","skypeapp")
    if ($DryRun) { $Log.Invoke("[SIMULACAO] Removeria: $($apps -join ', ')"); return }
    foreach ($a in $apps) {
        Get-AppxPackage "*$a*" -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction SilentlyContinue
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*$a*" } |
            Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
        $Log.Invoke("Removido (se existia): $a")
    }
}

function Ensure-ChocoAvailable {
    param($Log)
    if (Get-Command choco -ErrorAction SilentlyContinue) { return $true }

    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath    = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"

    if (Get-Command choco -ErrorAction SilentlyContinue) { return $true }

    $chocoBin = Join-Path $env:ProgramData "chocolatey\bin"
    if (Test-Path (Join-Path $chocoBin "choco.exe")) {
        $env:Path += ";$chocoBin"
        return $true
    }

    if ($Log) { $Log.Invoke("Chocolatey nao encontrado. Marque e execute a etapa 'Instalar/Atualizar Chocolatey' primeiro.") }
    return $false
}

function Step-Chocolatey {
    param($Log, [bool]$DryRun)
    $Log.Invoke("== Chocolatey ==")
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        $Log.Invoke("Chocolatey ja instalado, pulando.")
        return
    }
    if ($DryRun) { $Log.Invoke("[SIMULACAO] Instalaria o Chocolatey."); return }
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:Path += ";$env:ProgramData\chocolatey\bin"
    $Log.Invoke("Chocolatey instalado.")
}

function Step-WingetUpgradeAll {
    param($Log, [bool]$DryRun)
    $Log.Invoke("== Preparando winget e atualizando todos os apps instalados ==")
    if (-not $DryRun) {
        try {
            Install-PackageProvider -Name NuGet -Force -ErrorAction Stop | Out-Null
            if (-not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
                Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery -Confirm:$false -ErrorAction Stop
            }
            Repair-WinGetPackageManager -ErrorAction SilentlyContinue
            winget source update | Out-Null
        } catch {
            $Log.Invoke("Aviso ao preparar winget: $($_.Exception.Message)")
        }
    }

    if ($DryRun) { $Log.Invoke("[SIMULACAO] winget upgrade --all"); return }
    $Log.Invoke("Atualizando todos os pacotes via winget")
    winget upgrade --all --accept-source-agreements --accept-package-agreements --silent 2>&1 | ForEach-Object { $Log.Invoke($_) }
}

function Step-TarefaLimpeza {
    param($Log, [bool]$DryRun)
    $Log.Invoke("== Tarefa agendada de limpeza de disco ==")
    if ($DryRun) { $Log.Invoke("[SIMULACAO] Criaria tarefa 'LimpezaDisco' (domingos 03:00, como SYSTEM)."); return }
    schtasks /create /tn "LimpezaDisco" /tr "cleanmgr /sagerun:1" /sc weekly /d SUN /st 03:00 /ru "SYSTEM" /rl highest /f | Out-Null
    $Log.Invoke("Tarefa 'LimpezaDisco' criada/atualizada.")
}

# ============================================================
#  CATALOGO DE PROGRAMAS (construido a partir das listas hardcoded)
# ============================================================
function Build-AppCatalogLabels {
    $script:AppCatalogMap = @{}
    $labels = New-Object System.Collections.ArrayList
    foreach ($id in $ChocoApps) {
        $label = "[Choco] $id"
        $script:AppCatalogMap[$label] = @{ Manager = "choco"; Id = $id }
        [void]$labels.Add($label)
    }
    foreach ($id in $WingetApps) {
        $label = "[Winget] $id"
        $script:AppCatalogMap[$label] = @{ Manager = "winget"; Id = $id }
        [void]$labels.Add($label)
    }
    foreach ($id in $WingetStoreApps) {
        $label = "[Store] $id"
        $script:AppCatalogMap[$label] = @{ Manager = "wingetStore"; Id = $id }
        [void]$labels.Add($label)
    }
    return $labels
}

function Get-InstalledProgramsList {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and (-not $_.SystemComponent) -and $_.UninstallString } |
        Select-Object DisplayName, UninstallString, QuietUninstallString |
        Sort-Object DisplayName
}

# ============================================================
#  INTERFACE GRAFICA - MCNTV INSTALLER
# ============================================================

$ColorBackground = [System.Drawing.Color]::FromArgb(245,247,250)
$ColorSurface    = [System.Drawing.Color]::White
$ColorText       = [System.Drawing.Color]::FromArgb(35,38,42)
$ColorMuted      = [System.Drawing.Color]::FromArgb(95,102,110)
$ColorPrimary    = [System.Drawing.Color]::FromArgb(0,120,215)
$ColorSuccess    = [System.Drawing.Color]::FromArgb(40,150,90)
$ColorDanger     = [System.Drawing.Color]::FromArgb(190,55,55)
$ColorBorder     = [System.Drawing.Color]::FromArgb(210,215,222)

$FontNormal = New-Object System.Drawing.Font("Segoe UI", 9)
$FontSmall  = New-Object System.Drawing.Font("Segoe UI", 8)
$FontHeader = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$FontTitle  = New-Object System.Drawing.Font("Segoe UI Semibold", 18)
$FontButton = New-Object System.Drawing.Font("Segoe UI", 9)

$formWidth  = 1180
$formHeight = 760
$margin     = 20
$gap        = 15
$colW       = 365
$topY       = 78
$groupH     = 430
$col1X      = $margin
$col2X      = $col1X + $colW + $gap
$col3X      = $col2X + $colW + $gap

$form = New-Object System.Windows.Forms.Form
$form.Text = "MCNTV Installer - Provisionamento Windows"
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $true
$form.MinimizeBox = $true
$form.ClientSize = New-Object System.Drawing.Size($formWidth,$formHeight)
$form.BackColor = $ColorBackground
$form.Font = $FontNormal

# ---------- CABECALHO ----------
$lblMainTitle = New-Object System.Windows.Forms.Label
$lblMainTitle.Text = "MCNTV Installer"
$lblMainTitle.Font = $FontTitle
$lblMainTitle.ForeColor = $ColorText
$lblMainTitle.Location = New-Object System.Drawing.Point($margin,15)
$lblMainTitle.Size = New-Object System.Drawing.Size(500,30)
$form.Controls.Add($lblMainTitle)

$lblSubtitle = New-Object System.Windows.Forms.Label
$lblSubtitle.Text = "Instale, configure e gerencie este computador"
$lblSubtitle.Font = $FontNormal
$lblSubtitle.ForeColor = $ColorMuted
$lblSubtitle.Location = New-Object System.Drawing.Point($margin,45)
$lblSubtitle.Size = New-Object System.Drawing.Size(500,22)
$form.Controls.Add($lblSubtitle)

# ---------- GRUPO 1: ETAPAS DO SISTEMA ----------
$grpSystem = New-Object System.Windows.Forms.GroupBox
$grpSystem.Text = "1. Configuracao do sistema"
$grpSystem.Font = $FontHeader
$grpSystem.ForeColor = $ColorText
$grpSystem.Location = New-Object System.Drawing.Point($col1X,$topY)
$grpSystem.Size = New-Object System.Drawing.Size($colW,$groupH)
$form.Controls.Add($grpSystem)

$steps = [ordered]@{
    "Ponto de Restauracao"                  = { param($l,$d) Step-RestorePoint -Log $l -DryRun $d }
    "Versoes Anteriores (Shadow Copy)"      = { param($l,$d) Step-VersoesAnteriores -Log $l -DryRun $d }
    "Icones da Area de Trabalho"            = { param($l,$d) Step-IconesAreaTrabalho -Log $l -DryRun $d }
    "Desativar Telemetria"                  = { param($l,$d) Step-Telemetria -Log $l -DryRun $d }
    "Ajustar Plano de Energia"              = { param($l,$d) Step-Energia -Log $l -DryRun $d }
    "Fuso Horario / Localizacao (BR)"       = { param($l,$d) Step-RegiaoIdioma -Log $l -DryRun $d }
    "Remover Apps Padrao (Debloat)"         = { param($l,$d) Step-Debloat -Log $l -DryRun $d }
    "Instalar/Atualizar Chocolatey"         = { param($l,$d) Step-Chocolatey -Log $l -DryRun $d }
    "Atualizar Apps (winget upgrade)"       = { param($l,$d) Step-WingetUpgradeAll -Log $l -DryRun $d }
    "Criar Tarefa de Limpeza Semanal"       = { param($l,$d) Step-TarefaLimpeza -Log $l -DryRun $d }
}

$UncheckedByDefault = @("Versoes Anteriores (Shadow Copy)")
$checkboxes = @{}
$y = 35
foreach ($key in $steps.Keys) {
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $key
    $cb.Checked = -not ($UncheckedByDefault -contains $key)
    $cb.Location = New-Object System.Drawing.Point(15,$y)
    $cb.Size = New-Object System.Drawing.Size(330,22)
    $cb.Font = $FontNormal
    $cb.ForeColor = $ColorText
    $grpSystem.Controls.Add($cb)
    $checkboxes[$key] = $cb
    $y += 24
}

$chkDryRun = New-Object System.Windows.Forms.CheckBox
$chkDryRun.Text = "Modo Simulacao (dry-run)"
$chkDryRun.Location = [System.Drawing.Point]::new(15, ($y + 3))
$chkDryRun.Size = New-Object System.Drawing.Size(330,22)
$chkDryRun.ForeColor = [System.Drawing.Color]::DarkBlue
$grpSystem.Controls.Add($chkDryRun)

$btnSelAll = New-Object System.Windows.Forms.Button
$btnSelAll.Text = "Marcar todos"
$btnSelAll.Location = New-Object System.Drawing.Point(15,335)
$btnSelAll.Size = New-Object System.Drawing.Size(160,30)
$btnSelAll.Font = $FontButton
$btnSelAll.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSelAll.FlatAppearance.BorderColor = $ColorBorder
$btnSelAll.BackColor = $ColorSurface
$btnSelAll.Add_Click({ $checkboxes.Values | ForEach-Object { $_.Checked = $true } })
$grpSystem.Controls.Add($btnSelAll)

$btnSelNone = New-Object System.Windows.Forms.Button
$btnSelNone.Text = "Desmarcar todos"
$btnSelNone.Location = New-Object System.Drawing.Point(190,335)
$btnSelNone.Size = New-Object System.Drawing.Size(160,30)
$btnSelNone.Font = $FontButton
$btnSelNone.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSelNone.FlatAppearance.BorderColor = $ColorBorder
$btnSelNone.BackColor = $ColorSurface
$btnSelNone.Add_Click({ $checkboxes.Values | ForEach-Object { $_.Checked = $false } })
$grpSystem.Controls.Add($btnSelNone)

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = "Executar configuracao"
$btnRun.Location = New-Object System.Drawing.Point(15,375)
$btnRun.Size = New-Object System.Drawing.Size(335,30)
$btnRun.Font = $FontButton
$btnRun.BackColor = $ColorPrimary
$btnRun.ForeColor = [System.Drawing.Color]::White
$btnRun.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnRun.FlatAppearance.BorderSize = 0
$grpSystem.Controls.Add($btnRun)

# ---------- GRUPO 2: INSTALAR ----------
$grpInstall = New-Object System.Windows.Forms.GroupBox
$grpInstall.Text = "2. Instalar aplicativos"
$grpInstall.Font = $FontHeader
$grpInstall.ForeColor = $ColorText
$grpInstall.Location = New-Object System.Drawing.Point($col2X,$topY)
$grpInstall.Size = New-Object System.Drawing.Size($colW,$groupH)
$form.Controls.Add($grpInstall)

$lblInstallInfo = New-Object System.Windows.Forms.Label
$lblInstallInfo.Text = "Buscar:"
$lblInstallInfo.Font = $FontNormal
$lblInstallInfo.ForeColor = $ColorMuted
$lblInstallInfo.Location = New-Object System.Drawing.Point(15,32)
$lblInstallInfo.Size = New-Object System.Drawing.Size(50,22)
$grpInstall.Controls.Add($lblInstallInfo)

$txtSearchInstall = New-Object System.Windows.Forms.TextBox
$txtSearchInstall.Location = New-Object System.Drawing.Point(65,32)
$txtSearchInstall.Size = New-Object System.Drawing.Size(280,22)
$txtSearchInstall.Font = $FontNormal
$grpInstall.Controls.Add($txtSearchInstall)

$clbInstall = New-Object System.Windows.Forms.CheckedListBox
$clbInstall.Location = New-Object System.Drawing.Point(15,58)
$clbInstall.Size = New-Object System.Drawing.Size(330,290)
$clbInstall.CheckOnClick = $true
$clbInstall.Font = $FontNormal
# Preencher com todos os labels
$allLabels = Build-AppCatalogLabels
$clbInstall.Tag = $allLabels   # guarda a lista completa
foreach ($label in $allLabels) { [void]$clbInstall.Items.Add($label,$true) }
$grpInstall.Controls.Add($clbInstall)

# Evento de filtro
$txtSearchInstall.Add_TextChanged({
    $search = $txtSearchInstall.Text.Trim().ToLower()
    $clbInstall.BeginUpdate()
    $clbInstall.Items.Clear()
    $all = $clbInstall.Tag
    if ([string]::IsNullOrEmpty($search)) {
        foreach ($item in $all) { [void]$clbInstall.Items.Add($item,$true) }
    } else {
        foreach ($item in $all) {
            if ($item.ToLower().Contains($search)) {
                [void]$clbInstall.Items.Add($item,$true)
            }
        }
    }
    $clbInstall.EndUpdate()
})

$btnInstallSelected = New-Object System.Windows.Forms.Button
$btnInstallSelected.Text = "INSTALAR SELECIONADOS (Paralelo)"
$btnInstallSelected.Location = New-Object System.Drawing.Point(15,358)
$btnInstallSelected.Size = New-Object System.Drawing.Size(330,40)
$btnInstallSelected.Font = New-Object System.Drawing.Font("Segoe UI Semibold",10)
$btnInstallSelected.BackColor = $ColorSuccess
$btnInstallSelected.ForeColor = [System.Drawing.Color]::White
$btnInstallSelected.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnInstallSelected.FlatAppearance.BorderSize = 0
$grpInstall.Controls.Add($btnInstallSelected)

# ---------- GRUPO 3: REMOVER ----------
$grpUninstall = New-Object System.Windows.Forms.GroupBox
$grpUninstall.Text = "3. Gerenciar aplicativos instalados"
$grpUninstall.Font = $FontHeader
$grpUninstall.ForeColor = $ColorText
$grpUninstall.Location = New-Object System.Drawing.Point($col3X,$topY)
$grpUninstall.Size = New-Object System.Drawing.Size($colW,$groupH)
$form.Controls.Add($grpUninstall)

$lblUninstallInfo = New-Object System.Windows.Forms.Label
$lblUninstallInfo.Text = "Atualize a lista e selecione o que deseja remover:"
$lblUninstallInfo.Font = $FontNormal
$lblUninstallInfo.ForeColor = $ColorMuted
$lblUninstallInfo.Location = New-Object System.Drawing.Point(15,32)
$lblUninstallInfo.Size = New-Object System.Drawing.Size(330,22)
$grpUninstall.Controls.Add($lblUninstallInfo)

$clbUninstall = New-Object System.Windows.Forms.CheckedListBox
$clbUninstall.Location = New-Object System.Drawing.Point(15,58)
$clbUninstall.Size = New-Object System.Drawing.Size(330,270)
$clbUninstall.CheckOnClick = $true
$clbUninstall.Font = $FontNormal
$grpUninstall.Controls.Add($clbUninstall)

$btnRefreshInstalled = New-Object System.Windows.Forms.Button
$btnRefreshInstalled.Text = "Atualizar lista"
$btnRefreshInstalled.Location = New-Object System.Drawing.Point(15,340)
$btnRefreshInstalled.Size = New-Object System.Drawing.Size(160,30)
$btnRefreshInstalled.Font = $FontButton
$btnRefreshInstalled.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnRefreshInstalled.FlatAppearance.BorderColor = $ColorBorder
$btnRefreshInstalled.BackColor = $ColorSurface
$grpUninstall.Controls.Add($btnRefreshInstalled)

$btnUninstallSelected = New-Object System.Windows.Forms.Button
$btnUninstallSelected.Text = "Desinstalar selecionados"
$btnUninstallSelected.Location = New-Object System.Drawing.Point(190,340)
$btnUninstallSelected.Size = New-Object System.Drawing.Size(160,30)
$btnUninstallSelected.Font = $FontButton
$btnUninstallSelected.BackColor = $ColorDanger
$btnUninstallSelected.ForeColor = [System.Drawing.Color]::White
$btnUninstallSelected.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnUninstallSelected.FlatAppearance.BorderSize = 0
$grpUninstall.Controls.Add($btnUninstallSelected)

# ---------- ACAO PERSONALIZADA (segura) ----------
$btnCustom = New-Object System.Windows.Forms.Button
$btnCustom.Text = $CustomScriptLabel
$btnCustom.Location = New-Object System.Drawing.Point(15,380)
$btnCustom.Size = New-Object System.Drawing.Size(335,30)
$btnCustom.Font = $FontButton
$btnCustom.BackColor = $ColorSurface
$btnCustom.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnCustom.FlatAppearance.BorderColor = $ColorBorder
$grpUninstall.Controls.Add($btnCustom)

# ---------- STATUS E LOG ----------
$grpStatus = New-Object System.Windows.Forms.GroupBox
$grpStatus.Text = "Status"
$grpStatus.Font = $FontHeader
$grpStatus.ForeColor = $ColorText
$grpStatus.Location = New-Object System.Drawing.Point($margin,525)
$grpStatus.Size = New-Object System.Drawing.Size(($formWidth - ($margin*2)),205)
$form.Controls.Add($grpStatus)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(15,32)
$progressBar.Size = New-Object System.Drawing.Size(($formWidth - 70),20)
$progressBar.Minimum = 0
$grpStatus.Controls.Add($progressBar)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Pronto para instalar"
$lblStatus.Font = $FontNormal
$lblStatus.ForeColor = $ColorSuccess
$lblStatus.Location = New-Object System.Drawing.Point(15,57)
$lblStatus.Size = New-Object System.Drawing.Size(330,22)
$grpStatus.Controls.Add($lblStatus)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Location = New-Object System.Drawing.Point(15,82)
$txtLog.Size = New-Object System.Drawing.Size(($formWidth - 70),105)
$txtLog.Font = New-Object System.Drawing.Font("Consolas",8)
$txtLog.BackColor = [System.Drawing.Color]::White
$txtLog.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
$grpStatus.Controls.Add($txtLog)

# ============================================================
#  VARIAVEIS PARA BACKGROUNDWORKER
# ============================================================
$worker = $null
$logDelegate = $null

# ============================================================
#  LOGICA DE EXECUCAO COM BACKGROUNDWORKER
# ============================================================

$AppendLog = {
    param($msg)
    $line = "$msg"
    $txtLog.AppendText("$line`r`n")
    $txtLog.SelectionStart = $txtLog.Text.Length
    $txtLog.ScrollToCaret()
    Add-Content -Path $LogFilePath -Value $line -Encoding UTF8
    [System.Windows.Forms.Application]::DoEvents()
}

# Função que será executada no BackgroundWorker
function Start-Provisioning {
    param($selectedSteps, $dryRun, $logDelegate, $progressDelegate, $reportDelegate)

    $script:Results.Clear()
    $logDelegate.Invoke("Iniciando provisionamento - Modo: $(if ($dryRun) {'SIMULACAO'} else {'EXECUCAO REAL'})")
    $logDelegate.Invoke("Log completo salvo em: $LogFilePath")
    $logDelegate.Invoke("")

    $total = $selectedSteps.Count
    $current = 0
    foreach ($key in $selectedSteps) {
        if ($script:CancelRequested) {
            $logDelegate.Invoke("Cancelamento solicitado pelo usuario.")
            break
        }
        $current++
        $progressDelegate.Invoke($current, $total)
        $lblStatus.Text = "Executando: $key ..."
        try {
            & $steps[$key] $logDelegate $dryRun
            $script:Results[$key] = if ($dryRun) { "SIMULADO" } else { "OK" }
        } catch {
            $logDelegate.Invoke("ERRO em '$key': $($_.Exception.Message)")
            $script:Results[$key] = "FALHA: $($_.Exception.Message)"
        }
    }

    $logDelegate.Invoke("")
    $logDelegate.Invoke("=== Concluido ===")

    # relatorio final
    $reportLines = @()
    $reportLines += "Relatorio de Provisionamento - $Timestamp"
    $reportLines += "Modo: $(if ($dryRun) {'SIMULACAO'} else {'EXECUCAO REAL'})"
    $reportLines += ""
    foreach ($k in $script:Results.Keys) {
        $reportLines += ("{0,-45} {1}" -f $k, $script:Results[$k])
    }
    $reportLines | Set-Content -Path $ReportPath -Encoding UTF8
    $logDelegate.Invoke("Relatorio salvo em: $ReportPath")
    $reportDelegate.Invoke($ReportPath)
    $lblStatus.Text = "Provisionamento finalizado."
}

# ---------- BOTÃO EXECUTAR (UNIFICADO) ----------
$btnRun.Add_Click({
    $btnRun.Enabled = $false
    $btnSelAll.Enabled = $false
    $btnSelNone.Enabled = $false
    $txtLog.Clear()
    $script:CancelRequested = $false

    $DryRun = $chkDryRun.Checked
    $selectedSteps = $steps.Keys | Where-Object { $checkboxes[$_].Checked }

    if ($selectedSteps.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Nenhuma etapa selecionada.", "Aviso") | Out-Null
        $btnRun.Enabled = $true
        $btnSelAll.Enabled = $true
        $btnSelNone.Enabled = $true
        return
    }

    $progressBar.Maximum = $selectedSteps.Count
    $progressBar.Value = 0

    # Exibe o botão Cancelar
    $btnCancel.Visible = $true
    $btnCancel.Enabled = $true

    # Cria o worker
    $worker = New-Object System.ComponentModel.BackgroundWorker
    $worker.WorkerReportsProgress = $true
    $worker.WorkerSupportsCancellation = $true

    $worker.Add_DoWork({
        param($sender, $e)
        $logDel = $AppendLog
        $progressDel = {
            param($current, $total)
            $progressBar.Value = $current
            $sender.ReportProgress(($current / $total * 100))
        }
        $reportDel = {
            param($path)
            [System.Windows.Forms.MessageBox]::Show("Provisionamento concluido. Relatorio em:`n$path", "Finalizado") | Out-Null
        }
        Start-Provisioning -selectedSteps $selectedSteps -dryRun $DryRun -logDelegate $logDel -progressDelegate $progressDel -reportDelegate $reportDel
    })

    $worker.Add_ProgressChanged({
        # (opcional) pode atualizar o lblStatus aqui se desejar
    })

    $worker.Add_RunWorkerCompleted({
        # Restaura a interface
        $btnRun.Enabled = $true
        $btnSelAll.Enabled = $true
        $btnSelNone.Enabled = $true
        $btnCancel.Visible = $false
        $btnCancel.Enabled = $false

        if ($script:CancelRequested) {
            $lblStatus.Text = "Cancelado pelo usuario."
        } else {
            $lblStatus.Text = "Pronto."
        }
    })

    $worker.RunWorkerAsync()
})

# ---------- BOTÃO CANCELAR ----------
$btnCancel.Add_Click({
    if ($worker -and $worker.IsBusy) {
        $script:CancelRequested = $true
        $worker.CancelAsync()
        $btnCancel.Enabled = $false
        $lblStatus.Text = "Cancelando..."
    }
})

# Botão para cancelar (opcional) - adicionar um botão de cancelar no status
$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = "Cancelar"
$btnCancel.Location = New-Object System.Drawing.Point(($formWidth - 120), 57)
$btnCancel.Size = New-Object System.Drawing.Size(80, 22)
$btnCancel.Font = $FontButton
$btnCancel.BackColor = $ColorDanger
$btnCancel.ForeColor = [System.Drawing.Color]::White
$btnCancel.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnCancel.Visible = $false
$grpStatus.Controls.Add($btnCancel)

# Modificar o worker para mostrar o botão cancelar
$btnRun.Add_Click({
    # === DIAGNÓSTICO ===
    [System.Windows.Forms.MessageBox]::Show("Botão Executar foi clicado!", "Debug")
    Write-Host "Botão Executar clicado!" -ForegroundColor Green
    # === FIM DIAGNÓSTICO ===

    $btnRun.Enabled = $false
    # ... resto do código
})

$btnRun.Add_Click({
    # ... (código existente)
    $btnCancel.Visible = $true
    $btnCancel.Enabled = $true
    $worker.RunWorkerAsync()
})

$btnCancel.Add_Click({
    if ($worker -and $worker.IsBusy) {
        $script:CancelRequested = $true
        $worker.CancelAsync()
        $btnCancel.Enabled = $false
        $lblStatus.Text = "Cancelando..."
    }
})

# Ajustar o evento RunWorkerCompleted para esconder o botão cancelar
$worker.Add_RunWorkerCompleted({
    $btnCancel.Visible = $false
    $btnCancel.Enabled = $false
    # ... resto do código
})

# ============================================================
#  INSTALACAO PARALELA DE APLICATIVOS
# ============================================================
$btnInstallSelected.Add_Click({
    $selectedLabels = @($clbInstall.CheckedItems)
    if ($selectedLabels.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Selecione ao menos um programa na lista.", "Aviso") | Out-Null
        return
    }

    $btnInstallSelected.Enabled = $false
    $AppendLog.Invoke("== Instalando programas selecionados (em paralelo) ==")
    $AppendLog.Invoke("Total: $($selectedLabels.Count) aplicativos")

    $precisaChoco = $selectedLabels | Where-Object { $script:AppCatalogMap[$_].Manager -eq "choco" }
    $chocoOk = if ($precisaChoco) { Ensure-ChocoAvailable -Log $AppendLog } else { $true }

    if ($precisaChoco -and -not $chocoOk) {
        $AppendLog.Invoke("Chocolatey nao disponivel. Instale-o primeiro.")
        $btnInstallSelected.Enabled = $true
        return
    }

    $jobs = @()
    $totalJobs = $selectedLabels.Count
    $completed = 0

    # Função para instalar um app em um job
    foreach ($label in $selectedLabels) {
        $info = $script:AppCatalogMap[$label]
        if (-not $info) { continue }

        $jobScript = {
            param($manager, $id, $logDelegate)
            try {
                $output = @()
                switch ($manager) {
                    "choco" {
                        $output += "Instalando (choco): $id"
                        $result = choco install $id -y --force --ignore-checksums 2>&1
                        $output += $result
                    }
                    "winget" {
                        $output += "Instalando (winget): $id"
                        $result = winget install -e --id $id --accept-source-agreements --accept-package-agreements --silent 2>&1
                        $output += $result
                    }
                    "wingetStore" {
                        $output += "Instalando (msstore): $id"
                        $result = winget install --id $id --source msstore --accept-source-agreements --accept-package-agreements --silent 2>&1
                        $output += $result
                    }
                }
                return $output
            } catch {
                return "ERRO ao instalar $id : $($_.Exception.Message)"
            }
        }

        $job = Start-Job -ScriptBlock $jobScript -ArgumentList $info.Manager, $info.Id, $AppendLog
        $jobs += $job
    }

    # Aguardar todos os jobs completarem e coletar saídas
    while ($jobs | Where-Object { $_.State -eq 'Running' }) {
        Start-Sleep -Milliseconds 500
        # Atualizar progresso
        $running = ($jobs | Where-Object { $_.State -eq 'Running' }).Count
        $completed = $totalJobs - $running
        $lblStatus.Text = "Instalando... $completed de $totalJobs concluidos"
        $progressBar.Value = [int](($completed / $totalJobs) * 100)
        [System.Windows.Forms.Application]::DoEvents()
    }

    # Coletar resultados
    foreach ($job in $jobs) {
        $output = Receive-Job -Job $job -ErrorAction SilentlyContinue
        if ($output) {
            foreach ($line in $output) { $AppendLog.Invoke($line) }
        }
        Remove-Job -Job $job -Force
    }

    $AppendLog.Invoke("Instalacao paralela concluida.")
    $lblStatus.Text = "Instalacao concluida."
    $progressBar.Value = 0
    $btnInstallSelected.Enabled = $true
})

# ============================================================
#  BOTAO CUSTOMIZADO (seguro)
# ============================================================
$btnCustom.Add_Click({
    if ([string]::IsNullOrWhiteSpace($CustomScriptUrl) -or $CustomScriptUrl -like "*usuario/repositorio*") {
        [System.Windows.Forms.MessageBox]::Show("Edite as variaveis `$CustomScriptUrl e `$CustomScriptLabel no topo do ProvisioningTool.ps1 antes de usar este botao.", "Configure o link") | Out-Null
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Isso vai baixar e executar o script em:`n$CustomScriptUrl`n`nTem certeza que confia nesta fonte?",
        "Confirmar execucao de script remoto",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $btnCustom.Enabled = $false
    $AppendLog.Invoke("== Executando script externo: $CustomScriptLabel ==")
    $AppendLog.Invoke("URL: $CustomScriptUrl")

    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        # Baixa para um arquivo temporário
        $tempScript = Join-Path $env:TEMP "MCNTV_custom_$(Get-Random).ps1"
        (New-Object System.Net.WebClient).DownloadFile($CustomScriptUrl, $tempScript)

        # Opcional: verificar hash (descomente e substitua pelo hash esperado)
        # $hash = (Get-FileHash $tempScript -Algorithm SHA256).Hash
        # $expectedHash = "SEU_HASH_AQUI"
        # if ($hash -ne $expectedHash) { throw "Hash do script nao confere. Execucao cancelada." }

        $AppendLog.Invoke("Script baixado para $tempScript")
        # Executa com & (mais seguro que iex)
        & $tempScript 2>&1 | ForEach-Object { $AppendLog.Invoke($_) }
        $AppendLog.Invoke("Script '$CustomScriptLabel' concluido.")
        Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
    } catch {
        $AppendLog.Invoke("ERRO ao executar '$CustomScriptLabel': $($_.Exception.Message)")
    }
    $btnCustom.Enabled = $true
})

# ============================================================
#  LISTA DE INSTALADOS
# ============================================================
$script:UninstallMap = @{}

$btnRefreshInstalled.Add_Click({
    $btnRefreshInstalled.Enabled = $false
    $AppendLog.Invoke("Consultando programas instalados no registro...")
    $clbUninstall.Items.Clear()
    $script:UninstallMap = @{}
    $programs = Get-InstalledProgramsList
    foreach ($p in $programs) {
        if (-not $script:UninstallMap.ContainsKey($p.DisplayName)) {
            $cmd = if ($p.QuietUninstallString) { $p.QuietUninstallString } else { $p.UninstallString }
            $script:UninstallMap[$p.DisplayName] = $cmd
            [void]$clbUninstall.Items.Add($p.DisplayName)
        }
    }
    $AppendLog.Invoke("$($clbUninstall.Items.Count) programas encontrados.")
    $btnRefreshInstalled.Enabled = $true
})

$btnUninstallSelected.Add_Click({
    $selected = @($clbUninstall.CheckedItems)
    if ($selected.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Selecione ao menos um programa para remover.", "Aviso") | Out-Null
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Desinstalar os seguintes programas?`n`n$($selected -join "`n")",
        "Confirmar remocao",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $btnUninstallSelected.Enabled = $false
    $AppendLog.Invoke("== Desinstalando programas selecionados ==")
    foreach ($name in $selected) {
        $cmd = $script:UninstallMap[$name]
        if (-not $cmd) { continue }
        $AppendLog.Invoke("Desinstalando: $name")
        try {
            if ($cmd -match "(?i)msiexec" -and $cmd -notmatch "(?i)/qn|/quiet") {
                $cmd = "$cmd /quiet /norestart"
            }
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c $cmd" -Wait -ErrorAction Stop
            $AppendLog.Invoke("Concluido: $name")
        } catch {
            $AppendLog.Invoke("ERRO ao desinstalar '$name': $($_.Exception.Message)")
        }
    }
    $AppendLog.Invoke("Remocao concluida. Clique em 'Atualizar lista' para ver a lista atualizada.")
    $btnUninstallSelected.Enabled = $true
})

# Carregar lista de instalados ao abrir o formulário
$form.Add_Shown({
    $btnRefreshInstalled.PerformClick()
})

[void]$form.ShowDialog()
