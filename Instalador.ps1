<#
    ProvisioningTool.ps1
    Interface grafica para provisionamento de maquinas Windows.
    Layout com TableLayoutPanel – adapta-se automaticamente ao redimensionamento da janela.
    Todas as funções e eventos incluídos.

    Alterações desta revisão:
    - Corrigido bug em $btnRun.Add_Click onde $selectedSteps.Count nunca era 0
      (Where-Object retorna $null quando nenhum item passa no filtro, e $null.Count
      não gera erro nem é igual a 0). Agora o resultado é forçado a array com @(...).
    - Install-Sitef agora tenta baixar/extrair AMBOS os arquivos mesmo que um falhe,
      reporta claramente quais falharam, e só executa os instaladores se os dois
      arquivos necessários (.msi e .exe) estiverem realmente presentes.
    - Layout da coluna "3. Gerenciar aplicativos instalados" reescrito com
      TableLayoutPanel (Dock=Fill) em vez de posicionamento absoluto por pixel,
      corrigindo o problema da coluna não aparecer inteira ao redimensionar a janela.
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
#  FUNCOES DE CADA ETAPA (Provisionamento)
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
#  (revisada: tenta baixar/extrair AMBOS os arquivos mesmo que um falhe,
#   e só dispara os instaladores se os dois arquivos necessários existirem)
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

    # Rastreia sucesso/falha de cada arquivo individualmente, em vez de abortar
    # tudo no primeiro problema.
    $itemStatus = @{}

    foreach ($item in $zipUrls) {
        $url = $item.url
        $fileName = $item.nome
        $zipPath = Join-Path $sitefDir $fileName
        $extractPath = Join-Path $sitefDir ([System.IO.Path]::GetFileNameWithoutExtension($fileName))
        $itemStatus[$fileName] = $false

        if (Test-Path $zipPath) {
            $log.Invoke("Arquivo $fileName já existe. Verificando integridade...")
            try {
                if (-not (Test-Path $extractPath)) { New-Item -ItemType Directory -Path $extractPath -Force | Out-Null }
                Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
                $log.Invoke("Extraído com sucesso (arquivo existente).")
                $progressSitef.Value += 2
                $itemStatus[$fileName] = $true
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
            $log.Invoke("Pulando '$fileName' e tentando o próximo arquivo, se houver.")
            continue
        }

        $bytes = [System.IO.File]::ReadAllBytes($zipPath)
        $isZip = $bytes.Count -ge 4 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B -and $bytes[2] -eq 0x03 -and $bytes[3] -eq 0x04
        if (-not $isZip) {
            $log.Invoke("ERRO: O arquivo baixado '$fileName' não é um ZIP válido (cabeçalho inválido).")
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            $log.Invoke("Pulando '$fileName' e tentando o próximo arquivo, se houver.")
            continue
        }

        $log.Invoke("Extraindo $fileName para $extractPath ...")
        try {
            if (-not (Test-Path $extractPath)) { New-Item -ItemType Directory -Path $extractPath -Force | Out-Null }
            Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
            $log.Invoke("Extraído com sucesso.")
            $progressSitef.Value += 1
            $itemStatus[$fileName] = $true
        } catch {
            $log.Invoke("ERRO ao extrair com Expand-Archive: $($_.Exception.Message)")
            $log.Invoke("Tentando extrair com System.IO.Compression.ZipFile (fallback)...")
            try {
                [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractPath, $true)
                $log.Invoke("Extraído com sucesso via fallback.")
                $progressSitef.Value += 1
                $itemStatus[$fileName] = $true
            } catch {
                $log.Invoke("Falha na extração de '$fileName': $($_.Exception.Message)")
                Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                $log.Invoke("Pulando '$fileName' e tentando o próximo arquivo, se houver.")
                continue
            }
        }
    }

    $log.Invoke("")
    $falhas = $itemStatus.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key }
    if ($falhas) {
        $log.Invoke("Os seguintes arquivos NÃO foram baixados/extraídos com sucesso: $($falhas -join ', ')")
    } else {
        $log.Invoke("Todos os arquivos foram baixados e extraídos com sucesso.")
    }

    $msiPath = Get-ChildItem -Path $sitefDir -Recurse -Filter "GSurfRSA_Listener_Setup.msi" -ErrorAction SilentlyContinue | Select-Object -First 1
    $exePath = Get-ChildItem -Path $sitefDir -Recurse -Filter "InstaladorGSurf.exe" -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $msiPath) {
        $log.Invoke("ERRO: Arquivo GSurfRSA_Listener_Setup.msi não encontrado. Instalação abortada.")
        return
    }
    if (-not $exePath) {
        $log.Invoke("ERRO: Arquivo InstaladorGSurf.exe não encontrado. Instalação abortada.")
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
#  INTERFACE GRAFICA (COM TABLELAYOUTPANEL)
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

# Criar o formulário com tamanho inicial adequado
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

# Panel principal com scroll
$mainPanel = New-Object System.Windows.Forms.Panel
$mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$mainPanel.AutoScroll = $true
$form.Controls.Add($mainPanel)

# ============================================================
#  CABECALHO (fixo no topo)
# ============================================================
$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$headerPanel.Height = 70
$headerPanel.BackColor = $ColorBackground
$mainPanel.Controls.Add($headerPanel)

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

# ============================================================
#  CONTEÚDO PRINCIPAL (TabControl + Status)
# ============================================================
$contentPanel = New-Object System.Windows.Forms.Panel
$contentPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$contentPanel.BackColor = $ColorBackground
$mainPanel.Controls.Add($contentPanel)

# TabControl (ocupa 70% da altura)
$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Dock = [System.Windows.Forms.DockStyle]::Fill
$tabControl.Font = $FontNormal
$contentPanel.Controls.Add($tabControl)

# Painel de status (altura fixa na parte inferior)
$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
$statusPanel.Height = 210
$statusPanel.BackColor = $ColorBackground
$contentPanel.Controls.Add($statusPanel)

# ============================================================
#  ABA PROVISIONAMENTO (COM TABLELAYOUTPANEL)
# ============================================================
$tabProvisioning = New-Object System.Windows.Forms.TabPage
$tabProvisioning.Text = "Provisionamento"
$tabProvisioning.BackColor = $ColorBackground
$tabControl.Controls.Add($tabProvisioning)

# TableLayoutPanel com 3 colunas iguais
$tableLayout = New-Object System.Windows.Forms.TableLayoutPanel
$tableLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$tableLayout.ColumnCount = 3
$tableLayout.RowCount = 1
$tableLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.33)))
$tableLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.33)))
$tableLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.34)))
$tableLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$tableLayout.Padding = New-Object System.Windows.Forms.Padding(10, 10, 10, 10)
$tableLayout.BackColor = $ColorBackground
$tabProvisioning.Controls.Add($tableLayout)

# ----- GRUPO 1: Configuração -----
$grpSystem = New-Object System.Windows.Forms.GroupBox
$grpSystem.Text = "1. Configuracao do sistema"
$grpSystem.Font = $FontHeader
$grpSystem.ForeColor = $ColorText
$grpSystem.Dock = [System.Windows.Forms.DockStyle]::Fill
$grpSystem.Padding = New-Object System.Windows.Forms.Padding(10, 20, 10, 10)
$tableLayout.Controls.Add($grpSystem, 0, 0)

$panelSystem = New-Object System.Windows.Forms.Panel
$panelSystem.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelSystem.AutoScroll = $true
$grpSystem.Controls.Add($panelSystem)

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
$y = 10
foreach ($key in $steps.Keys) {
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $key
    $cb.Checked = -not ($UncheckedByDefault -contains $key)
    $cb.Location = New-Object System.Drawing.Point(10, $y)
    $cb.Size = New-Object System.Drawing.Size(350, 22)
    $cb.Font = $FontNormal
    $cb.ForeColor = $ColorText
    $cb.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $panelSystem.Controls.Add($cb)
    $checkboxes[$key] = $cb
    $y += 26
}

$chkDryRun = New-Object System.Windows.Forms.CheckBox
$chkDryRun.Text = "Modo Simulacao (dry-run)"
$chkDryRun.Location = New-Object System.Drawing.Point(10, $y + 3)
$chkDryRun.Size = New-Object System.Drawing.Size(350, 22)
$chkDryRun.Font = $FontNormal
$chkDryRun.ForeColor = [System.Drawing.Color]::DarkBlue
$chkDryRun.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$panelSystem.Controls.Add($chkDryRun)

$btnSelAll = New-Object System.Windows.Forms.Button
$btnSelAll.Text = "Marcar todos"
$btnSelAll.Location = New-Object System.Drawing.Point(10, $y + 35)
$btnSelAll.Size = New-Object System.Drawing.Size(150, 30)
$btnSelAll.Font = $FontButton
$btnSelAll.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSelAll.FlatAppearance.BorderColor = $ColorBorder
$btnSelAll.BackColor = $ColorSurface
$btnSelAll.Add_Click({ $checkboxes.Values | ForEach-Object { $_.Checked = $true } })
$panelSystem.Controls.Add($btnSelAll)

$btnSelNone = New-Object System.Windows.Forms.Button
$btnSelNone.Text = "Desmarcar todos"
$btnSelNone.Location = New-Object System.Drawing.Point(180, $y + 35)
$btnSelNone.Size = New-Object System.Drawing.Size(150, 30)
$btnSelNone.Font = $FontButton
$btnSelNone.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSelNone.FlatAppearance.BorderColor = $ColorBorder
$btnSelNone.BackColor = $ColorSurface
$btnSelNone.Add_Click({ $checkboxes.Values | ForEach-Object { $_.Checked = $false } })
$panelSystem.Controls.Add($btnSelNone)

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = "Executar configuracao"
$btnRun.Location = New-Object System.Drawing.Point(10, $y + 80)
$btnRun.Size = New-Object System.Drawing.Size(320, 30)
$btnRun.Font = $FontButton
$btnRun.BackColor = $ColorPrimary
$btnRun.ForeColor = [System.Drawing.Color]::White
$btnRun.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnRun.FlatAppearance.BorderSize = 0
$btnRun.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$panelSystem.Controls.Add($btnRun)

# ----- GRUPO 2: Instalar -----
$grpInstall = New-Object System.Windows.Forms.GroupBox
$grpInstall.Text = "2. Instalar aplicativos"
$grpInstall.Font = $FontHeader
$grpInstall.ForeColor = $ColorText
$grpInstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$grpInstall.Padding = New-Object System.Windows.Forms.Padding(10, 20, 10, 10)
$tableLayout.Controls.Add($grpInstall, 1, 0)

$panelInstall = New-Object System.Windows.Forms.Panel
$panelInstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelInstall.AutoScroll = $true
$grpInstall.Controls.Add($panelInstall)

$lblInstallInfo = New-Object System.Windows.Forms.Label
$lblInstallInfo.Text = "Buscar:"
$lblInstallInfo.Font = $FontNormal
$lblInstallInfo.ForeColor = $ColorMuted
$lblInstallInfo.Location = New-Object System.Drawing.Point(10, 10)
$lblInstallInfo.Size = New-Object System.Drawing.Size(50, 22)
$panelInstall.Controls.Add($lblInstallInfo)

$txtSearchInstall = New-Object System.Windows.Forms.TextBox
$txtSearchInstall.Location = New-Object System.Drawing.Point(60, 10)
$txtSearchInstall.Size = New-Object System.Drawing.Size(250, 22)
$txtSearchInstall.Font = $FontNormal
$txtSearchInstall.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$panelInstall.Controls.Add($txtSearchInstall)

$clbInstall = New-Object System.Windows.Forms.CheckedListBox
$clbInstall.Location = New-Object System.Drawing.Point(10, 40)
$clbInstall.Size = New-Object System.Drawing.Size(300, 230)
$clbInstall.CheckOnClick = $true
$clbInstall.Font = $FontNormal
$clbInstall.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
$allLabels = Build-AppCatalogLabels
$clbInstall.Tag = $allLabels
foreach ($label in $allLabels) { [void]$clbInstall.Items.Add($label, $true) }
$panelInstall.Controls.Add($clbInstall)

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
$btnInstallSelected.Location = New-Object System.Drawing.Point(10, 275)
$btnInstallSelected.Size = New-Object System.Drawing.Size(300, 40)
$btnInstallSelected.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$btnInstallSelected.BackColor = $ColorSuccess
$btnInstallSelected.ForeColor = [System.Drawing.Color]::White
$btnInstallSelected.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnInstallSelected.FlatAppearance.BorderSize = 0
$btnInstallSelected.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$panelInstall.Controls.Add($btnInstallSelected)

# ----- GRUPO 3: Remover (layout reescrito com TableLayoutPanel / Dock=Fill) -----
$grpUninstall = New-Object System.Windows.Forms.GroupBox
$grpUninstall.Text = "3. Gerenciar aplicativos instalados"
$grpUninstall.Font = $FontHeader
$grpUninstall.ForeColor = $ColorText
$grpUninstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$grpUninstall.Padding = New-Object System.Windows.Forms.Padding(10, 20, 10, 10)
$tableLayout.Controls.Add($grpUninstall, 2, 0)

# TableLayoutPanel com 4 linhas: label (auto), lista (100%), botoes (auto), botao ativar (auto).
# Dock=Fill em cada linha garante que a coluna inteira sempre fique visível,
# independente do tamanho da janela — em vez de posicionar por pixel fixo.
$tableUninstall = New-Object System.Windows.Forms.TableLayoutPanel
$tableUninstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$tableUninstall.ColumnCount = 1
$tableUninstall.RowCount = 4
$tableUninstall.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$tableUninstall.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$tableUninstall.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$tableUninstall.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$grpUninstall.Controls.Add($tableUninstall)

$lblUninstallInfo = New-Object System.Windows.Forms.Label
$lblUninstallInfo.Text = "Atualize a lista e selecione o que deseja remover:"
$lblUninstallInfo.Font = $FontNormal
$lblUninstallInfo.ForeColor = $ColorMuted
$lblUninstallInfo.AutoSize = $false
$lblUninstallInfo.Dock = [System.Windows.Forms.DockStyle]::Top
$lblUninstallInfo.Height = 22
$lblUninstallInfo.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
$tableUninstall.Controls.Add($lblUninstallInfo, 0, 0)

$clbUninstall = New-Object System.Windows.Forms.CheckedListBox
$clbUninstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$clbUninstall.CheckOnClick = $true
$clbUninstall.Font = $FontNormal
$clbUninstall.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
$tableUninstall.Controls.Add($clbUninstall, 0, 1)

# Linha de botões "Atualizar lista" / "Desinstalar" lado a lado, cada um ocupando 50%
$panelUninstallButtons = New-Object System.Windows.Forms.TableLayoutPanel
$panelUninstallButtons.Dock = [System.Windows.Forms.DockStyle]::Top
$panelUninstallButtons.Height = 38
$panelUninstallButtons.ColumnCount = 2
$panelUninstallButtons.RowCount = 1
$panelUninstallButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
$panelUninstallButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
$panelUninstallButtons.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$tableUninstall.Controls.Add($panelUninstallButtons, 0, 2)

$btnRefreshInstalled = New-Object System.Windows.Forms.Button
$btnRefreshInstalled.Text = "Atualizar lista"
$btnRefreshInstalled.Dock = [System.Windows.Forms.DockStyle]::Fill
$btnRefreshInstalled.Margin = New-Object System.Windows.Forms.Padding(0, 4, 4, 4)
$btnRefreshInstalled.Font = $FontButton
$btnRefreshInstalled.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnRefreshInstalled.FlatAppearance.BorderColor = $ColorBorder
$btnRefreshInstalled.BackColor = $ColorSurface
$panelUninstallButtons.Controls.Add($btnRefreshInstalled, 0, 0)

$btnUninstallSelected = New-Object System.Windows.Forms.Button
$btnUninstallSelected.Text = "Desinstalar"
$btnUninstallSelected.Dock = [System.Windows.Forms.DockStyle]::Fill
$btnUninstallSelected.Margin = New-Object System.Windows.Forms.Padding(4, 4, 0, 4)
$btnUninstallSelected.Font = $FontButton
$btnUninstallSelected.BackColor = $ColorDanger
$btnUninstallSelected.ForeColor = [System.Drawing.Color]::White
$btnUninstallSelected.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnUninstallSelected.FlatAppearance.BorderSize = 0
$panelUninstallButtons.Controls.Add($btnUninstallSelected, 1, 0)

$btnCustom = New-Object System.Windows.Forms.Button
$btnCustom.Text = $CustomScriptLabel
$btnCustom.Dock = [System.Windows.Forms.DockStyle]::Top
$btnCustom.Height = 32
$btnCustom.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
$btnCustom.Font = $FontButton
$btnCustom.BackColor = $ColorSurface
$btnCustom.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnCustom.FlatAppearance.BorderColor = $ColorBorder
$tableUninstall.Controls.Add($btnCustom, 0, 3)

# ============================================================
#  ABA SITEF
# ============================================================
$tabSitef = New-Object System.Windows.Forms.TabPage
$tabSitef.Text = "SITEF"
$tabSitef.BackColor = $ColorBackground
$tabControl.Controls.Add($tabSitef)

$panelSitef = New-Object System.Windows.Forms.Panel
$panelSitef.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelSitef.AutoScroll = $true
$panelSitef.Padding = New-Object System.Windows.Forms.Padding(20)
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
$progressSitef.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
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
$txtSitefLog.Size = New-Object System.Drawing.Size(700, 200)
$txtSitefLog.Font = New-Object System.Drawing.Font("Consolas", 8)
$txtSitefLog.BackColor = [System.Drawing.Color]::White
$txtSitefLog.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
$panelSitef.Controls.Add($txtSitefLog)

# ============================================================
#  STATUS GERAL
# ============================================================
$grpStatus = New-Object System.Windows.Forms.GroupBox
$grpStatus.Text = "Status Geral"
$grpStatus.Font = $FontHeader
$grpStatus.ForeColor = $ColorText
$grpStatus.Dock = [System.Windows.Forms.DockStyle]::Fill
$grpStatus.Padding = New-Object System.Windows.Forms.Padding(10, 20, 10, 10)
$statusPanel.Controls.Add($grpStatus)

$panelStatusInner = New-Object System.Windows.Forms.Panel
$panelStatusInner.Dock = [System.Windows.Forms.DockStyle]::Fill
$grpStatus.Controls.Add($panelStatusInner)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(10, 10)
$progressBar.Size = New-Object System.Drawing.Size(700, 20)
$progressBar.Minimum = 0
$progressBar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$panelStatusInner.Controls.Add($progressBar)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Pronto para instalar"
$lblStatus.Font = $FontNormal
$lblStatus.ForeColor = $ColorSuccess
$lblStatus.Location = New-Object System.Drawing.Point(10, 35)
$lblStatus.Size = New-Object System.Drawing.Size(330, 22)
$panelStatusInner.Controls.Add($lblStatus)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Location = New-Object System.Drawing.Point(10, 62)
$txtLog.Size = New-Object System.Drawing.Size(700, 120)
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 8)
$txtLog.BackColor = [System.Drawing.Color]::White
$txtLog.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
$panelStatusInner.Controls.Add($txtLog)

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

    # CORREÇÃO: forçar array com @(...). Sem isso, quando nenhuma etapa está
    # marcada, Where-Object retorna $null e "$null.Count -eq 0" nunca é $true,
    # então o aviso de "nenhuma etapa selecionada" nunca aparecia.
    $selectedSteps = @($steps.Keys | Where-Object { $checkboxes[$_].Checked })

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
