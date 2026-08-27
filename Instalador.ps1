<#
    ProvisioningTool.ps1
    Interface com abas separadas para cada função.
    Layout automático com FlowLayoutPanel – sem coordenadas fixas.
    Inclui botões DLL_FLY e DLL_FLY_EMBARCADO na aba SITEF.
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
#  NOVAS FUNÇÕES: DOWNLOAD DLL_FLY E DLL_FLY_EMBARCADO
# ============================================================
function Download-DllFly {
    $log = $script:SitefLogDelegate
    $log.Invoke("=== BAIXANDO DLL_FLY ===")
    $log.Invoke("")

    $baseDir = "C:\SITEF"
    $targetDir = Join-Path $baseDir "DLL_FLY"
    $zipUrl = "https://github.com/c1000x/InstaladorMCNTV/raw/a4dbdb2b2fbbea02d3d4109220199490e4e9e1bf/DLL_FLY.zip"
    $zipFile = Join-Path $baseDir "DLL_FLY.zip"

    # Criar pasta destino
    if (-not (Test-Path $targetDir)) {
        $log.Invoke("Criando diretório $targetDir ...")
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        $log.Invoke("Diretório criado.")
    }

    # Baixar o ZIP
    $log.Invoke("Baixando DLL_FLY.zip (11.6 MB) ...")
    try {
        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
        $webClient.DownloadFile($zipUrl, $zipFile)
        $log.Invoke("Download concluído: $zipFile")
    } catch {
        $log.Invoke("ERRO ao baixar DLL_FLY.zip: $($_.Exception.Message)")
        return
    }

    # Extrair para a pasta DLL_FLY
    $log.Invoke("Extraindo DLL_FLY.zip para $targetDir ...")
    try {
        Expand-Archive -Path $zipFile -DestinationPath $targetDir -Force
        $log.Invoke("Extraído com sucesso.")
    } catch {
        $log.Invoke("ERRO ao extrair DLL_FLY.zip: $($_.Exception.Message)")
        $log.Invoke("Tentando extrair com System.IO.Compression.ZipFile (fallback)...")
        try {
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zipFile, $targetDir, $true)
            $log.Invoke("Extraído com sucesso via fallback.")
        } catch {
            $log.Invoke("Falha na extração: $($_.Exception.Message)")
            return
        }
    }

    # Remover o ZIP após extração
    Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
    $log.Invoke("Arquivo ZIP removido.")

    $log.Invoke("")
    $log.Invoke("=== DLL_FLY INSTALADO COM SUCESSO ===")
    $progressSitef.Value = 100
    [System.Windows.Forms.MessageBox]::Show("DLL_FLY baixado e extraído com sucesso em:`n$targetDir", "DLL_FLY")
}

function Download-DllFlyEmbarcado {
    $log = $script:SitefLogDelegate
    $log.Invoke("=== BAIXANDO DLL_FLY_EMBARCADO ===")
    $log.Invoke("")

    $baseDir = "C:\SITEF"
    $targetDir = Join-Path $baseDir "DLL_FLY_EMBARCADO"
    $zipUrl = "https://github.com/c1000x/InstaladorMCNTV/raw/a4dbdb2b2fbbea02d3d4109220199490e4e9e1bf/DLL_FLY_EMBARCADO.zip"
    $zipFile = Join-Path $baseDir "DLL_FLY_EMBARCADO.zip"

    # Criar pasta destino
    if (-not (Test-Path $targetDir)) {
        $log.Invoke("Criando diretório $targetDir ...")
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        $log.Invoke("Diretório criado.")
    }

    # Baixar o ZIP
    $log.Invoke("Baixando DLL_FLY_EMBARCADO.zip (11.6 MB) ...")
    try {
        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
        $webClient.DownloadFile($zipUrl, $zipFile)
        $log.Invoke("Download concluído: $zipFile")
    } catch {
        $log.Invoke("ERRO ao baixar DLL_FLY_EMBARCADO.zip: $($_.Exception.Message)")
        return
    }

    # Extrair para a pasta DLL_FLY_EMBARCADO
    $log.Invoke("Extraindo DLL_FLY_EMBARCADO.zip para $targetDir ...")
    try {
        Expand-Archive -Path $zipFile -DestinationPath $targetDir -Force
        $log.Invoke("Extraído com sucesso.")
    } catch {
        $log.Invoke("ERRO ao extrair DLL_FLY_EMBARCADO.zip: $($_.Exception.Message)")
        $log.Invoke("Tentando extrair com System.IO.Compression.ZipFile (fallback)...")
        try {
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zipFile, $targetDir, $true)
            $log.Invoke("Extraído com sucesso via fallback.")
        } catch {
            $log.Invoke("Falha na extração: $($_.Exception.Message)")
            return
        }
    }

    # Remover o ZIP após extração
    Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
    $log.Invoke("Arquivo ZIP removido.")

    $log.Invoke("")
    $log.Invoke("=== DLL_FLY_EMBARCADO INSTALADO COM SUCESSO ===")
    $progressSitef.Value = 100
    [System.Windows.Forms.MessageBox]::Show("DLL_FLY_EMBARCADO baixado e extraído com sucesso em:`n$targetDir", "DLL_FLY_EMBARCADO")
}

# ============================================================
#  INTERFACE GRAFICA COM ABAS SEPARADAS E LAYOUT AUTOMÁTICO
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

# ----- Formulário principal com AutoSize -----
$form = New-Object System.Windows.Forms.Form
$form.Text = "MCNTV Installer - Provisionamento Windows"
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
$form.MaximizeBox = $true
$form.MinimizeBox = $true
$form.BackColor = $ColorBackground
$form.Font = $FontNormal
$form.AutoSize = $true
$form.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$form.MinimumSize = New-Object System.Drawing.Size(600, 400)

# ----- Painel principal -----
$mainPanel = New-Object System.Windows.Forms.Panel
$mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$mainPanel.AutoSize = $true
$mainPanel.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$form.Controls.Add($mainPanel)

# ----- TabControl (cada aba é uma função) -----
$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Dock = [System.Windows.Forms.DockStyle]::Fill
$tabControl.Font = $FontNormal
$mainPanel.Controls.Add($tabControl)

# ============================================================
#  ABA 1: CONFIGURAÇÃO DO SISTEMA
# ============================================================
$tabConfig = New-Object System.Windows.Forms.TabPage
$tabConfig.Text = "Configuração do Sistema"
$tabConfig.BackColor = $ColorBackground
$tabControl.Controls.Add($tabConfig)

$flowConfig = New-Object System.Windows.Forms.FlowLayoutPanel
$flowConfig.Dock = [System.Windows.Forms.DockStyle]::Fill
$flowConfig.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$flowConfig.AutoScroll = $true
$flowConfig.WrapContents = $false
$flowConfig.Padding = New-Object System.Windows.Forms.Padding(10)
$tabConfig.Controls.Add($flowConfig)

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
    $flowConfig.Controls.Add($cb)
    $checkboxes[$key] = $cb
}

$chkDryRun = New-Object System.Windows.Forms.CheckBox
$chkDryRun.Text = "Modo Simulacao (dry-run)"
$chkDryRun.Font = $FontNormal
$chkDryRun.ForeColor = [System.Drawing.Color]::DarkBlue
$chkDryRun.AutoSize = $true
$chkDryRun.Margin = New-Object System.Windows.Forms.Padding(3, 10, 3, 5)
$flowConfig.Controls.Add($chkDryRun)

$btnSelAll = New-Object System.Windows.Forms.Button
$btnSelAll.Text = "Marcar todos"
$btnSelAll.Font = $FontButton
$btnSelAll.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSelAll.FlatAppearance.BorderColor = $ColorBorder
$btnSelAll.BackColor = $ColorSurface
$btnSelAll.AutoSize = $true
$btnSelAll.Margin = New-Object System.Windows.Forms.Padding(3, 5, 3, 0)
$btnSelAll.Add_Click({ $checkboxes.Values | ForEach-Object { $_.Checked = $true } })
$flowConfig.Controls.Add($btnSelAll)

$btnSelNone = New-Object System.Windows.Forms.Button
$btnSelNone.Text = "Desmarcar todos"
$btnSelNone.Font = $FontButton
$btnSelNone.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSelNone.FlatAppearance.BorderColor = $ColorBorder
$btnSelNone.BackColor = $ColorSurface
$btnSelNone.AutoSize = $true
$btnSelNone.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 5)
$btnSelNone.Add_Click({ $checkboxes.Values | ForEach-Object { $_.Checked = $false } })
$flowConfig.Controls.Add($btnSelNone)

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = "Executar configuração"
$btnRun.Font = $FontButton
$btnRun.BackColor = $ColorPrimary
$btnRun.ForeColor = [System.Drawing.Color]::White
$btnRun.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnRun.FlatAppearance.BorderSize = 0
$btnRun.AutoSize = $true
$btnRun.Margin = New-Object System.Windows.Forms.Padding(3, 10, 3, 3)
$flowConfig.Controls.Add($btnRun)

# ============================================================
#  ABA 2: INSTALAR APLICATIVOS
# ============================================================
$tabInstall = New-Object System.Windows.Forms.TabPage
$tabInstall.Text = "Instalar Aplicativos"
$tabInstall.BackColor = $ColorBackground
$tabControl.Controls.Add($tabInstall)

$flowInstall = New-Object System.Windows.Forms.FlowLayoutPanel
$flowInstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$flowInstall.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$flowInstall.AutoScroll = $true
$flowInstall.WrapContents = $false
$flowInstall.Padding = New-Object System.Windows.Forms.Padding(10)
$tabInstall.Controls.Add($flowInstall)

$lblInstallInfo = New-Object System.Windows.Forms.Label
$lblInstallInfo.Text = "Buscar:"
$lblInstallInfo.Font = $FontNormal
$lblInstallInfo.ForeColor = $ColorMuted
$lblInstallInfo.AutoSize = $true
$lblInstallInfo.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 0)
$flowInstall.Controls.Add($lblInstallInfo)

$txtSearchInstall = New-Object System.Windows.Forms.TextBox
$txtSearchInstall.Font = $FontNormal
$txtSearchInstall.Width = 300
$txtSearchInstall.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 5)
$flowInstall.Controls.Add($txtSearchInstall)

$clbInstall = New-Object System.Windows.Forms.CheckedListBox
$clbInstall.CheckOnClick = $true
$clbInstall.Font = $FontNormal
$clbInstall.Height = 200
$clbInstall.Width = 350
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
$btnInstallSelected.Margin = New-Object System.Windows.Forms.Padding(3, 10, 3, 3)
$flowInstall.Controls.Add($btnInstallSelected)

# ============================================================
#  ABA 3: GERENCIAR APLICATIVOS
# ============================================================
$tabUninstall = New-Object System.Windows.Forms.TabPage
$tabUninstall.Text = "Gerenciar Aplicativos"
$tabUninstall.BackColor = $ColorBackground
$tabControl.Controls.Add($tabUninstall)

$flowUninstall = New-Object System.Windows.Forms.FlowLayoutPanel
$flowUninstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$flowUninstall.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$flowUninstall.AutoScroll = $true
$flowUninstall.WrapContents = $false
$flowUninstall.Padding = New-Object System.Windows.Forms.Padding(10)
$tabUninstall.Controls.Add($flowUninstall)

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
$clbUninstall.Height = 200
$clbUninstall.Width = 350
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
#  ABA 4: SITEF (COM BOTÕES DLL_FLY E DLL_FLY_EMBARCADO)
# ============================================================
$tabSitef = New-Object System.Windows.Forms.TabPage
$tabSitef.Text = "SITEF"
$tabSitef.BackColor = $ColorBackground
$tabControl.Controls.Add($tabSitef)

$flowSitef = New-Object System.Windows.Forms.FlowLayoutPanel
$flowSitef.Dock = [System.Windows.Forms.DockStyle]::Fill
$flowSitef.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$flowSitef.AutoScroll = $true
$flowSitef.WrapContents = $false
$flowSitef.Padding = New-Object System.Windows.Forms.Padding(10)
$tabSitef.Controls.Add($flowSitef)

$lblSitefTitle = New-Object System.Windows.Forms.Label
$lblSitefTitle.Text = "Instalação do Ambiente SITEF"
$lblSitefTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 12)
$lblSitefTitle.ForeColor = $ColorText
$lblSitefTitle.AutoSize = $true
$lblSitefTitle.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 5)
$flowSitef.Controls.Add($lblSitefTitle)

$lblSitefDesc = New-Object System.Windows.Forms.Label
$lblSitefDesc.Text = "Esta etapa irá baixar, extrair e executar os instaladores do SITEF.`n" +
                     "Após a execução, você deverá configurar manualmente os programas.`n" +
                     "Ao fechar os instaladores, o serviço 'GSurfRSA Listener' será iniciado." +
                     "`n`nOs botões abaixo baixam e extraem os pacotes DLL_FLY e DLL_FLY_EMBARCADO."
$lblSitefDesc.Font = $FontNormal
$lblSitefDesc.ForeColor = $ColorMuted
$lblSitefDesc.AutoSize = $true
$lblSitefDesc.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 10)
$flowSitef.Controls.Add($lblSitefDesc)

# --- BOTÃO: Instalar SITEF (existente) ---
$btnSitefInstall = New-Object System.Windows.Forms.Button
$btnSitefInstall.Text = "Instalar SITEF"
$btnSitefInstall.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$btnSitefInstall.BackColor = $ColorPrimary
$btnSitefInstall.ForeColor = [System.Drawing.Color]::White
$btnSitefInstall.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSitefInstall.FlatAppearance.BorderSize = 0
$btnSitefInstall.AutoSize = $true
$btnSitefInstall.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 5)
$flowSitef.Controls.Add($btnSitefInstall)

# --- BOTÃO: DLL_FLY (NOVO) ---
$btnDllFly = New-Object System.Windows.Forms.Button
$btnDllFly.Text = "DLL_FLY"
$btnDllFly.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$btnDllFly.BackColor = $ColorPrimary
$btnDllFly.ForeColor = [System.Drawing.Color]::White
$btnDllFly.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnDllFly.FlatAppearance.BorderSize = 0
$btnDllFly.AutoSize = $true
$btnDllFly.Margin = New-Object System.Windows.Forms.Padding(3, 5, 3, 5)
$flowSitef.Controls.Add($btnDllFly)

# --- BOTÃO: DLL_FLY_EMBARCADO (NOVO) ---
$btnDllFlyEmbarcado = New-Object System.Windows.Forms.Button
$btnDllFlyEmbarcado.Text = "DLL_FLY_EMBARCADO"
$btnDllFlyEmbarcado.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$btnDllFlyEmbarcado.BackColor = $ColorPrimary
$btnDllFlyEmbarcado.ForeColor = [System.Drawing.Color]::White
$btnDllFlyEmbarcado.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnDllFlyEmbarcado.FlatAppearance.BorderSize = 0
$btnDllFlyEmbarcado.AutoSize = $true
$btnDllFlyEmbarcado.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 10)
$flowSitef.Controls.Add($btnDllFlyEmbarcado)

# --- BOTÃO: Abrir pasta (existente) ---
$btnSitefOpenFolder = New-Object System.Windows.Forms.Button
$btnSitefOpenFolder.Text = "Abrir pasta C:\SITEF"
$btnSitefOpenFolder.Font = $FontButton
$btnSitefOpenFolder.BackColor = $ColorSurface
$btnSitefOpenFolder.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSitefOpenFolder.FlatAppearance.BorderColor = $ColorBorder
$btnSitefOpenFolder.AutoSize = $true
$btnSitefOpenFolder.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 10)
$flowSitef.Controls.Add($btnSitefOpenFolder)

# Progresso
$progressSitef = New-Object System.Windows.Forms.ProgressBar
$progressSitef.Height = 20
$progressSitef.Width = 500
$progressSitef.Minimum = 0
$progressSitef.Maximum = 100
$progressSitef.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 5)
$flowSitef.Controls.Add($progressSitef)

# Log
$lblSitefLog = New-Object System.Windows.Forms.Label
$lblSitefLog.Text = "Log da instalação SITEF:"
$lblSitefLog.Font = $FontNormal
$lblSitefLog.ForeColor = $ColorMuted
$lblSitefLog.AutoSize = $true
$lblSitefLog.Margin = New-Object System.Windows.Forms.Padding(3, 5, 3, 0)
$flowSitef.Controls.Add($lblSitefLog)

$txtSitefLog = New-Object System.Windows.Forms.TextBox
$txtSitefLog.Multiline = $true
$txtSitefLog.ScrollBars = "Vertical"
$txtSitefLog.ReadOnly = $true
$txtSitefLog.Height = 200
$txtSitefLog.Width = 600
$txtSitefLog.Font = New-Object System.Drawing.Font("Consolas", 8)
$txtSitefLog.BackColor = [System.Drawing.Color]::White
$txtSitefLog.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 3)
$flowSitef.Controls.Add($txtSitefLog)

# ============================================================
#  STATUS (painel inferior fixo) – visível em todas as abas
# ============================================================
$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
$statusPanel.Height = 150
$statusPanel.BackColor = $ColorBackground
$mainPanel.Controls.Add($statusPanel)

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
$progressBar.Width = 500
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
$txtLog.Height = 60
$txtLog.Width = 500
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
#  EVENTOS DOS BOTÕES (TODOS)
# ============================================================

# --- Evento: Executar configuração ---
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

# --- Evento: Instalar selecionados (paralelo) ---
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

# --- Evento: Ativar Windows (personalizado) ---
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

# --- Evento: Atualizar lista de instalados ---
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

# --- Evento: Desinstalar selecionados ---
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

# --- Evento: Instalar SITEF (completo) ---
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

# --- Evento: DLL_FLY ---
$btnDllFly.Add_Click({
    $btnDllFly.Enabled = $false
    $txtSitefLog.Clear()
    $progressSitef.Value = 0
    try {
        Download-DllFly
    } catch {
        $txtSitefLog.AppendText("ERRO inesperado: $($_.Exception.Message)`r`n")
    }
    $btnDllFly.Enabled = $true
})

# --- Evento: DLL_FLY_EMBARCADO ---
$btnDllFlyEmbarcado.Add_Click({
    $btnDllFlyEmbarcado.Enabled = $false
    $txtSitefLog.Clear()
    $progressSitef.Value = 0
    try {
        Download-DllFlyEmbarcado
    } catch {
        $txtSitefLog.AppendText("ERRO inesperado: $($_.Exception.Message)`r`n")
    }
    $btnDllFlyEmbarcado.Enabled = $true
})

# --- Evento: Abrir pasta C:\SITEF ---
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
