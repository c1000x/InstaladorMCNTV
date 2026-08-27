<#
    ProvisioningTool.ps1
    MCNTV Installer
    Interface com abas:
      1. Configuração do Sistema
      2. Instalar Aplicativos (Layout 1)
      3. Gerenciar Aplicativos
      4. Ativar Windows
      5. SITEF

    Layout 1: categorias de aplicativos, lista com checkboxes, rodapé com versão/status.
#>

# ============================================================
# EXECUÇÃO LOCAL OU VIA "irm ... | iex"
# ============================================================

$scriptPath = $PSCommandPath

if ([string]::IsNullOrWhiteSpace($scriptPath)) {

    $bootstrapDir = Join-Path $env:TEMP "MCNTVInstaller"

    if (-not (Test-Path $bootstrapDir)) {
        New-Item -Path $bootstrapDir -ItemType Directory -Force | Out-Null
    }

    $scriptPath = Join-Path $bootstrapDir "ProvisioningTool.ps1"

    $scriptContent = $MyInvocation.MyCommand.Definition

    [System.IO.File]::WriteAllText(
        $scriptPath,
        $scriptContent,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

# ============================================================
# AUTO-ELEVAÇÃO
# ============================================================

$isAdmin = (
    [Security.Principal.WindowsPrincipal](
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )
).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {

    $psi = New-Object System.Diagnostics.ProcessStartInfo

    $psi.FileName = "powershell.exe"

    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""

    $psi.Verb = "runas"

    try {
        [System.Diagnostics.Process]::Start($psi) | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "A execução como administrador foi cancelada.",
            "MCNTV Installer"
        )
    }

    exit
}

# ============================================================
# ASSEMBLIES
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

[System.Windows.Forms.Application]::EnableVisualStyles()

# ============================================================
# CONFIGURAÇÕES
# ============================================================

# Definição dos aplicativos com categoria
$AppsWithCategories = @(
    @{ Id = "googlechrome"; Manager = "choco"; Nome = "Google Chrome"; Categoria = "Navegadores" },
    @{ Id = "AnyDesk.AnyDesk"; Manager = "winget"; Nome = "AnyDesk"; Categoria = "Ferramentas" },
    @{ Id = "Adobe.Acrobat.Reader.64-bit"; Manager = "winget"; Nome = "Adobe Reader DC"; Categoria = "Essenciais" },
    @{ Id = "Oracle.JavaRuntimeEnvironment"; Manager = "winget"; Nome = "Java (Runtime)"; Categoria = "Desenvolvimento" },
    @{ Id = "Mozilla.Firefox.pt-BR"; Manager = "winget"; Nome = "Mozilla Firefox"; Categoria = "Navegadores" },
    @{ Id = "7zip.7zip"; Manager = "winget"; Nome = "7-Zip"; Categoria = "Ferramentas" },
    @{ Id = "Microsoft.Office"; Manager = "winget"; Nome = "Microsoft Office"; Categoria = "Essenciais" },
    @{ Id = "9WZDNCRFJBMP"; Manager = "wingetStore"; Nome = "Windows Store App"; Categoria = "Outros" }
)

# Extrai listas para compatibilidade com funções existentes
$ChocoApps = $AppsWithCategories | Where-Object { $_.Manager -eq "choco" } | ForEach-Object { $_.Id }
$WingetApps = $AppsWithCategories | Where-Object { $_.Manager -eq "winget" } | ForEach-Object { $_.Id }
$WingetStoreApps = $AppsWithCategories | Where-Object { $_.Manager -eq "wingetStore" } | ForEach-Object { $_.Id }

# URL que será aberta pelo botão "ABRIR ATIVAÇÃO DO WINDOWS"
$ActivationUrl = "https://www.microsoft.com/pt-br/software-download/windows11"

# Versão do instalador
$InstallerVersion = "2.6"

# ============================================================
# DIRETÓRIOS DE LOG
# ============================================================

$ScriptDir = Split-Path -Parent $scriptPath

$LogsDir = Join-Path $ScriptDir "logs"

if (-not (Test-Path $LogsDir)) {
    New-Item -Path $LogsDir -ItemType Directory -Force | Out-Null
}

$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

$LogFilePath = Join-Path $LogsDir "provisionamento_$Timestamp.log"

$ReportPath = Join-Path $LogsDir "relatorio_$Timestamp.txt"

# ============================================================
# VARIÁVEIS GLOBAIS
# ============================================================

$script:Results = [ordered]@{}

$script:CancelRequested = $false

$script:SitefBusy = $false

$script:AppCatalogMap = @{}

$script:UninstallMap = @{}

# ============================================================
# FUNÇÃO DE LOG GENÉRICA
# ============================================================

function Write-LogFile {
    param(
        [string]$Message
    )

    try {
        Add-Content -Path $LogFilePath -Value $Message -Encoding UTF8
    }
    catch {
        # Não interromper o programa caso o arquivo de log esteja bloqueado.
    }
}

# ============================================================
# FUNÇÕES DE PROVISIONAMENTO
# ============================================================

function Step-RestorePoint {
    param($Log, [bool]$DryRun)
    $Log.Invoke("== Ponto de restauração ==")
    if ($DryRun) {
        $Log.Invoke("[SIMULAÇÃO] Criaria um ponto de restauração antes das alterações.")
        return $true
    }
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "Antes do provisionamento" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
        $Log.Invoke("Ponto de restauração criado.")
        return $true
    }
    catch {
        $Log.Invoke("AVISO: não foi possível criar ponto de restauração: $($_.Exception.Message)")
        return $true
    }
}

function Step-VersoesAnteriores {
    param($Log, [bool]$DryRun)
    $drive = $env:SystemDrive
    $Log.Invoke("== Habilitar Versões Anteriores / Shadow Copy em $drive ==")
    if ($DryRun) {
        $Log.Invoke("[SIMULAÇÃO] Ativaria System Restore em $drive.")
        $Log.Invoke("[SIMULAÇÃO] Reservaria 10% do volume para Shadow Copies.")
        $Log.Invoke("[SIMULAÇÃO] Criaria snapshot inicial.")
        $Log.Invoke("[SIMULAÇÃO] Agendaria snapshot a cada 4 horas.")
        return $true
    }
    try {
        Enable-ComputerRestore -Drive "$drive\" -ErrorAction Stop
        $Log.Invoke("System Restore ativado em $drive.")
    }
    catch {
        $Log.Invoke("Aviso ao ativar System Restore: $($_.Exception.Message)")
    }
    try {
        $Log.Invoke("Reservando espaço para cópias de sombra...")
        $vssOutput = vssadmin resize shadowstorage /for="$drive" /on="$drive" /maxsize=10% 2>&1
        foreach ($line in $vssOutput) { $Log.Invoke("$line") }
        $Log.Invoke("Criando snapshot inicial...")
        $shadowOutput = vssadmin create shadow /for="$drive" 2>&1
        foreach ($line in $shadowOutput) { $Log.Invoke("$line") }
        schtasks /create /tn "VersoesAnteriores_ShadowCopy" /tr "vssadmin create shadow /for=$drive" /sc hourly /mo 4 /ru "SYSTEM" /rl highest /f | Out-Null
        $Log.Invoke("Tarefa agendada criada.")
        return $true
    }
    catch {
        $Log.Invoke("ERRO ao configurar Shadow Copy: $($_.Exception.Message)")
        return $false
    }
}

function Step-IconesAreaTrabalho {
    param($Log, [bool]$DryRun)
    $Log.Invoke("== Ícones Este Computador / Pasta do Usuário ==")
    if ($DryRun) {
        $Log.Invoke("[SIMULAÇÃO] Ativaria os ícones.")
        return $true
    }
    try {
        $path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
        New-Item -Path $path -Force | Out-Null
        New-ItemProperty -Path $path -Name "{20D04FE0-3AEA-1069-A2D8-08002B30309D}" -PropertyType DWord -Value 0 -Force | Out-Null
        New-ItemProperty -Path $path -Name "{59031a47-3f72-44a7-89c5-5595fe6b30ee}" -PropertyType DWord -Value 0 -Force | Out-Null
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Process explorer.exe
        $Log.Invoke("Ícones configurados e Explorer reiniciado.")
        return $true
    }
    catch {
        $Log.Invoke("ERRO ao configurar ícones: $($_.Exception.Message)")
        return $false
    }
}

function Step-Telemetria {
    param($Log, [bool]$DryRun)
    $Log.Invoke("== Telemetria ==")
    if ($DryRun) {
        $Log.Invoke("[SIMULAÇÃO] Desativaria a telemetria via política local.")
        return $true
    }
    try {
        $path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"
        New-Item -Path $path -Force | Out-Null
        Set-ItemProperty -Path $path -Name "AllowTelemetry" -Value 0 -Type DWord -Force
        $Log.Invoke("Política de telemetria configurada.")
        return $true
    }
    catch {
        $Log.Invoke("ERRO ao configurar telemetria: $($_.Exception.Message)")
        return $false
    }
}

function Step-Energia {
    param($Log, [bool]$DryRun)
    $Log.Invoke("== Plano de energia ==")
    if ($DryRun) {
        $Log.Invoke("[SIMULAÇÃO] Desativaria temporizadores de monitor, disco e suspensão.")
        return $true
    }
    try {
        powercfg /change monitor-timeout-ac 0
        powercfg /change monitor-timeout-dc 0
        powercfg /change standby-timeout-ac 0
        powercfg /change standby-timeout-dc 0
        powercfg /change hibernate-timeout-ac 0
        powercfg /change hibernate-timeout-dc 0
        powercfg /change disk-timeout-ac 0
        powercfg /change disk-timeout-dc 0
        $Log.Invoke("Plano de energia ajustado.")
        return $true
    }
    catch {
        $Log.Invoke("ERRO ao ajustar energia: $($_.Exception.Message)")
        return $false
    }
}

function Step-RegiaoIdioma {
    param($Log, [bool]$DryRun)
    $Log.Invoke("== Fuso horário e localização Brasil ==")
    if ($DryRun) {
        $Log.Invoke("[SIMULAÇÃO] Definiria fuso horário de Brasília.")
        $Log.Invoke("[SIMULAÇÃO] Definiria localização Brasil.")
        return $true
    }
    try {
        Set-TimeZone -Id "E. South America Standard Time" -ErrorAction Stop
        $Log.Invoke("Fuso horário de Brasília definido.")
    }
    catch {
        $Log.Invoke("Aviso: não foi possível definir o fuso horário: $($_.Exception.Message)")
    }
    try {
        Set-WinHomeLocation -GeoId 76 -ErrorAction Stop
        $Log.Invoke("Localização Brasil definida.")
    }
    catch {
        $Log.Invoke("Aviso: não foi possível definir a localização Brasil.")
    }
    return $true
}

function Step-Debloat {
    param($Log, [bool]$DryRun)
    $Log.Invoke("== Remover aplicativos padrão ==")
    $apps = @("3dbuilder","bingweather","xboxapp","zunemusic","officehub","skypeapp")
    if ($DryRun) {
        $Log.Invoke("[SIMULAÇÃO] Removeria: $($apps -join ', ')")
        return $true
    }
    foreach ($app in $apps) {
        try {
            Get-AppxPackage "*$app*" -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction SilentlyContinue
            Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*$app*" } | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
            $Log.Invoke("Processado: $app")
        }
        catch {
            $Log.Invoke("Aviso ao remover $app : $($_.Exception.Message)")
        }
    }
    return $true
}

function Ensure-ChocoAvailable {
    param($Log)
    if (Get-Command choco -ErrorAction SilentlyContinue) { return $true }
    $machinePath = [Environment]::GetEnvironmentVariable("Path","Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path","User")
    $env:Path = "$machinePath;$userPath"
    if (Get-Command choco -ErrorAction SilentlyContinue) { return $true }
    $chocoBin = Join-Path $env:ProgramData "chocolatey\bin"
    $chocoExe = Join-Path $chocoBin "choco.exe"
    if (Test-Path $chocoExe) {
        $env:Path += ";$chocoBin"
        return $true
    }
    if ($Log) { $Log.Invoke("Chocolatey não encontrado.") }
    return $false
}

function Step-Chocolatey {
    param($Log, [bool]$DryRun)
    $Log.Invoke("== Chocolatey ==")
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        $Log.Invoke("Chocolatey já está instalado.")
        return $true
    }
    if ($DryRun) {
        $Log.Invoke("[SIMULAÇÃO] Instalaria Chocolatey.")
        return $true
    }
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
        $installScript = Invoke-RestMethod -Uri "https://community.chocolatey.org/install.ps1"
        Invoke-Expression $installScript
        $chocoBin = Join-Path $env:ProgramData "chocolatey\bin"
        if (Test-Path $chocoBin) { $env:Path += ";$chocoBin" }
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            $Log.Invoke("Chocolatey instalado com sucesso.")
            return $true
        }
        $Log.Invoke("Chocolatey não foi localizado após a instalação.")
        return $false
    }
    catch {
        $Log.Invoke("ERRO ao instalar Chocolatey: $($_.Exception.Message)")
        return $false
    }
}

function Step-WingetUpgradeAll {
    param($Log, [bool]$DryRun)
    $Log.Invoke("== Atualização dos aplicativos via winget ==")
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        $Log.Invoke("ERRO: winget não está disponível neste computador.")
        return $false
    }
    if ($DryRun) {
        $Log.Invoke("[SIMULAÇÃO] winget upgrade --all")
        return $true
    }
    try {
        $Log.Invoke("Atualizando fontes do winget...")
        winget source update 2>&1 | ForEach-Object { $Log.Invoke("$_") }
        $Log.Invoke("Atualizando aplicativos...")
        winget upgrade --all --accept-source-agreements --accept-package-agreements --silent 2>&1 | ForEach-Object { $Log.Invoke("$_") }
        $Log.Invoke("Atualização concluída.")
        return $true
    }
    catch {
        $Log.Invoke("ERRO no winget upgrade: $($_.Exception.Message)")
        return $false
    }
}

function Step-TarefaLimpeza {
    param($Log, [bool]$DryRun)
    $Log.Invoke("== Tarefa agendada de limpeza de disco ==")
    if ($DryRun) {
        $Log.Invoke("[SIMULAÇÃO] Criaria tarefa LimpezaDisco aos domingos às 03:00.")
        return $true
    }
    try {
        schtasks /create /tn "LimpezaDisco" /tr "cleanmgr /sagerun:1" /sc weekly /d SUN /st 03:00 /ru "SYSTEM" /rl highest /f | Out-Null
        $Log.Invoke("Tarefa LimpezaDisco criada/atualizada.")
        return $true
    }
    catch {
        $Log.Invoke("ERRO ao criar tarefa: $($_.Exception.Message)")
        return $false
    }
}

# ============================================================
# LISTA DE ETAPAS
# ============================================================

$steps = [ordered]@{
    "Ponto de Restauração" = { param($l,$d) Step-RestorePoint -Log $l -DryRun $d }
    "Versões Anteriores (Shadow Copy)" = { param($l,$d) Step-VersoesAnteriores -Log $l -DryRun $d }
    "Ícones da Área de Trabalho" = { param($l,$d) Step-IconesAreaTrabalho -Log $l -DryRun $d }
    "Desativar Telemetria" = { param($l,$d) Step-Telemetria -Log $l -DryRun $d }
    "Ajustar Plano de Energia" = { param($l,$d) Step-Energia -Log $l -DryRun $d }
    "Fuso Horário / Localização (BR)" = { param($l,$d) Step-RegiaoIdioma -Log $l -DryRun $d }
    "Remover Apps Padrão (Debloat)" = { param($l,$d) Step-Debloat -Log $l -DryRun $d }
    "Instalar/Atualizar Chocolatey" = { param($l,$d) Step-Chocolatey -Log $l -DryRun $d }
    "Atualizar Apps (winget upgrade)" = { param($l,$d) Step-WingetUpgradeAll -Log $l -DryRun $d }
    "Criar Tarefa de Limpeza Semanal" = { param($l,$d) Step-TarefaLimpeza -Log $l -DryRun $d }
}

$UncheckedByDefault = @(
    "Versões Anteriores (Shadow Copy)"
)

# ============================================================
# CATÁLOGO DE PROGRAMAS (com categorias)
# ============================================================

function Build-AppCatalogLabels {
    $script:AppCatalogMap = @{}
    $labels = New-Object System.Collections.ArrayList

    foreach ($app in $AppsWithCategories) {
        $id = $app.Id
        $manager = $app.Manager
        $nome = $app.Nome
        $categoria = $app.Categoria

        $label = "[$manager] $nome"
        $script:AppCatalogMap[$label] = @{
            Manager = $manager
            Id = $id
            Nome = $nome
            Categoria = $categoria
        }
        [void]$labels.Add($label)
    }
    return $labels
}

# ============================================================
# FUNÇÕES DE VERIFICAÇÃO DE INSTALAÇÃO
# ============================================================

function Is-WingetPackageInstalled {
    param($id)
    try {
        winget list --id $id --exact --accept-source-agreements 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Is-ChocoPackageInstalled {
    param($id)
    try {
        choco list $id --exact --limit-output 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Uninstall-WingetPackage {
    param($id)
    try {
        winget uninstall --id $id --silent --accept-source-agreements 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Uninstall-ChocoPackage {
    param($id)
    try {
        choco uninstall $id -y 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Uninstall-RegistryProgram {
    param($cmd)
    try {
        if ($cmd -match "(?i)msiexec" -and $cmd -notmatch "(?i)/qn|/quiet") {
            $cmd = "$cmd /quiet /norestart"
        }
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c $cmd" -Wait -ErrorAction Stop
        return $true
    } catch { return $false }
}

# ============================================================
# SITEF
# ============================================================

function Download-FileWithTimeout {
    param([string]$Url, [string]$Destination, [int]$TimeoutSeconds = 60)
    try {
        $webRequest = [System.Net.WebRequest]::Create($Url)
        $webRequest.Timeout = $TimeoutSeconds * 1000
        $webRequest.Method = "GET"
        $webRequest.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
        $response = $webRequest.GetResponse()
        $responseStream = $response.GetResponseStream()
        $fileStream = [System.IO.File]::Create($Destination)
        $responseStream.CopyTo($fileStream)
        $fileStream.Close()
        $responseStream.Close()
        $response.Close()
        return $true
    }
    catch {
        Write-Error "Erro no download: $($_.Exception.Message)"
        return $false
    }
}

function Validate-ZipFile {
    param([string]$Path)
    try {
        if (-not (Test-Path $Path)) { return $false }
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Count -lt 4) { return $false }
        return ($bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B -and $bytes[2] -eq 0x03 -and $bytes[3] -eq 0x04)
    } catch { return $false }
}

function Install-Sitef {
    $log = $script:SitefLogDelegate
    $log.Invoke("=== INICIANDO INSTALAÇÃO SITEF ===")
    $log.Invoke("")
    $sitefDir = "C:\SITEF"
    $zipUrls = @(
        @{ url = "http://gsurf.com.br/lib/win/certificado.zip"; nome = "certificado.zip" },
        @{ url = "http://gsurf.com.br/lib/win/gsclient.zip"; nome = "gsclient.zip" }
    )
    try {
        if (-not (Test-Path $sitefDir)) {
            $log.Invoke("Criando diretório $sitefDir...")
            New-Item -ItemType Directory -Path $sitefDir -Force | Out-Null
            $log.Invoke("Diretório criado.")
        } else {
            $log.Invoke("Diretório $sitefDir já existe.")
        }
        $progressSitef.Maximum = $zipUrls.Count * 2
        $progressSitef.Value = 0
        foreach ($item in $zipUrls) {
            $url = $item.url
            $fileName = $item.nome
            $zipPath = Join-Path $sitefDir $fileName
            $extractPath = Join-Path $sitefDir ([IO.Path]::GetFileNameWithoutExtension($fileName))
            if (Test-Path $zipPath) {
                $log.Invoke("Arquivo $fileName já existe.")
                if (Validate-ZipFile $zipPath) {
                    try {
                        if (-not (Test-Path $extractPath)) {
                            New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
                        }
                        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
                        $log.Invoke("Arquivo existente extraído.")
                        $progressSitef.Value += 2
                        continue
                    } catch {
                        $log.Invoke("Falha ao extrair arquivo existente.")
                    }
                }
                Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            }
            $log.Invoke("Baixando $fileName...")
            try {
                if (-not (Download-FileWithTimeout -Url $url -Destination $zipPath -TimeoutSeconds 120)) {
                    throw "Falha no download de $url"
                }
                $log.Invoke("Download concluído.")
                $progressSitef.Value += 1
            } catch {
                $log.Invoke("ERRO ao baixar $url : $($_.Exception.Message)")
                return $false
            }
            if (-not (Validate-ZipFile $zipPath)) {
                $log.Invoke("ERRO: o arquivo baixado não é um ZIP válido.")
                Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                return $false
            }
            $log.Invoke("Extraindo $fileName...")
            try {
                if (Test-Path $extractPath) {
                    Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
                }
                New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
                Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
                $log.Invoke("Extraído com sucesso.")
                $progressSitef.Value += 1
            } catch {
                $log.Invoke("Falha com Expand-Archive.")
                try {
                    [IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractPath, $true)
                    $log.Invoke("Extraído usando fallback.")
                    $progressSitef.Value += 1
                } catch {
                    $log.Invoke("ERRO ao extrair: $($_.Exception.Message)")
                    return $false
                }
            }
        }
        $log.Invoke("")
        $log.Invoke("Arquivos baixados e extraídos.")
        $msiPath = Get-ChildItem -Path $sitefDir -Recurse -Filter "GSurfRSA_Listener_Setup.msi" -ErrorAction SilentlyContinue | Select-Object -First 1
        $exePath = Get-ChildItem -Path $sitefDir -Recurse -Filter "InstaladorGSurf.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $msiPath) {
            $log.Invoke("ERRO: GSurfRSA_Listener_Setup.msi não encontrado.")
            return $false
        }
        if (-not $exePath) {
            $log.Invoke("ERRO: InstaladorGSurf.exe não encontrado.")
            return $false
        }
        $log.Invoke("")
        $log.Invoke("Executando instalador MSI...")
        try {
            $process = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$($msiPath.FullName)`"" -Wait -PassThru
            $log.Invoke("MSI finalizado. Código: $($process.ExitCode)")
        } catch {
            $log.Invoke("ERRO MSI: $($_.Exception.Message)")
        }
        $log.Invoke("Executando InstaladorGSurf.exe...")
        try {
            $process = Start-Process -FilePath $exePath.FullName -Wait -PassThru
            $log.Invoke("EXE finalizado. Código: $($process.ExitCode)")
        } catch {
            $log.Invoke("ERRO EXE: $($_.Exception.Message)")
        }
        $log.Invoke("")
        $log.Invoke("Aguardando 5 segundos...")
        Start-Sleep -Seconds 5
        $serviceName = "GSurfRSA Listener"
        $log.Invoke("Verificando serviço '$serviceName'...")
        $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($svc) {
            if ($svc.Status -eq "Stopped") {
                try {
                    Start-Service -Name $serviceName -ErrorAction Stop
                    $log.Invoke("Serviço iniciado com sucesso.")
                } catch {
                    $log.Invoke("ERRO ao iniciar serviço: $($_.Exception.Message)")
                }
            } else {
                $log.Invoke("Serviço já está em execução. Status: $($svc.Status)")
            }
        } else {
            $log.Invoke("Serviço '$serviceName' não encontrado.")
        }
        $log.Invoke("")
        $log.Invoke("=== INSTALAÇÃO SITEF CONCLUÍDA ===")
        $progressSitef.Value = $progressSitef.Maximum
        return $true
    } catch {
        $log.Invoke("ERRO geral SITEF: $($_.Exception.Message)")
        return $false
    }
}

function Install-DllPackage {
    param([string]$PackageName, [string]$ZipUrl, [string]$SuccessMessage)
    $log = $script:SitefLogDelegate
    $log.Invoke("=== BAIXANDO $PackageName ===")
    $log.Invoke("")
    $progressSitef.Maximum = 100
    $progressSitef.Value = 0
    $baseDir = "C:\SITEF"
    $targetDir = Join-Path $baseDir $PackageName
    $zipFile = Join-Path $baseDir "$PackageName.zip"
    $tempExtractDir = Join-Path $baseDir "${PackageName}_temp"
    try {
        if (-not (Test-Path $baseDir)) {
            New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
        }
        if (-not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            $log.Invoke("Diretório criado: $targetDir")
        }
        $log.Invoke("Baixando $PackageName.zip...")
        if (-not (Download-FileWithTimeout -Url $ZipUrl -Destination $zipFile -TimeoutSeconds 120)) {
            throw "Falha no download de $ZipUrl"
        }
        $log.Invoke("Download concluído.")
        $progressSitef.Value = 30
        if (-not (Validate-ZipFile $zipFile)) {
            throw "O arquivo baixado não é um ZIP válido."
        }
        if (Test-Path $tempExtractDir) {
            Remove-Item $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType Directory -Path $tempExtractDir -Force | Out-Null
        $log.Invoke("Extraindo pacote...")
        Expand-Archive -Path $zipFile -DestinationPath $tempExtractDir -Force
        $progressSitef.Value = 60
        $subItems = @(Get-ChildItem -Path $tempExtractDir -Force)
        if ($subItems.Count -eq 1 -and $subItems[0].PSIsContainer) {
            $sourceDir = $subItems[0].FullName
            $log.Invoke("Subpasta detectada: $($subItems[0].Name)")
            Get-ChildItem -Path $sourceDir -Recurse -File | ForEach-Object {
                $relativePath = $_.FullName.Substring($sourceDir.Length + 1)
                $destFile = Join-Path $targetDir $relativePath
                $destDir = Split-Path $destFile -Parent
                if (-not (Test-Path $destDir)) {
                    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                }
                Copy-Item -Path $_.FullName -Destination $destFile -Force
            }
        } else {
            Get-ChildItem -Path $tempExtractDir -Recurse -File | ForEach-Object {
                $relativePath = $_.FullName.Substring($tempExtractDir.Length + 1)
                $destFile = Join-Path $targetDir $relativePath
                $destDir = Split-Path $destFile -Parent
                if (-not (Test-Path $destDir)) {
                    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                }
                Copy-Item -Path $_.FullName -Destination $destFile -Force
            }
        }
        Remove-Item $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
        $progressSitef.Value = 80
        Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
        $log.Invoke("ZIP removido.")
        $log.Invoke("Configurando exclusão do Windows Defender...")
        try {
            Add-MpPreference -ExclusionPath $targetDir -ErrorAction Stop
            $log.Invoke("Exclusão adicionada.")
        } catch {
            $log.Invoke("Aviso: não foi possível adicionar exclusão: $($_.Exception.Message)")
        }
        $progressSitef.Value = 100
        $log.Invoke("")
        $log.Invoke($SuccessMessage)
        return $true
    } catch {
        $log.Invoke("ERRO em $PackageName : $($_.Exception.Message)")
        Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
        Remove-Item $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Download-DllFly {
    return Install-DllPackage -PackageName "DLL_FLY" -ZipUrl "https://github.com/c1000x/InstaladorMCNTV/raw/a4dbdb2b2fbbea02d3d4109220199490e4e9e1bf/DLL_FLY.zip" -SuccessMessage "=== DLL_FLY INSTALADO COM SUCESSO ==="
}

function Download-DllFlyEmbarcado {
    return Install-DllPackage -PackageName "DLL_FLY_EMBARCADO" -ZipUrl "https://github.com/c1000x/InstaladorMCNTV/raw/a4dbdb2b2fbbea02d3d4109220199490e4e9e1bf/DLL_FLY_EMBARCADO.zip" -SuccessMessage "=== DLL_FLY_EMBARCADO INSTALADO COM SUCESSO ==="
}

# ============================================================
# CORES
# ============================================================

$ColorBackground = [System.Drawing.Color]::FromArgb(245,247,250)
$ColorSurface = [System.Drawing.Color]::White
$ColorText = [System.Drawing.Color]::FromArgb(35,38,42)
$ColorMuted = [System.Drawing.Color]::FromArgb(95,102,110)
$ColorPrimary = [System.Drawing.Color]::FromArgb(0,120,215)
$ColorSuccess = [System.Drawing.Color]::FromArgb(40,150,90)
$ColorDanger = [System.Drawing.Color]::FromArgb(190,55,55)
$ColorBorder = [System.Drawing.Color]::FromArgb(210,215,222)

# ============================================================
# FONTES
# ============================================================

$FontNormal = New-Object System.Drawing.Font("Segoe UI", 9)
$FontSmall = New-Object System.Drawing.Font("Segoe UI", 8)
$FontHeader = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$FontTitle = New-Object System.Drawing.Font("Segoe UI Semibold", 18)
$FontButton = New-Object System.Drawing.Font("Segoe UI", 9)
$FontButtonBold = New-Object System.Drawing.Font("Segoe UI Semibold", 10)

# ============================================================
# FORMULÁRIO
# ============================================================

$form = New-Object System.Windows.Forms.Form
$form.Text = "MCN TV Instalador"
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
$form.MaximizeBox = $true
$form.MinimizeBox = $true
$form.BackColor = $ColorBackground
$form.Font = $FontNormal
$form.MinimumSize = New-Object System.Drawing.Size(900,700)
$form.Size = New-Object System.Drawing.Size(1100,800)

$mainPanel = New-Object System.Windows.Forms.Panel
$mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$form.Controls.Add($mainPanel)

# ============================================================
# TABCONTROL
# ============================================================

$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Dock = [System.Windows.Forms.DockStyle]::Fill
$tabControl.Font = $FontNormal
$mainPanel.Controls.Add($tabControl)

# ============================================================
# ABA CONFIGURAÇÃO (inalterada)
# ============================================================

$tabConfig = New-Object System.Windows.Forms.TabPage
$tabConfig.Text = "Configuração do Sistema"
$tabConfig.BackColor = $ColorBackground
$tabControl.Controls.Add($tabConfig)

$configLayout = New-Object System.Windows.Forms.TableLayoutPanel
$configLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$configLayout.ColumnCount = 1
$configLayout.RowCount = 3
$configLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$configLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$configLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$configLayout.Padding = New-Object System.Windows.Forms.Padding(10)
$tabConfig.Controls.Add($configLayout)

$lblConfigTitle = New-Object System.Windows.Forms.Label
$lblConfigTitle.Text = "Configuração do Sistema"
$lblConfigTitle.Font = $FontTitle
$lblConfigTitle.ForeColor = $ColorText
$lblConfigTitle.AutoSize = $true
$lblConfigTitle.Margin = New-Object System.Windows.Forms.Padding(3,3,3,10)
$configLayout.Controls.Add($lblConfigTitle, 0, 0)

$panelCheck = New-Object System.Windows.Forms.Panel
$panelCheck.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelCheck.AutoScroll = $true
$configLayout.Controls.Add($panelCheck, 0, 1)

$tableCheck = New-Object System.Windows.Forms.TableLayoutPanel
$tableCheck.Dock = [System.Windows.Forms.DockStyle]::Top
$tableCheck.AutoSize = $true
$tableCheck.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$tableCheck.ColumnCount = 2
$tableCheck.RowCount = [Math]::Ceiling($steps.Count / 2) + 2
$tableCheck.Padding = New-Object System.Windows.Forms.Padding(5)
$panelCheck.Controls.Add($tableCheck)

$tableCheck.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
$tableCheck.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))

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
    $cb.Margin = New-Object System.Windows.Forms.Padding(5,5,5,5)
    $tableCheck.Controls.Add($cb, $col, $row)
    $checkboxes[$key] = $cb
    $col++
    if ($col -eq 2) { $col = 0; $row++ }
}

$chkDryRun = New-Object System.Windows.Forms.CheckBox
$chkDryRun.Text = "Modo Simulação (dry-run)"
$chkDryRun.Font = $FontNormal
$chkDryRun.ForeColor = [System.Drawing.Color]::DarkBlue
$chkDryRun.AutoSize = $true
$chkDryRun.Margin = New-Object System.Windows.Forms.Padding(5,10,5,5)
$tableCheck.Controls.Add($chkDryRun, 0, $row)
$tableCheck.SetColumnSpan($chkDryRun, 2)

$panelConfigStatus = New-Object System.Windows.Forms.Panel
$panelConfigStatus.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelConfigStatus.Height = 55
$configLayout.Controls.Add($panelConfigStatus, 0, 2)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Pronto."
$lblStatus.Font = $FontNormal
$lblStatus.ForeColor = $ColorMuted
$lblStatus.AutoSize = $true
$lblStatus.Location = New-Object System.Drawing.Point(5,5)
$panelConfigStatus.Controls.Add($lblStatus)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$progressBar.Value = 0
$progressBar.Width = 350
$progressBar.Height = 20
$progressBar.Location = New-Object System.Drawing.Point(5,27)
$panelConfigStatus.Controls.Add($progressBar)

$txtConfigLog = New-Object System.Windows.Forms.TextBox
$txtConfigLog.Multiline = $true
$txtConfigLog.ReadOnly = $true
$txtConfigLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtConfigLog.Height = 120
$txtConfigLog.Width = 700
$txtConfigLog.Location = New-Object System.Drawing.Point(5,55)
$txtConfigLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$txtConfigLog.BackColor = [System.Drawing.Color]::WhiteSmoke
$panelConfigStatus.Controls.Add($txtConfigLog)

$panelButtonsConfig = New-Object System.Windows.Forms.FlowLayoutPanel
$panelButtonsConfig.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$panelButtonsConfig.Dock = [System.Windows.Forms.DockStyle]::Bottom
$panelButtonsConfig.Height = 50
$panelButtonsConfig.Padding = New-Object System.Windows.Forms.Padding(5)
$configLayout.Controls.Add($panelButtonsConfig, 0, 2)

$btnSelAll = New-Object System.Windows.Forms.Button
$btnSelAll.Text = "Marcar todos"
$btnSelAll.Size = New-Object System.Drawing.Size(130,32)
$btnSelAll.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSelAll.BackColor = $ColorSurface
$btnSelAll.FlatAppearance.BorderColor = $ColorBorder
$panelButtonsConfig.Controls.Add($btnSelAll)

$btnSelNone = New-Object System.Windows.Forms.Button
$btnSelNone.Text = "Desmarcar todos"
$btnSelNone.Size = New-Object System.Drawing.Size(140,32)
$btnSelNone.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSelNone.BackColor = $ColorSurface
$btnSelNone.FlatAppearance.BorderColor = $ColorBorder
$panelButtonsConfig.Controls.Add($btnSelNone)

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = "Executar configuração"
$btnRun.Font = $FontButtonBold
$btnRun.BackColor = $ColorPrimary
$btnRun.ForeColor = [System.Drawing.Color]::White
$btnRun.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnRun.FlatAppearance.BorderSize = 0
$btnRun.Size = New-Object System.Drawing.Size(190,32)
$btnRun.Margin = New-Object System.Windows.Forms.Padding(20,0,0,0)
$panelButtonsConfig.Controls.Add($btnRun)

# ============================================================
# ABA INSTALAR APLICATIVOS (NOVO LAYOUT 1)
# ============================================================

$tabInstall = New-Object System.Windows.Forms.TabPage
$tabInstall.Text = "Instalar Aplicativos"
$tabInstall.BackColor = $ColorBackground
$tabControl.Controls.Add($tabInstall)

# Painel principal com TableLayoutPanel
$mainInstallLayout = New-Object System.Windows.Forms.TableLayoutPanel
$mainInstallLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$mainInstallLayout.ColumnCount = 1
$mainInstallLayout.RowCount = 5
$mainInstallLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))  # Título
$mainInstallLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))  # Categorias
$mainInstallLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))  # Barra de pesquisa
$mainInstallLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) # Lista
$mainInstallLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))  # Botões + rodapé
$mainInstallLayout.Padding = New-Object System.Windows.Forms.Padding(15)
$tabInstall.Controls.Add($mainInstallLayout)

# Título
$lblInstallTitle = New-Object System.Windows.Forms.Label
$lblInstallTitle.Text = "INSTALAR APLICATIVOS"
$lblInstallTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 14)
$lblInstallTitle.ForeColor = $ColorText
$lblInstallTitle.AutoSize = $true
$mainInstallLayout.Controls.Add($lblInstallTitle, 0, 0)

# Painel de categorias (FlowLayoutPanel com botões)
$categoryPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$categoryPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$categoryPanel.WrapContents = $true
$categoryPanel.AutoSize = $true
$categoryPanel.Margin = New-Object System.Windows.Forms.Padding(0,5,0,5)
$mainInstallLayout.Controls.Add($categoryPanel, 0, 1)

# Lista de categorias e aplicativos correspondentes
$allCategories = @("Todos", "Essenciais", "Navegadores", "Multimídia", "Ferramentas", "Desenvolvimento", "Outros")
$categoryButtons = @{}
$selectedCategory = "Todos"

# Função para criar botões de categoria
foreach ($cat in $allCategories) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $cat
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderColor = $ColorBorder
    $btn.BackColor = $ColorSurface
    $btn.Size = New-Object System.Drawing.Size(100, 28)
    $btn.Font = $FontNormal
    $btn.Tag = $cat
    $categoryPanel.Controls.Add($btn)
    $categoryButtons[$cat] = $btn
}

# Destacar o botão "Todos" inicialmente
$categoryButtons["Todos"].BackColor = $ColorPrimary
$categoryButtons["Todos"].ForeColor = [System.Drawing.Color]::White

# Barra de pesquisa (opcional) - manter
$searchPanel = New-Object System.Windows.Forms.Panel
$searchPanel.AutoSize = $true
$searchPanel.Height = 30
$mainInstallLayout.Controls.Add($searchPanel, 0, 2)

$lblSearchInstall = New-Object System.Windows.Forms.Label
$lblSearchInstall.Text = "Buscar:"
$lblSearchInstall.AutoSize = $true
$lblSearchInstall.Location = New-Object System.Drawing.Point(0, 5)
$searchPanel.Controls.Add($lblSearchInstall)

$txtSearchInstall = New-Object System.Windows.Forms.TextBox
$txtSearchInstall.Width = 250
$txtSearchInstall.Height = 25
$txtSearchInstall.Location = New-Object System.Drawing.Point(50, 2)
$searchPanel.Controls.Add($txtSearchInstall)

# Lista de aplicativos (CheckedListBox)
$clbInstall = New-Object System.Windows.Forms.CheckedListBox
$clbInstall.CheckOnClick = $true
$clbInstall.Font = $FontNormal
$clbInstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$clbInstall.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$clbInstall.IntegralHeight = $false
$mainInstallLayout.Controls.Add($clbInstall, 0, 3)

# Preencher a lista (todos os aplicativos)
$allLabels = @(Build-AppCatalogLabels)
$clbInstall.Tag = $allLabels   # guarda todos os labels para filtro
foreach ($label in $allLabels) {
    [void]$clbInstall.Items.Add($label, $true)
}

# Painel inferior (botões + rodapé)
$bottomPanel = New-Object System.Windows.Forms.TableLayoutPanel
$bottomPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$bottomPanel.ColumnCount = 2
$bottomPanel.RowCount = 2
$bottomPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 70)))
$bottomPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 30)))
$bottomPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$bottomPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$bottomPanel.Margin = New-Object System.Windows.Forms.Padding(0,10,0,0)
$mainInstallLayout.Controls.Add($bottomPanel, 0, 4)

# Botões de seleção/instalação (coluna 0)
$buttonFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$buttonFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$buttonFlow.AutoSize = $true
$buttonFlow.WrapContents = $false
$bottomPanel.Controls.Add($buttonFlow, 0, 0)

$btnInstallSelectAll = New-Object System.Windows.Forms.Button
$btnInstallSelectAll.Text = "SELECIONAR TODOS"
$btnInstallSelectAll.Size = New-Object System.Drawing.Size(150, 30)
$btnInstallSelectAll.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnInstallSelectAll.BackColor = $ColorSurface
$btnInstallSelectAll.FlatAppearance.BorderColor = $ColorBorder
$buttonFlow.Controls.Add($btnInstallSelectAll)

$btnInstallClearAll = New-Object System.Windows.Forms.Button
$btnInstallClearAll.Text = "LIMPAR SELEÇÃO"
$btnInstallClearAll.Size = New-Object System.Drawing.Size(140, 30)
$btnInstallClearAll.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnInstallClearAll.BackColor = $ColorSurface
$btnInstallClearAll.FlatAppearance.BorderColor = $ColorBorder
$buttonFlow.Controls.Add($btnInstallClearAll)

$btnInstallSelected = New-Object System.Windows.Forms.Button
$btnInstallSelected.Text = "INSTALAR SELECIONADOS"
$btnInstallSelected.Size = New-Object System.Drawing.Size(180, 30)
$btnInstallSelected.Font = $FontButtonBold
$btnInstallSelected.BackColor = $ColorSuccess
$btnInstallSelected.ForeColor = [System.Drawing.Color]::White
$btnInstallSelected.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnInstallSelected.FlatAppearance.BorderSize = 0
$buttonFlow.Controls.Add($btnInstallSelected)

# Rodapé com versão e status (coluna 1)
$footerPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$footerPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
$footerPanel.AutoSize = $true
$footerPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$bottomPanel.Controls.Add($footerPanel, 1, 0)

$lblVersion = New-Object System.Windows.Forms.Label
$lblVersion.Text = "Versão: $InstallerVersion"
$lblVersion.Font = $FontSmall
$lblVersion.ForeColor = $ColorMuted
$lblVersion.AutoSize = $true
$footerPanel.Controls.Add($lblVersion)

$lblStatusOnline = New-Object System.Windows.Forms.Label
$lblStatusOnline.Text = "  Online"
$lblStatusOnline.Font = $FontSmall
$lblStatusOnline.ForeColor = [System.Drawing.Color]::Green
$lblStatusOnline.AutoSize = $true
$footerPanel.Controls.Add($lblStatusOnline)

# Segunda linha do bottomPanel (pode ser vazia ou para log de instalação)
$installLogPanel = New-Object System.Windows.Forms.Panel
$installLogPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$installLogPanel.Height = 80
$bottomPanel.SetRowSpan($installLogPanel, 2)
$bottomPanel.Controls.Add($installLogPanel, 0, 1)
$bottomPanel.SetColumnSpan($installLogPanel, 2)

$txtInstallLog = New-Object System.Windows.Forms.TextBox
$txtInstallLog.Multiline = $true
$txtInstallLog.ReadOnly = $true
$txtInstallLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtInstallLog.Dock = [System.Windows.Forms.DockStyle]::Fill
$txtInstallLog.Font = New-Object System.Drawing.Font("Consolas", 8)
$txtInstallLog.BackColor = [System.Drawing.Color]::WhiteSmoke
$installLogPanel.Controls.Add($txtInstallLog)

# ============================================================
# EVENTOS DA ABA DE INSTALAÇÃO
# ============================================================

# Filtro por categoria
foreach ($cat in $allCategories) {
    $categoryButtons[$cat].Add_Click({
        $categoria = $this.Tag
        # Atualizar cores dos botões
        foreach ($b in $categoryButtons.Values) {
            $b.BackColor = $ColorSurface
            $b.ForeColor = $ColorText
        }
        $this.BackColor = $ColorPrimary
        $this.ForeColor = [System.Drawing.Color]::White

        $selectedCategory = $categoria

        # Filtrar a lista
        $clbInstall.BeginUpdate()
        try {
            $clbInstall.Items.Clear()
            $allLabels = $clbInstall.Tag
            foreach ($label in $allLabels) {
                $info = $script:AppCatalogMap[$label]
                if ($categoria -eq "Todos" -or $info.Categoria -eq $categoria) {
                    [void]$clbInstall.Items.Add($label, $true)
                }
            }
        } finally {
            $clbInstall.EndUpdate()
        }
    })
}

# Barra de pesquisa (filtra sobre os itens atuais)
$txtSearchInstall.Add_TextChanged({
    $search = $txtSearchInstall.Text.Trim().ToLower()
    $clbInstall.BeginUpdate()
    try {
        $clbInstall.Items.Clear()
        $allLabels = $clbInstall.Tag
        # Se a categoria atual for "Todos", mostra todos; senão, filtra pela categoria atual
        $catAtual = $selectedCategory
        foreach ($label in $allLabels) {
            $info = $script:AppCatalogMap[$label]
            $matchCat = ($catAtual -eq "Todos" -or $info.Categoria -eq $catAtual)
            $matchSearch = [string]::IsNullOrEmpty($search) -or $info.Nome.ToLower().Contains($search) -or $label.ToLower().Contains($search)
            if ($matchCat -and $matchSearch) {
                [void]$clbInstall.Items.Add($label, $true)
            }
        }
    } finally {
        $clbInstall.EndUpdate()
    }
})

# Selecionar todos
$btnInstallSelectAll.Add_Click({
    for ($i = 0; $i -lt $clbInstall.Items.Count; $i++) {
        $clbInstall.SetItemChecked($i, $true)
    }
})

# Limpar seleção
$btnInstallClearAll.Add_Click({
    for ($i = 0; $i -lt $clbInstall.Items.Count; $i++) {
        $clbInstall.SetItemChecked($i, $false)
    }
})

# Instalar selecionados (mesma lógica anterior, adaptada para usar o log $txtInstallLog)
$btnInstallSelected.Add_Click({
    $selectedLabels = @($clbInstall.CheckedItems)
    if ($selectedLabels.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Selecione ao menos um aplicativo.", "Aviso")
        return
    }
    $btnInstallSelected.Enabled = $false
    Write-InstallLog ""
    Write-InstallLog "== INSTALAÇÃO DE APLICATIVOS =="
    Write-InstallLog "Total: $($selectedLabels.Count)"
    $totalJobs = 0; $completed = 0; $maxConcurrent = 3
    $results = @{}
    try {
        $needsChoco = @($selectedLabels | Where-Object { $script:AppCatalogMap[$_].Manager -eq "choco" })
        if ($needsChoco.Count -gt 0) {
            if (-not (Ensure-ChocoAvailable -Log $AppendLog)) {
                Write-InstallLog "Chocolatey não está disponível."
                $btnInstallSelected.Enabled = $true
                return
            }
        }
        $toInstall = @()
        foreach ($label in $selectedLabels) {
            $info = $script:AppCatalogMap[$label]
            if (-not $info) { continue }
            $manager = $info.Manager; $id = $info.Id
            $alreadyInstalled = $false
            if ($manager -eq "winget" -or $manager -eq "wingetStore") {
                $alreadyInstalled = Is-WingetPackageInstalled -id $id
            } elseif ($manager -eq "choco") {
                $alreadyInstalled = Is-ChocoPackageInstalled -id $id
            }
            if ($alreadyInstalled) {
                Write-InstallLog "$label já está instalado. Pulando."
            } else {
                $toInstall += @{ Label = $label; Info = $info }
            }
        }
        if ($toInstall.Count -eq 0) {
            Write-InstallLog "Nenhum novo aplicativo para instalar."
            $btnInstallSelected.Enabled = $true
            return
        }
        Write-InstallLog "Instalando $($toInstall.Count) aplicativos..."
        $totalJobs = $toInstall.Count
        $progressBar.Minimum = 0; $progressBar.Maximum = 100; $progressBar.Value = 0
        $jobQueue = [System.Collections.Queue]::new($toInstall)
        $runningJobs = @()
        while ($jobQueue.Count -gt 0 -or $runningJobs.Count -gt 0) {
            while ($runningJobs.Count -lt $maxConcurrent -and $jobQueue.Count -gt 0) {
                $item = $jobQueue.Dequeue()
                $info = $item.Info; $id = $info.Id; $manager = $info.Manager; $label = $item.Label
                Write-InstallLog "Iniciando instalação de $label"
                $jobScript = {
                    param($manager, $id)
                    $output = @()
                    try {
                        switch ($manager) {
                            "choco" { $out = choco install $id -y --force --ignore-checksums 2>&1; $output += $out }
                            "winget" { $out = winget install -e --id $id --accept-source-agreements --accept-package-agreements --silent 2>&1; $output += $out }
                            "wingetStore" { $out = winget install --id $id --source msstore --accept-source-agreements --accept-package-agreements --silent 2>&1; $output += $out }
                        }
                        return @{ Success = $true; Output = $output }
                    } catch {
                        return @{ Success = $false; Output = @("ERRO: $($_.Exception.Message)") }
                    }
                }
                $job = Start-Job -ScriptBlock $jobScript -ArgumentList $manager, $id
                $runningJobs += @{ Job = $job; Label = $label }
            }
            Start-Sleep -Milliseconds 500
            $finished = $runningJobs | Where-Object { $_.Job.State -ne 'Running' }
            foreach ($item in $finished) {
                $job = $item.Job; $label = $item.Label
                $result = Receive-Job -Job $job -ErrorAction SilentlyContinue
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
                $completed++
                if ($result -and $result.Success) {
                    Write-InstallLog "$label instalado com sucesso."
                    $results[$label] = "OK"
                } else {
                    Write-InstallLog "Falha na instalação de $label."
                    $results[$label] = "FALHA"
                }
                $percent = [int](($completed / $totalJobs) * 100)
                if ($percent -gt 100) { $percent = 100 }
                $progressBar.Value = $percent
                $lblStatus.Text = "Instalando: $completed de $totalJobs"
                [System.Windows.Forms.Application]::DoEvents()
            }
            $runningJobs = $runningJobs | Where-Object { $_.Job.State -eq 'Running' }
        }
        $progressBar.Value = 100
        $lblStatus.Text = "Instalação de aplicativos concluída."
        Write-InstallLog "=== INSTALAÇÃO DE APLICATIVOS CONCLUÍDA ==="
    } catch {
        Write-InstallLog "ERRO geral na instalação: $($_.Exception.Message)"
    } finally {
        Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
        $btnInstallSelected.Enabled = $true
    }
})

# Função para log na aba de instalação (substitui a antiga)
function Write-InstallLog {
    param([string]$Message)
    $line = "$Message`r`n"
    $txtInstallLog.AppendText($line)
    $txtInstallLog.SelectionStart = $txtInstallLog.Text.Length
    $txtInstallLog.ScrollToCaret()
    Write-LogFile "[INSTALL] $Message"
    [System.Windows.Forms.Application]::DoEvents()
}

# ============================================================
# ABA GERENCIAR APLICATIVOS (inalterada)
# ============================================================

$tabUninstall = New-Object System.Windows.Forms.TabPage
$tabUninstall.Text = "Gerenciar Aplicativos"
$tabUninstall.BackColor = $ColorBackground
$tabControl.Controls.Add($tabUninstall)

$tableUninstall = New-Object System.Windows.Forms.TableLayoutPanel
$tableUninstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$tableUninstall.ColumnCount = 1
$tableUninstall.RowCount = 3
$tableUninstall.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$tableUninstall.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$tableUninstall.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$tableUninstall.Padding = New-Object System.Windows.Forms.Padding(10)
$tabUninstall.Controls.Add($tableUninstall)

$lblUninstallInfo = New-Object System.Windows.Forms.Label
$lblUninstallInfo.Text = "Atualize a lista e selecione os programas que deseja remover."
$lblUninstallInfo.AutoSize = $true
$tableUninstall.Controls.Add($lblUninstallInfo, 0, 0)

$panelUninstallList = New-Object System.Windows.Forms.Panel
$panelUninstallList.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelUninstallList.AutoScroll = $true
$tableUninstall.Controls.Add($panelUninstallList, 0, 1)

$clbUninstall = New-Object System.Windows.Forms.CheckedListBox
$clbUninstall.CheckOnClick = $true
$clbUninstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$clbUninstall.Font = $FontNormal
$panelUninstallList.Controls.Add($clbUninstall)

$panelUninstallButtons = New-Object System.Windows.Forms.FlowLayoutPanel
$panelUninstallButtons.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelUninstallButtons.Height = 55
$tableUninstall.Controls.Add($panelUninstallButtons, 0, 2)

$btnRefreshInstalled = New-Object System.Windows.Forms.Button
$btnRefreshInstalled.Text = "Atualizar lista"
$btnRefreshInstalled.Size = New-Object System.Drawing.Size(130,32)
$panelUninstallButtons.Controls.Add($btnRefreshInstalled)

$btnUninstallSelected = New-Object System.Windows.Forms.Button
$btnUninstallSelected.Text = "Desinstalar"
$btnUninstallSelected.Size = New-Object System.Drawing.Size(130,32)
$btnUninstallSelected.BackColor = $ColorDanger
$btnUninstallSelected.ForeColor = [System.Drawing.Color]::White
$btnUninstallSelected.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnUninstallSelected.FlatAppearance.BorderSize = 0
$panelUninstallButtons.Controls.Add($btnUninstallSelected)

# ============================================================
# ABA ATIVAR WINDOWS (inalterada, com link)
# ============================================================

$tabActivate = New-Object System.Windows.Forms.TabPage
$tabActivate.Text = "Ativar Windows"
$tabActivate.BackColor = $ColorBackground
$tabControl.Controls.Add($tabActivate)

$flowActivate = New-Object System.Windows.Forms.FlowLayoutPanel
$flowActivate.Dock = [System.Windows.Forms.DockStyle]::Fill
$flowActivate.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$flowActivate.WrapContents = $false
$flowActivate.AutoScroll = $true
$flowActivate.Padding = New-Object System.Windows.Forms.Padding(30)
$tabActivate.Controls.Add($flowActivate)

$lblActivateTitle = New-Object System.Windows.Forms.Label
$lblActivateTitle.Text = "Ativação do Windows"
$lblActivateTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 16)
$lblActivateTitle.AutoSize = $true
$lblActivateTitle.Margin = New-Object System.Windows.Forms.Padding(0,0,0,20)
$flowActivate.Controls.Add($lblActivateTitle)

$lblActivateDesc = New-Object System.Windows.Forms.Label
$lblActivateDesc.Text = "Clique no botão abaixo para acessar o link de ativação/instalação do Windows."
$lblActivateDesc.MaximumSize = New-Object System.Drawing.Size(700,0)
$lblActivateDesc.AutoSize = $true
$lblActivateDesc.Margin = New-Object System.Windows.Forms.Padding(0,0,0,25)
$flowActivate.Controls.Add($lblActivateDesc)

$btnCustomActivate = New-Object System.Windows.Forms.Button
$btnCustomActivate.Text = "ABRIR LINK DE ATIVAÇÃO"
$btnCustomActivate.Font = $FontButtonBold
$btnCustomActivate.BackColor = $ColorPrimary
$btnCustomActivate.ForeColor = [System.Drawing.Color]::White
$btnCustomActivate.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnCustomActivate.FlatAppearance.BorderSize = 0
$btnCustomActivate.Size = New-Object System.Drawing.Size(300,50)
$flowActivate.Controls.Add($btnCustomActivate)

# ============================================================
# ABA SITEF (inalterada)
# ============================================================

$tabSitef = New-Object System.Windows.Forms.TabPage
$tabSitef.Text = "SITEF"
$tabSitef.BackColor = $ColorBackground
$tabControl.Controls.Add($tabSitef)

$tableSitef = New-Object System.Windows.Forms.TableLayoutPanel
$tableSitef.Dock = [System.Windows.Forms.DockStyle]::Fill
$tableSitef.ColumnCount = 1
$tableSitef.RowCount = 4
$tableSitef.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$tableSitef.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$tableSitef.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$tableSitef.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$tableSitef.Padding = New-Object System.Windows.Forms.Padding(15)
$tabSitef.Controls.Add($tableSitef)

$lblSitefTitle = New-Object System.Windows.Forms.Label
$lblSitefTitle.Text = "Instalação do Ambiente SITEF"
$lblSitefTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 14)
$lblSitefTitle.ForeColor = $ColorText
$lblSitefTitle.AutoSize = $true
$lblSitefTitle.Margin = New-Object System.Windows.Forms.Padding(3,3,3,10)
$tableSitef.Controls.Add($lblSitefTitle, 0, 0)

$lblSitefDesc = New-Object System.Windows.Forms.Label
$lblSitefDesc.Text = "Esta etapa baixa, extrai e executa os componentes do SITEF.`r`n" +
    "Os instaladores podem solicitar configurações manuais.`r`n" +
    "Também estão disponíveis os pacotes DLL_FLY e DLL_FLY_EMBARCADO.`r`n" +
    "As pastas dos pacotes serão adicionadas à exclusão do Windows Defender."
$lblSitefDesc.Font = $FontNormal
$lblSitefDesc.ForeColor = $ColorMuted
$lblSitefDesc.AutoSize = $true
$lblSitefDesc.Margin = New-Object System.Windows.Forms.Padding(3,0,3,10)
$tableSitef.Controls.Add($lblSitefDesc, 0, 1)

$flowSitefButtons = New-Object System.Windows.Forms.FlowLayoutPanel
$flowSitefButtons.Dock = [System.Windows.Forms.DockStyle]::Fill
$flowSitefButtons.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$flowSitefButtons.WrapContents = $true
$flowSitefButtons.AutoSize = $true
$flowSitefButtons.Padding = New-Object System.Windows.Forms.Padding(3)
$tableSitef.Controls.Add($flowSitefButtons, 0, 2)

function New-SitefButton {
    param([string]$Text, [int]$Width, [System.Drawing.Color]$BackColor, [System.Drawing.Color]$ForeColor)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Font = $FontButtonBold
    $button.BackColor = $BackColor
    $button.ForeColor = $ForeColor
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 0
    $button.Size = New-Object System.Drawing.Size($Width, 40)
    $button.Margin = New-Object System.Windows.Forms.Padding(4)
    return $button
}

$btnSitefInstall = New-SitefButton "Instalar SITEF" 160 $ColorPrimary ([System.Drawing.Color]::White)
$flowSitefButtons.Controls.Add($btnSitefInstall)

$btnDllFly = New-SitefButton "DLL_FLY" 150 $ColorPrimary ([System.Drawing.Color]::White)
$flowSitefButtons.Controls.Add($btnDllFly)

$btnDllFlyEmbarcado = New-SitefButton "DLL_FLY_EMBARCADO" 190 $ColorPrimary ([System.Drawing.Color]::White)
$flowSitefButtons.Controls.Add($btnDllFlyEmbarcado)

$btnSitefOpenFolder = New-SitefButton "Abrir pasta" 130 $ColorSurface $ColorText
$btnSitefOpenFolder.FlatAppearance.BorderColor = $ColorBorder
$flowSitefButtons.Controls.Add($btnSitefOpenFolder)

$btnInstallAll = New-SitefButton "Instalar tudo" 150 $ColorSuccess ([System.Drawing.Color]::White)
$flowSitefButtons.Controls.Add($btnInstallAll)

$btnClearLog = New-SitefButton "Limpar log" 120 $ColorSurface $ColorText
$btnClearLog.FlatAppearance.BorderColor = $ColorBorder
$flowSitefButtons.Controls.Add($btnClearLog)

$panelSitefLog = New-Object System.Windows.Forms.Panel
$panelSitefLog.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelSitefLog.Padding = New-Object System.Windows.Forms.Padding(0,10,0,0)
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
$txtSitefLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtSitefLog.ReadOnly = $true
$txtSitefLog.Dock = [System.Windows.Forms.DockStyle]::Fill
$txtSitefLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$txtSitefLog.BackColor = [System.Drawing.Color]::White
$grpSitefLog.Controls.Add($txtSitefLog)

$progressSitef = New-Object System.Windows.Forms.ProgressBar
$progressSitef.Minimum = 0
$progressSitef.Maximum = 100
$progressSitef.Value = 0
$progressSitef.Dock = [System.Windows.Forms.DockStyle]::Bottom
$progressSitef.Height = 20
$grpSitefLog.Controls.Add($progressSitef)

# ============================================================
# FUNÇÕES DE LOG COMPARTILHADAS
# ============================================================

function Write-ConfigLog {
    param([string]$Message)
    $line = "$Message`r`n"
    $txtConfigLog.AppendText($line)
    $txtConfigLog.SelectionStart = $txtConfigLog.Text.Length
    $txtConfigLog.ScrollToCaret()
    Write-LogFile $Message
    [System.Windows.Forms.Application]::DoEvents()
}

$AppendLog = {
    param($msg)
    Write-ConfigLog $msg
}

$script:SitefLogDelegate = {
    param($msg)
    $line = "$msg`r`n"
    $txtSitefLog.AppendText($line)
    $txtSitefLog.SelectionStart = $txtSitefLog.Text.Length
    $txtSitefLog.ScrollToCaret()
    Write-LogFile "[SITEF] $msg"
    [System.Windows.Forms.Application]::DoEvents()
}

# ============================================================
# EVENTOS DOS BOTÕES (CONFIGURAÇÃO, GERENCIAR, ATIVAR, SITEF)
# ============================================================

# Configuração - marcar/desmarcar todos
$btnSelAll.Add_Click({
    foreach ($cb in $checkboxes.Values) { $cb.Checked = $true }
})
$btnSelNone.Add_Click({
    foreach ($cb in $checkboxes.Values) { $cb.Checked = $false }
})

# Configuração - executar
$btnRun.Add_Click({
    $btnRun.Enabled = $false
    $btnSelAll.Enabled = $false
    $btnSelNone.Enabled = $false
    $chkDryRun.Enabled = $false
    $script:CancelRequested = $false
    $script:Results = [ordered]@{}
    $txtConfigLog.Clear()
    $DryRun = [bool]$chkDryRun.Checked
    $selectedSteps = @($steps.Keys | Where-Object { $checkboxes[$_].Checked })
    if ($selectedSteps.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Nenhuma etapa foi selecionada.","Aviso",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)
        $btnRun.Enabled = $true; $btnSelAll.Enabled = $true; $btnSelNone.Enabled = $true; $chkDryRun.Enabled = $true
        return
    }
    Write-ConfigLog "=== INICIANDO PROVISIONAMENTO ==="
    Write-ConfigLog "Modo: $(if ($DryRun) { 'SIMULAÇÃO' } else { 'EXECUÇÃO REAL' })"
    Write-ConfigLog ""
    $progressBar.Minimum = 0
    $progressBar.Maximum = $selectedSteps.Count
    $progressBar.Value = 0
    foreach ($key in $selectedSteps) {
        $lblStatus.Text = "Executando: $key..."
        Write-ConfigLog ""
        Write-ConfigLog ">>> $key"
        try {
            $result = & $steps[$key] $AppendLog $DryRun
            if ($result -eq $false) {
                $script:Results[$key] = "FALHA"
                Write-ConfigLog "Resultado: FALHA"
            } else {
                $script:Results[$key] = if ($DryRun) { "SIMULADO" } else { "OK" }
                Write-ConfigLog "Resultado: $($script:Results[$key])"
            }
        } catch {
            $errorMessage = $_.Exception.Message
            $script:Results[$key] = "FALHA: $errorMessage"
            Write-ConfigLog "ERRO em '$key': $errorMessage"
        }
        if ($progressBar.Value -lt $progressBar.Maximum) { $progressBar.Value++ }
        [System.Windows.Forms.Application]::DoEvents()
    }
    Write-ConfigLog ""
    Write-ConfigLog "=== PROVISIONAMENTO CONCLUÍDO ==="
    $reportLines = @()
    $reportLines += "Relatório de Provisionamento - $Timestamp"
    $reportLines += "Modo: $(if ($DryRun) { 'SIMULAÇÃO' } else { 'EXECUÇÃO REAL' })"
    $reportLines += ""
    foreach ($k in $script:Results.Keys) {
        $reportLines += ("{0,-50} {1}" -f $k, $script:Results[$k])
    }
    try {
        $reportLines | Set-Content -Path $ReportPath -Encoding UTF8
        Write-ConfigLog "Relatório salvo em: $ReportPath"
    } catch {
        Write-ConfigLog "ERRO ao salvar relatório: $($_.Exception.Message)"
    }
    $lblStatus.Text = "Provisionamento concluído."
    $progressBar.Value = $progressBar.Maximum
    $btnRun.Enabled = $true; $btnSelAll.Enabled = $true; $btnSelNone.Enabled = $true; $chkDryRun.Enabled = $true
    [System.Windows.Forms.MessageBox]::Show("Provisionamento concluído.`r`n`r`nRelatório:`r`n$ReportPath","Finalizado",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)
})

# Gerenciar - atualizar lista
$btnRefreshInstalled.Add_Click({
    $btnRefreshInstalled.Enabled = $false
    try {
        Write-ConfigLog "Consultando programas instalados..."
        $clbUninstall.Items.Clear()
        $script:UninstallMap = @{}
        $programs = @(Get-InstalledProgramsList)
        $wingetList = @()
        try {
            $wingetOutput = winget list --accept-source-agreements 2>$null
            $wingetList = $wingetOutput | ForEach-Object {
                if ($_ -match '^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)') { $Matches[1] }
            } | Where-Object { $_ -ne "Name" -and $_ -ne "─" -and $_ -ne "" }
        } catch {}
        $chocoList = @()
        try {
            $chocoOutput = choco list --limit-output 2>$null
            $chocoList = $chocoOutput | ForEach-Object {
                if ($_ -match '^([^|]+)\|') { $Matches[1] }
            } | Where-Object { $_ -ne "" }
        } catch {}
        foreach ($program in $programs) {
            $name = $program.DisplayName
            if (-not [string]::IsNullOrWhiteSpace($name) -and -not $script:UninstallMap.ContainsKey($name)) {
                $isWinget = $wingetList -contains $name
                $isChoco = $chocoList -contains $name
                $cmd = if ($isWinget) { "winget_uninstall" } elseif ($isChoco) { "choco_uninstall" } else {
                    if (-not [string]::IsNullOrWhiteSpace($program.QuietUninstallString)) { $program.QuietUninstallString } else { $program.UninstallString }
                }
                $script:UninstallMap[$name] = @{ Command = $cmd; IsWinget = $isWinget; IsChoco = $isChoco }
                [void]$clbUninstall.Items.Add($name)
            }
        }
        Write-ConfigLog "$($clbUninstall.Items.Count) programas encontrados."
    } catch {
        Write-ConfigLog "ERRO ao atualizar lista: $($_.Exception.Message)"
    } finally {
        $btnRefreshInstalled.Enabled = $true
    }
})

# Gerenciar - desinstalar
$btnUninstallSelected.Add_Click({
    $selected = @($clbUninstall.CheckedItems)
    if ($selected.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Selecione ao menos um programa.","Aviso")
        return
    }
    $confirm = [System.Windows.Forms.MessageBox]::Show("Deseja desinstalar os seguintes programas?`r`n`r`n$($selected -join "`r`n")","Confirmar remoção",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $btnUninstallSelected.Enabled = $false
    try {
        Write-ConfigLog ""
        Write-ConfigLog "== DESINSTALAÇÃO DE PROGRAMAS =="
        foreach ($name in $selected) {
            $info = $script:UninstallMap[$name]
            $cmd = $info.Command
            Write-ConfigLog "Desinstalando: $name"
            $success = $false
            if ($info.IsWinget) {
                $success = Uninstall-WingetPackage -id $name
                if ($success) { Write-ConfigLog "Desinstalado via winget: $name" } else { Write-ConfigLog "Falha ao desinstalar via winget, tentando método alternativo." }
            }
            if (-not $success -and $info.IsChoco) {
                $success = Uninstall-ChocoPackage -id $name
                if ($success) { Write-ConfigLog "Desinstalado via Chocolatey: $name" } else { Write-ConfigLog "Falha ao desinstalar via Chocolatey, tentando método alternativo." }
            }
            if (-not $success) {
                if ($cmd -and $cmd -ne "winget_uninstall" -and $cmd -ne "choco_uninstall") {
                    $success = Uninstall-RegistryProgram -cmd $cmd
                    if ($success) { Write-ConfigLog "Desinstalado via registro: $name" } else { Write-ConfigLog "ERRO ao desinstalar '$name' via registro." }
                } else {
                    Write-ConfigLog "Nenhum método de desinstalação disponível para '$name'."
                }
            }
        }
        Write-ConfigLog "Remoção concluída."
        Write-ConfigLog "Clique em Atualizar lista."
    } finally {
        $btnUninstallSelected.Enabled = $true
    }
})

# Ativar Windows - abrir link
$btnCustomActivate.Add_Click({
    try {
        Write-ConfigLog "Abrindo link de ativação: $ActivationUrl"
        Start-Process $ActivationUrl
        Write-ConfigLog "Link aberto."
    } catch {
        Write-ConfigLog "ERRO ao abrir link: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Não foi possível abrir o link de ativação.`r`nVerifique sua conexão com a internet e tente novamente.","Erro")
    }
})

# SITEF - botões
$btnSitefInstall.Add_Click({
    if ($script:SitefBusy) { return }
    $script:SitefBusy = $true
    $btnSitefInstall.Enabled = $false; $btnDllFly.Enabled = $false; $btnDllFlyEmbarcado.Enabled = $false; $btnInstallAll.Enabled = $false
    $txtSitefLog.Clear(); $progressSitef.Value = 0
    try {
        $result = Install-Sitef
        if ($result) {
            [System.Windows.Forms.MessageBox]::Show("Instalação do SITEF concluída.","SITEF",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)
        } else {
            [System.Windows.Forms.MessageBox]::Show("A instalação do SITEF apresentou erro. Consulte o log.","SITEF",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    } catch {
        $txtSitefLog.AppendText("ERRO inesperado: $($_.Exception.Message)`r`n")
    } finally {
        $btnSitefInstall.Enabled = $true; $btnDllFly.Enabled = $true; $btnDllFlyEmbarcado.Enabled = $true; $btnInstallAll.Enabled = $true
        $script:SitefBusy = $false
    }
})

$btnDllFly.Add_Click({
    if ($script:SitefBusy) { return }
    $script:SitefBusy = $true
    $btnSitefInstall.Enabled = $false; $btnDllFly.Enabled = $false; $btnDllFlyEmbarcado.Enabled = $false; $btnInstallAll.Enabled = $false
    $txtSitefLog.Clear(); $progressSitef.Value = 0
    try {
        $result = Download-DllFly
        if ($result) {
            [System.Windows.Forms.MessageBox]::Show("DLL_FLY instalado com sucesso em C:\SITEF\DLL_FLY.","DLL_FLY")
        } else {
            [System.Windows.Forms.MessageBox]::Show("Falha na instalação do DLL_FLY. Consulte o log.","DLL_FLY")
        }
    } catch {
        $txtSitefLog.AppendText("ERRO inesperado: $($_.Exception.Message)`r`n")
    } finally {
        $btnSitefInstall.Enabled = $true; $btnDllFly.Enabled = $true; $btnDllFlyEmbarcado.Enabled = $true; $btnInstallAll.Enabled = $true
        $script:SitefBusy = $false
    }
})

$btnDllFlyEmbarcado.Add_Click({
    if ($script:SitefBusy) { return }
    $script:SitefBusy = $true
    $btnSitefInstall.Enabled = $false; $btnDllFly.Enabled = $false; $btnDllFlyEmbarcado.Enabled = $false; $btnInstallAll.Enabled = $false
    $txtSitefLog.Clear(); $progressSitef.Value = 0
    try {
        $result = Download-DllFlyEmbarcado
        if ($result) {
            [System.Windows.Forms.MessageBox]::Show("DLL_FLY_EMBARCADO instalado com sucesso em C:\SITEF\DLL_FLY_EMBARCADO.","DLL_FLY_EMBARCADO")
        } else {
            [System.Windows.Forms.MessageBox]::Show("Falha na instalação do DLL_FLY_EMBARCADO. Consulte o log.","DLL_FLY_EMBARCADO")
        }
    } catch {
        $txtSitefLog.AppendText("ERRO inesperado: $($_.Exception.Message)`r`n")
    } finally {
        $btnSitefInstall.Enabled = $true; $btnDllFly.Enabled = $true; $btnDllFlyEmbarcado.Enabled = $true; $btnInstallAll.Enabled = $true
        $script:SitefBusy = $false
    }
})

$btnSitefOpenFolder.Add_Click({
    $sitefDir = "C:\SITEF"
    if (Test-Path $sitefDir) {
        Start-Process "explorer.exe" -ArgumentList "`"$sitefDir`""
    } else {
        [System.Windows.Forms.MessageBox]::Show("A pasta C:\SITEF ainda não existe.","Pasta não encontrada")
    }
})

$btnInstallAll.Add_Click({
    if ($script:SitefBusy) { return }
    $script:SitefBusy = $true
    $btnSitefInstall.Enabled = $false; $btnDllFly.Enabled = $false; $btnDllFlyEmbarcado.Enabled = $false; $btnInstallAll.Enabled = $false
    $txtSitefLog.Clear(); $progressSitef.Value = 0
    $script:SitefLogDelegate.Invoke("=== INSTALAÇÃO COMPLETA SITEF ===")
    $success = $true
    try {
        $script:SitefLogDelegate.Invoke(""); $script:SitefLogDelegate.Invoke("1/3 - Instalando SITEF...")
        if (-not (Install-Sitef)) { $success = $false }
        if ($success) {
            $script:SitefLogDelegate.Invoke(""); $script:SitefLogDelegate.Invoke("2/3 - Instalando DLL_FLY...")
            if (-not (Download-DllFly)) { $success = $false }
        }
        if ($success) {
            $script:SitefLogDelegate.Invoke(""); $script:SitefLogDelegate.Invoke("3/3 - Instalando DLL_FLY_EMBARCADO...")
            if (-not (Download-DllFlyEmbarcado)) { $success = $false }
        }
        $script:SitefLogDelegate.Invoke("")
        if ($success) {
            $script:SitefLogDelegate.Invoke("=== INSTALAÇÃO COMPLETA CONCLUÍDA ===")
            [System.Windows.Forms.MessageBox]::Show("Todas as etapas do SITEF foram concluídas.","SITEF",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)
        } else {
            $script:SitefLogDelegate.Invoke("=== INSTALAÇÃO COMPLETA FINALIZADA COM ERROS ===")
            [System.Windows.Forms.MessageBox]::Show("Uma ou mais etapas apresentaram erro. Consulte o log.","SITEF",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    } catch {
        $script:SitefLogDelegate.Invoke("ERRO inesperado: $($_.Exception.Message)")
    } finally {
        $btnSitefInstall.Enabled = $true; $btnDllFly.Enabled = $true; $btnDllFlyEmbarcado.Enabled = $true; $btnInstallAll.Enabled = $true
        $script:SitefBusy = $false
    }
})

$btnClearLog.Add_Click({
    $txtSitefLog.Clear(); $progressSitef.Value = 0
    $script:SitefLogDelegate.Invoke("Log limpo.")
})

# ============================================================
# CARREGAR PROGRAMAS AO ABRIR
# ============================================================

$form.Add_Shown({
    try { $btnRefreshInstalled.PerformClick() } catch { Write-ConfigLog "Erro ao carregar programas instalados: $($_.Exception.Message)" }
})

# ============================================================
# FECHAMENTO
# ============================================================

$form.Add_FormClosing({
    $script:CancelRequested = $true
    Get-Job | Where-Object { $_.State -in @("Running","NotStarted") } | Remove-Job -Force -ErrorAction SilentlyContinue
})

# ============================================================
# EXECUTAR INTERFACE
# ============================================================

[void]$form.ShowDialog()
