# ============================================================
#  PROVISIONING TOOL - LAYOUT COMPACTO EM GRID (ALINHADO)
#  Uso interno - Windows PowerShell 5.1+
# ============================================================
$scriptPath = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($scriptPath)) {
    $bootstrapDir = Join-Path $env:TEMP "Installer"
    if (-not (Test-Path $bootstrapDir)) { New-Item -Path $bootstrapDir -ItemType Directory -Force | Out-Null }
    $scriptPath = Join-Path $bootstrapDir "ProvisioningTool.ps1"
    $scriptContent = $MyInvocation.MyCommand.Definition
    [System.IO.File]::WriteAllText($scriptPath, $scriptContent, (New-Object System.Text.UTF8Encoding($false)))
}

# AUTO-ELEVAÇÃO
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $tempScript = Join-Path $env:TEMP "ProvisioningTool_Elevated.ps1"
        $scriptContent = $MyInvocation.MyCommand.Definition
        [System.IO.File]::WriteAllText($tempScript, $scriptContent, (New-Object System.Text.UTF8Encoding($false)))
        $scriptPath = $tempScript
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    $psi.Verb = "runas"
    try { [System.Diagnostics.Process]::Start($psi) | Out-Null } catch { Write-Host "Elevação cancelada." }
    exit
}

# FORÇAR TLS 1.2 GLOBALMENTE PARA REQUISIÇÕES HTTPS
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem
$ErrorActionPreference = "Continue"

# LISTAS DE APLICATIVOS
$ChocoApps = @("googlechrome")
$WingetApps = @(
    "AnyDesk.AnyDesk",
    "Adobe.Acrobat.Reader.64-bit",
    "Oracle.JavaRuntimeEnvironment",
    "Mozilla.Firefox",
    "7zip.7zip",
    "Microsoft.Office"
)
$WingetStoreApps = @("9WZDNCRFJBMP")

# LOGS
$ScriptDir = Split-Path -Parent $scriptPath
$LogsDir   = Join-Path $ScriptDir "logs"
if (-not (Test-Path $LogsDir)) { New-Item -Path $LogsDir -ItemType Directory -Force | Out-Null }

$Timestamp   = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$LogFilePath = Join-Path $LogsDir "provisionamento_$Timestamp.log"

function Safe-Log {
    param([string]$Message)
    if ($null -ne $txtLog -and -not $txtLog.IsDisposed) {
        $txtLog.AppendText("$Message`r`n")
        $txtLog.SelectionStart = $txtLog.Text.Length
        $txtLog.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
    if ($LogFilePath) { Add-Content -Path $LogFilePath -Value $Message -Encoding UTF8 -ErrorAction SilentlyContinue }
}

function Update-Status {
    param([string]$Text, [int]$Progress = -1)
    if ($null -ne $lblStatus) { $lblStatus.Text = $Text }
    if ($Progress -ge 0 -and $null -ne $progressBar) { 
        $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
        $progressBar.Value = $Progress 
    }
    [System.Windows.Forms.Application]::DoEvents()
}

# ------------------------------------------------------------
# FUNÇÕES DE SISTEMA
# ------------------------------------------------------------
function Add-DefenderExclusion {
    param([string]$FolderPath)
    try {
        if (-not (Test-Path $FolderPath)) { New-Item -ItemType Directory -Path $FolderPath -Force | Out-Null }
        Safe-Log "Adicionando $FolderPath às exceções do Windows Defender..."
        Add-MpPreference -ExclusionPath $FolderPath -ErrorAction SilentlyContinue
        Safe-Log "Pasta $FolderPath configurada nas exceções."
    } catch {
        Safe-Log "Aviso ao adicionar exceção no Defender: $($_.Exception.Message)"
    }
}

function Download-DllFlyPackage {
    param([string]$PackageName, [string]$Url)
    $sitefDir = "C:\SITEF"
    Add-DefenderExclusion -FolderPath $sitefDir

    $zipPath = Join-Path $env:TEMP "$PackageName.zip"
    try {
        Update-Status "Baixando $PackageName..." 30
        Safe-Log "Baixando pacote $PackageName..."
        
        $userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        Invoke-WebRequest -Uri $Url -OutFile $zipPath -UserAgent $userAgent -UseBasicParsing

        Update-Status "Extraindo $PackageName..." 70
        Safe-Log "Extraindo $PackageName para $sitefDir..."
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $sitefDir)
        
        Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
        Update-Status "Concluído!" 100
        Safe-Log "Pacote $PackageName instalado com sucesso em $sitefDir!"
    } catch {
        Update-Status "Erro." 0
        Safe-Log "ERRO ao processar ${PackageName}: $($_.Exception.Message)"
    }
}

function Install-Sitef {
    $sitefDir = "C:\SITEF"
    Add-DefenderExclusion -FolderPath $sitefDir

    $packages = @(
        @{ Name = "Certificado"; Url = "http://gsurf.com.br/lib/win/certificado.zip"; ZipName = "certificado.zip"; Folder = "Certificado" },
        @{ Name = "GSClient (GSurf)"; Url = "https://gsurf.com.br/lib/win/gsclient.zip"; ZipName = "gsclient.zip"; Folder = "gsclient" }
    )

    $userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    foreach ($pkg in $packages) {
        $extractDir = Join-Path $sitefDir $pkg.Folder
        $zipPath    = Join-Path $sitefDir $pkg.ZipName
        try {
            if (Test-Path $extractDir) { Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
            New-Item -Path $extractDir -ItemType Directory -Force | Out-Null

            Update-Status "Baixando $($pkg.Name)..." 25
            Safe-Log "Baixando pacote $($pkg.Name)..."
            
            Invoke-WebRequest -Uri $pkg.Url -OutFile $zipPath -UserAgent $userAgent -UseBasicParsing
            Safe-Log "Tamanho do arquivo baixado: $((Get-Item $zipPath).Length) bytes"

            Update-Status "Extraindo $($pkg.Name)..." 50
            Safe-Log "Extraindo $($pkg.Name) em $extractDir..."
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDir)

            Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
            Safe-Log "Pacote $($pkg.Name) extraído com sucesso em $extractDir."

            Update-Status "Executando instalador de $($pkg.Name)..." 75
            
            $installer = Get-ChildItem -Path $extractDir -Include "*.exe","*.msi" -File -Recurse | Select-Object -First 1

            if ($null -ne $installer) {
                Safe-Log "Executando instalador principal: $($installer.FullName)..."
                if ($installer.Extension -ieq ".msi") {
                    Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$($installer.FullName)`"" -WorkingDirectory $installer.DirectoryName -Wait
                } else {
                    Start-Process -FilePath $installer.FullName -WorkingDirectory $installer.DirectoryName -Wait
                }
                Safe-Log "Instalação de $($installer.Name) concluída."
            } else {
                Safe-Log "Aviso: Nenhum instalador encontrado em $extractDir."
            }
        } catch {
            Safe-Log "ERRO ao processar $($pkg.Name): $($_.Exception.Message)"
        }
    }

    Update-Status "Iniciando serviços do GSurf..." 90
    Safe-Log "Configurando e iniciando serviços do GSurf..."

    $gsurfServices = @("GSurfRSA Listener", "GSCliSvc", "GSurf")

    foreach ($serviceName in $gsurfServices) {
        $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -ne $svc) {
            try {
                Safe-Log "Definindo o serviço '$serviceName' para inicialização automática..."
                Set-Service -Name $serviceName -StartupType Automatic -ErrorAction SilentlyContinue
                
                if ($svc.Status -ne 'Running') {
                    Safe-Log "Iniciando serviço '$serviceName'..."
                    Start-Service -Name $serviceName -ErrorAction Stop
                    Safe-Log "Serviço '$serviceName' iniciado com sucesso!"
                } else {
                    Safe-Log "O serviço '$serviceName' já está rodando."
                }
            } catch {
                Safe-Log "Erro ao iniciar o serviço ${serviceName}: $($_.Exception.Message)"
            }
        }
    }

    Update-Status "Concluído!" 100
    Safe-Log "Instalação e inicialização dos serviços SiTef / GSURF finalizada com sucesso."
}

function Instalar-MitryusWeb {
    $vetorDir   = "C:\VETOR"
    $tempExtract = Join-Path $env:TEMP "MitryusTemp"
    $zipUrl     = "http://mitryusweb.com.br/mitryusweb/versao/versao.zip"
    $zipPath    = Join-Path $env:TEMP "versao_mitryus.zip"

    Add-DefenderExclusion -FolderPath $vetorDir

    try {
        Update-Status "Baixando MitryusWeb..." 20
        Safe-Log "Iniciando download do MitryusWeb ($zipUrl)..."
        
        $userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UserAgent $userAgent -UseBasicParsing

        Safe-Log "Download concluído! Tamanho: $((Get-Item $zipPath).Length) bytes."

        Update-Status "Extraindo arquivos..." 40
        
        if (Test-Path $tempExtract) { Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -Path $tempExtract -ItemType Directory -Force | Out-Null

        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $tempExtract)
        Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue

        Update-Status "Organizando estrutura em C:\VETOR..." 60
        if (-not (Test-Path $vetorDir)) { New-Item -Path $vetorDir -ItemType Directory -Force | Out-Null }

        $sourcePath = $tempExtract
        if (Test-Path (Join-Path $tempExtract "VETOR")) {
            $sourcePath = Join-Path $tempExtract "VETOR"
        }

        Get-ChildItem -Path $sourcePath | Copy-Item -Destination $vetorDir -Recurse -Force
        Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue

        Update-Status "Copiando DLLs para pastas do sistema..." 80
        $dllSource = Join-Path $vetorDir "MITRYUSWEB\DLL"

        if (Test-Path $dllSource) {
            $sys32  = "$env:SystemRoot\System32"
            $syswow = "$env:SystemRoot\SysWOW64"

            Safe-Log "Copiando DLLs de $dllSource para $sys32 e $syswow..."

            $dllFiles = Get-ChildItem -Path $dllSource -Filter "*.dll" -File
            foreach ($dll in $dllFiles) {
                Copy-Item -Path $dll.FullName -Destination $sys32 -Force -ErrorAction SilentlyContinue
                if (Test-Path $syswow) {
                    Copy-Item -Path $dll.FullName -Destination $syswow -Force -ErrorAction SilentlyContinue
                }
            }
            Safe-Log "$($dllFiles.Count) DLL(s) copiadas com sucesso para o sistema."
        } else {
            Safe-Log "Aviso: A pasta de DLLs '$dllSource' não foi encontrada em $vetorDir."
        }

        Update-Status "Concluído!" 100
        Safe-Log "Instalação do MitryusWeb finalizada com sucesso."
    } catch {
        Update-Status "Erro." 0
        Safe-Log "ERRO ao instalar MitryusWeb: $($_.Exception.Message)"
    }
}

function Instalar-MitryusFly {
    Update-Status "Instalando MitryusFly..." 50
    Safe-Log "Instalando MitryusFly via Windows Store..."
    Start-Process -FilePath "winget.exe" -ArgumentList "install --id 9N5Z8N96BZBQ --source msstore --accept-source-agreements --accept-package-agreements --silent" -Wait -NoNewWindow
    Update-Status "Concluído!" 100
    Safe-Log "MitryusFly finalizado."
}

# ETAPAS DE CONFIGURAÇÃO
function Step-RestorePoint { Enable-ComputerRestore -Drive "$env:SystemDrive\"; Checkpoint-Computer -Description "Provisionamento" -RestorePointType "MODIFY_SETTINGS" -ErrorAction SilentlyContinue }
function Step-IconesAreaTrabalho { $p = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"; New-Item -Path $p -Force | Out-Null; Set-ItemProperty -Path $p -Name "{20D04FE0-3AEA-1069-A2D8-08002B30309D}" -Value 0 -Force; Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Start-Process explorer }
function Step-Telemetria { Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -Value 0 -Force }
function Step-Energia { powercfg /change monitor-timeout-ac 0; powercfg /change standby-timeout-ac 0 }
function Step-RegiaoIdioma { Set-TimeZone -Id "E. South America Standard Time" -ErrorAction SilentlyContinue; Set-WinHomeLocation -GeoId 76 -ErrorAction SilentlyContinue }
function Step-Debloat { @("3dbuilder","bingweather","xboxapp") | ForEach-Object { Get-AppxPackage "*$_*" | Remove-AppxPackage -ErrorAction SilentlyContinue } }
function Step-Chocolatey { if (-not (Get-Command choco -ErrorAction SilentlyContinue)) { iwr https://community.chocolatey.org/install.ps1 -UseBasicParsing | iex } }
function Step-WingetUpgradeAll { winget upgrade --all --accept-source-agreements --accept-package-agreements --silent }

function Build-AppCatalogLabels {
    $script:AppCatalogMap = @{}
    $labels = New-Object System.Collections.ArrayList
    foreach ($id in $ChocoApps) { $l = "[Choco] $id"; $script:AppCatalogMap[$l] = @{ Manager = "choco"; Id = $id }; [void]$labels.Add($l) }
    foreach ($id in $WingetApps) { $l = "[Winget] $id"; $script:AppCatalogMap[$l] = @{ Manager = "winget"; Id = $id }; [void]$labels.Add($l) }
    foreach ($id in $WingetStoreApps) { $l = "[Store] $id"; $script:AppCatalogMap[$l] = @{ Manager = "wingetStore"; Id = $id }; [void]$labels.Add($l) }
    return $labels
}

function Get-InstalledProgramsList {
    $paths = @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*","HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*")
    Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and $_.UninstallString } | Select-Object DisplayName, UninstallString, QuietUninstallString | Sort-Object DisplayName
}

# ============================================================
#  ESTILO E LAYOUT DA INTERFACE (GRID ALINHADO COM ALTURA AJUSTADA)
# ============================================================
$ColorBg       = [System.Drawing.Color]::FromArgb(28, 28, 28)
$ColorCard     = [System.Drawing.Color]::FromArgb(40, 40, 40)
$ColorSidebar  = [System.Drawing.Color]::FromArgb(18, 20, 24)
$ColorText     = [System.Drawing.Color]::FromArgb(240, 243, 246)
$ColorMuted    = [System.Drawing.Color]::FromArgb(140, 148, 160)
$ColorPrimary  = [System.Drawing.Color]::FromArgb(0, 122, 255)
$ColorSuccess  = [System.Drawing.Color]::FromArgb(46, 160, 67)
$ColorDanger   = [System.Drawing.Color]::FromArgb(218, 54, 51)

$FontTitle     = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$FontSubTitle  = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$FontText      = New-Object System.Drawing.Font("Segoe UI", 8.5)
$FontConsole   = New-Object System.Drawing.Font("Consolas", 8.5)

function New-StyledButton {
    param($Text, $Width=220, $Height=32, $BgColor=$ColorPrimary, $Action=$null)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Size = New-Object System.Drawing.Size($Width, $Height)
    $btn.BackColor = $BgColor
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.Font = $FontSubTitle
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 0
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($Action) { $btn.Add_Click($Action) }
    return $btn
}

# DIMENSÕES PADRÃO DOS CARDS PARA MANTER O GRID SIMÉTRICO
$CardWidth  = 450
$CardHeight = 290

function New-CardGroup {
    param($Title)
    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text = " $Title "
    $grp.Size = New-Object System.Drawing.Size($script:CardWidth, $script:CardHeight)
    $grp.ForeColor = $ColorPrimary
    $grp.Font = $FontSubTitle
    $grp.BackColor = $ColorCard
    $grp.Margin = New-Object System.Windows.Forms.Padding(10)
    return $grp
}

# FORMULÁRIO PRINCIPAL COM ALTURA EXPANDIDA PARA 880px
$form = New-Object System.Windows.Forms.Form
$form.Text = "Provisioning Tool v3.0 - Direct Grid"
$form.Size = New-Object System.Drawing.Size(980, 880)
$form.StartPosition = "CenterScreen"
$form.BackColor = $ColorBg
$form.ForeColor = $ColorText
$form.Font = $FontText

# TOP HEADER
$pnlHeader = New-Object System.Windows.Forms.Panel
$pnlHeader.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlHeader.Height = 45
$pnlHeader.BackColor = $ColorSidebar
$form.Controls.Add($pnlHeader)

$lblAppTitle = New-Object System.Windows.Forms.Label
$lblAppTitle.Text = "⚡ INSTALADOR MCNTV"
$lblAppTitle.Font = $FontTitle
$lblAppTitle.ForeColor = $ColorPrimary
$lblAppTitle.AutoSize = $true
$lblAppTitle.Location = New-Object System.Drawing.Point(15, 10)
$pnlHeader.Controls.Add($lblAppTitle)

$btnHeaderScript = New-StyledButton -Text "ATIVAR Windows" -Width 150 -Height 28 -BgColor $ColorPrimary -Action {
    try {
        Safe-Log "Iniciando script de ativação do Windows..."
        $scriptBlock = [scriptblock]::Create((Invoke-RestMethod -Uri "get.activated.win" -UseBasicParsing))
        & $scriptBlock
    } catch { Safe-Log "Erro ao ativar Windows: $($_.Exception.Message)" }
}
$btnHeaderScript.Location = New-Object System.Drawing.Point(240, 8)
$pnlHeader.Controls.Add($btnHeaderScript)

# BOTTOM LOG CONSOLE
$pnlConsole = New-Object System.Windows.Forms.Panel
$pnlConsole.Dock = [System.Windows.Forms.DockStyle]::Bottom
$pnlConsole.Height = 160
$pnlConsole.BackColor = $ColorSidebar
$pnlConsole.Padding = New-Object System.Windows.Forms.Padding(8)
$form.Controls.Add($pnlConsole)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Dock = [System.Windows.Forms.DockStyle]::Top
$progressBar.Height = 5
$pnlConsole.Controls.Add($progressBar)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Sistema Pronto."
$lblStatus.Font = $FontText
$lblStatus.ForeColor = $ColorMuted
$lblStatus.Dock = [System.Windows.Forms.DockStyle]::Bottom
$lblStatus.Height = 18
$pnlConsole.Controls.Add($lblStatus)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(12, 14, 18)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(0, 255, 128)
$txtLog.Font = $FontConsole
$txtLog.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$txtLog.Dock = [System.Windows.Forms.DockStyle]::Fill
$pnlConsole.Controls.Add($txtLog)
$pnlConsole.Controls.SetChildIndex($txtLog, 0)

# PAINEL CENTRAL (FLOW LAYOUT EM GRID)
$flowGrid = New-Object System.Windows.Forms.FlowLayoutPanel
$flowGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
$flowGrid.Padding = New-Object System.Windows.Forms.Padding(10)
$flowGrid.AutoScroll = $true
$form.Controls.Add($flowGrid)
$form.Controls.SetChildIndex($flowGrid, 0)

# ------------------------------------------------------------
# CARD 1: SISTEMAS & DLLs
# ------------------------------------------------------------
$cardSistemas = New-CardGroup -Title "Sistemas & DLLs"
$flowGrid.Controls.Add($cardSistemas)

$btnSitef = New-StyledButton -Text "Instalar SiTef / GSURF" -Width 400 -Height 32 -BgColor $ColorPrimary -Action { Install-Sitef }
$btnSitef.Location = New-Object System.Drawing.Point(25, 30)
$cardSistemas.Controls.Add($btnSitef)

$btnMitryus = New-StyledButton -Text "Instalar MitryusWeb" -Width 400 -Height 32 -BgColor $ColorPrimary -Action { Instalar-MitryusWeb }
$btnMitryus.Location = New-Object System.Drawing.Point(25, 75)
$cardSistemas.Controls.Add($btnMitryus)

$btnMitryusFly = New-StyledButton -Text "Instalar MitryusFly" -Width 400 -Height 32 -BgColor $ColorSuccess -Action { Instalar-MitryusFly }
$btnMitryusFly.Location = New-Object System.Drawing.Point(25, 120)
$cardSistemas.Controls.Add($btnMitryusFly)

$btnDllFly = New-StyledButton -Text "DLL_FLY" -Width 400 -Height 32 -BgColor $ColorPrimary -Action {
    Download-DllFlyPackage -PackageName "DLL_FLY" -Url "https://github.com/c1000x/InstaladorMCNTV/raw/71411a8aa1f8b019f9f85b6980c34bcbe52f44e3/DLL_FLY.zip"
}
$btnDllFly.Location = New-Object System.Drawing.Point(25, 165)
$cardSistemas.Controls.Add($btnDllFly)

$btnDllFlyEmbarcado = New-StyledButton -Text "DLL_FLY_EMBARCADO" -Width 400 -Height 32 -BgColor $ColorPrimary -Action {
    Download-DllFlyPackage -PackageName "DLL_FLY_EMBARCADO" -Url "https://github.com/c1000x/InstaladorMCNTV/raw/71411a8aa1f8b019f9f85b6980c34bcbe52f44e3/DLL_FLY_EMBARCADO.zip"
}
$btnDllFlyEmbarcado.Location = New-Object System.Drawing.Point(25, 210)
$cardSistemas.Controls.Add($btnDllFlyEmbarcado)

# ------------------------------------------------------------
# CARD 2: CONFIGURAÇÕES DO SISTEMA
# ------------------------------------------------------------
$cardConfig = New-CardGroup -Title "Configurações do Sistema"
$flowGrid.Controls.Add($cardConfig)

$steps = [ordered]@{
    "Ponto de Restauração"             = { Step-RestorePoint }
    "Ícones da Área de Trabalho"       = { Step-IconesAreaTrabalho }
    "Desativar Telemetria"             = { Step-Telemetria }
    "Ajustar Plano de Energia"         = { Step-Energia }
    "Fuso Horário / Localização (BR)"  = { Step-RegiaoIdioma }
    "Remover Apps Padrão (Debloat)"    = { Step-Debloat }
    "Instalar/Atualizar Chocolatey"    = { Step-Chocolatey }
    "Atualizar Apps (winget upgrade)"  = { Step-WingetUpgradeAll }
}

$pnlCheckboxes = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlCheckboxes.Location = New-Object System.Drawing.Point(20, 25)
$pnlCheckboxes.Size = New-Object System.Drawing.Size(410, 190)
$pnlCheckboxes.AutoScroll = $true
$cardConfig.Controls.Add($pnlCheckboxes)

$checkboxes = @{}
foreach ($key in $steps.Keys) {
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $key
    $cb.Checked = $true
    $cb.ForeColor = $ColorText
    $cb.Font = $FontText
    $cb.Width = 380
    $cb.Height = 22
    $pnlCheckboxes.Controls.Add($cb)
    $checkboxes[$key] = $cb
}

$btnRun = New-StyledButton -Text "Executar Selecionados" -Width 400 -Height 32 -BgColor $ColorSuccess -Action {
    $selectedSteps = $steps.Keys | Where-Object { $checkboxes[$_].Checked }
    if ($selectedSteps.Count -eq 0) { return }
    $i = 0
    foreach ($key in $selectedSteps) {
        $i++
        Update-Status "Executando: $key..." ([int](($i / $selectedSteps.Count) * 100))
        Safe-Log ">>> Executando: $key"
        try { & $steps[$key] } catch { Safe-Log "ERRO: $($_.Exception.Message)" }
    }
    Update-Status "Concluído." 100
}
$btnRun.Location = New-Object System.Drawing.Point(25, 230)
$cardConfig.Controls.Add($btnRun)

# ------------------------------------------------------------
# CARD 3: INSTALAÇÃO DE APPS
# ------------------------------------------------------------
$cardApps = New-CardGroup -Title "Instalação de Apps"
$flowGrid.Controls.Add($cardApps)

$clbInstall = New-Object System.Windows.Forms.CheckedListBox
$clbInstall.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$clbInstall.ForeColor = $ColorText
$clbInstall.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$clbInstall.Location = New-Object System.Drawing.Point(25, 25)
$clbInstall.Size = New-Object System.Drawing.Size(400, 190)
$clbInstall.CheckOnClick = $true
$allLabels = Build-AppCatalogLabels
foreach ($label in $allLabels) { [void]$clbInstall.Items.Add($label, $true) }
$cardApps.Controls.Add($clbInstall)

$btnInstallApps = New-StyledButton -Text "Instalar Marcados" -Width 400 -Height 32 -BgColor $ColorPrimary -Action {
    $selected = @($clbInstall.CheckedItems)
    if ($selected.Count -eq 0) { return }
    foreach ($label in $selected) {
        $info = $script:AppCatalogMap[$label]
        Update-Status "Instalando $($info.Id)..." 50
        Safe-Log "Instalando $($info.Id)..."
        if ($info.Manager -eq "choco") {
            Start-Process "$env:ProgramData\chocolatey\bin\choco.exe" -ArgumentList "install $($info.Id) -y" -Wait -NoNewWindow
        } else {
            Start-Process "winget.exe" -ArgumentList "install --id $($info.Id) -e --accept-source-agreements --accept-package-agreements --silent" -Wait -NoNewWindow
        }
    }
    Update-Status "Concluído." 100
}
$btnInstallApps.Location = New-Object System.Drawing.Point(25, 230)
$cardApps.Controls.Add($btnInstallApps)

# ------------------------------------------------------------
# CARD 4: DESINSTALAR PROGRAMAS
# ------------------------------------------------------------
$cardUninstall = New-CardGroup -Title "Desinstalar Programas"
$flowGrid.Controls.Add($cardUninstall)

$clbUninstall = New-Object System.Windows.Forms.CheckedListBox
$clbUninstall.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$clbUninstall.ForeColor = $ColorText
$clbUninstall.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$clbUninstall.Location = New-Object System.Drawing.Point(25, 25)
$clbUninstall.Size = New-Object System.Drawing.Size(230, 235)
$clbUninstall.CheckOnClick = $true
$cardUninstall.Controls.Add($clbUninstall)

$btnRefresh = New-StyledButton -Text "Carregar Programas" -Width 150 -Height 35 -BgColor $ColorCard -Action {
    $clbUninstall.Items.Clear()
    $script:UninstallMap = @{}
    Get-InstalledProgramsList | ForEach-Object {
        if (-not $script:UninstallMap.ContainsKey($_.DisplayName)) {
            $cmd = if ($_.QuietUninstallString) { $_.QuietUninstallString } else { $_.UninstallString }
            $script:UninstallMap[$_.DisplayName] = $cmd
            [void]$clbUninstall.Items.Add($_.DisplayName)
        }
    }
}
$btnRefresh.Location = New-Object System.Drawing.Point(270, 25)
$cardUninstall.Controls.Add($btnRefresh)

$btnUninstall = New-StyledButton -Text "Remover Selecionados" -Width 150 -Height 35 -BgColor $ColorDanger -Action {
    $selected = @($clbUninstall.CheckedItems)
    if ($selected.Count -eq 0) { return }
    foreach ($name in $selected) {
        $cmd = $script:UninstallMap[$name]
        Update-Status "Removendo $name..." 50
        Safe-Log "Removendo $name..."
        try {
            if ($cmd -match '^(?:"(?<exe>[^"]+)"|(?<exe>\S+))\s*(?<args>.*)$') {
                Start-Process -FilePath $Matches['exe'] -ArgumentList $Matches['args'] -Wait -NoNewWindow
            }
        } catch { Safe-Log "Erro ao remover ${name}: $($_.Exception.Message)" }
    }
    Update-Status "Concluído." 100
}
$btnUninstall.Location = New-Object System.Drawing.Point(270, 75)
$cardUninstall.Controls.Add($btnUninstall)

[void]$form.ShowDialog()
