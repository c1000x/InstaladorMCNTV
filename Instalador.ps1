<#
    ProvisioningTool.ps1
    MCNTV Installer
    Interface com abas:
      1. Configuração do Sistema
      2. Instalar Aplicativos
      3. Gerenciar Aplicativos
      4. Ativar Windows
      5. SITEF

    Correções principais:
      - $steps criado antes de ser utilizado
      - $txtLog criado
      - $progressBar criado
      - $lblStatus criado
      - Layout das abas corrigido
      - Layout SITEF corrigido
      - Eventos dos botões corrigidos
      - Tratamento de erros melhorado
      - Instalação de aplicativos sem passar delegate para Start-Job
      - Pesquisa de aplicativos preservando seleção
      - Verificação de sucesso/erro das etapas
      - Logs centralizados
      - Ativação direcionada para as configurações oficiais do Windows
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

$ChocoApps = @(
    "googlechrome"
)

$WingetApps = @(
    "AnyDesk.AnyDesk",
    "Adobe.Acrobat.Reader.64-bit",
    "Oracle.JavaRuntimeEnvironment",
    "Mozilla.Firefox.pt-BR",
    "7zip.7zip",
    "Microsoft.Office"
)

$WingetStoreApps = @(
    "9WZDNCRFJBMP"
)

# ============================================================
# DIRETÓRIOS DE LOG
# ============================================================

$ScriptDir = Split-Path -Parent $scriptPath

$LogsDir = Join-Path $ScriptDir "logs"

if (-not (Test-Path $LogsDir)) {
    New-Item -Path $LogsDir -ItemType Directory -Force | Out-Null
}

$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

$LogFilePath = Join-Path `
    $LogsDir `
    "provisionamento_$Timestamp.log"

$ReportPath = Join-Path `
    $LogsDir `
    "relatorio_$Timestamp.txt"

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
        Add-Content `
            -Path $LogFilePath `
            -Value $Message `
            -Encoding UTF8
    }
    catch {
        # Não interromper o programa caso o arquivo de log esteja bloqueado.
    }
}

# ============================================================
# FUNÇÕES DE PROVISIONAMENTO
# ============================================================

function Step-RestorePoint {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke("== Ponto de restauração ==")

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULAÇÃO] Criaria um ponto de restauração antes das alterações."
        )

        return $true
    }

    try {

        Enable-ComputerRestore `
            -Drive "$env:SystemDrive\" `
            -ErrorAction SilentlyContinue

        Checkpoint-Computer `
            -Description "Antes do provisionamento" `
            -RestorePointType "MODIFY_SETTINGS" `
            -ErrorAction Stop

        $Log.Invoke("Ponto de restauração criado.")

        return $true
    }
    catch {

        $Log.Invoke(
            "AVISO: não foi possível criar ponto de restauração: $($_.Exception.Message)"
        )

        return $true
    }
}

function Step-VersoesAnteriores {

    param(
        $Log,
        [bool]$DryRun
    )

    $drive = $env:SystemDrive

    $Log.Invoke(
        "== Habilitar Versões Anteriores / Shadow Copy em $drive =="
    )

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULAÇÃO] Ativaria System Restore em $drive."
        )

        $Log.Invoke(
            "[SIMULAÇÃO] Reservaria 10% do volume para Shadow Copies."
        )

        $Log.Invoke(
            "[SIMULAÇÃO] Criaria snapshot inicial."
        )

        $Log.Invoke(
            "[SIMULAÇÃO] Agendaria snapshot a cada 4 horas."
        )

        return $true
    }

    try {

        Enable-ComputerRestore `
            -Drive "$drive\" `
            -ErrorAction Stop

        $Log.Invoke(
            "System Restore ativado em $drive."
        )
    }
    catch {

        $Log.Invoke(
            "Aviso ao ativar System Restore: $($_.Exception.Message)"
        )
    }

    try {

        $Log.Invoke(
            "Reservando espaço para cópias de sombra..."
        )

        $vssOutput = vssadmin resize shadowstorage `
            /for="$drive" `
            /on="$drive" `
            /maxsize=10% 2>&1

        foreach ($line in $vssOutput) {
            $Log.Invoke("$line")
        }

        $Log.Invoke(
            "Criando snapshot inicial..."
        )

        $shadowOutput = vssadmin create shadow `
            /for="$drive" 2>&1

        foreach ($line in $shadowOutput) {
            $Log.Invoke("$line")
        }

        schtasks /create `
            /tn "VersoesAnteriores_ShadowCopy" `
            /tr "vssadmin create shadow /for=$drive" `
            /sc hourly `
            /mo 4 `
            /ru "SYSTEM" `
            /rl highest `
            /f | Out-Null

        $Log.Invoke(
            "Tarefa agendada criada."
        )

        return $true
    }
    catch {

        $Log.Invoke(
            "ERRO ao configurar Shadow Copy: $($_.Exception.Message)"
        )

        return $false
    }
}

function Step-IconesAreaTrabalho {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke(
        "== Ícones Este Computador / Pasta do Usuário =="
    )

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULAÇÃO] Ativaria os ícones."
        )

        return $true
    }

    try {

        $path =
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"

        New-Item `
            -Path $path `
            -Force | Out-Null

        New-ItemProperty `
            -Path $path `
            -Name "{20D04FE0-3AEA-1069-A2D8-08002B30309D}" `
            -PropertyType DWord `
            -Value 0 `
            -Force | Out-Null

        New-ItemProperty `
            -Path $path `
            -Name "{59031a47-3f72-44a7-89c5-5595fe6b30ee}" `
            -PropertyType DWord `
            -Value 0 `
            -Force | Out-Null

        Stop-Process `
            -Name explorer `
            -Force `
            -ErrorAction SilentlyContinue

        Start-Process explorer.exe

        $Log.Invoke(
            "Ícones configurados e Explorer reiniciado."
        )

        return $true
    }
    catch {

        $Log.Invoke(
            "ERRO ao configurar ícones: $($_.Exception.Message)"
        )

        return $false
    }
}

function Step-Telemetria {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke("== Telemetria ==")

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULAÇÃO] Desativaria a telemetria via política local."
        )

        return $true
    }

    try {

        $path =
            "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"

        New-Item `
            -Path $path `
            -Force | Out-Null

        Set-ItemProperty `
            -Path $path `
            -Name "AllowTelemetry" `
            -Value 0 `
            -Type DWord `
            -Force

        $Log.Invoke(
            "Política de telemetria configurada."
        )

        return $true
    }
    catch {

        $Log.Invoke(
            "ERRO ao configurar telemetria: $($_.Exception.Message)"
        )

        return $false
    }
}

function Step-Energia {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke("== Plano de energia ==")

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULAÇÃO] Desativaria temporizadores de monitor, disco e suspensão."
        )

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

        $Log.Invoke(
            "Plano de energia ajustado."
        )

        return $true
    }
    catch {

        $Log.Invoke(
            "ERRO ao ajustar energia: $($_.Exception.Message)"
        )

        return $false
    }
}

function Step-RegiaoIdioma {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke(
        "== Fuso horário e localização Brasil =="
    )

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULAÇÃO] Definiria fuso horário de Brasília."
        )

        $Log.Invoke(
            "[SIMULAÇÃO] Definiria localização Brasil."
        )

        return $true
    }

    try {

        Set-TimeZone `
            -Id "E. South America Standard Time" `
            -ErrorAction Stop

        $Log.Invoke(
            "Fuso horário de Brasília definido."
        )
    }
    catch {

        $Log.Invoke(
            "Aviso: não foi possível definir o fuso horário: $($_.Exception.Message)"
        )
    }

    try {

        Set-WinHomeLocation `
            -GeoId 76 `
            -ErrorAction Stop

        $Log.Invoke(
            "Localização Brasil definida."
        )
    }
    catch {

        $Log.Invoke(
            "Aviso: não foi possível definir a localização Brasil."
        )
    }

    return $true
}

function Step-Debloat {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke(
        "== Remover aplicativos padrão =="
    )

    $apps = @(
        "3dbuilder",
        "bingweather",
        "xboxapp",
        "zunemusic",
        "officehub",
        "skypeapp"
    )

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULAÇÃO] Removeria: $($apps -join ', ')"
        )

        return $true
    }

    foreach ($app in $apps) {

        try {

            Get-AppxPackage `
                "*$app*" `
                -ErrorAction SilentlyContinue |
                Remove-AppxPackage `
                    -ErrorAction SilentlyContinue

            Get-AppxProvisionedPackage `
                -Online `
                -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.DisplayName -like "*$app*"
                } |
                Remove-AppxProvisionedPackage `
                    -Online `
                    -ErrorAction SilentlyContinue |
                Out-Null

            $Log.Invoke(
                "Processado: $app"
            )
        }
        catch {

            $Log.Invoke(
                "Aviso ao remover $app : $($_.Exception.Message)"
            )
        }
    }

    return $true
}

function Ensure-ChocoAvailable {

    param(
        $Log
    )

    if (Get-Command choco -ErrorAction SilentlyContinue) {
        return $true
    }

    $machinePath =
        [Environment]::GetEnvironmentVariable(
            "Path",
            "Machine"
        )

    $userPath =
        [Environment]::GetEnvironmentVariable(
            "Path",
            "User"
        )

    $env:Path = "$machinePath;$userPath"

    if (Get-Command choco -ErrorAction SilentlyContinue) {
        return $true
    }

    $chocoBin =
        Join-Path `
            $env:ProgramData `
            "chocolatey\bin"

    $chocoExe =
        Join-Path `
            $chocoBin `
            "choco.exe"

    if (Test-Path $chocoExe) {

        $env:Path += ";$chocoBin"

        return $true
    }

    if ($Log) {

        $Log.Invoke(
            "Chocolatey não encontrado."
        )
    }

    return $false
}

function Step-Chocolatey {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke("== Chocolatey ==")

    if (Get-Command choco -ErrorAction SilentlyContinue) {

        $Log.Invoke(
            "Chocolatey já está instalado."
        )

        return $true
    }

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULAÇÃO] Instalaria Chocolatey."
        )

        return $true
    }

    try {

        Set-ExecutionPolicy `
            Bypass `
            -Scope Process `
            -Force

        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor 3072

        $installScript =
            Invoke-RestMethod `
                -Uri "https://community.chocolatey.org/install.ps1"

        Invoke-Expression $installScript

        $chocoBin =
            Join-Path `
                $env:ProgramData `
                "chocolatey\bin"

        if (Test-Path $chocoBin) {
            $env:Path += ";$chocoBin"
        }

        if (Get-Command choco -ErrorAction SilentlyContinue) {

            $Log.Invoke(
                "Chocolatey instalado com sucesso."
            )

            return $true
        }

        $Log.Invoke(
            "Chocolatey não foi localizado após a instalação."
        )

        return $false
    }
    catch {

        $Log.Invoke(
            "ERRO ao instalar Chocolatey: $($_.Exception.Message)"
        )

        return $false
    }
}

function Step-WingetUpgradeAll {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke(
        "== Atualização dos aplicativos via winget =="
    )

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {

        $Log.Invoke(
            "ERRO: winget não está disponível neste computador."
        )

        return $false
    }

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULAÇÃO] winget upgrade --all"
        )

        return $true
    }

    try {

        $Log.Invoke(
            "Atualizando fontes do winget..."
        )

        winget source update 2>&1 |
            ForEach-Object {
                $Log.Invoke("$_")
            }

        $Log.Invoke(
            "Atualizando aplicativos..."
        )

        winget upgrade `
            --all `
            --accept-source-agreements `
            --accept-package-agreements `
            --silent 2>&1 |
            ForEach-Object {
                $Log.Invoke("$_")
            }

        $Log.Invoke(
            "Atualização concluída."
        )

        return $true
    }
    catch {

        $Log.Invoke(
            "ERRO no winget upgrade: $($_.Exception.Message)"
        )

        return $false
    }
}

function Step-TarefaLimpeza {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke(
        "== Tarefa agendada de limpeza de disco =="
    )

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULAÇÃO] Criaria tarefa LimpezaDisco aos domingos às 03:00."
        )

        return $true
    }

    try {

        schtasks /create `
            /tn "LimpezaDisco" `
            /tr "cleanmgr /sagerun:1" `
            /sc weekly `
            /d SUN `
            /st 03:00 `
            /ru "SYSTEM" `
            /rl highest `
            /f | Out-Null

        $Log.Invoke(
            "Tarefa LimpezaDisco criada/atualizada."
        )

        return $true
    }
    catch {

        $Log.Invoke(
            "ERRO ao criar tarefa: $($_.Exception.Message)"
        )

        return $false
    }
}

# ============================================================
# LISTA DE ETAPAS
# IMPORTANTE: DEVE SER DECLARADA ANTES DA INTERFACE
# ============================================================

$steps = [ordered]@{

    "Ponto de Restauração" = {
        param($l, $d)
        Step-RestorePoint -Log $l -DryRun $d
    }

    "Versões Anteriores (Shadow Copy)" = {
        param($l, $d)
        Step-VersoesAnteriores -Log $l -DryRun $d
    }

    "Ícones da Área de Trabalho" = {
        param($l, $d)
        Step-IconesAreaTrabalho -Log $l -DryRun $d
    }

    "Desativar Telemetria" = {
        param($l, $d)
        Step-Telemetria -Log $l -DryRun $d
    }

    "Ajustar Plano de Energia" = {
        param($l, $d)
        Step-Energia -Log $l -DryRun $d
    }

    "Fuso Horário / Localização (BR)" = {
        param($l, $d)
        Step-RegiaoIdioma -Log $l -DryRun $d
    }

    "Remover Apps Padrão (Debloat)" = {
        param($l, $d)
        Step-Debloat -Log $l -DryRun $d
    }

    "Instalar/Atualizar Chocolatey" = {
        param($l, $d)
        Step-Chocolatey -Log $l -DryRun $d
    }

    "Atualizar Apps (winget upgrade)" = {
        param($l, $d)
        Step-WingetUpgradeAll -Log $l -DryRun $d
    }

    "Criar Tarefa de Limpeza Semanal" = {
        param($l, $d)
        Step-TarefaLimpeza -Log $l -DryRun $d
    }
}

$UncheckedByDefault = @(
    "Versões Anteriores (Shadow Copy)"
)

# ============================================================
# CATÁLOGO DE PROGRAMAS
# ============================================================

function Build-AppCatalogLabels {

    $script:AppCatalogMap = @{}

    $labels =
        New-Object System.Collections.ArrayList

    foreach ($id in $ChocoApps) {

        $label = "[Choco] $id"

        $script:AppCatalogMap[$label] = @{
            Manager = "choco"
            Id      = $id
        }

        [void]$labels.Add($label)
    }

    foreach ($id in $WingetApps) {

        $label = "[Winget] $id"

        $script:AppCatalogMap[$label] = @{
            Manager = "winget"
            Id      = $id
        }

        [void]$labels.Add($label)
    }

    foreach ($id in $WingetStoreApps) {

        $label = "[Store] $id"

        $script:AppCatalogMap[$label] = @{
            Manager = "wingetStore"
            Id      = $id
        }

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

    Get-ItemProperty `
        -Path $paths `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -and
            (-not $_.SystemComponent) -and
            $_.UninstallString
        } |
        Select-Object `
            DisplayName,
            UninstallString,
            QuietUninstallString |
        Sort-Object DisplayName
}

# ============================================================
# SITEF
# ============================================================

function Get-WebClient {

    $client = New-Object System.Net.WebClient

    $client.Headers.Add(
        "User-Agent",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
    )

    return $client
}

function Validate-ZipFile {

    param(
        [string]$Path
    )

    try {

        if (-not (Test-Path $Path)) {
            return $false
        }

        $bytes =
            [System.IO.File]::ReadAllBytes($Path)

        if ($bytes.Count -lt 4) {
            return $false
        }

        return (
            $bytes[0] -eq 0x50 -and
            $bytes[1] -eq 0x4B -and
            $bytes[2] -eq 0x03 -and
            $bytes[3] -eq 0x04
        )
    }
    catch {

        return $false
    }
}

function Install-Sitef {

    $log = $script:SitefLogDelegate

    $log.Invoke("=== INICIANDO INSTALAÇÃO SITEF ===")
    $log.Invoke("")

    $sitefDir = "C:\SITEF"

    $zipUrls = @(
        @{
            url  = "http://gsurf.com.br/lib/win/certificado.zip"
            nome = "certificado.zip"
        },
        @{
            url  = "http://gsurf.com.br/lib/win/gsclient.zip"
            nome = "gsclient.zip"
        }
    )

    try {

        if (-not (Test-Path $sitefDir)) {

            $log.Invoke(
                "Criando diretório $sitefDir..."
            )

            New-Item `
                -ItemType Directory `
                -Path $sitefDir `
                -Force | Out-Null

            $log.Invoke(
                "Diretório criado."
            )
        }
        else {

            $log.Invoke(
                "Diretório $sitefDir já existe."
            )
        }

        $progressSitef.Maximum =
            $zipUrls.Count * 2

        $progressSitef.Value = 0

        foreach ($item in $zipUrls) {

            $url = $item.url
            $fileName = $item.nome

            $zipPath =
                Join-Path `
                    $sitefDir `
                    $fileName

            $extractPath =
                Join-Path `
                    $sitefDir `
                    ([IO.Path]::GetFileNameWithoutExtension($fileName))

            if (Test-Path $zipPath) {

                $log.Invoke(
                    "Arquivo $fileName já existe."
                )

                if (Validate-ZipFile $zipPath) {

                    try {

                        if (-not (Test-Path $extractPath)) {

                            New-Item `
                                -ItemType Directory `
                                -Path $extractPath `
                                -Force | Out-Null
                        }

                        Expand-Archive `
                            -Path $zipPath `
                            -DestinationPath $extractPath `
                            -Force

                        $log.Invoke(
                            "Arquivo existente extraído."
                        )

                        $progressSitef.Value += 2

                        continue
                    }
                    catch {

                        $log.Invoke(
                            "Falha ao extrair arquivo existente."
                        )
                    }
                }

                Remove-Item `
                    $zipPath `
                    -Force `
                    -ErrorAction SilentlyContinue
            }

            $log.Invoke(
                "Baixando $fileName..."
            )

            try {

                $webClient = Get-WebClient

                $webClient.DownloadFile(
                    $url,
                    $zipPath
                )

                $webClient.Dispose()

                $log.Invoke(
                    "Download concluído."
                )

                $progressSitef.Value += 1
            }
            catch {

                $log.Invoke(
                    "ERRO ao baixar $url : $($_.Exception.Message)"
                )

                return $false
            }

            if (-not (Validate-ZipFile $zipPath)) {

                $log.Invoke(
                    "ERRO: o arquivo baixado não é um ZIP válido."
                )

                Remove-Item `
                    $zipPath `
                    -Force `
                    -ErrorAction SilentlyContinue

                return $false
            }

            $log.Invoke(
                "Extraindo $fileName..."
            )

            try {

                if (Test-Path $extractPath) {

                    Remove-Item `
                        $extractPath `
                        -Recurse `
                        -Force `
                        -ErrorAction SilentlyContinue
                }

                New-Item `
                    -ItemType Directory `
                    -Path $extractPath `
                    -Force | Out-Null

                Expand-Archive `
                    -Path $zipPath `
                    -DestinationPath $extractPath `
                    -Force

                $log.Invoke(
                    "Extraído com sucesso."
                )

                $progressSitef.Value += 1
            }
            catch {

                $log.Invoke(
                    "Falha com Expand-Archive."
                )

                try {

                    [IO.Compression.ZipFile]::ExtractToDirectory(
                        $zipPath,
                        $extractPath,
                        $true
                    )

                    $log.Invoke(
                        "Extraído usando fallback."
                    )

                    $progressSitef.Value += 1
                }
                catch {

                    $log.Invoke(
                        "ERRO ao extrair: $($_.Exception.Message)"
                    )

                    return $false
                }
            }
        }

        $log.Invoke("")
        $log.Invoke(
            "Arquivos baixados e extraídos."
        )

        $msiPath =
            Get-ChildItem `
                -Path $sitefDir `
                -Recurse `
                -Filter "GSurfRSA_Listener_Setup.msi" `
                -ErrorAction SilentlyContinue |
                Select-Object -First 1

        $exePath =
            Get-ChildItem `
                -Path $sitefDir `
                -Recurse `
                -Filter "InstaladorGSurf.exe" `
                -ErrorAction SilentlyContinue |
                Select-Object -First 1

        if (-not $msiPath) {

            $log.Invoke(
                "ERRO: GSurfRSA_Listener_Setup.msi não encontrado."
            )

            return $false
        }

        if (-not $exePath) {

            $log.Invoke(
                "ERRO: InstaladorGSurf.exe não encontrado."
            )

            return $false
        }

        $log.Invoke("")
        $log.Invoke(
            "Executando instalador MSI..."
        )

        try {

            $process =
                Start-Process `
                    -FilePath "msiexec.exe" `
                    -ArgumentList "/i `"$($msiPath.FullName)`"" `
                    -Wait `
                    -PassThru

            $log.Invoke(
                "MSI finalizado. Código: $($process.ExitCode)"
            )
        }
        catch {

            $log.Invoke(
                "ERRO MSI: $($_.Exception.Message)"
            )
        }

        $log.Invoke(
            "Executando InstaladorGSurf.exe..."
        )

        try {

            $process =
                Start-Process `
                    -FilePath $exePath.FullName `
                    -Wait `
                    -PassThru

            $log.Invoke(
                "EXE finalizado. Código: $($process.ExitCode)"
            )
        }
        catch {

            $log.Invoke(
                "ERRO EXE: $($_.Exception.Message)"
            )
        }

        $log.Invoke("")
        $log.Invoke(
            "Aguardando 5 segundos..."
        )

        Start-Sleep -Seconds 5

        $serviceName = "GSurfRSA Listener"

        $log.Invoke(
            "Verificando serviço '$serviceName'..."
        )

        $svc =
            Get-Service `
                -Name $serviceName `
                -ErrorAction SilentlyContinue

        if ($svc) {

            if ($svc.Status -eq "Stopped") {

                try {

                    Start-Service `
                        -Name $serviceName `
                        -ErrorAction Stop

                    $log.Invoke(
                        "Serviço iniciado com sucesso."
                    )
                }
                catch {

                    $log.Invoke(
                        "ERRO ao iniciar serviço: $($_.Exception.Message)"
                    )
                }
            }
            else {

                $log.Invoke(
                    "Serviço já está em execução. Status: $($svc.Status)"
                )
            }
        }
        else {

            $log.Invoke(
                "Serviço '$serviceName' não encontrado."
            )
        }

        $log.Invoke("")
        $log.Invoke(
            "=== INSTALAÇÃO SITEF CONCLUÍDA ==="
        )

        $progressSitef.Value =
            $progressSitef.Maximum

        return $true
    }
    catch {

        $log.Invoke(
            "ERRO geral SITEF: $($_.Exception.Message)"
        )

        return $false
    }
}

function Install-DllPackage {

    param(
        [string]$PackageName,
        [string]$ZipUrl,
        [string]$SuccessMessage
    )

    $log = $script:SitefLogDelegate

    $log.Invoke(
        "=== BAIXANDO $PackageName ==="
    )

    $log.Invoke("")

    $progressSitef.Maximum = 100
    $progressSitef.Value = 0

    $baseDir = "C:\SITEF"

    $targetDir =
        Join-Path `
            $baseDir `
            $PackageName

    $zipFile =
        Join-Path `
            $baseDir `
            "$PackageName.zip"

    $tempExtractDir =
        Join-Path `
            $baseDir `
            "${PackageName}_temp"

    try {

        if (-not (Test-Path $baseDir)) {

            New-Item `
                -ItemType Directory `
                -Path $baseDir `
                -Force | Out-Null
        }

        if (-not (Test-Path $targetDir)) {

            New-Item `
                -ItemType Directory `
                -Path $targetDir `
                -Force | Out-Null

            $log.Invoke(
                "Diretório criado: $targetDir"
            )
        }

        $log.Invoke(
            "Baixando $PackageName.zip..."
        )

        $webClient = Get-WebClient

        $webClient.DownloadFile(
            $ZipUrl,
            $zipFile
        )

        $webClient.Dispose()

        $log.Invoke(
            "Download concluído."
        )

        $progressSitef.Value = 30

        if (-not (Validate-ZipFile $zipFile)) {

            throw "O arquivo baixado não é um ZIP válido."
        }

        if (Test-Path $tempExtractDir) {

            Remove-Item `
                $tempExtractDir `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }

        New-Item `
            -ItemType Directory `
            -Path $tempExtractDir `
            -Force | Out-Null

        $log.Invoke(
            "Extraindo pacote..."
        )

        Expand-Archive `
            -Path $zipFile `
            -DestinationPath $tempExtractDir `
            -Force

        $progressSitef.Value = 60

        $subItems =
            @(Get-ChildItem `
                -Path $tempExtractDir `
                -Force)

        if (
            $subItems.Count -eq 1 -and
            $subItems[0].PSIsContainer
        ) {

            $sourceDir =
                $subItems[0].FullName

            $log.Invoke(
                "Subpasta detectada: $($subItems[0].Name)"
            )

            Get-ChildItem `
                -Path $sourceDir `
                -Recurse `
                -File |
                ForEach-Object {

                    $relativePath =
                        $_.FullName.Substring(
                            $sourceDir.Length + 1
                        )

                    $destFile =
                        Join-Path `
                            $targetDir `
                            $relativePath

                    $destDir =
                        Split-Path `
                            $destFile `
                            -Parent

                    if (-not (Test-Path $destDir)) {

                        New-Item `
                            -ItemType Directory `
                            -Path $destDir `
                            -Force | Out-Null
                    }

                    Copy-Item `
                        -Path $_.FullName `
                        -Destination $destFile `
                        -Force
                }
        }
        else {

            Get-ChildItem `
                -Path $tempExtractDir `
                -Recurse `
                -File |
                ForEach-Object {

                    $relativePath =
                        $_.FullName.Substring(
                            $tempExtractDir.Length + 1
                        )

                    $destFile =
                        Join-Path `
                            $targetDir `
                            $relativePath

                    $destDir =
                        Split-Path `
                            $destFile `
                            -Parent

                    if (-not (Test-Path $destDir)) {

                        New-Item `
                            -ItemType Directory `
                            -Path $destDir `
                            -Force | Out-Null
                    }

                    Copy-Item `
                        -Path $_.FullName `
                        -Destination $destFile `
                        -Force
                }
        }

        Remove-Item `
            $tempExtractDir `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue

        $progressSitef.Value = 80

        Remove-Item `
            $zipFile `
            -Force `
            -ErrorAction SilentlyContinue

        $log.Invoke(
            "ZIP removido."
        )

        $log.Invoke(
            "Configurando exclusão do Windows Defender..."
        )

        try {

            Add-MpPreference `
                -ExclusionPath $targetDir `
                -ErrorAction Stop

            $log.Invoke(
                "Exclusão adicionada."
            )
        }
        catch {

            $log.Invoke(
                "Aviso: não foi possível adicionar exclusão: $($_.Exception.Message)"
            )
        }

        $progressSitef.Value = 100

        $log.Invoke("")
        $log.Invoke($SuccessMessage)

        return $true
    }
    catch {

        $log.Invoke(
            "ERRO em $PackageName : $($_.Exception.Message)"
        )

        Remove-Item `
            $zipFile `
            -Force `
            -ErrorAction SilentlyContinue

        Remove-Item `
            $tempExtractDir `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue

        return $false
    }
}

function Download-DllFly {

    return Install-DllPackage `
        -PackageName "DLL_FLY" `
        -ZipUrl "https://github.com/c1000x/InstaladorMCNTV/raw/a4dbdb2b2fbbea02d3d4109220199490e4e9e1bf/DLL_FLY.zip" `
        -SuccessMessage "=== DLL_FLY INSTALADO COM SUCESSO ==="
}

function Download-DllFlyEmbarcado {

    return Install-DllPackage `
        -PackageName "DLL_FLY_EMBARCADO" `
        -ZipUrl "https://github.com/c1000x/InstaladorMCNTV/raw/a4dbdb2b2fbbea02d3d4109220199490e4e9e1bf/DLL_FLY_EMBARCADO.zip" `
        -SuccessMessage "=== DLL_FLY_EMBARCADO INSTALADO COM SUCESSO ==="
}

# ============================================================
# CORES
# ============================================================

$ColorBackground =
    [System.Drawing.Color]::FromArgb(
        245,247,250
    )

$ColorSurface =
    [System.Drawing.Color]::White

$ColorText =
    [System.Drawing.Color]::FromArgb(
        35,38,42
    )

$ColorMuted =
    [System.Drawing.Color]::FromArgb(
        95,102,110
    )

$ColorPrimary =
    [System.Drawing.Color]::FromArgb(
        0,120,215
    )

$ColorSuccess =
    [System.Drawing.Color]::FromArgb(
        40,150,90
    )

$ColorDanger =
    [System.Drawing.Color]::FromArgb(
        190,55,55
    )

$ColorBorder =
    [System.Drawing.Color]::FromArgb(
        210,215,222
    )

# ============================================================
# FONTES
# ============================================================

$FontNormal =
    New-Object System.Drawing.Font(
        "Segoe UI",
        9
    )

$FontSmall =
    New-Object System.Drawing.Font(
        "Segoe UI",
        8
    )

$FontHeader =
    New-Object System.Drawing.Font(
        "Segoe UI Semibold",
        10
    )

$FontTitle =
    New-Object System.Drawing.Font(
        "Segoe UI Semibold",
        18
    )

$FontButton =
    New-Object System.Drawing.Font(
        "Segoe UI",
        9
    )

$FontButtonBold =
    New-Object System.Drawing.Font(
        "Segoe UI Semibold",
        10
    )

# ============================================================
# FORMULÁRIO
# ============================================================

$form =
    New-Object System.Windows.Forms.Form

$form.Text =
    "MCNTV Installer - Provisionamento Windows"

$form.StartPosition =
    "CenterScreen"

$form.FormBorderStyle =
    [System.Windows.Forms.FormBorderStyle]::Sizable

$form.MaximizeBox = $true
$form.MinimizeBox = $true

$form.BackColor =
    $ColorBackground

$form.Font =
    $FontNormal

$form.MinimumSize =
    New-Object System.Drawing.Size(
        900,
        700
    )

$form.Size =
    New-Object System.Drawing.Size(
        1100,
        800
    )

# ============================================================
# PAINEL PRINCIPAL
# ============================================================

$mainPanel =
    New-Object System.Windows.Forms.Panel

$mainPanel.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$form.Controls.Add(
    $mainPanel
)

# ============================================================
# TABCONTROL
# ============================================================

$tabControl =
    New-Object System.Windows.Forms.TabControl

$tabControl.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$tabControl.Font =
    $FontNormal

$mainPanel.Controls.Add(
    $tabControl
)

# ============================================================
# ABA CONFIGURAÇÃO
# ============================================================

$tabConfig =
    New-Object System.Windows.Forms.TabPage

$tabConfig.Text =
    "Configuração do Sistema"

$tabConfig.BackColor =
    $ColorBackground

$tabControl.Controls.Add(
    $tabConfig
)

$configLayout =
    New-Object System.Windows.Forms.TableLayoutPanel

$configLayout.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$configLayout.ColumnCount = 1
$configLayout.RowCount = 3

$configLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::AutoSize
    ))
)

$configLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Percent,
        100
    ))
)

$configLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::AutoSize
    ))
)

$configLayout.Padding =
    New-Object System.Windows.Forms.Padding(
        10
    )

$tabConfig.Controls.Add(
    $configLayout
)

$lblConfigTitle =
    New-Object System.Windows.Forms.Label

$lblConfigTitle.Text =
    "Configuração do Sistema"

$lblConfigTitle.Font =
    $FontTitle

$lblConfigTitle.ForeColor =
    $ColorText

$lblConfigTitle.AutoSize = $true

$lblConfigTitle.Margin =
    New-Object System.Windows.Forms.Padding(
        3,3,3,10
    )

$configLayout.Controls.Add(
    $lblConfigTitle,
    0,
    0
)

# ============================================================
# PAINEL DE CHECKBOXES
# ============================================================

$panelCheck =
    New-Object System.Windows.Forms.Panel

$panelCheck.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$panelCheck.AutoScroll = $true

$configLayout.Controls.Add(
    $panelCheck,
    0,
    1
)

$tableCheck =
    New-Object System.Windows.Forms.TableLayoutPanel

$tableCheck.Dock =
    [System.Windows.Forms.DockStyle]::Top

$tableCheck.AutoSize = $true
$tableCheck.AutoSizeMode =
    [System.Windows.Forms.AutoSizeMode]::GrowAndShrink

$tableCheck.ColumnCount = 2

$tableCheck.RowCount =
    [Math]::Ceiling(
        $steps.Count / 2
    ) + 2

$tableCheck.Padding =
    New-Object System.Windows.Forms.Padding(
        5
    )

$panelCheck.Controls.Add(
    $tableCheck
)

$tableCheck.ColumnStyles.Add(
    [System.Windows.Forms.ColumnStyle]::new(
        [System.Windows.Forms.SizeType]::Percent,
        50
    )
)

$tableCheck.ColumnStyles.Add(
    New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Percent,
        50
    )
)

$checkboxes = @{}

$row = 0
$col = 0

foreach ($key in $steps.Keys) {

    $cb =
        New-Object System.Windows.Forms.CheckBox

    $cb.Text = $key

    $cb.Checked =
        -not (
            $UncheckedByDefault -contains $key
        )

    $cb.Font =
        $FontNormal

    $cb.ForeColor =
        $ColorText

    $cb.AutoSize = $true

    $cb.Margin =
        New-Object System.Windows.Forms.Padding(
            5,5,5,5
        )

    $tableCheck.Controls.Add(
        $cb,
        $col,
        $row
    )

    $checkboxes[$key] = $cb

    $col++

    if ($col -eq 2) {

        $col = 0
        $row++
    }
}

$chkDryRun =
    New-Object System.Windows.Forms.CheckBox

$chkDryRun.Text =
    "Modo Simulação (dry-run)"

$chkDryRun.Font =
    $FontNormal

$chkDryRun.ForeColor =
    [System.Drawing.Color]::DarkBlue

$chkDryRun.AutoSize = $true

$chkDryRun.Margin =
    New-Object System.Windows.Forms.Padding(
        5,10,5,5
    )

$tableCheck.Controls.Add(
    $chkDryRun,
    0,
    $row
)

$tableCheck.SetColumnSpan(
    $chkDryRun,
    2
)

# ============================================================
# STATUS + PROGRESSO
# ============================================================

$panelConfigStatus =
    New-Object System.Windows.Forms.Panel

$panelConfigStatus.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$panelConfigStatus.Height = 55

$configLayout.Controls.Add(
    $panelConfigStatus,
    0,
    2
)

$lblStatus =
    New-Object System.Windows.Forms.Label

$lblStatus.Text =
    "Pronto."

$lblStatus.Font =
    $FontNormal

$lblStatus.ForeColor =
    $ColorMuted

$lblStatus.AutoSize = $true

$lblStatus.Location =
    New-Object System.Drawing.Point(
        5,
        5
    )

$panelConfigStatus.Controls.Add(
    $lblStatus
)

$progressBar =
    New-Object System.Windows.Forms.ProgressBar

$progressBar.Minimum = 0
$progressBar.Maximum = 100
$progressBar.Value = 0

$progressBar.Width = 350
$progressBar.Height = 20

$progressBar.Location =
    New-Object System.Drawing.Point(
        5,
        27
    )

$panelConfigStatus.Controls.Add(
    $progressBar
)

$panelButtonsConfig =
    New-Object System.Windows.Forms.FlowLayoutPanel

$panelButtonsConfig.FlowDirection =
    [System.Windows.Forms.FlowDirection]::LeftToRight

$panelButtonsConfig.Dock =
    [System.Windows.Forms.DockStyle]::Bottom

$panelButtonsConfig.Height = 50

$panelButtonsConfig.Padding =
    New-Object System.Windows.Forms.Padding(
        5
    )

$configLayout.Controls.Add(
    $panelButtonsConfig,
    0,
    2
)

# ============================================================
# BOTÕES CONFIGURAÇÃO
# ============================================================

$btnSelAll =
    New-Object System.Windows.Forms.Button

$btnSelAll.Text =
    "Marcar todos"

$btnSelAll.Size =
    New-Object System.Drawing.Size(
        130,
        32
    )

$btnSelAll.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnSelAll.BackColor =
    $ColorSurface

$btnSelAll.FlatAppearance.BorderColor =
    $ColorBorder

$panelButtonsConfig.Controls.Add(
    $btnSelAll
)

$btnSelNone =
    New-Object System.Windows.Forms.Button

$btnSelNone.Text =
    "Desmarcar todos"

$btnSelNone.Size =
    New-Object System.Drawing.Size(
        140,
        32
    )

$btnSelNone.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnSelNone.BackColor =
    $ColorSurface

$btnSelNone.FlatAppearance.BorderColor =
    $ColorBorder

$panelButtonsConfig.Controls.Add(
    $btnSelNone
)

$btnRun =
    New-Object System.Windows.Forms.Button

$btnRun.Text =
    "Executar configuração"

$btnRun.Font =
    $FontButtonBold

$btnRun.BackColor =
    $ColorPrimary

$btnRun.ForeColor =
    [System.Drawing.Color]::White

$btnRun.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnRun.FlatAppearance.BorderSize = 0

$btnRun.Size =
    New-Object System.Drawing.Size(
        190,
        32
    )

$btnRun.Margin =
    New-Object System.Windows.Forms.Padding(
        20,0,0,0
    )

$panelButtonsConfig.Controls.Add(
    $btnRun
)

# ============================================================
# ABA INSTALAR APLICATIVOS
# ============================================================

$tabInstall =
    New-Object System.Windows.Forms.TabPage

$tabInstall.Text =
    "Instalar Aplicativos"

$tabInstall.BackColor =
    $ColorBackground

$tabControl.Controls.Add(
    $tabInstall
)

$tableInstall =
    New-Object System.Windows.Forms.TableLayoutPanel

$tableInstall.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$tableInstall.ColumnCount = 1
$tableInstall.RowCount = 3

$tableInstall.RowStyles.Add(
    [System.Windows.Forms.RowStyle]::new(
        [System.Windows.Forms.SizeType]::AutoSize
    )
)

$tableInstall.RowStyles.Add(
    New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Percent,
        100
    )
)

$tableInstall.RowStyles.Add(
    New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::AutoSize
    )
)

$tableInstall.Padding =
    New-Object System.Windows.Forms.Padding(
        10
    )

$tabInstall.Controls.Add(
    $tableInstall
)

$lblInstallTitle =
    New-Object System.Windows.Forms.Label

$lblInstallTitle.Text =
    "Instalar Aplicativos"

$lblInstallTitle.Font =
    $FontTitle

$lblInstallTitle.AutoSize = $true

$tableInstall.Controls.Add(
    $lblInstallTitle,
    0,
    0
)

$panelInstallList =
    New-Object System.Windows.Forms.Panel

$panelInstallList.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$panelInstallList.AutoScroll = $true

$tableInstall.Controls.Add(
    $panelInstallList,
    0,
    1
)

$grpInstall =
    New-Object System.Windows.Forms.GroupBox

$grpInstall.Text =
    "Aplicativos disponíveis"

$grpInstall.Font =
    $FontHeader

$grpInstall.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$grpInstall.Padding =
    New-Object System.Windows.Forms.Padding(
        10
    )

$panelInstallList.Controls.Add(
    $grpInstall
)

$txtSearchInstall =
    New-Object System.Windows.Forms.TextBox

$txtSearchInstall.Width = 400
$txtSearchInstall.Height = 25

$txtSearchInstall.Location =
    New-Object System.Drawing.Point(
        15,
        25
    )

$grpInstall.Controls.Add(
    $txtSearchInstall
)

$lblSearch =
    New-Object System.Windows.Forms.Label

$lblSearch.Text =
    "Buscar aplicativo:"

$lblSearch.AutoSize = $true

$lblSearch.Location =
    New-Object System.Drawing.Point(
        420,
        28
    )

$grpInstall.Controls.Add(
    $lblSearch
)

$clbInstall =
    New-Object System.Windows.Forms.CheckedListBox

$clbInstall.CheckOnClick = $true

$clbInstall.Font =
    $FontNormal

$clbInstall.Location =
    New-Object System.Drawing.Point(
        15,
        60
    )

$clbInstall.Size =
    New-Object System.Drawing.Size(
        600,
        350
    )

$allLabels =
    @(Build-AppCatalogLabels)

$clbInstall.Tag =
    $allLabels

foreach ($label in $allLabels) {

    [void]$clbInstall.Items.Add(
        $label,
        $true
    )
}

$grpInstall.Controls.Add(
    $clbInstall
)

$txtSearchInstall.Add_TextChanged({

    $search =
        $txtSearchInstall.Text.Trim().ToLower()

    $clbInstall.BeginUpdate()

    try {

        $clbInstall.Items.Clear()

        foreach ($item in $clbInstall.Tag) {

            if (
                [string]::IsNullOrEmpty($search) -or
                $item.ToLower().Contains($search)
            ) {

                [void]$clbInstall.Items.Add(
                    $item,
                    $true
                )
            }
        }
    }
    finally {

        $clbInstall.EndUpdate()
    }
})

$panelInstallButton =
    New-Object System.Windows.Forms.Panel

$panelInstallButton.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$panelInstallButton.Height = 60

$tableInstall.Controls.Add(
    $panelInstallButton,
    0,
    2
)

$btnInstallSelected =
    New-Object System.Windows.Forms.Button

$btnInstallSelected.Text =
    "INSTALAR SELECIONADOS"

$btnInstallSelected.Font =
    $FontButtonBold

$btnInstallSelected.BackColor =
    $ColorSuccess

$btnInstallSelected.ForeColor =
    [System.Drawing.Color]::White

$btnInstallSelected.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnInstallSelected.FlatAppearance.BorderSize = 0

$btnInstallSelected.Size =
    New-Object System.Drawing.Size(
        260,
        40
    )

$btnInstallSelected.Location =
    New-Object System.Drawing.Point(
        5,
        5
    )

$panelInstallButton.Controls.Add(
    $btnInstallSelected
)

# ============================================================
# ABA GERENCIAR APLICATIVOS
# ============================================================

$tabUninstall =
    New-Object System.Windows.Forms.TabPage

$tabUninstall.Text =
    "Gerenciar Aplicativos"

$tabUninstall.BackColor =
    $ColorBackground

$tabControl.Controls.Add(
    $tabUninstall
)

$tableUninstall =
    New-Object System.Windows.Forms.TableLayoutPanel

$tableUninstall.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$tableUninstall.ColumnCount = 1
$tableUninstall.RowCount = 3

$tableUninstall.RowStyles.Add(
    New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::AutoSize
    )
)

$tableUninstall.RowStyles.Add(
    New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Percent,
        100
    )
)

$tableUninstall.RowStyles.Add(
    New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::AutoSize
    )
)

$tableUninstall.Padding =
    New-Object System.Windows.Forms.Padding(
        10
    )

$tabUninstall.Controls.Add(
    $tableUninstall
)

$lblUninstallInfo =
    New-Object System.Windows.Forms.Label

$lblUninstallInfo.Text =
    "Atualize a lista e selecione os programas que deseja remover."

$lblUninstallInfo.AutoSize = $true

$tableUninstall.Controls.Add(
    $lblUninstallInfo,
    0,
    0
)

$panelUninstallList =
    New-Object System.Windows.Forms.Panel

$panelUninstallList.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$panelUninstallList.AutoScroll = $true

$tableUninstall.Controls.Add(
    $panelUninstallList,
    0,
    1
)

$clbUninstall =
    New-Object System.Windows.Forms.CheckedListBox

$clbUninstall.CheckOnClick = $true

$clbUninstall.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$clbUninstall.Font =
    $FontNormal

$panelUninstallList.Controls.Add(
    $clbUninstall
)

$panelUninstallButtons =
    New-Object System.Windows.Forms.FlowLayoutPanel

$panelUninstallButtons.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$panelUninstallButtons.Height = 55

$tableUninstall.Controls.Add(
    $panelUninstallButtons,
    0,
    2
)

$btnRefreshInstalled =
    New-Object System.Windows.Forms.Button

$btnRefreshInstalled.Text =
    "Atualizar lista"

$btnRefreshInstalled.Size =
    New-Object System.Drawing.Size(
        130,
        32
    )

$panelUninstallButtons.Controls.Add(
    $btnRefreshInstalled
)

$btnUninstallSelected =
    New-Object System.Windows.Forms.Button

$btnUninstallSelected.Text =
    "Desinstalar"

$btnUninstallSelected.Size =
    New-Object System.Drawing.Size(
        130,
        32
    )

$btnUninstallSelected.BackColor =
    $ColorDanger

$btnUninstallSelected.ForeColor =
    [System.Drawing.Color]::White

$btnUninstallSelected.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnUninstallSelected.FlatAppearance.BorderSize = 0

$panelUninstallButtons.Controls.Add(
    $btnUninstallSelected
)

# ============================================================
# ABA ATIVAR WINDOWS
# ============================================================

$tabActivate =
    New-Object System.Windows.Forms.TabPage

$tabActivate.Text =
    "Ativar Windows"

$tabActivate.BackColor =
    $ColorBackground

$tabControl.Controls.Add(
    $tabActivate
)

$flowActivate =
    New-Object System.Windows.Forms.FlowLayoutPanel

$flowActivate.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$flowActivate.FlowDirection =
    [System.Windows.Forms.FlowDirection]::TopDown

$flowActivate.WrapContents = $false

$flowActivate.AutoScroll = $true

$flowActivate.Padding =
    New-Object System.Windows.Forms.Padding(
        30
    )

$tabActivate.Controls.Add(
    $flowActivate
)

$lblActivateTitle =
    New-Object System.Windows.Forms.Label

$lblActivateTitle.Text =
    "Ativação do Windows"

$lblActivateTitle.Font =
    New-Object System.Drawing.Font(
        "Segoe UI Semibold",
        16
    )

$lblActivateTitle.AutoSize = $true

$lblActivateTitle.Margin =
    New-Object System.Windows.Forms.Padding(
        0,0,0,20
    )

$flowActivate.Controls.Add(
    $lblActivateTitle
)

$lblActivateDesc =
    New-Object System.Windows.Forms.Label

$lblActivateDesc.Text =
    "Use as configurações oficiais do Windows para verificar o estado da ativação, inserir uma chave de produto ou solucionar problemas de ativação."

$lblActivateDesc.MaximumSize =
    New-Object System.Drawing.Size(
        700,
        0
    )

$lblActivateDesc.AutoSize = $true

$lblActivateDesc.Margin =
    New-Object System.Windows.Forms.Padding(
        0,0,0,25
    )

$flowActivate.Controls.Add(
    $lblActivateDesc
)

$btnCustomActivate =
    New-Object System.Windows.Forms.Button

$btnCustomActivate.Text =
    "ABRIR ATIVAÇÃO DO WINDOWS"

$btnCustomActivate.Font =
    $FontButtonBold

$btnCustomActivate.BackColor =
    $ColorPrimary

$btnCustomActivate.ForeColor =
    [System.Drawing.Color]::White

$btnCustomActivate.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnCustomActivate.FlatAppearance.BorderSize = 0

$btnCustomActivate.Size =
    New-Object System.Drawing.Size(
        300,
        50
    )

$flowActivate.Controls.Add(
    $btnCustomActivate
)

# ============================================================
# ABA SITEF
# ============================================================

$tabSitef =
    New-Object System.Windows.Forms.TabPage

$tabSitef.Text =
    "SITEF"

$tabSitef.BackColor =
    $ColorBackground

$tabControl.Controls.Add(
    $tabSitef
)

$tableSitef =
    New-Object System.Windows.Forms.TableLayoutPanel

$tableSitef.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$tableSitef.ColumnCount = 1
$tableSitef.RowCount = 4

$tableSitef.RowStyles.Add(
    New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::AutoSize
    )
)

$tableSitef.RowStyles.Add(
    New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::AutoSize
    )
)

$tableSitef.RowStyles.Add(
    New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::AutoSize
    )
)

$tableSitef.RowStyles.Add(
    New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Percent,
        100
    )
)

$tableSitef.Padding =
    New-Object System.Windows.Forms.Padding(
        15
    )

$tabSitef.Controls.Add(
    $tableSitef
)

# ============================================================
# TÍTULO SITEF
# ============================================================

$lblSitefTitle =
    New-Object System.Windows.Forms.Label

$lblSitefTitle.Text =
    "Instalação do Ambiente SITEF"

$lblSitefTitle.Font =
    New-Object System.Drawing.Font(
        "Segoe UI Semibold",
        14
    )

$lblSitefTitle.ForeColor =
    $ColorText

$lblSitefTitle.AutoSize = $true

$lblSitefTitle.Margin =
    New-Object System.Windows.Forms.Padding(
        3,3,3,10
    )

$tableSitef.Controls.Add(
    $lblSitefTitle,
    0,
    0
)

# ============================================================
# DESCRIÇÃO SITEF
# ============================================================

$lblSitefDesc =
    New-Object System.Windows.Forms.Label

$lblSitefDesc.Text =
    "Esta etapa baixa, extrai e executa os componentes do SITEF.`r`n" +
    "Os instaladores podem solicitar configurações manuais.`r`n" +
    "Também estão disponíveis os pacotes DLL_FLY e DLL_FLY_EMBARCADO.`r`n" +
    "As pastas dos pacotes serão adicionadas à exclusão do Windows Defender."

$lblSitefDesc.Font =
    $FontNormal

$lblSitefDesc.ForeColor =
    $ColorMuted

$lblSitefDesc.AutoSize = $true

$lblSitefDesc.Margin =
    New-Object System.Windows.Forms.Padding(
        3,0,3,10
    )

$tableSitef.Controls.Add(
    $lblSitefDesc,
    0,
    1
)

# ============================================================
# BOTÕES SITEF
# ============================================================

$flowSitefButtons =
    New-Object System.Windows.Forms.FlowLayoutPanel

$flowSitefButtons.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$flowSitefButtons.FlowDirection =
    [System.Windows.Forms.FlowDirection]::LeftToRight

$flowSitefButtons.WrapContents = $true

$flowSitefButtons.AutoSize = $true

$flowSitefButtons.Padding =
    New-Object System.Windows.Forms.Padding(
        3
    )

$tableSitef.Controls.Add(
    $flowSitefButtons,
    0,
    2
)

function New-SitefButton {

    param(
        [string]$Text,
        [int]$Width,
        [System.Drawing.Color]$BackColor,
        [System.Drawing.Color]$ForeColor
    )

    $button =
        New-Object System.Windows.Forms.Button

    $button.Text = $Text

    $button.Font =
        $FontButtonBold

    $button.BackColor =
        $BackColor

    $button.ForeColor =
        $ForeColor

    $button.FlatStyle =
        [System.Windows.Forms.FlatStyle]::Flat

    $button.FlatAppearance.BorderSize = 0

    $button.Size =
        New-Object System.Drawing.Size(
            $Width,
            40
        )

    $button.Margin =
        New-Object System.Windows.Forms.Padding(
            4
        )

    return $button
}

$btnSitefInstall =
    New-SitefButton `
        "Instalar SITEF" `
        160 `
        $ColorPrimary `
        ([System.Drawing.Color]::White)

$flowSitefButtons.Controls.Add(
    $btnSitefInstall
)

$btnDllFly =
    New-SitefButton `
        "DLL_FLY" `
        150 `
        $ColorPrimary `
        ([System.Drawing.Color]::White)

$flowSitefButtons.Controls.Add(
    $btnDllFly
)

$btnDllFlyEmbarcado =
    New-SitefButton `
        "DLL_FLY_EMBARCADO" `
        190 `
        $ColorPrimary `
        ([System.Drawing.Color]::White)

$flowSitefButtons.Controls.Add(
    $btnDllFlyEmbarcado
)

$btnSitefOpenFolder =
    New-SitefButton `
        "Abrir pasta" `
        130 `
        $ColorSurface `
        $ColorText

$btnSitefOpenFolder.FlatAppearance.BorderColor =
    $ColorBorder

$flowSitefButtons.Controls.Add(
    $btnSitefOpenFolder
)

$btnInstallAll =
    New-SitefButton `
        "Instalar tudo" `
        150 `
        $ColorSuccess `
        ([System.Drawing.Color]::White)

$flowSitefButtons.Controls.Add(
    $btnInstallAll
)

$btnClearLog =
    New-SitefButton `
        "Limpar log" `
        120 `
        $ColorSurface `
        $ColorText

$btnClearLog.FlatAppearance.BorderColor =
    $ColorBorder

$flowSitefButtons.Controls.Add(
    $btnClearLog
)

# ============================================================
# LOG SITEF
# ============================================================

$panelSitefLog =
    New-Object System.Windows.Forms.Panel

$panelSitefLog.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$panelSitefLog.Padding =
    New-Object System.Windows.Forms.Padding(
        0,10,0,0
    )

$tableSitef.Controls.Add(
    $panelSitefLog,
    0,
    3
)

$grpSitefLog =
    New-Object System.Windows.Forms.GroupBox

$grpSitefLog.Text =
    "Log da instalação SITEF"

$grpSitefLog.Font =
    $FontHeader

$grpSitefLog.ForeColor =
    $ColorText

$grpSitefLog.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$grpSitefLog.Padding =
    New-Object System.Windows.Forms.Padding(
        10
    )

$panelSitefLog.Controls.Add(
    $grpSitefLog
)

$txtSitefLog =
    New-Object System.Windows.Forms.TextBox

$txtSitefLog.Multiline = $true

$txtSitefLog.ScrollBars =
    [System.Windows.Forms.ScrollBars]::Vertical

$txtSitefLog.ReadOnly = $true

$txtSitefLog.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$txtSitefLog.Font =
    New-Object System.Drawing.Font(
        "Consolas",
        9
    )

$txtSitefLog.BackColor =
    [System.Drawing.Color]::White

$grpSitefLog.Controls.Add(
    $txtSitefLog
)

$progressSitef =
    New-Object System.Windows.Forms.ProgressBar

$progressSitef.Minimum = 0
$progressSitef.Maximum = 100
$progressSitef.Value = 0

$progressSitef.Dock =
    [System.Windows.Forms.DockStyle]::Bottom

$progressSitef.Height = 20

$grpSitefLog.Controls.Add(
    $progressSitef
)

# ============================================================
# LOG DA CONFIGURAÇÃO
# ============================================================

$txtLog =
    New-Object System.Windows.Forms.TextBox

$txtLog.Multiline = $true

$txtLog.ReadOnly = $true

$txtLog.ScrollBars =
    [System.Windows.Forms.ScrollBars]::Vertical

$txtLog.Visible = $false

function Write-MainLog {

    param(
        [string]$Message
    )

    $line = "$Message"

    if ($txtLog -ne $null) {

        $txtLog.AppendText(
            "$line`r`n"
        )

        $txtLog.SelectionStart =
            $txtLog.Text.Length

        $txtLog.ScrollToCaret()
    }

    Write-LogFile $line

    [System.Windows.Forms.Application]::DoEvents()
}

$AppendLog = {
    param($msg)

    Write-MainLog "$msg"
}

$script:SitefLogDelegate = {

    param($msg)

    $line = "$msg"

    $txtSitefLog.AppendText(
        "$line`r`n"
    )

    $txtSitefLog.SelectionStart =
        $txtSitefLog.Text.Length

    $txtSitefLog.ScrollToCaret()

    Write-LogFile "[SITEF] $line"

    [System.Windows.Forms.Application]::DoEvents()
}

# ============================================================
# EVENTO MARCAR TODOS
# ============================================================

$btnSelAll.Add_Click({

    foreach ($cb in $checkboxes.Values) {
        $cb.Checked = $true
    }
})

# ============================================================
# EVENTO DESMARCAR TODOS
# ============================================================

$btnSelNone.Add_Click({

    foreach ($cb in $checkboxes.Values) {
        $cb.Checked = $false
    }
})

# ============================================================
# EXECUTAR CONFIGURAÇÃO
# ============================================================

$btnRun.Add_Click({

    $btnRun.Enabled = $false
    $btnSelAll.Enabled = $false
    $btnSelNone.Enabled = $false

    $chkDryRun.Enabled = $false

    $script:CancelRequested = $false

    $script:Results = [ordered]@{}

    $txtLog.Clear()

    $DryRun =
        [bool]$chkDryRun.Checked

    $selectedSteps =
        @(
            $steps.Keys |
            Where-Object {
                $checkboxes[$_].Checked
            }
        )

    if ($selectedSteps.Count -eq 0) {

        [System.Windows.Forms.MessageBox]::Show(
            "Nenhuma etapa foi selecionada.",
            "Aviso",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        $btnRun.Enabled = $true
        $btnSelAll.Enabled = $true
        $btnSelNone.Enabled = $true
        $chkDryRun.Enabled = $true

        return
    }

    Write-MainLog(
        "=== INICIANDO PROVISIONAMENTO ==="
    )

    Write-MainLog(
        "Modo: $(if ($DryRun) { 'SIMULAÇÃO' } else { 'EXECUÇÃO REAL' })"
    )

    Write-MainLog("")

    $progressBar.Minimum = 0
    $progressBar.Maximum =
        $selectedSteps.Count

    $progressBar.Value = 0

    foreach ($key in $selectedSteps) {

        $lblStatus.Text =
            "Executando: $key..."

        Write-MainLog("")
        Write-MainLog(
            ">>> $key"
        )

        try {

            $result =
                & $steps[$key] `
                    $AppendLog `
                    $DryRun

            if ($result -eq $false) {

                $script:Results[$key] =
                    "FALHA"

                Write-MainLog(
                    "Resultado: FALHA"
                )
            }
            else {

                $script:Results[$key] =
                    if ($DryRun) {
                        "SIMULADO"
                    }
                    else {
                        "OK"
                    }

                Write-MainLog(
                    "Resultado: $($script:Results[$key])"
                )
            }
        }
        catch {

            $errorMessage =
                $_.Exception.Message

            $script:Results[$key] =
                "FALHA: $errorMessage"

            Write-MainLog(
                "ERRO em '$key': $errorMessage"
            )
        }

        if ($progressBar.Value -lt $progressBar.Maximum) {
            $progressBar.Value++
        }

        [System.Windows.Forms.Application]::DoEvents()
    }

    Write-MainLog("")
    Write-MainLog(
        "=== PROVISIONAMENTO CONCLUÍDO ==="
    )

    $reportLines = @()

    $reportLines +=
        "Relatório de Provisionamento - $Timestamp"

    $reportLines +=
        "Modo: $(if ($DryRun) { 'SIMULAÇÃO' } else { 'EXECUÇÃO REAL' })"

    $reportLines += ""

    foreach ($k in $script:Results.Keys) {

        $reportLines +=
            ("{0,-50} {1}" -f `
                $k,
                $script:Results[$k]
            )
    }

    try {

        $reportLines |
            Set-Content `
                -Path $ReportPath `
                -Encoding UTF8

        Write-MainLog(
            "Relatório salvo em: $ReportPath"
        )
    }
    catch {

        Write-MainLog(
            "ERRO ao salvar relatório: $($_.Exception.Message)"
        )
    }

    $lblStatus.Text =
        "Provisionamento concluído."

    $progressBar.Value =
        $progressBar.Maximum

    $btnRun.Enabled = $true
    $btnSelAll.Enabled = $true
    $btnSelNone.Enabled = $true
    $chkDryRun.Enabled = $true

    [System.Windows.Forms.MessageBox]::Show(
        "Provisionamento concluído.`r`n`r`nRelatório:`r`n$ReportPath",
        "Finalizado",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
})

# ============================================================
# INSTALAR APLICATIVOS
# ============================================================

$btnInstallSelected.Add_Click({

    $selectedLabels =
        @(
            $clbInstall.CheckedItems
        )

    if ($selectedLabels.Count -eq 0) {

        [System.Windows.Forms.MessageBox]::Show(
            "Selecione ao menos um aplicativo.",
            "Aviso"
        )

        return
    }

    $btnInstallSelected.Enabled = $false

    $AppendLog.Invoke("")
    $AppendLog.Invoke(
        "== INSTALAÇÃO DE APLICATIVOS =="
    )

    $AppendLog.Invoke(
        "Total: $($selectedLabels.Count)"
    )

    $totalJobs = 0
    $completed = 0

    $jobs = @()

    try {

        $needsChoco =
            @(
                $selectedLabels |
                Where-Object {
                    $script:AppCatalogMap[$_].Manager -eq "choco"
                }
            )

        if ($needsChoco.Count -gt 0) {

            if (-not (Ensure-ChocoAvailable -Log $AppendLog)) {

                $AppendLog.Invoke(
                    "Chocolatey não está disponível."
                )

                $btnInstallSelected.Enabled = $true

                return
            }
        }

        foreach ($label in $selectedLabels) {

            $info =
                $script:AppCatalogMap[$label]

            if (-not $info) {
                continue
            }

            $manager = $info.Manager
            $id = $info.Id

            $AppendLog.Invoke(
                "Iniciando: $label"
            )

            switch ($manager) {

                "choco" {

                    $jobScript = {
                        param($id)

                        try {

                            $output =
                                choco install `
                                    $id `
                                    -y `
                                    --force `
                                    --ignore-checksums 2>&1

                            return @(
                                "[$id]"
                                $output
                            )
                        }
                        catch {

                            return @(
                                "ERRO [$id]: $($_.Exception.Message)"
                            )
                        }
                    }
                }

                "winget" {

                    $jobScript = {
                        param($id)

                        try {

                            $output =
                                winget install `
                                    -e `
                                    --id $id `
                                    --accept-source-agreements `
                                    --accept-package-agreements `
                                    --silent 2>&1

                            return @(
                                "[$id]"
                                $output
                            )
                        }
                        catch {

                            return @(
                                "ERRO [$id]: $($_.Exception.Message)"
                            )
                        }
                    }
                }

                "wingetStore" {

                    $jobScript = {
                        param($id)

                        try {

                            $output =
                                winget install `
                                    --id $id `
                                    --source msstore `
                                    --accept-source-agreements `
                                    --accept-package-agreements `
                                    --silent 2>&1

                            return @(
                                "[$id]"
                                $output
                            )
                        }
                        catch {

                            return @(
                                "ERRO [$id]: $($_.Exception.Message)"
                            )
                        }
                    }
                }
            }

            $job =
                Start-Job `
                    -ScriptBlock $jobScript `
                    -ArgumentList $id

            $jobs += $job

            $totalJobs++
        }

        if ($totalJobs -eq 0) {

            $AppendLog.Invoke(
                "Nenhum aplicativo válido selecionado."
            )

            return
        }

        $progressBar.Minimum = 0
        $progressBar.Maximum = 100
        $progressBar.Value = 0

        while (
            @(
                $jobs |
                Where-Object {
                    $_.State -eq "Running"
                }
            ).Count -gt 0
        ) {

            Start-Sleep -Milliseconds 500

            $running =
                @(
                    $jobs |
                    Where-Object {
                        $_.State -eq "Running"
                    }
                ).Count

            $completed =
                $totalJobs - $running

            $percent =
                [int](
                    ($completed / $totalJobs) * 100
                )

            if ($percent -gt 100) {
                $percent = 100
            }

            $progressBar.Value =
                $percent

            $lblStatus.Text =
                "Instalando aplicativos: $completed de $totalJobs"

            [System.Windows.Forms.Application]::DoEvents()
        }

        foreach ($job in $jobs) {

            $output =
                Receive-Job `
                    -Job $job `
                    -ErrorAction SilentlyContinue

            if ($output) {

                foreach ($line in $output) {

                    $AppendLog.Invoke(
                        "$line"
                    )
                }
            }

            Remove-Job `
                -Job $job `
                -Force `
                -ErrorAction SilentlyContinue
        }

        $progressBar.Value = 100

        $AppendLog.Invoke("")
        $AppendLog.Invoke(
            "=== INSTALAÇÃO DE APLICATIVOS CONCLUÍDA ==="
        )

        $lblStatus.Text =
            "Instalação de aplicativos concluída."
    }
    catch {

        $AppendLog.Invoke(
            "ERRO geral na instalação: $($_.Exception.Message)"
        )
    }
    finally {

        foreach ($job in $jobs) {

            Remove-Job `
                -Job $job `
                -Force `
                -ErrorAction SilentlyContinue
        }

        $btnInstallSelected.Enabled = $true
    }
})

# ============================================================
# ATUALIZAR PROGRAMAS INSTALADOS
# ============================================================

$btnRefreshInstalled.Add_Click({

    $btnRefreshInstalled.Enabled = $false

    try {

        $AppendLog.Invoke(
            "Consultando programas instalados..."
        )

        $clbUninstall.Items.Clear()

        $script:UninstallMap = @{}

        $programs =
            @(Get-InstalledProgramsList)

        foreach ($program in $programs) {

            $name =
                $program.DisplayName

            if (
                -not [string]::IsNullOrWhiteSpace($name) -and
                -not $script:UninstallMap.ContainsKey($name)
            ) {

                $cmd =
                    if (
                        -not [string]::IsNullOrWhiteSpace(
                            $program.QuietUninstallString
                        )
                    ) {
                        $program.QuietUninstallString
                    }
                    else {
                        $program.UninstallString
                    }

                $script:UninstallMap[$name] =
                    $cmd

                [void]$clbUninstall.Items.Add(
                    $name
                )
            }
        }

        $AppendLog.Invoke(
            "$($clbUninstall.Items.Count) programas encontrados."
        )
    }
    catch {

        $AppendLog.Invoke(
            "ERRO ao atualizar lista: $($_.Exception.Message)"
        )
    }
    finally {

        $btnRefreshInstalled.Enabled = $true
    }
})

# ============================================================
# DESINSTALAR
# ============================================================

$btnUninstallSelected.Add_Click({

    $selected =
        @(
            $clbUninstall.CheckedItems
        )

    if ($selected.Count -eq 0) {

        [System.Windows.Forms.MessageBox]::Show(
            "Selecione ao menos um programa.",
            "Aviso"
        )

        return
    }

    $confirm =
        [System.Windows.Forms.MessageBox]::Show(
            "Deseja desinstalar os seguintes programas?`r`n`r`n$($selected -join "`r`n")",
            "Confirmar remoção",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

    if (
        $confirm -ne
        [System.Windows.Forms.DialogResult]::Yes
    ) {
        return
    }

    $btnUninstallSelected.Enabled = $false

    try {

        $AppendLog.Invoke("")
        $AppendLog.Invoke(
            "== DESINSTALAÇÃO DE PROGRAMAS =="
        )

        foreach ($name in $selected) {

            $cmd =
                $script:UninstallMap[$name]

            if (
                [string]::IsNullOrWhiteSpace($cmd)
            ) {
                continue
            }

            $AppendLog.Invoke(
                "Desinstalando: $name"
            )

            try {

                if (
                    $cmd -match "(?i)msiexec" -and
                    $cmd -notmatch "(?i)/qn|/quiet"
                ) {

                    $cmd =
                        "$cmd /quiet /norestart"
                }

                Start-Process `
                    -FilePath "cmd.exe" `
                    -ArgumentList "/c $cmd" `
                    -Wait `
                    -ErrorAction Stop

                $AppendLog.Invoke(
                    "Concluído: $name"
                )
            }
            catch {

                $AppendLog.Invoke(
                    "ERRO ao desinstalar '$name': $($_.Exception.Message)"
                )
            }
        }

        $AppendLog.Invoke(
            "Remoção concluída."
        )

        $AppendLog.Invoke(
            "Clique em Atualizar lista."
        )
    }
    finally {

        $btnUninstallSelected.Enabled = $true
    }
})

# ============================================================
# ATIVAÇÃO OFICIAL DO WINDOWS
# ============================================================

$btnCustomActivate.Add_Click({

    try {

        $AppendLog.Invoke(
            "Abrindo configurações oficiais de ativação do Windows..."
        )

        Start-Process `
            "ms-settings:activation"

        $AppendLog.Invoke(
            "Configurações de ativação abertas."
        )
    }
    catch {

        $AppendLog.Invoke(
            "ERRO ao abrir ativação: $($_.Exception.Message)"
        )

        [System.Windows.Forms.MessageBox]::Show(
            "Não foi possível abrir as configurações de ativação.",
            "Erro"
        )
    }
})

# ============================================================
# SITEF - INSTALAÇÃO
# ============================================================

$btnSitefInstall.Add_Click({

    if ($script:SitefBusy) {
        return
    }

    $script:SitefBusy = $true

    $btnSitefInstall.Enabled = $false
    $btnDllFly.Enabled = $false
    $btnDllFlyEmbarcado.Enabled = $false
    $btnInstallAll.Enabled = $false

    $txtSitefLog.Clear()
    $progressSitef.Value = 0

    try {

        $result =
            Install-Sitef

        if ($result) {

            [System.Windows.Forms.MessageBox]::Show(
                "Instalação do SITEF concluída.",
                "SITEF",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        }
        else {

            [System.Windows.Forms.MessageBox]::Show(
                "A instalação do SITEF apresentou erro. Consulte o log.",
                "SITEF",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
        }
    }
    catch {

        $txtSitefLog.AppendText(
            "ERRO inesperado: $($_.Exception.Message)`r`n"
        )
    }
    finally {

        $btnSitefInstall.Enabled = $true
        $btnDllFly.Enabled = $true
        $btnDllFlyEmbarcado.Enabled = $true
        $btnInstallAll.Enabled = $true

        $script:SitefBusy = $false
    }
})

# ============================================================
# SITEF - DLL FLY
# ============================================================

$btnDllFly.Add_Click({

    if ($script:SitefBusy) {
        return
    }

    $script:SitefBusy = $true

    $btnSitefInstall.Enabled = $false
    $btnDllFly.Enabled = $false
    $btnDllFlyEmbarcado.Enabled = $false
    $btnInstallAll.Enabled = $false

    $txtSitefLog.Clear()
    $progressSitef.Value = 0

    try {

        $result =
            Download-DllFly

        if ($result) {

            [System.Windows.Forms.MessageBox]::Show(
                "DLL_FLY instalado com sucesso em C:\SITEF\DLL_FLY.",
                "DLL_FLY"
            )
        }
        else {

            [System.Windows.Forms.MessageBox]::Show(
                "Falha na instalação do DLL_FLY. Consulte o log.",
                "DLL_FLY"
            )
        }
    }
    catch {

        $txtSitefLog.AppendText(
            "ERRO inesperado: $($_.Exception.Message)`r`n"
        )
    }
    finally {

        $btnSitefInstall.Enabled = $true
        $btnDllFly.Enabled = $true
        $btnDllFlyEmbarcado.Enabled = $true
        $btnInstallAll.Enabled = $true

        $script:SitefBusy = $false
    }
})

# ============================================================
# SITEF - DLL FLY EMBARCADO
# ============================================================

$btnDllFlyEmbarcado.Add_Click({

    if ($script:SitefBusy) {
        return
    }

    $script:SitefBusy = $true

    $btnSitefInstall.Enabled = $false
    $btnDllFly.Enabled = $false
    $btnDllFlyEmbarcado.Enabled = $false
    $btnInstallAll.Enabled = $false

    $txtSitefLog.Clear()
    $progressSitef.Value = 0

    try {

        $result =
            Download-DllFlyEmbarcado

        if ($result) {

            [System.Windows.Forms.MessageBox]::Show(
                "DLL_FLY_EMBARCADO instalado com sucesso em C:\SITEF\DLL_FLY_EMBARCADO.",
                "DLL_FLY_EMBARCADO"
            )
        }
        else {

            [System.Windows.Forms.MessageBox]::Show(
                "Falha na instalação do DLL_FLY_EMBARCADO. Consulte o log.",
                "DLL_FLY_EMBARCADO"
            )
        }
    }
    catch {

        $txtSitefLog.AppendText(
            "ERRO inesperado: $($_.Exception.Message)`r`n"
        )
    }
    finally {

        $btnSitefInstall.Enabled = $true
        $btnDllFly.Enabled = $true
        $btnDllFlyEmbarcado.Enabled = $true
        $btnInstallAll.Enabled = $true

        $script:SitefBusy = $false
    }
})

# ============================================================
# SITEF - ABRIR PASTA
# ============================================================

$btnSitefOpenFolder.Add_Click({

    $sitefDir = "C:\SITEF"

    if (Test-Path $sitefDir) {

        Start-Process `
            "explorer.exe" `
            -ArgumentList "`"$sitefDir`""
    }
    else {

        [System.Windows.Forms.MessageBox]::Show(
            "A pasta C:\SITEF ainda não existe.",
            "Pasta não encontrada"
        )
    }
})

# ============================================================
# SITEF - INSTALAR TUDO
# ============================================================

$btnInstallAll.Add_Click({

    if ($script:SitefBusy) {
        return
    }

    $script:SitefBusy = $true

    $btnSitefInstall.Enabled = $false
    $btnDllFly.Enabled = $false
    $btnDllFlyEmbarcado.Enabled = $false
    $btnInstallAll.Enabled = $false

    $txtSitefLog.Clear()
    $progressSitef.Value = 0

    $script:SitefLogDelegate.Invoke(
        "=== INSTALAÇÃO COMPLETA SITEF ==="
    )

    $success = $true

    try {

        $script:SitefLogDelegate.Invoke("")
        $script:SitefLogDelegate.Invoke(
            "1/3 - Instalando SITEF..."
        )

        if (-not (Install-Sitef)) {
            $success = $false
        }

        if ($success) {

            $script:SitefLogDelegate.Invoke("")
            $script:SitefLogDelegate.Invoke(
                "2/3 - Instalando DLL_FLY..."
            )

            if (-not (Download-DllFly)) {
                $success = $false
            }
        }

        if ($success) {

            $script:SitefLogDelegate.Invoke("")
            $script:SitefLogDelegate.Invoke(
                "3/3 - Instalando DLL_FLY_EMBARCADO..."
            )

            if (-not (Download-DllFlyEmbarcado)) {
                $success = $false
            }
        }

        $script:SitefLogDelegate.Invoke("")

        if ($success) {

            $script:SitefLogDelegate.Invoke(
                "=== INSTALAÇÃO COMPLETA CONCLUÍDA ==="
            )

            [System.Windows.Forms.MessageBox]::Show(
                "Todas as etapas do SITEF foram concluídas.",
                "SITEF",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        }
        else {

            $script:SitefLogDelegate.Invoke(
                "=== INSTALAÇÃO COMPLETA FINALIZADA COM ERROS ==="
            )

            [System.Windows.Forms.MessageBox]::Show(
                "Uma ou mais etapas apresentaram erro. Consulte o log.",
                "SITEF",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
        }
    }
    catch {

        $script:SitefLogDelegate.Invoke(
            "ERRO inesperado: $($_.Exception.Message)"
        )
    }
    finally {

        $btnSitefInstall.Enabled = $true
        $btnDllFly.Enabled = $true
        $btnDllFlyEmbarcado.Enabled = $true
        $btnInstallAll.Enabled = $true

        $script:SitefBusy = $false
    }
})

# ============================================================
# LIMPAR LOG SITEF
# ============================================================

$btnClearLog.Add_Click({

    $txtSitefLog.Clear()

    $progressSitef.Value = 0

    $script:SitefLogDelegate.Invoke(
        "Log limpo."
    )
})

# ============================================================
# CARREGAR PROGRAMAS AO ABRIR
# ============================================================

$form.Add_Shown({

    try {

        $btnRefreshInstalled.PerformClick()
    }
    catch {

        $AppendLog.Invoke(
            "Erro ao carregar programas instalados: $($_.Exception.Message)"
        )
    }
})

# ============================================================
# FECHAMENTO
# ============================================================

$form.Add_FormClosing({

    $script:CancelRequested = $true

    Get-Job |
        Where-Object {
            $_.State -in @(
                "Running",
                "NotStarted"
            )
        } |
        Remove-Job `
            -Force `
            -ErrorAction SilentlyContinue
})

# ============================================================
# EXECUTAR INTERFACE
# ============================================================

[void]$form.ShowDialog()
