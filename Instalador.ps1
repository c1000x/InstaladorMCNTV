<#
    ProvisioningTool.ps1
    Interface com MENU LATERAL (sidebar) em vez de abas.
    Cada seção é um painel que aparece/desaparece ao clicar no menu.
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
    "7zip.7zip",
    "Microsoft.Office"
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
        $Log.Invoke("Fuso horario (Brasilia) definido com sucesso.")
    } catch {
        $Log.Invoke("Aviso: não foi possível definir o fuso horário: $($_.Exception.Message)")
    }

    try {
        Set-WinHomeLocation -GeoId 76 -ErrorAction Stop
        $Log.Invoke("Localização (Brasil) definida com sucesso.")
    } catch {
        $Log.Invoke("Aviso: não foi possível definir a localização (GeoId 76). Isso é comum em edições sem suporte a idiomas adicionais. O fuso horário já foi ajustado.")
        try {
            Set-WinHomeLocation -GeoId 76 -ErrorAction SilentlyContinue
        } catch {
            # Ignora
        }
    }
    $Log.Invoke("Configuração de região concluída.")
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
#  CATALOGO DE PROGRAMAS
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
#  FUNÇÕES SITEF (COM CORREÇÃO DAS DLLS)
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

function Download-DllFly {
    $log = $script:SitefLogDelegate
    $log.Invoke("=== BAIXANDO DLL_FLY ===")
    $log.Invoke("")

    $progressSitef.Maximum = 100
    $progressSitef.Value = 0

    $baseDir = "C:\SITEF"
    $targetDir = Join-Path $baseDir "DLL_FLY"
    $zipUrl = "https://github.com/c1000x/InstaladorMCNTV/raw/a4dbdb2b2fbbea02d3d4109220199490e4e9e1bf/DLL_FLY.zip"
    $zipFile = Join-Path $baseDir "DLL_FLY.zip"
    $tempExtractDir = Join-Path $baseDir "DLL_FLY_temp"

    if (-not (Test-Path $targetDir)) {
        $log.Invoke("Criando diretório $targetDir ...")
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        $log.Invoke("Diretório criado.")
    }

    $log.Invoke("Baixando DLL_FLY.zip (11.6 MB) ...")
    try {
        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
        $webClient.DownloadFile($zipUrl, $zipFile)
        $log.Invoke("Download concluído: $zipFile")
        $progressSitef.Value = 30
    } catch {
        $log.Invoke("ERRO ao baixar DLL_FLY.zip: $($_.Exception.Message)")
        return
    }

    $log.Invoke("Extraindo DLL_FLY.zip ...")
    try {
        if (Test-Path $tempExtractDir) { Remove-Item $tempExtractDir -Recurse -Force }
        New-Item -ItemType Directory -Path $tempExtractDir -Force | Out-Null
        Expand-Archive -Path $zipFile -DestinationPath $tempExtractDir -Force
        $log.Invoke("Extraído para pasta temporária.")
        $progressSitef.Value = 60
    } catch {
        $log.Invoke("ERRO ao extrair DLL_FLY.zip: $($_.Exception.Message)")
        Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
        Remove-Item $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
        return
    }

    # Verificar se a extração criou uma única subpasta
    $subItems = Get-ChildItem -Path $tempExtractDir
    if ($subItems.Count -eq 1 -and $subItems[0].PSIsContainer) {
        $sourceDir = $subItems[0].FullName
        $log.Invoke("Detectada subpasta raiz: $($subItems[0].Name). Movendo conteúdo para $targetDir ...")
        Get-ChildItem -Path $sourceDir -Recurse -File | ForEach-Object {
            $relativePath = $_.FullName.Substring($sourceDir.Length + 1)
            $destFile = Join-Path $targetDir $relativePath
            $destDir = Split-Path $destFile -Parent
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            Move-Item -Path $_.FullName -Destination $destFile -Force
        }
    } else {
        $log.Invoke("Movendo arquivos diretamente para $targetDir ...")
        Get-ChildItem -Path $tempExtractDir -Recurse -File | ForEach-Object {
            $relativePath = $_.FullName.Substring($tempExtractDir.Length + 1)
            $destFile = Join-Path $targetDir $relativePath
            $destDir = Split-Path $destFile -Parent
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            Move-Item -Path $_.FullName -Destination $destFile -Force
        }
    }

    Remove-Item $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    $log.Invoke("Arquivos organizados.")
    $progressSitef.Value = 80

    Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
    $log.Invoke("Arquivo ZIP removido.")

    $log.Invoke("Adicionando exclusão no Windows Defender para: $targetDir")
    try {
        Add-MpPreference -ExclusionPath $targetDir -ErrorAction Stop
        $log.Invoke("Exclusão adicionada com sucesso.")
        $progressSitef.Value = 95
    } catch {
        $log.Invoke("Aviso: não foi possível adicionar exclusão no Windows Defender: $($_.Exception.Message)")
        $progressSitef.Value = 95
    }

    $log.Invoke("")
    $log.Invoke("=== DLL_FLY INSTALADO COM SUCESSO ===")
    $progressSitef.Value = 100
    [System.Windows.Forms.MessageBox]::Show("DLL_FLY baixado, extraído e adicionado à exclusão do Windows Defender com sucesso em:`n$targetDir", "DLL_FLY")
}

function Download-DllFlyEmbarcado {
    $log = $script:SitefLogDelegate
    $log.Invoke("=== BAIXANDO DLL_FLY_EMBARCADO ===")
    $log.Invoke("")

    $progressSitef.Maximum = 100
    $progressSitef.Value = 0

    $baseDir = "C:\SITEF"
    $targetDir = Join-Path $baseDir "DLL_FLY_EMBARCADO"
    $zipUrl = "https://github.com/c1000x/InstaladorMCNTV/raw/a4dbdb2b2fbbea02d3d4109220199490e4e9e1bf/DLL_FLY_EMBARCADO.zip"
    $zipFile = Join-Path $baseDir "DLL_FLY_EMBARCADO.zip"
    $tempExtractDir = Join-Path $baseDir "DLL_FLY_EMBARCADO_temp"

    if (-not (Test-Path $targetDir)) {
        $log.Invoke("Criando diretório $targetDir ...")
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        $log.Invoke("Diretório criado.")
    }

    $log.Invoke("Baixando DLL_FLY_EMBARCADO.zip (11.6 MB) ...")
    try {
        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
        $webClient.DownloadFile($zipUrl, $zipFile)
        $log.Invoke("Download concluído: $zipFile")
        $progressSitef.Value = 30
    } catch {
        $log.Invoke("ERRO ao baixar DLL_FLY_EMBARCADO.zip: $($_.Exception.Message)")
        return
    }

    $log.Invoke("Extraindo DLL_FLY_EMBARCADO.zip ...")
    try {
        if (Test-Path $tempExtractDir) { Remove-Item $tempExtractDir -Recurse -Force }
        New-Item -ItemType Directory -Path $tempExtractDir -Force | Out-Null
        Expand-Archive -Path $zipFile -DestinationPath $tempExtractDir -Force
        $log.Invoke("Extraído para pasta temporária.")
        $progressSitef.Value = 60
    } catch {
        $log.Invoke("ERRO ao extrair DLL_FLY_EMBARCADO.zip: $($_.Exception.Message)")
        Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
        Remove-Item $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
        return
    }

    $subItems = Get-ChildItem -Path $tempExtractDir
    if ($subItems.Count -eq 1 -and $subItems[0].PSIsContainer) {
        $sourceDir = $subItems[0].FullName
        $log.Invoke("Detectada subpasta raiz: $($subItems[0].Name). Movendo conteúdo para $targetDir ...")
        Get-ChildItem -Path $sourceDir -Recurse -File | ForEach-Object {
            $relativePath = $_.FullName.Substring($sourceDir.Length + 1)
            $destFile = Join-Path $targetDir $relativePath
            $destDir = Split-Path $destFile -Parent
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            Move-Item -Path $_.FullName -Destination $destFile -Force
        }
    } else {
        $log.Invoke("Movendo arquivos diretamente para $targetDir ...")
        Get-ChildItem -Path $tempExtractDir -Recurse -File | ForEach-Object {
            $relativePath = $_.FullName.Substring($tempExtractDir.Length + 1)
            $destFile = Join-Path $targetDir $relativePath
            $destDir = Split-Path $destFile -Parent
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            Move-Item -Path $_.FullName -Destination $destFile -Force
        }
    }

    Remove-Item $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    $log.Invoke("Arquivos organizados.")
    $progressSitef.Value = 80

    Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
    $log.Invoke("Arquivo ZIP removido.")

    $log.Invoke("Adicionando exclusão no Windows Defender para: $targetDir")
    try {
        Add-MpPreference -ExclusionPath $targetDir -ErrorAction Stop
        $log.Invoke("Exclusão adicionada com sucesso.")
        $progressSitef.Value = 95
    } catch {
        $log.Invoke("Aviso: não foi possível adicionar exclusão no Windows Defender: $($_.Exception.Message)")
        $progressSitef.Value = 95
    }

    $log.Invoke("")
    $log.Invoke("=== DLL_FLY_EMBARCADO INSTALADO COM SUCESSO ===")
    $progressSitef.Value = 100
    [System.Windows.Forms.MessageBox]::Show("DLL_FLY_EMBARCADO baixado, extraído e adicionado à exclusão do Windows Defender com sucesso em:`n$targetDir", "DLL_FLY_EMBARCADO")
}

# ============================================================
#  INTERFACE GRAFICA - COM MENU LATERAL (SIDEBAR)
# ============================================================
$ColorBackground = [System.Drawing.Color]::FromArgb(245,247,250)
$ColorSurface    = [System.Drawing.Color]::White
$ColorSidebar    = [System.Drawing.Color]::FromArgb(250,251,252)
$ColorSidebarSel = [System.Drawing.Color]::FromArgb(228,238,250)
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
$FontButtonBold = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$FontNav    = New-Object System.Drawing.Font("Segoe UI", 10)
$FontNavBold = New-Object System.Drawing.Font("Segoe UI Semibold", 10)

# ----- Formulário -----
$form = New-Object System.Windows.Forms.Form
$form.Text = "MCNTV Installer - Provisionamento Windows"
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
$form.MaximizeBox = $true
$form.MinimizeBox = $true
$form.BackColor = $ColorBackground
$form.Font = $FontNormal
$form.MinimumSize = New-Object System.Drawing.Size(900, 750)

# ----- Painel principal (sidebar + conteudo) -----
$mainPanel = New-Object System.Windows.Forms.Panel
$mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$form.Controls.Add($mainPanel)

# ----- Sidebar -----
$sidebarPanel = New-Object System.Windows.Forms.Panel
$sidebarPanel.Dock = [System.Windows.Forms.DockStyle]::Left
$sidebarPanel.Width = 210
$sidebarPanel.BackColor = $ColorSidebar
$mainPanel.Controls.Add($sidebarPanel)

$sidebarBorder = New-Object System.Windows.Forms.Panel
$sidebarBorder.Dock = [System.Windows.Forms.DockStyle]::Right
$sidebarBorder.Width = 1
$sidebarBorder.BackColor = $ColorBorder
$sidebarPanel.Controls.Add($sidebarBorder)

# FlowLayoutPanel garante que o titulo e os botoes fiquem na ordem em que
# sao adicionados (de cima para baixo), sem depender da ordem de Dock=Top
# nem de BringToFront (que era a causa do titulo aparecer embaixo).
$flowSidebarNav = New-Object System.Windows.Forms.FlowLayoutPanel
$flowSidebarNav.Dock = [System.Windows.Forms.DockStyle]::Top
$flowSidebarNav.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$flowSidebarNav.WrapContents = $false
$flowSidebarNav.AutoSize = $true
$flowSidebarNav.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$flowSidebarNav.BackColor = $ColorSidebar
$sidebarPanel.Controls.Add($flowSidebarNav)

$lblSidebarTitle = New-Object System.Windows.Forms.Label
$lblSidebarTitle.Text = "MCNTV Installer"
$lblSidebarTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 12)
$lblSidebarTitle.ForeColor = $ColorText
$lblSidebarTitle.AutoSize = $false
$lblSidebarTitle.Width = 208
$lblSidebarTitle.Height = 55
$lblSidebarTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$lblSidebarTitle.Padding = New-Object System.Windows.Forms.Padding(16, 0, 0, 0)
$flowSidebarNav.Controls.Add($lblSidebarTitle)

# ----- Painel de conteudo (onde as "paginas" aparecem) -----
$contentPanel = New-Object System.Windows.Forms.Panel
$contentPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$contentPanel.BackColor = $ColorBackground
$mainPanel.Controls.Add($contentPanel)

# ----- Definicao dos itens de navegacao -----
$NavItems = [ordered]@{
    "Configuração do Sistema" = "config"
    "Instalar Aplicativos"    = "install"
    "Gerenciar Aplicativos"   = "uninstall"
    "Ativar Windows"          = "activate"
    "SITEF"                   = "sitef"
}

$script:NavButtons = @{}
$script:PagePanels = @{}

function Set-ActivePage {
    param($key)
    # Em vez de alternar Visible (que deixava o TableLayoutPanel da pagina
    # calculando larguras erradas ao reaparecer), todas as paginas ficam
    # sempre visiveis, sobrepostas (Dock=Fill), e so a pagina ativa e trazida
    # para frente com BringToFront. Isso evita o glitch de layout/paginas
    # cortadas ao trocar de secao.
    if ($script:PagePanels.ContainsKey($key)) {
        $script:PagePanels[$key].BringToFront()
        $script:PagePanels[$key].PerformLayout()
        $script:PagePanels[$key].Refresh()
    }
    foreach ($k in $script:NavButtons.Keys) {
        $btn = $script:NavButtons[$k]
        if ($k -eq $key) {
            $btn.BackColor = $ColorSidebarSel
            $btn.Font = $FontNavBold
        } else {
            $btn.BackColor = $ColorSidebar
            $btn.Font = $FontNav
        }
    }
}

foreach ($label in $NavItems.Keys) {
    $key = $NavItems[$label]
    $btnNav = New-Object System.Windows.Forms.Button
    $btnNav.Text = "   $label"
    $btnNav.Font = $FontNav
    $btnNav.ForeColor = $ColorText
    $btnNav.BackColor = $ColorSidebar
    $btnNav.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnNav.FlatAppearance.BorderSize = 0
    $btnNav.FlatAppearance.MouseOverBackColor = $ColorSidebarSel
    $btnNav.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $btnNav.Width = 208
    $btnNav.Height = 44
    $btnNav.Margin = New-Object System.Windows.Forms.Padding(0)
    $btnNav.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btnNav.Tag = $key
    $btnNav.Add_Click({ Set-ActivePage -key $this.Tag }.GetNewClosure())
    $flowSidebarNav.Controls.Add($btnNav)
    $script:NavButtons[$key] = $btnNav
}

# ============================================================
#  PAGINA 1: CONFIGURAÇÃO (2 colunas)
# ============================================================
$pageConfig = New-Object System.Windows.Forms.Panel
$pageConfig.Dock = [System.Windows.Forms.DockStyle]::Fill
$pageConfig.BackColor = $ColorBackground
$contentPanel.Controls.Add($pageConfig)
$script:PagePanels["config"] = $pageConfig

$mainTableConfig = New-Object System.Windows.Forms.TableLayoutPanel
$mainTableConfig.Dock = [System.Windows.Forms.DockStyle]::Fill
$mainTableConfig.ColumnCount = 1
$mainTableConfig.RowCount = 2
$mainTableConfig.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$mainTableConfig.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$mainTableConfig.Padding = New-Object System.Windows.Forms.Padding(20)
$pageConfig.Controls.Add($mainTableConfig)

$panelCheck = New-Object System.Windows.Forms.Panel
$panelCheck.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelCheck.AutoScroll = $true
$mainTableConfig.Controls.Add($panelCheck, 0, 0)

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

$tableCheck = New-Object System.Windows.Forms.TableLayoutPanel
$tableCheck.Dock = [System.Windows.Forms.DockStyle]::Fill
$tableCheck.ColumnCount = 2
$tableCheck.RowCount = [Math]::Ceiling($steps.Count / 2) + 2
$tableCheck.Padding = New-Object System.Windows.Forms.Padding(5)
$panelCheck.Controls.Add($tableCheck)

$tableCheck.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
$tableCheck.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))

$UncheckedByDefault = @("Versoes Anteriores (Shadow Copy)")
$checkboxes = @{}
$row = 0
$col = 0
foreach ($key in $steps.Keys) {
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $key
    $cb.Checked = -not ($UncheckedByDefault -contains $key)
    $cb.Font = $FontNormal
    $cb.ForeColor = $ColorText
    $cb.AutoSize = $true
    $cb.Margin = New-Object System.Windows.Forms.Padding(5, 3, 5, 3)
    $tableCheck.Controls.Add($cb, $col, $row)
    $checkboxes[$key] = $cb
    $col++
    if ($col -eq 2) { $col = 0; $row++ }
}

$chkDryRun = New-Object System.Windows.Forms.CheckBox
$chkDryRun.Text = "Modo Simulacao (dry-run)"
$chkDryRun.Font = $FontNormal
$chkDryRun.ForeColor = [System.Drawing.Color]::DarkBlue
$chkDryRun.AutoSize = $true
$chkDryRun.Margin = New-Object System.Windows.Forms.Padding(5, 10, 5, 5)
$tableCheck.Controls.Add($chkDryRun, 0, $row)
$tableCheck.SetColumnSpan($chkDryRun, 2)

$panelButtonsConfig = New-Object System.Windows.Forms.Panel
$panelButtonsConfig.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelButtonsConfig.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 5)
$mainTableConfig.Controls.Add($panelButtonsConfig, 0, 1)

$flowButtons = New-Object System.Windows.Forms.FlowLayoutPanel
$flowButtons.Dock = [System.Windows.Forms.DockStyle]::Fill
$flowButtons.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$flowButtons.WrapContents = $true
$flowButtons.Padding = New-Object System.Windows.Forms.Padding(5)
$panelButtonsConfig.Controls.Add($flowButtons)

$btnSelAll = New-Object System.Windows.Forms.Button
$btnSelAll.Text = "Marcar todos"
$btnSelAll.Font = $FontButton
$btnSelAll.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSelAll.FlatAppearance.BorderColor = $ColorBorder
$btnSelAll.BackColor = $ColorSurface
$btnSelAll.Size = New-Object System.Drawing.Size(120, 30)
$btnSelAll.Add_Click({ $checkboxes.Values | ForEach-Object { $_.Checked = $true } })
$flowButtons.Controls.Add($btnSelAll)

$btnSelNone = New-Object System.Windows.Forms.Button
$btnSelNone.Text = "Desmarcar todos"
$btnSelNone.Font = $FontButton
$btnSelNone.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSelNone.FlatAppearance.BorderColor = $ColorBorder
$btnSelNone.BackColor = $ColorSurface
$btnSelNone.Size = New-Object System.Drawing.Size(120, 30)
$btnSelNone.Add_Click({ $checkboxes.Values | ForEach-Object { $_.Checked = $false } })
$flowButtons.Controls.Add($btnSelNone)

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = "Executar configuração"
$btnRun.Font = $FontButtonBold
$btnRun.BackColor = $ColorPrimary
$btnRun.ForeColor = [System.Drawing.Color]::White
$btnRun.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnRun.FlatAppearance.BorderSize = 0
$btnRun.Size = New-Object System.Drawing.Size(180, 30)
$btnRun.Margin = New-Object System.Windows.Forms.Padding(20, 0, 0, 0)
$flowButtons.Controls.Add($btnRun)

# ============================================================
#  PAGINA 2: INSTALAR APLICATIVOS
# ============================================================
$pageInstall = New-Object System.Windows.Forms.Panel
$pageInstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$pageInstall.BackColor = $ColorBackground
$contentPanel.Controls.Add($pageInstall)
$script:PagePanels["install"] = $pageInstall

$tableInstall = New-Object System.Windows.Forms.TableLayoutPanel
$tableInstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$tableInstall.ColumnCount = 1
$tableInstall.RowCount = 2
$tableInstall.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$tableInstall.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$tableInstall.Padding = New-Object System.Windows.Forms.Padding(20)
$pageInstall.Controls.Add($tableInstall)

$panelInstallList = New-Object System.Windows.Forms.Panel
$panelInstallList.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelInstallList.AutoScroll = $true
$tableInstall.Controls.Add($panelInstallList, 0, 0)

$grpInstall = New-Object System.Windows.Forms.GroupBox
$grpInstall.Text = "Aplicativos disponíveis"
$grpInstall.Font = $FontHeader
$grpInstall.ForeColor = $ColorText
$grpInstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$grpInstall.Padding = New-Object System.Windows.Forms.Padding(10)
$panelInstallList.Controls.Add($grpInstall)

$flowInstall = New-Object System.Windows.Forms.FlowLayoutPanel
$flowInstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$flowInstall.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$flowInstall.AutoSize = $true
$flowInstall.WrapContents = $false
$grpInstall.Controls.Add($flowInstall)

$lblInstallInfo = New-Object System.Windows.Forms.Label
$lblInstallInfo.Text = "Buscar:"
$lblInstallInfo.Font = $FontNormal
$lblInstallInfo.ForeColor = $ColorMuted
$lblInstallInfo.AutoSize = $true
$flowInstall.Controls.Add($lblInstallInfo)

$txtSearchInstall = New-Object System.Windows.Forms.TextBox
$txtSearchInstall.Font = $FontNormal
$txtSearchInstall.Width = 400
$txtSearchInstall.Height = 22
$txtSearchInstall.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 5)
$flowInstall.Controls.Add($txtSearchInstall)

$clbInstall = New-Object System.Windows.Forms.CheckedListBox
$clbInstall.CheckOnClick = $true
$clbInstall.Font = $FontNormal
$clbInstall.Height = 300
$clbInstall.Width = 450
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

$panelInstallButton = New-Object System.Windows.Forms.Panel
$panelInstallButton.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelInstallButton.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 5)
$tableInstall.Controls.Add($panelInstallButton, 0, 1)

$btnInstallSelected = New-Object System.Windows.Forms.Button
$btnInstallSelected.Text = "INSTALAR SELECIONADOS (Paralelo)"
$btnInstallSelected.Font = $FontButtonBold
$btnInstallSelected.BackColor = $ColorSuccess
$btnInstallSelected.ForeColor = [System.Drawing.Color]::White
$btnInstallSelected.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnInstallSelected.FlatAppearance.BorderSize = 0
$btnInstallSelected.Size = New-Object System.Drawing.Size(450, 40)
$btnInstallSelected.Anchor = [System.Windows.Forms.AnchorStyles]::Left
$panelInstallButton.Controls.Add($btnInstallSelected)

# ============================================================
#  PAGINA 3: GERENCIAR APLICATIVOS
# ============================================================
$pageUninstall = New-Object System.Windows.Forms.Panel
$pageUninstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$pageUninstall.BackColor = $ColorBackground
$contentPanel.Controls.Add($pageUninstall)
$script:PagePanels["uninstall"] = $pageUninstall

$tableUninstall = New-Object System.Windows.Forms.TableLayoutPanel
$tableUninstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$tableUninstall.ColumnCount = 1
$tableUninstall.RowCount = 3
$tableUninstall.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$tableUninstall.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$tableUninstall.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$tableUninstall.Padding = New-Object System.Windows.Forms.Padding(20)
$pageUninstall.Controls.Add($tableUninstall)

$lblUninstallInfo = New-Object System.Windows.Forms.Label
$lblUninstallInfo.Text = "Atualize a lista e selecione o que deseja remover:"
$lblUninstallInfo.Font = $FontNormal
$lblUninstallInfo.ForeColor = $ColorMuted
$lblUninstallInfo.AutoSize = $true
$lblUninstallInfo.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 5)
$tableUninstall.Controls.Add($lblUninstallInfo, 0, 0)

$panelUninstallList = New-Object System.Windows.Forms.Panel
$panelUninstallList.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelUninstallList.AutoScroll = $true
$tableUninstall.Controls.Add($panelUninstallList, 0, 1)

$clbUninstall = New-Object System.Windows.Forms.CheckedListBox
$clbUninstall.CheckOnClick = $true
$clbUninstall.Font = $FontNormal
$clbUninstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$clbUninstall.Height = 300
$clbUninstall.Width = 450
$panelUninstallList.Controls.Add($clbUninstall)

$panelUninstallButtons = New-Object System.Windows.Forms.Panel
$panelUninstallButtons.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelUninstallButtons.Padding = New-Object System.Windows.Forms.Padding(0, 10, 0, 10)
$tableUninstall.Controls.Add($panelUninstallButtons, 0, 2)

$flowUninstallButtons = New-Object System.Windows.Forms.FlowLayoutPanel
$flowUninstallButtons.Dock = [System.Windows.Forms.DockStyle]::Fill
$flowUninstallButtons.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$flowUninstallButtons.WrapContents = $true
$flowUninstallButtons.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 5)
$panelUninstallButtons.Controls.Add($flowUninstallButtons)

$btnRefreshInstalled = New-Object System.Windows.Forms.Button
$btnRefreshInstalled.Text = "Atualizar lista"
$btnRefreshInstalled.Font = $FontButton
$btnRefreshInstalled.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnRefreshInstalled.FlatAppearance.BorderColor = $ColorBorder
$btnRefreshInstalled.BackColor = $ColorSurface
$btnRefreshInstalled.Size = New-Object System.Drawing.Size(120, 30)
$flowUninstallButtons.Controls.Add($btnRefreshInstalled)

$btnUninstallSelected = New-Object System.Windows.Forms.Button
$btnUninstallSelected.Text = "Desinstalar"
$btnUninstallSelected.Font = $FontButton
$btnUninstallSelected.BackColor = $ColorDanger
$btnUninstallSelected.ForeColor = [System.Drawing.Color]::White
$btnUninstallSelected.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnUninstallSelected.FlatAppearance.BorderSize = 0
$btnUninstallSelected.Size = New-Object System.Drawing.Size(120, 30)
$btnUninstallSelected.Margin = New-Object System.Windows.Forms.Padding(15, 0, 0, 0)
$flowUninstallButtons.Controls.Add($btnUninstallSelected)

# ============================================================
#  PAGINA 4: ATIVAR WINDOWS
# ============================================================
$pageActivate = New-Object System.Windows.Forms.Panel
$pageActivate.Dock = [System.Windows.Forms.DockStyle]::Fill
$pageActivate.BackColor = $ColorBackground
$contentPanel.Controls.Add($pageActivate)
$script:PagePanels["activate"] = $pageActivate

$flowActivate = New-Object System.Windows.Forms.FlowLayoutPanel
$flowActivate.Dock = [System.Windows.Forms.DockStyle]::Fill
$flowActivate.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$flowActivate.AutoScroll = $true
$flowActivate.WrapContents = $false
$flowActivate.Padding = New-Object System.Windows.Forms.Padding(30, 25, 20, 20)
$pageActivate.Controls.Add($flowActivate)

$lblActivateTitle = New-Object System.Windows.Forms.Label
$lblActivateTitle.Text = "Ativação do Windows"
$lblActivateTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 14)
$lblActivateTitle.ForeColor = $ColorText
$lblActivateTitle.AutoSize = $true
$lblActivateTitle.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 20)
$flowActivate.Controls.Add($lblActivateTitle)

$lblActivateDesc = New-Object System.Windows.Forms.Label
$lblActivateDesc.Text = "Clique no botão abaixo para ativar o Windows utilizando o script MassGrave.`n" +
                        "O script será baixado e executado automaticamente."
$lblActivateDesc.Font = $FontNormal
$lblActivateDesc.ForeColor = $ColorMuted
$lblActivateDesc.AutoSize = $true
$lblActivateDesc.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 30)
$flowActivate.Controls.Add($lblActivateDesc)

$btnCustomActivate = New-Object System.Windows.Forms.Button
$btnCustomActivate.Text = "ATIVAR WINDOWS"
$btnCustomActivate.Font = $FontButtonBold
$btnCustomActivate.BackColor = $ColorPrimary
$btnCustomActivate.ForeColor = [System.Drawing.Color]::White
$btnCustomActivate.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnCustomActivate.FlatAppearance.BorderSize = 0
$btnCustomActivate.Size = New-Object System.Drawing.Size(300, 50)
$btnCustomActivate.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 20)
$flowActivate.Controls.Add($btnCustomActivate)

# ============================================================
#  PAGINA 5: SITEF
# ============================================================
$pageSitef = New-Object System.Windows.Forms.Panel
$pageSitef.Dock = [System.Windows.Forms.DockStyle]::Fill
$pageSitef.BackColor = $ColorBackground
$contentPanel.Controls.Add($pageSitef)
$script:PagePanels["sitef"] = $pageSitef

$tableSitef = New-Object System.Windows.Forms.TableLayoutPanel
$tableSitef.Dock = [System.Windows.Forms.DockStyle]::Fill
$tableSitef.ColumnCount = 1
$tableSitef.RowCount = 4
$tableSitef.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$tableSitef.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$tableSitef.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$tableSitef.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$tableSitef.Padding = New-Object System.Windows.Forms.Padding(20)
$pageSitef.Controls.Add($tableSitef)

# Título
$lblSitefTitle = New-Object System.Windows.Forms.Label
$lblSitefTitle.Text = "Instalação do Ambiente SITEF"
$lblSitefTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 12)
$lblSitefTitle.ForeColor = $ColorText
$lblSitefTitle.AutoSize = $true
$tableSitef.Controls.Add($lblSitefTitle, 0, 0)

# Descrição
$lblSitefDesc = New-Object System.Windows.Forms.Label
$lblSitefDesc.Text = "Esta etapa irá baixar, extrair e executar os instaladores do SITEF.`n" +
                     "Após a execução, você deverá configurar manualmente os programas.`n" +
                     "Ao fechar os instaladores, o serviço 'GSurfRSA Listener' será iniciado." +
                     "`n`nOs botões abaixo baixam e extraem os pacotes DLL_FLY e DLL_FLY_EMBARCADO.`n" +
                     "As pastas serão automaticamente adicionadas à exclusão do Windows Defender."
$lblSitefDesc.Font = $FontNormal
$lblSitefDesc.ForeColor = $ColorMuted
$lblSitefDesc.AutoSize = $true
$lblSitefDesc.Margin = New-Object System.Windows.Forms.Padding(0, 5, 0, 15)
$tableSitef.Controls.Add($lblSitefDesc, 0, 1)

# Painel de botões – com AutoSize
$flowSitefButtons = New-Object System.Windows.Forms.FlowLayoutPanel
$flowSitefButtons.Dock = [System.Windows.Forms.DockStyle]::Fill
$flowSitefButtons.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$flowSitefButtons.WrapContents = $true
$flowSitefButtons.AutoSize = $true
$flowSitefButtons.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$flowSitefButtons.Padding = New-Object System.Windows.Forms.Padding(5)
$tableSitef.Controls.Add($flowSitefButtons, 0, 2)

# Botão: Instalar SITEF
$btnSitefInstall = New-Object System.Windows.Forms.Button
$btnSitefInstall.Text = "Instalar SITEF"
$btnSitefInstall.Font = $FontButtonBold
$btnSitefInstall.BackColor = $ColorPrimary
$btnSitefInstall.ForeColor = [System.Drawing.Color]::White
$btnSitefInstall.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSitefInstall.FlatAppearance.BorderSize = 0
$btnSitefInstall.Size = New-Object System.Drawing.Size(160, 35)
$btnSitefInstall.Margin = New-Object System.Windows.Forms.Padding(3)
$flowSitefButtons.Controls.Add($btnSitefInstall)

# Botão: DLL_FLY
$btnDllFly = New-Object System.Windows.Forms.Button
$btnDllFly.Text = "DLL_FLY (11.6 MB)"
$btnDllFly.Font = $FontButtonBold
$btnDllFly.BackColor = $ColorPrimary
$btnDllFly.ForeColor = [System.Drawing.Color]::White
$btnDllFly.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnDllFly.FlatAppearance.BorderSize = 0
$btnDllFly.Size = New-Object System.Drawing.Size(160, 35)
$btnDllFly.Margin = New-Object System.Windows.Forms.Padding(3)
$flowSitefButtons.Controls.Add($btnDllFly)

# Botão: DLL_FLY_EMBARCADO
$btnDllFlyEmbarcado = New-Object System.Windows.Forms.Button
$btnDllFlyEmbarcado.Text = "DLL_FLY_EMBARCADO (11.6 MB)"
$btnDllFlyEmbarcado.Font = $FontButtonBold
$btnDllFlyEmbarcado.BackColor = $ColorPrimary
$btnDllFlyEmbarcado.ForeColor = [System.Drawing.Color]::White
$btnDllFlyEmbarcado.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnDllFlyEmbarcado.FlatAppearance.BorderSize = 0
$btnDllFlyEmbarcado.Size = New-Object System.Drawing.Size(170, 35)
$btnDllFlyEmbarcado.Margin = New-Object System.Windows.Forms.Padding(3)
$flowSitefButtons.Controls.Add($btnDllFlyEmbarcado)

# Botão: Abrir pasta
$btnSitefOpenFolder = New-Object System.Windows.Forms.Button
$btnSitefOpenFolder.Text = "📂 Abrir pasta"
$btnSitefOpenFolder.Font = $FontButton
$btnSitefOpenFolder.BackColor = $ColorSurface
$btnSitefOpenFolder.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSitefOpenFolder.FlatAppearance.BorderColor = $ColorBorder
$btnSitefOpenFolder.Size = New-Object System.Drawing.Size(130, 35)
$btnSitefOpenFolder.Margin = New-Object System.Windows.Forms.Padding(3)
$flowSitefButtons.Controls.Add($btnSitefOpenFolder)

# Botão: Instalar tudo
$btnInstallAll = New-Object System.Windows.Forms.Button
$btnInstallAll.Text = "▶ Instalar tudo"
$btnInstallAll.Font = $FontButtonBold
$btnInstallAll.BackColor = $ColorSuccess
$btnInstallAll.ForeColor = [System.Drawing.Color]::White
$btnInstallAll.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnInstallAll.FlatAppearance.BorderSize = 0
$btnInstallAll.Size = New-Object System.Drawing.Size(150, 35)
$btnInstallAll.Margin = New-Object System.Windows.Forms.Padding(3)
$flowSitefButtons.Controls.Add($btnInstallAll)

# Botão: Limpar log
$btnClearLog = New-Object System.Windows.Forms.Button
$btnClearLog.Text = "🗑️ Limpar log"
$btnClearLog.Font = $FontButton
$btnClearLog.BackColor = $ColorSurface
$btnClearLog.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnClearLog.FlatAppearance.BorderColor = $ColorBorder
$btnClearLog.Size = New-Object System.Drawing.Size(120, 35)
$btnClearLog.Margin = New-Object System.Windows.Forms.Padding(3)
$flowSitefButtons.Controls.Add($btnClearLog)

# Painel do log (ocupa o espaço restante)
$panelSitefLog = New-Object System.Windows.Forms.Panel
$panelSitefLog.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelSitefLog.Padding = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
$tableSitef.Controls.Add($panelSitefLog, 0, 3)

$grpSitefLog = New-Object System.Windows.Forms.GroupBox
$grpSitefLog.Text = "Log da instalação SITEF"
$grpSitefLog.Font = $FontHeader
$grpSitefLog.ForeColor = $ColorText
$grpSitefLog.Dock = [System.Windows.Forms.DockStyle]::Fill
$grpSitefLog.Padding = New-Object System.Windows.Forms.Padding(10)
$panelSitefLog.Controls.Add($grpSitefLog)

$txtSitefLog = New-Object System.Windows.Forms.TextBox
$txtSitefLog.Multiline = $true
$txtSitefLog.ScrollBars = "Vertical"
$txtSitefLog.ReadOnly = $true
$txtSitefLog.Dock = [System.Windows.Forms.DockStyle]::Fill
$txtSitefLog.Font = New-Object System.Drawing.Font("Consolas", 8)
$txtSitefLog.BackColor = [System.Drawing.Color]::White
$grpSitefLog.Controls.Add($txtSitefLog)

$progressSitef = New-Object System.Windows.Forms.ProgressBar
$progressSitef.Dock = [System.Windows.Forms.DockStyle]::Top
$progressSitef.Height = 20
$progressSitef.Minimum = 0
$progressSitef.Maximum = 100
$progressSitef.Margin = New-Object System.Windows.Forms.Padding(0, 5, 0, 5)
$grpSitefLog.Controls.Add($progressSitef)
$grpSitefLog.Controls.SetChildIndex($progressSitef, 0)

# ============================================================
#  BARRA DE STATUS E PROGRESSO GLOBAL (usada na pagina Config)
# ============================================================
$panelStatusBar = New-Object System.Windows.Forms.Panel
$panelStatusBar.Dock = [System.Windows.Forms.DockStyle]::Bottom
$panelStatusBar.Height = 30
$mainTableConfig.RowCount = 3
$mainTableConfig.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$mainTableConfig.Controls.Add($panelStatusBar, 0, 2)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Dock = [System.Windows.Forms.DockStyle]::Top
$progressBar.Height = 16
$panelStatusBar.Controls.Add($progressBar)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Pronto."
$lblStatus.Font = $FontSmall
$lblStatus.ForeColor = $ColorMuted
$lblStatus.Dock = [System.Windows.Forms.DockStyle]::Bottom
$lblStatus.Height = 14
$panelStatusBar.Controls.Add($lblStatus)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 8)
$txtLog.Height = 140
$txtLog.Dock = [System.Windows.Forms.DockStyle]::Bottom
$panelCheck.Controls.Add($txtLog)

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

# Evento: Ativar Windows
$btnCustomActivate.Add_Click({
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

    $btnCustomActivate.Enabled = $false
    $AppendLog.Invoke("== Executando script externo: $CustomScriptLabel ==")
    $AppendLog.Invoke("URL: $CustomScriptUrl")

    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        $tempScript = Join-Path $env:TEMP "MCNTV_custom_$(Get-Random).ps1"
        (New-Object System.Net.WebClient).DownloadFile($CustomScriptUrl, $tempScript)

        $AppendLog.Invoke("Script baixado para $tempScript")
        powershell.exe -ExecutionPolicy Bypass -File "$tempScript" 2>&1 | ForEach-Object { $AppendLog.Invoke($_) }
        $AppendLog.Invoke("Script '$CustomScriptLabel' concluido.")
        Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
    } catch {
        $AppendLog.Invoke("ERRO ao executar '$CustomScriptLabel': $($_.Exception.Message)")
    }
    $btnCustomActivate.Enabled = $true
})

# Eventos da aba SITEF
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

$btnSitefOpenFolder.Add_Click({
    $sitefDir = "C:\SITEF"
    if (Test-Path $sitefDir) {
        explorer $sitefDir
    } else {
        [System.Windows.Forms.MessageBox]::Show("A pasta C:\SITEF ainda não existe. Execute a instalação primeiro.", "Pasta não encontrada")
    }
})

$btnInstallAll.Add_Click({
    $btnInstallAll.Enabled = $false
    $txtSitefLog.Clear()
    $progressSitef.Value = 0
    $script:SitefLogDelegate.Invoke("=== INICIANDO INSTALAÇÃO COMPLETA SITEF ===")
    try {
        Install-Sitef
        Download-DllFly
        Download-DllFlyEmbarcado
        $script:SitefLogDelegate.Invoke("")
        $script:SitefLogDelegate.Invoke("=== INSTALAÇÃO COMPLETA CONCLUÍDA ===")
        [System.Windows.Forms.MessageBox]::Show("Todas as etapas do SITEF foram concluídas com sucesso!", "SITEF")
    } catch {
        $txtSitefLog.AppendText("ERRO inesperado: $($_.Exception.Message)`r`n")
    }
    $btnInstallAll.Enabled = $true
})

$btnClearLog.Add_Click({
    $txtSitefLog.Clear()
    $progressSitef.Value = 0
    $script:SitefLogDelegate.Invoke("Log limpo.")
})

# ============================================================
#  CARREGAR LISTA DE INSTALADOS E ATIVAR PAGINA INICIAL
# ============================================================
function Force-FullRelayout {
    # Corrige o bug classico do WinForms em que paineis aninhados (Panel >
    # TableLayoutPanel > FlowLayoutPanel) calculam largura/posicao erradas na
    # primeira exibicao, deixando conteudo "atras" da sidebar ate a janela
    # ser redimensionada manualmente. Forcamos isso programaticamente
    # "cutucando" o tamanho do form em 1px para cima e para baixo, o que
    # obriga TODOS os controles dockados/ancorados a recalcular seus bounds.
    $originalSize = $form.Size
    $form.SuspendLayout()
    $form.Size = New-Object System.Drawing.Size(($originalSize.Width + 1), ($originalSize.Height + 1))
    $form.ResumeLayout($true)
    $form.PerformLayout()
    $form.SuspendLayout()
    $form.Size = $originalSize
    $form.ResumeLayout($true)
    $form.PerformLayout()
    foreach ($p in $script:PagePanels.Values) { $p.PerformLayout() }
    $contentPanel.PerformLayout()
    $mainPanel.PerformLayout()
}

$form.Add_Shown({
    Set-ActivePage -key "config"
    Force-FullRelayout
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
