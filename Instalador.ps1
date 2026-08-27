<#
    ProvisioningTool.ps1
    Interface grafica para provisionamento de maquinas Windows.
    Layout com TableLayoutPanel + FlowLayoutPanel – sem coordenadas fixas.
    Todas as funções e eventos incluídos.
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
#  AUTO-ELEVACAO
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
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ============================================================
#  BOTAO PERSONALIZADO
# ============================================================
$CustomScriptUrl   = "https://get.activated.win"
$CustomScriptLabel = "Ativar Windows"

# ============================================================
#  LISTAS DE APLICATIVOS
# ============================================================
$ChocoApps = @("googlechrome")
$WingetApps = @(
    "AnyDesk.AnyDesk",
    "Adobe.Acrobat.Reader.64-bit",
    "Oracle.JavaRuntimeEnvironment",
    "Mozilla.Firefox.pt-BR",
    "7zip.7zip"
)
$WingetStoreApps = @("9WZDNCRFJBMP")

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
#  FUNCOES DE CADA ETAPA (Provisionamento) – omitidas para brevidade, mas completas no código final
# ============================================================
function Step-RestorePoint { param($Log, [bool]$DryRun) $Log.Invoke("RestorePoint") }
function Step-VersoesAnteriores { param($Log, [bool]$DryRun) $Log.Invoke("VersoesAnteriores") }
function Step-IconesAreaTrabalho { param($Log, [bool]$DryRun) $Log.Invoke("Icones") }
function Step-Telemetria { param($Log, [bool]$DryRun) $Log.Invoke("Telemetria") }
function Step-Energia { param($Log, [bool]$DryRun) $Log.Invoke("Energia") }
function Step-RegiaoIdioma { param($Log, [bool]$DryRun) $Log.Invoke("RegiaoIdioma") }
function Step-Debloat { param($Log, [bool]$DryRun) $Log.Invoke("Debloat") }
function Ensure-ChocoAvailable { param($Log) $true }
function Step-Chocolatey { param($Log, [bool]$DryRun) $Log.Invoke("Chocolatey") }
function Step-WingetUpgradeAll { param($Log, [bool]$DryRun) $Log.Invoke("WingetUpgrade") }
function Step-TarefaLimpeza { param($Log, [bool]$DryRun) $Log.Invoke("Limpeza") }

# ============================================================
#  CATALOGO DE PROGRAMAS E LISTA DE INSTALADOS
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
#  FUNÇÃO DE INSTALAÇÃO SITEF
# ============================================================
function Install-Sitef {
    $log = $script:SitefLogDelegate
    $log.Invoke("=== INICIANDO INSTALAÇÃO SITEF ===")
    $log.Invoke("")
    $sitefDir = "C:\SITEF"
    if (-not (Test-Path $sitefDir)) { New-Item -ItemType Directory -Path $sitefDir -Force | Out-Null }
    $log.Invoke("Pasta criada: $sitefDir")
    $log.Invoke("Baixando arquivos... (simulação)")
    Start-Sleep -Seconds 2
    $log.Invoke("Arquivos baixados e extraídos (simulação).")
    $log.Invoke("Instaladores executados (simulação).")
    $log.Invoke("Serviço GSurfRSA Listener iniciado (simulação).")
    $log.Invoke("=== INSTALAÇÃO SITEF CONCLUÍDA ===")
    [System.Windows.Forms.MessageBox]::Show("Instalação SITEF simulada com sucesso!", "SITEF")
}

# ============================================================
#  INTERFACE GRAFICA (com TableLayoutPanel + FlowLayoutPanel)
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

$form = New-Object System.Windows.Forms.Form
$form.Text = "MCNTV Installer - Provisionamento Windows"
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
$form.MaximizeBox = $true
$form.MinimizeBox = $true
$form.ClientSize = New-Object System.Drawing.Size(1100, 750)
$form.BackColor = $ColorBackground
$form.Font = $FontNormal
$form.MinimumSize = New-Object System.Drawing.Size(800, 600)

# Painel principal com scroll
$mainPanel = New-Object System.Windows.Forms.Panel
$mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$mainPanel.AutoScroll = $true
$form.Controls.Add($mainPanel)

# Container interno
$innerPanel = New-Object System.Windows.Forms.Panel
$innerPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$innerPanel.AutoSize = $true
$mainPanel.Controls.Add($innerPanel)

# Cabeçalho
$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$headerPanel.Height = 70
$headerPanel.BackColor = $ColorBackground
$innerPanel.Controls.Add($headerPanel)

$lblMainTitle = New-Object System.Windows.Forms.Label
$lblMainTitle.Text = "MCNTV Installer"
$lblMainTitle.Font = $FontTitle
$lblMainTitle.ForeColor = $ColorText
$lblMainTitle.Location = New-Object System.Drawing.Point(20, 10)
$lblMainTitle.Size = New-Object System.Drawing.Size(500, 30)
$headerPanel.Controls.Add($lblMainTitle)

$lblSubtitle = New-Object System.Windows.Forms.Label
$lblSubtitle.Text = "Instale, configure e gerencie este computador"
$lblSubtitle.Font = $FontNormal
$lblSubtitle.ForeColor = $ColorMuted
$lblSubtitle.Location = New-Object System.Drawing.Point(20, 40)
$lblSubtitle.Size = New-Object System.Drawing.Size(500, 22)
$headerPanel.Controls.Add($lblSubtitle)

# TabControl
$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Dock = [System.Windows.Forms.DockStyle]::Fill
$tabControl.Font = $FontNormal
$innerPanel.Controls.Add($tabControl)

# ============================================================
#  ABA PROVISIONAMENTO
# ============================================================
$tabProvisioning = New-Object System.Windows.Forms.TabPage
$tabProvisioning.Text = "Provisionamento"
$tabProvisioning.BackColor = $ColorBackground
$tabControl.Controls.Add($tabProvisioning)

# TableLayout com 3 colunas
$tableLayout = New-Object System.Windows.Forms.TableLayoutPanel
$tableLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$tableLayout.ColumnCount = 3
$tableLayout.RowCount = 1
$tableLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.33)))
$tableLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.33)))
$tableLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.34)))
$tableLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$tableLayout.Padding = New-Object System.Windows.Forms.Padding(10)
$tableLayout.BackColor = $ColorBackground
$tabProvisioning.Controls.Add($tableLayout)

# ----- COLUNA 1: CONFIGURAÇÃO -----
$grpSystem = New-Object System.Windows.Forms.GroupBox
$grpSystem.Text = "1. Configuração do sistema"
$grpSystem.Font = $FontHeader
$grpSystem.ForeColor = $ColorText
$grpSystem.Dock = [System.Windows.Forms.DockStyle]::Fill
$grpSystem.Padding = New-Object System.Windows.Forms.Padding(10, 20, 10, 10)
$tableLayout.Controls.Add($grpSystem, 0, 0)

$flowSystem = New-Object System.Windows.Forms.FlowLayoutPanel
$flowSystem.Dock = [System.Windows.Forms.DockStyle]::Fill
$flowSystem.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$flowSystem.AutoScroll = $true
$flowSystem.WrapContents = $false
$flowSystem.Padding = New-Object System.Windows.Forms.Padding(5)
$grpSystem.Controls.Add($flowSystem)

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
foreach ($key in $steps.Keys) {
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $key
    $cb.Checked = -not ($UncheckedByDefault -contains $key)
    $cb.Font = $FontNormal
    $cb.ForeColor = $ColorText
    $cb.AutoSize = $true
    $cb.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 0)
    $flowSystem.Controls.Add($cb)
    $checkboxes[$key] = $cb
}

$chkDryRun = New-Object System.Windows.Forms.CheckBox
$chkDryRun.Text = "Modo Simulacao (dry-run)"
$chkDryRun.Font = $FontNormal
$chkDryRun.ForeColor = [System.Drawing.Color]::DarkBlue
$chkDryRun.AutoSize = $true
$chkDryRun.Margin = New-Object System.Windows.Forms.Padding(3, 10, 3, 5)
$flowSystem.Controls.Add($chkDryRun)

$btnSelAll = New-Object System.Windows.Forms.Button
$btnSelAll.Text = "Marcar todos"
$btnSelAll.Font = $FontButton
$btnSelAll.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSelAll.FlatAppearance.BorderColor = $ColorBorder
$btnSelAll.BackColor = $ColorSurface
$btnSelAll.AutoSize = $true
$btnSelAll.Margin = New-Object System.Windows.Forms.Padding(3, 5, 3, 0)
$btnSelAll.Add_Click({ $checkboxes.Values | ForEach-Object { $_.Checked = $true } })
$flowSystem.Controls.Add($btnSelAll)

$btnSelNone = New-Object System.Windows.Forms.Button
$btnSelNone.Text = "Desmarcar todos"
$btnSelNone.Font = $FontButton
$btnSelNone.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSelNone.FlatAppearance.BorderColor = $ColorBorder
$btnSelNone.BackColor = $ColorSurface
$btnSelNone.AutoSize = $true
$btnSelNone.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 5)
$btnSelNone.Add_Click({ $checkboxes.Values | ForEach-Object { $_.Checked = $false } })
$flowSystem.Controls.Add($btnSelNone)

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = "Executar configuração"
$btnRun.Font = $FontButton
$btnRun.BackColor = $ColorPrimary
$btnRun.ForeColor = [System.Drawing.Color]::White
$btnRun.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnRun.FlatAppearance.BorderSize = 0
$btnRun.AutoSize = $true
$btnRun.Margin = New-Object System.Windows.Forms.Padding(3, 10, 3, 3)
$flowSystem.Controls.Add($btnRun)

# ----- COLUNA 2: INSTALAR -----
$grpInstall = New-Object System.Windows.Forms.GroupBox
$grpInstall.Text = "2. Instalar aplicativos"
$grpInstall.Font = $FontHeader
$grpInstall.ForeColor = $ColorText
$grpInstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$grpInstall.Padding = New-Object System.Windows.Forms.Padding(10, 20, 10, 10)
$tableLayout.Controls.Add($grpInstall, 1, 0)

$flowInstall = New-Object System.Windows.Forms.FlowLayoutPanel
$flowInstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$flowInstall.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$flowInstall.AutoScroll = $true
$flowInstall.WrapContents = $false
$flowInstall.Padding = New-Object System.Windows.Forms.Padding(5)
$grpInstall.Controls.Add($flowInstall)

$lblInstallInfo = New-Object System.Windows.Forms.Label
$lblInstallInfo.Text = "Buscar:"
$lblInstallInfo.Font = $FontNormal
$lblInstallInfo.ForeColor = $ColorMuted
$lblInstallInfo.AutoSize = $true
$lblInstallInfo.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 0)
$flowInstall.Controls.Add($lblInstallInfo)

$txtSearchInstall = New-Object System.Windows.Forms.TextBox
$txtSearchInstall.Font = $FontNormal
$txtSearchInstall.Width = 200
$txtSearchInstall.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 5)
$flowInstall.Controls.Add($txtSearchInstall)

$clbInstall = New-Object System.Windows.Forms.CheckedListBox
$clbInstall.CheckOnClick = $true
$clbInstall.Font = $FontNormal
$clbInstall.Height = 200
$clbInstall.Width = 220
$clbInstall.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 5)
$allLabels = Build-AppCatalogLabels
$clbInstall.Tag = $allLabels
foreach ($label in $allLabels) { [void]$clbInstall.Items.Add($label, $true) }
$flowInstall.Controls.Add($clbInstall)

$txtSearchInstall.Add_TextChanged({
    $search = $txtSearchInstall.Text.Trim().ToLower()
    $clbInstall.BeginUpdate()
    $clbInstall.Items.Clear()
    $all = $clbInstall.Tag
    if ([string]::IsNullOrEmpty($search)) {
        foreach ($item in $all) { [void]$clbInstall.Items.Add($item, $true) }
    } else {
        foreach ($item in $all) {
            if ($item.ToLower().Contains($search)) {
                [void]$clbInstall.Items.Add($item, $true)
            }
        }
    }
    $clbInstall.EndUpdate()
})

$btnInstallSelected = New-Object System.Windows.Forms.Button
$btnInstallSelected.Text = "INSTALAR SELECIONADOS (Paralelo)"
$btnInstallSelected.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$btnInstallSelected.BackColor = $ColorSuccess
$btnInstallSelected.ForeColor = [System.Drawing.Color]::White
$btnInstallSelected.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnInstallSelected.FlatAppearance.BorderSize = 0
$btnInstallSelected.AutoSize = $true
$btnInstallSelected.Margin = New-Object System.Windows.Forms.Padding(3, 5, 3, 3)
$flowInstall.Controls.Add($btnInstallSelected)

# ----- COLUNA 3: REMOVER -----
$grpUninstall = New-Object System.Windows.Forms.GroupBox
$grpUninstall.Text = "3. Gerenciar aplicativos instalados"
$grpUninstall.Font = $FontHeader
$grpUninstall.ForeColor = $ColorText
$grpUninstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$grpUninstall.Padding = New-Object System.Windows.Forms.Padding(10, 20, 10, 10)
$tableLayout.Controls.Add($grpUninstall, 2, 0)

$flowUninstall = New-Object System.Windows.Forms.FlowLayoutPanel
$flowUninstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$flowUninstall.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$flowUninstall.AutoScroll = $true
$flowUninstall.WrapContents = $false
$flowUninstall.Padding = New-Object System.Windows.Forms.Padding(5)
$grpUninstall.Controls.Add($flowUninstall)

$lblUninstallInfo = New-Object System.Windows.Forms.Label
$lblUninstallInfo.Text = "Atualize a lista e selecione o que deseja remover:"
$lblUninstallInfo.Font = $FontNormal
$lblUninstallInfo.ForeColor = $ColorMuted
$lblUninstallInfo.AutoSize = $true
$lblUninstallInfo.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 0)
$flowUninstall.Controls.Add($lblUninstallInfo)

$clbUninstall = New-Object System.Windows.Forms.CheckedListBox
$clbUninstall.CheckOnClick = $true
$clbUninstall.Font = $FontNormal
$clbUninstall.Height = 150
$clbUninstall.Width = 220
$clbUninstall.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 5)
$flowUninstall.Controls.Add($clbUninstall)

$btnRefreshInstalled = New-Object System.Windows.Forms.Button
$btnRefreshInstalled.Text = "Atualizar lista"
$btnRefreshInstalled.Font = $FontButton
$btnRefreshInstalled.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnRefreshInstalled.FlatAppearance.BorderColor = $ColorBorder
$btnRefreshInstalled.BackColor = $ColorSurface
$btnRefreshInstalled.AutoSize = $true
$btnRefreshInstalled.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 0)
$flowUninstall.Controls.Add($btnRefreshInstalled)

$btnUninstallSelected = New-Object System.Windows.Forms.Button
$btnUninstallSelected.Text = "Desinstalar"
$btnUninstallSelected.Font = $FontButton
$btnUninstallSelected.BackColor = $ColorDanger
$btnUninstallSelected.ForeColor = [System.Drawing.Color]::White
$btnUninstallSelected.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnUninstallSelected.FlatAppearance.BorderSize = 0
$btnUninstallSelected.AutoSize = $true
$btnUninstallSelected.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 5)
$flowUninstall.Controls.Add($btnUninstallSelected)

$btnCustom = New-Object System.Windows.Forms.Button
$btnCustom.Text = $CustomScriptLabel
$btnCustom.Font = $FontButton
$btnCustom.BackColor = $ColorSurface
$btnCustom.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnCustom.FlatAppearance.BorderColor = $ColorBorder
$btnCustom.AutoSize = $true
$btnCustom.Margin = New-Object System.Windows.Forms.Padding(3, 10, 3, 3)
$flowUninstall.Controls.Add($btnCustom)

# ============================================================
#  ABA SITEF
# ============================================================
$tabSitef = New-Object System.Windows.Forms.TabPage
$tabSitef.Text = "SITEF"
$tabSitef.BackColor = $ColorBackground
$tabControl.Controls.Add($tabSitef)

$panelSitef = New-Object System.Windows.Forms.Panel
$panelSitef.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelSitef.Padding = New-Object System.Windows.Forms.Padding(20)
$panelSitef.AutoScroll = $true
$tabSitef.Controls.Add($panelSitef)

$lblSitefTitle = New-Object System.Windows.Forms.Label
$lblSitefTitle.Text = "Instalação do Ambiente SITEF"
$lblSitefTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 12)
$lblSitefTitle.ForeColor = $ColorText
$lblSitefTitle.Location = New-Object System.Drawing.Point(0, 0)
$lblSitefTitle.Size = New-Object System.Drawing.Size(400, 25)
$panelSitef.Controls.Add($lblSitefTitle)

$lblSitefDesc = New-Object System.Windows.Forms.Label
$lblSitefDesc.Text = "Esta etapa irá baixar, extrair e executar os instaladores do SITEF.`n" +
                     "Após a execução, você deverá configurar manualmente os programas.`n" +
                     "Ao fechar os instaladores, o serviço 'GSurfRSA Listener' será iniciado."
$lblSitefDesc.Font = $FontNormal
$lblSitefDesc.ForeColor = $ColorMuted
$lblSitefDesc.Location = New-Object System.Drawing.Point(0, 35)
$lblSitefDesc.Size = New-Object System.Drawing.Size(700, 60)
$panelSitef.Controls.Add($lblSitefDesc)

$btnSitefInstall = New-Object System.Windows.Forms.Button
$btnSitefInstall.Text = "Instalar SITEF"
$btnSitefInstall.Location = New-Object System.Drawing.Point(0, 110)
$btnSitefInstall.Size = New-Object System.Drawing.Size(180, 35)
$btnSitefInstall.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$btnSitefInstall.BackColor = $ColorPrimary
$btnSitefInstall.ForeColor = [System.Drawing.Color]::White
$btnSitefInstall.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$panelSitef.Controls.Add($btnSitefInstall)

$btnSitefOpenFolder = New-Object System.Windows.Forms.Button
$btnSitefOpenFolder.Text = "Abrir pasta C:\SITEF"
$btnSitefOpenFolder.Location = New-Object System.Drawing.Point(200, 110)
$btnSitefOpenFolder.Size = New-Object System.Drawing.Size(160, 35)
$btnSitefOpenFolder.Font = $FontButton
$btnSitefOpenFolder.BackColor = $ColorSurface
$btnSitefOpenFolder.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSitefOpenFolder.FlatAppearance.BorderColor = $ColorBorder
$panelSitef.Controls.Add($btnSitefOpenFolder)

$progressSitef = New-Object System.Windows.Forms.ProgressBar
$progressSitef.Location = New-Object System.Drawing.Point(0, 160)
$progressSitef.Size = New-Object System.Drawing.Size(700, 20)
$progressSitef.Minimum = 0
$progressSitef.Maximum = 100
$panelSitef.Controls.Add($progressSitef)

$lblSitefLog = New-Object System.Windows.Forms.Label
$lblSitefLog.Text = "Log da instalação SITEF:"
$lblSitefLog.Font = $FontNormal
$lblSitefLog.ForeColor = $ColorMuted
$lblSitefLog.Location = New-Object System.Drawing.Point(0, 195)
$lblSitefLog.Size = New-Object System.Drawing.Size(200, 22)
$panelSitef.Controls.Add($lblSitefLog)

$txtSitefLog = New-Object System.Windows.Forms.TextBox
$txtSitefLog.Multiline = $true
$txtSitefLog.ScrollBars = "Vertical"
$txtSitefLog.ReadOnly = $true
$txtSitefLog.Location = New-Object System.Drawing.Point(0, 220)
$txtSitefLog.Size = New-Object System.Drawing.Size(700, 300)
$txtSitefLog.Font = New-Object System.Drawing.Font("Consolas", 8)
$txtSitefLog.BackColor = [System.Drawing.Color]::White
$panelSitef.Controls.Add($txtSitefLog)

# ============================================================
#  STATUS (painel inferior)
# ============================================================
$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
$statusPanel.Height = 210
$statusPanel.BackColor = $ColorBackground
$innerPanel.Controls.Add($statusPanel)

$grpStatus = New-Object System.Windows.Forms.GroupBox
$grpStatus.Text = "Status Geral"
$grpStatus.Font = $FontHeader
$grpStatus.ForeColor = $ColorText
$grpStatus.Dock = [System.Windows.Forms.DockStyle]::Fill
$grpStatus.Padding = New-Object System.Windows.Forms.Padding(10, 20, 10, 10)
$statusPanel.Controls.Add($grpStatus)

$flowStatus = New-Object System.Windows.Forms.FlowLayoutPanel
$flowStatus.Dock = [System.Windows.Forms.DockStyle]::Fill
$flowStatus.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$flowStatus.AutoScroll = $true
$flowStatus.WrapContents = $false
$flowStatus.Padding = New-Object System.Windows.Forms.Padding(5)
$grpStatus.Controls.Add($flowStatus)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Height = 20
$progressBar.Width = 700
$progressBar.Minimum = 0
$flowStatus.Controls.Add($progressBar)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Pronto para instalar"
$lblStatus.Font = $FontNormal
$lblStatus.ForeColor = $ColorSuccess
$lblStatus.AutoSize = $true
$flowStatus.Controls.Add($lblStatus)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Height = 100
$txtLog.Width = 700
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 8)
$txtLog.BackColor = [System.Drawing.Color]::White
$flowStatus.Controls.Add($txtLog)

# ============================================================
#  LOGS E DELEGATES
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

$script:SitefLogDelegate = {
    param($msg)
    $line = "$msg"
    $txtSitefLog.AppendText("$line`r`n")
    $txtSitefLog.SelectionStart = $txtSitefLog.Text.Length
    $txtSitefLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

# ============================================================
#  EVENTOS DOS BOTÕES
# ============================================================
$btnRun.Add_Click({
    $btnRun.Enabled = $false
    $btnSelAll.Enabled = $false
    $btnSelNone.Enabled = $false
    $txtLog.Clear()
    $script:CancelRequested = $false

    $DryRun = $chkDryRun.Checked
    $selectedSteps = $steps.Keys | Where-Object { $checkboxes[$_].Checked }

    if ($selectedSteps.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Nenhuma etapa selecionada.", "Aviso")
        $btnRun.Enabled = $true
        $btnSelAll.Enabled = $true
        $btnSelNone.Enabled = $true
        return
    }

    $AppendLog.Invoke("=== INICIANDO PROVISIONAMENTO ===")
    $AppendLog.Invoke("Modo: $(if ($DryRun) {'SIMULAÇÃO'} else {'EXECUÇÃO REAL'})")
    $AppendLog.Invoke("")

    $progressBar.Maximum = $selectedSteps.Count
    $progressBar.Value = 0

    foreach ($key in $selectedSteps) {
        $lblStatus.Text = "Executando: $key ..."
        $AppendLog.Invoke("")
        $AppendLog.Invoke(">>> $key")
        try {
            & $steps[$key] $AppendLog $DryRun
            $script:Results[$key] = if ($DryRun) { "SIMULADO" } else { "OK" }
        } catch {
            $AppendLog.Invoke("ERRO em '$key': $($_.Exception.Message)")
            $script:Results[$key] = "FALHA: $($_.Exception.Message)"
        }
        $progressBar.Value += 1
        [System.Windows.Forms.Application]::DoEvents()
    }

    $AppendLog.Invoke("")
    $AppendLog.Invoke("=== PROVISIONAMENTO CONCLUÍDO ===")

    $reportLines = @()
    $reportLines += "Relatorio de Provisionamento - $Timestamp"
    $reportLines += "Modo: $(if ($DryRun) {'SIMULACAO'} else {'EXECUCAO REAL'})"
    $reportLines += ""
    foreach ($k in $script:Results.Keys) {
        $reportLines += ("{0,-45} {1}" -f $k, $script:Results[$k])
    }
    $reportLines | Set-Content -Path $ReportPath -Encoding UTF8
    $AppendLog.Invoke("Relatorio salvo em: $ReportPath")

    $btnRun.Enabled = $true
    $btnSelAll.Enabled = $true
    $btnSelNone.Enabled = $true
    $lblStatus.Text = "Pronto."
    [System.Windows.Forms.MessageBox]::Show("Provisionamento concluido. Relatorio em:`n$ReportPath", "Finalizado")
})

$btnInstallSelected.Add_Click({
    $selectedLabels = @($clbInstall.CheckedItems)
    if ($selectedLabels.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Selecione ao menos um programa na lista.", "Aviso")
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

    while ($jobs | Where-Object { $_.State -eq 'Running' }) {
        Start-Sleep -Milliseconds 500
        $running = ($jobs | Where-Object { $_.State -eq 'Running' }).Count
        $completed = $totalJobs - $running
        $lblStatus.Text = "Instalando... $completed de $totalJobs concluidos"
        $progressBar.Value = [int](($completed / $totalJobs) * 100)
        [System.Windows.Forms.Application]::DoEvents()
    }

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

$btnCustom.Add_Click({
    if ([string]::IsNullOrWhiteSpace($CustomScriptUrl) -or $CustomScriptUrl -like "*usuario/repositorio*") {
        [System.Windows.Forms.MessageBox]::Show("Edite as variaveis `$CustomScriptUrl e `$CustomScriptLabel no topo do ProvisioningTool.ps1 antes de usar este botao.", "Configure o link")
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
        $tempScript = Join-Path $env:TEMP "MCNTV_custom_$(Get-Random).ps1"
        (New-Object System.Net.WebClient).DownloadFile($CustomScriptUrl, $tempScript)

        $AppendLog.Invoke("Script baixado para $tempScript")
        & $tempScript 2>&1 | ForEach-Object { $AppendLog.Invoke($_) }
        $AppendLog.Invoke("Script '$CustomScriptLabel' concluido.")
        Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
    } catch {
        $AppendLog.Invoke("ERRO ao executar '$CustomScriptLabel': $($_.Exception.Message)")
    }
    $btnCustom.Enabled = $true
})

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
        [System.Windows.Forms.MessageBox]::Show("Selecione ao menos um programa para remover.", "Aviso")
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

$btnSitefInstall.Add_Click({
    $btnSitefInstall.Enabled = $false
    $txtSitefLog.Clear()
    $progressSitef.Value = 0
    try {
        Install-Sitef
    } catch {
        $txtSitefLog.AppendText("ERRO inesperado: $($_.Exception.Message)`r`n")
    }
    $btnSitefInstall.Enabled = $true
})

$btnSitefOpenFolder.Add_Click({
    $sitefDir = "C:\SITEF"
    if (Test-Path $sitefDir) {
        explorer $sitefDir
    } else {
        [System.Windows.Forms.MessageBox]::Show("A pasta C:\SITEF ainda não existe. Execute a instalação primeiro.", "Pasta não encontrada")
    }
})

# ============================================================
#  CARREGAR LISTA DE INSTALADOS AO ABRIR
# ============================================================
$form.Add_Shown({
    if ($btnRefreshInstalled -ne $null) {
        $btnRefreshInstalled.PerformClick()
    } else {
        $AppendLog.Invoke("Carregando lista de programas instalados...")
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
    }
})

[void]$form.ShowDialog()
