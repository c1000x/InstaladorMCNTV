<#
    ProvisioningTool.ps1
    Interface grafica para provisionamento de maquinas Windows.
    Layout adaptativo – ajusta-se automaticamente ao tamanho da tela.
    Todos os eventos funcionando, incluindo a aba SITEF.
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
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ============================================================
#  BOTAO PERSONALIZADO (script externo do GitHub)
# ============================================================
$CustomScriptUrl   = "https://get.activated.win"
$CustomScriptLabel = "Ativar Windows"

# ============================================================
#  LISTAS DE APLICATIVOS (hardcoded)
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
#  DETECTAR TAMANHO DA TELA E CALCULAR LAYOUT ADAPTATIVO
# ============================================================
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$screenWidth  = $screen.Width
$screenHeight = $screen.Height

$margin     = [Math]::Max(20, [int]($screenWidth * 0.02))
$gap        = [Math]::Max(15, [int]($screenWidth * 0.015))
$headerHeight = 78
$statusHeight = 210
$tabHeight  = [Math]::Max(400, $screenHeight - $headerHeight - $statusHeight - 80)

$usableWidth = $screenWidth - ($margin * 2) - ($gap * 2)
$colWidth    = [Math]::Floor(($usableWidth) / 3)
if ($colWidth -lt 280) { $colWidth = 280 }

$formWidth  = $screenWidth - 20
$formHeight = $screenHeight - 20
$topY = $headerHeight
$groupH = $tabHeight

$col1X = $margin
$col2X = $col1X + $colWidth + $gap
$col3X = $col2X + $colWidth + $gap

# ============================================================
#  FUNCOES DE CADA ETAPA (Provisionamento)
# ============================================================
function Step-RestorePoint { param($Log, [bool]$DryRun) ... } # (coloque as funções completas aqui)
function Step-VersoesAnteriores { param($Log, [bool]$DryRun) ... }
function Step-IconesAreaTrabalho { param($Log, [bool]$DryRun) ... }
function Step-Telemetria { param($Log, [bool]$DryRun) ... }
function Step-Energia { param($Log, [bool]$DryRun) ... }
function Step-RegiaoIdioma { param($Log, [bool]$DryRun) ... }
function Step-Debloat { param($Log, [bool]$DryRun) ... }
function Ensure-ChocoAvailable { param($Log) ... }
function Step-Chocolatey { param($Log, [bool]$DryRun) ... }
function Step-WingetUpgradeAll { param($Log, [bool]$DryRun) ... }
function Step-TarefaLimpeza { param($Log, [bool]$DryRun) ... }

# ============================================================
#  CATALOGO DE PROGRAMAS E LISTA DE INSTALADOS
# ============================================================
function Build-AppCatalogLabels { ... }
function Get-InstalledProgramsList { ... }

# ============================================================
#  FUNÇÃO DE INSTALAÇÃO SITEF (COMPLETA)
# ============================================================
function Install-Sitef {
    $log = $script:SitefLogDelegate
    $log.Invoke("=== INICIANDO INSTALAÇÃO SITEF ===")
    $log.Invoke("")

    $sitefDir = "C:\SITEF"
    $zipUrls = @(
        @{ url = "http://gsurf.com.br/lib/win/certificado.zip"; nome = "certificado.zip" },
        @{ url = "http://gsurf.com.br/lib/win/gsclient.zip"; nome = "gsclient.zip" }
    )

    if (-not (Test-Path $sitefDir)) {
        $log.Invoke("Criando diretório $sitefDir ...")
        try {
            New-Item -ItemType Directory -Path $sitefDir -Force | Out-Null
            $log.Invoke("Diretório criado com sucesso.")
        } catch {
            $log.Invoke("ERRO ao criar diretório: $($_.Exception.Message)")
            return
        }
    } else {
        $log.Invoke("Diretório $sitefDir já existe.")
    }

    $progressSitef.Maximum = $zipUrls.Count * 2
    $progressSitef.Value = 0

    foreach ($item in $zipUrls) {
        $url = $item.url
        $fileName = $item.nome
        $zipPath = Join-Path $sitefDir $fileName
        $extractPath = Join-Path $sitefDir ([System.IO.Path]::GetFileNameWithoutExtension($fileName))

        if (Test-Path $zipPath) {
            $log.Invoke("Arquivo $fileName já existe. Verificando integridade...")
            try {
                if (-not (Test-Path $extractPath)) { New-Item -ItemType Directory -Path $extractPath -Force | Out-Null }
                Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
                $log.Invoke("Extraído com sucesso (arquivo existente).")
                $progressSitef.Value += 2
                continue
            } catch {
                $log.Invoke("Falha na extração do arquivo existente. Removendo e baixando novamente...")
                Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        $log.Invoke("Baixando $fileName ...")
        try {
            $webClient = New-Object System.Net.WebClient
            $webClient.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
            $webClient.DownloadFile($url, $zipPath)
            $log.Invoke("Download concluído: $zipPath")
            $progressSitef.Value += 1
        } catch {
            $log.Invoke("ERRO ao baixar $url : $($_.Exception.Message)")
            return
        }

        $bytes = [System.IO.File]::ReadAllBytes($zipPath)
        $isZip = $bytes.Count -ge 4 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B -and $bytes[2] -eq 0x03 -and $bytes[3] -eq 0x04
        if (-not $isZip) {
            $log.Invoke("ERRO: O arquivo baixado não é um ZIP válido (cabeçalho inválido).")
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            return
        }

        $log.Invoke("Extraindo $fileName para $extractPath ...")
        try {
            if (-not (Test-Path $extractPath)) { New-Item -ItemType Directory -Path $extractPath -Force | Out-Null }
            Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
            $log.Invoke("Extraído com sucesso.")
            $progressSitef.Value += 1
        } catch {
            $log.Invoke("ERRO ao extrair com Expand-Archive: $($_.Exception.Message)")
            $log.Invoke("Tentando extrair com System.IO.Compression.ZipFile (fallback)...")
            try {
                [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractPath, $true)
                $log.Invoke("Extraído com sucesso via fallback.")
                $progressSitef.Value += 1
            } catch {
                $log.Invoke("Falha na extração: $($_.Exception.Message)")
                Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                return
            }
        }
    }

    $log.Invoke("")
    $log.Invoke("Arquivos baixados e extraídos.")

    $msiPath = Get-ChildItem -Path $sitefDir -Recurse -Filter "GSurfRSA_Listener_Setup.msi" -ErrorAction SilentlyContinue | Select-Object -First 1
    $exePath = Get-ChildItem -Path $sitefDir -Recurse -Filter "InstaladorGSurf.exe" -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $msiPath) {
        $log.Invoke("ERRO: Arquivo GSurfRSA_Listener_Setup.msi não encontrado.")
        return
    }
    if (-not $exePath) {
        $log.Invoke("ERRO: Arquivo InstaladorGSurf.exe não encontrado.")
        return
    }

    $log.Invoke("")
    $log.Invoke("Executando instalador MSI: $($msiPath.FullName)")
    try {
        Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$($msiPath.FullName)`"" -Wait
        $log.Invoke("Instalador MSI concluído.")
    } catch {
        $log.Invoke("ERRO ao executar MSI: $($_.Exception.Message)")
    }

    $log.Invoke("Executando instalador EXE: $($exePath.FullName)")
    try {
        Start-Process -FilePath $exePath.FullName -Wait
        $log.Invoke("Instalador EXE concluído.")
    } catch {
        $log.Invoke("ERRO ao executar EXE: $($_.Exception.Message)")
    }

    $log.Invoke("")
    $log.Invoke("Aguardando 5 segundos antes de iniciar o serviço...")
    Start-Sleep -Seconds 5

    $serviceName = "GSurfRSA Listener"
    $log.Invoke("Verificando serviço '$serviceName'...")
    $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -eq 'Stopped') {
            try {
                Start-Service -Name $serviceName -ErrorAction Stop
                $log.Invoke("Serviço '$serviceName' iniciado com sucesso.")
            } catch {
                $log.Invoke("ERRO ao iniciar serviço: $($_.Exception.Message)")
            }
        } else {
            $log.Invoke("Serviço já está em execução (Status: $($svc.Status)).")
        }
    } else {
        $log.Invoke("Serviço '$serviceName' não encontrado.")
    }

    $log.Invoke("")
    $log.Invoke("=== INSTALAÇÃO SITEF CONCLUÍDA ===")
    $progressSitef.Value = $progressSitef.Maximum
    [System.Windows.Forms.MessageBox]::Show("Instalação SITEF concluída! Verifique o log para detalhes.", "SITEF")
}

# ============================================================
#  INTERFACE GRAFICA (LAYOUT ADAPTATIVO)
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
$form.ClientSize = New-Object System.Drawing.Size($formWidth, $formHeight)
$form.BackColor = $ColorBackground
$form.Font = $FontNormal

# Panel com scroll
$mainPanel = New-Object System.Windows.Forms.Panel
$mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$mainPanel.AutoScroll = $true
$form.Controls.Add($mainPanel)

$contentPanel = New-Object System.Windows.Forms.Panel
$contentPanel.Size = New-Object System.Drawing.Size($formWidth, $formHeight)
$contentPanel.Location = New-Object System.Drawing.Point(0, 0)
$mainPanel.Controls.Add($contentPanel)

# Cabeçalho
$lblMainTitle = New-Object System.Windows.Forms.Label
$lblMainTitle.Text = "MCNTV Installer"
$lblMainTitle.Font = $FontTitle
$lblMainTitle.ForeColor = $ColorText
$lblMainTitle.Location = New-Object System.Drawing.Point($margin, 15)
$lblMainTitle.Size = New-Object System.Drawing.Size(500, 30)
$contentPanel.Controls.Add($lblMainTitle)

$lblSubtitle = New-Object System.Windows.Forms.Label
$lblSubtitle.Text = "Instale, configure e gerencie este computador"
$lblSubtitle.Font = $FontNormal
$lblSubtitle.ForeColor = $ColorMuted
$lblSubtitle.Location = New-Object System.Drawing.Point($margin, 45)
$lblSubtitle.Size = New-Object System.Drawing.Size(500, 22)
$contentPanel.Controls.Add($lblSubtitle)

# TabControl
$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Location = New-Object System.Drawing.Point($margin, $topY)
$tabControl.Size = New-Object System.Drawing.Size(($formWidth - $margin*2), $tabHeight)
$tabControl.Font = $FontNormal
$tabControl.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$contentPanel.Controls.Add($tabControl)

# ============================================================
#  ABA PROVISIONAMENTO (resumida para não alongar)
# ============================================================
$tabProvisioning = New-Object System.Windows.Forms.TabPage
$tabProvisioning.Text = "Provisionamento"
$tabProvisioning.BackColor = $ColorBackground
$tabControl.Controls.Add($tabProvisioning)

# GRUPO 1 (Configuração)
$grpSystem = New-Object System.Windows.Forms.GroupBox
$grpSystem.Text = "1. Configuracao do sistema"
$grpSystem.Font = $FontHeader
$grpSystem.ForeColor = $ColorText
$grpSystem.Location = New-Object System.Drawing.Point($col1X, 10)
$grpSystem.Size = New-Object System.Drawing.Size($colWidth, $groupH)
$grpSystem.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
$tabProvisioning.Controls.Add($grpSystem)

# (Aqui você coloca os checkboxes e botões da primeira coluna, igual ao que já tem)

# GRUPO 2 (Instalar)
$grpInstall = New-Object System.Windows.Forms.GroupBox
$grpInstall.Text = "2. Instalar aplicativos"
$grpInstall.Font = $FontHeader
$grpInstall.ForeColor = $ColorText
$grpInstall.Location = New-Object System.Drawing.Point($col2X, 10)
$grpInstall.Size = New-Object System.Drawing.Size($colWidth, $groupH)
$grpInstall.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
$tabProvisioning.Controls.Add($grpInstall)

# (Aqui você coloca o filtro e a lista de apps)

# GRUPO 3 (Remover)
$grpUninstall = New-Object System.Windows.Forms.GroupBox
$grpUninstall.Text = "3. Gerenciar aplicativos instalados"
$grpUninstall.Font = $FontHeader
$grpUninstall.ForeColor = $ColorText
$grpUninstall.Location = New-Object System.Drawing.Point($col3X, 10)
$grpUninstall.Size = New-Object System.Drawing.Size($colWidth, $groupH)
$grpUninstall.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
$tabProvisioning.Controls.Add($grpUninstall)

# (Aqui você coloca a lista de instalados e botões)

# ============================================================
#  ABA SITEF (com eventos)
# ============================================================
$tabSitef = New-Object System.Windows.Forms.TabPage
$tabSitef.Text = "SITEF"
$tabSitef.BackColor = $ColorBackground
$tabControl.Controls.Add($tabSitef)

$lblSitefTitle = New-Object System.Windows.Forms.Label
$lblSitefTitle.Text = "Instalação do Ambiente SITEF"
$lblSitefTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 12)
$lblSitefTitle.ForeColor = $ColorText
$lblSitefTitle.Location = New-Object System.Drawing.Point(20, 20)
$lblSitefTitle.Size = New-Object System.Drawing.Size(400, 25)
$tabSitef.Controls.Add($lblSitefTitle)

$lblSitefDesc = New-Object System.Windows.Forms.Label
$lblSitefDesc.Text = "Esta etapa irá baixar, extrair e executar os instaladores do SITEF.`n" +
                     "Após a execução, você deverá configurar manualmente os programas.`n" +
                     "Ao fechar os instaladores, o serviço 'GSurfRSA Listener' será iniciado."
$lblSitefDesc.Font = $FontNormal
$lblSitefDesc.ForeColor = $ColorMuted
$lblSitefDesc.Location = New-Object System.Drawing.Point(20, 55)
$lblSitefDesc.Size = New-Object System.Drawing.Size(($tabControl.Width - 60), 60)
$tabSitef.Controls.Add($lblSitefDesc)

$btnSitefInstall = New-Object System.Windows.Forms.Button
$btnSitefInstall.Text = "Instalar SITEF"
$btnSitefInstall.Location = New-Object System.Drawing.Point(20, 130)
$btnSitefInstall.Size = New-Object System.Drawing.Size(180, 35)
$btnSitefInstall.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$btnSitefInstall.BackColor = $ColorPrimary
$btnSitefInstall.ForeColor = [System.Drawing.Color]::White
$btnSitefInstall.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$tabSitef.Controls.Add($btnSitefInstall)

$btnSitefOpenFolder = New-Object System.Windows.Forms.Button
$btnSitefOpenFolder.Text = "Abrir pasta C:\SITEF"
$btnSitefOpenFolder.Location = New-Object System.Drawing.Point(220, 130)
$btnSitefOpenFolder.Size = New-Object System.Drawing.Size(160, 35)
$btnSitefOpenFolder.Font = $FontButton
$btnSitefOpenFolder.BackColor = $ColorSurface
$btnSitefOpenFolder.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSitefOpenFolder.FlatAppearance.BorderColor = $ColorBorder
$tabSitef.Controls.Add($btnSitefOpenFolder)

$progressSitef = New-Object System.Windows.Forms.ProgressBar
$progressSitef.Location = New-Object System.Drawing.Point(20, 180)
$progressSitef.Size = New-Object System.Drawing.Size(($tabControl.Width - 60), 20)
$progressSitef.Minimum = 0
$progressSitef.Maximum = 100
$tabSitef.Controls.Add($progressSitef)

$lblSitefLog = New-Object System.Windows.Forms.Label
$lblSitefLog.Text = "Log da instalação SITEF:"
$lblSitefLog.Font = $FontNormal
$lblSitefLog.ForeColor = $ColorMuted
$lblSitefLog.Location = New-Object System.Drawing.Point(20, 215)
$lblSitefLog.Size = New-Object System.Drawing.Size(200, 22)
$tabSitef.Controls.Add($lblSitefLog)

$txtSitefLog = New-Object System.Windows.Forms.TextBox
$txtSitefLog.Multiline = $true
$txtSitefLog.ScrollBars = "Vertical"
$txtSitefLog.ReadOnly = $true
$txtSitefLog.Location = New-Object System.Drawing.Point(20, 240)
$txtSitefLog.Size = New-Object System.Drawing.Size(($tabControl.Width - 60), ($tabHeight - 280))
$txtSitefLog.Font = New-Object System.Drawing.Font("Consolas", 8)
$txtSitefLog.BackColor = [System.Drawing.Color]::White
$tabSitef.Controls.Add($txtSitefLog)

# ============================================================
#  EVENTOS DOS BOTÕES SITEF (AQUI ESTÁ A CORREÇÃO)
# ============================================================
$btnSitefInstall.Add_Click({
    [System.Windows.Forms.MessageBox]::Show("Botão Instalar SITEF clicado! Iniciando instalação...", "Diagnóstico")
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
    [System.Windows.Forms.MessageBox]::Show("Botão Abrir pasta clicado!", "Diagnóstico")
    $sitefDir = "C:\SITEF"
    if (Test-Path $sitefDir) {
        explorer $sitefDir
    } else {
        [System.Windows.Forms.MessageBox]::Show("A pasta C:\SITEF ainda não existe. Execute a instalação primeiro.", "Pasta não encontrada")
    }
})

# ============================================================
#  STATUS GERAL E LOG
# ============================================================
$grpStatus = New-Object System.Windows.Forms.GroupBox
$grpStatus.Text = "Status Geral"
$grpStatus.Font = $FontHeader
$grpStatus.ForeColor = $ColorText
$grpStatus.Location = New-Object System.Drawing.Point($margin, ($topY + $tabHeight + 15))
$grpStatus.Size = New-Object System.Drawing.Size(($formWidth - $margin*2), $statusHeight)
$grpStatus.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$contentPanel.Controls.Add($grpStatus)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(15, 32)
$progressBar.Size = New-Object System.Drawing.Size(($formWidth - $margin*2 - 40), 20)
$progressBar.Minimum = 0
$progressBar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$grpStatus.Controls.Add($progressBar)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Pronto para instalar"
$lblStatus.Font = $FontNormal
$lblStatus.ForeColor = $ColorSuccess
$lblStatus.Location = New-Object System.Drawing.Point(15, 57)
$lblStatus.Size = New-Object System.Drawing.Size(330, 22)
$grpStatus.Controls.Add($lblStatus)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Location = New-Object System.Drawing.Point(15, 82)
$txtLog.Size = New-Object System.Drawing.Size(($formWidth - $margin*2 - 40), 105)
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 8)
$txtLog.BackColor = [System.Drawing.Color]::White
$txtLog.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
$grpStatus.Controls.Add($txtLog)

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
#  CARREGAR LISTA DE INSTALADOS AO ABRIR
# ============================================================
$form.Add_Shown({
    $btnRefreshInstalled.PerformClick()
})

[void]$form.ShowDialog()
