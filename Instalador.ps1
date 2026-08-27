<#
    Instalador.ps1
    MCNTV Installer - Provisionamento de maquinas Windows

    CORRECOES DESTA VERSAO:
    - Corrigida a autoelevacao para funcionar corretamente com:
        irm https://raw.githubusercontent.com/c1000x/InstaladorMCNTV/main/Instalador.ps1 | iex
    - Corrigidos problemas de New-Object System.Drawing.Point com expressoes.
    - Corrigido teste de nenhuma etapa selecionada.
    - Layout responsivo com TableLayoutPanel.
    - Lista de aplicativos instalados.
    - Instalacao paralela via Chocolatey/Winget.
    - Instalacao SITEF com tentativa independente dos dois ZIPs.
    - Validacao dos ZIPs antes da extracao.
    - Logs em arquivo.
    - Relatorio final.
    - Modo Dry-Run.
#>

# ============================================================
# CONFIGURACAO DE COMPATIBILIDADE
# ============================================================

$ErrorActionPreference = "Continue"

# ============================================================
# EXECUCAO LOCAL OU VIA "irm ... | iex"
# ============================================================

$scriptPath = $PSCommandPath

if ([string]::IsNullOrWhiteSpace($scriptPath)) {

    $bootstrapDir = Join-Path $env:TEMP "MCNTVInstaller"

    if (-not (Test-Path -LiteralPath $bootstrapDir)) {
        New-Item -Path $bootstrapDir -ItemType Directory -Force | Out-Null
    }

    $scriptPath = Join-Path $bootstrapDir "Instalador.ps1"

    try {
        $scriptContent = $MyInvocation.MyCommand.Definition

        if ([string]::IsNullOrWhiteSpace($scriptContent)) {
            throw "Nao foi possivel obter o conteudo do script."
        }

        [System.IO.File]::WriteAllText(
            $scriptPath,
            $scriptContent,
            (New-Object System.Text.UTF8Encoding($false))
        )
    }
    catch {
        Write-Host "ERRO ao criar copia temporaria do instalador:"
        Write-Host $_.Exception.Message
        exit 1
    }
}

# ============================================================
# AUTO-ELEVACAO
# ============================================================

# IMPORTANTE:
# O cast foi mantido em uma unica expressao.
# Isso evita o erro:
# " ')' de fechamento ausente na expressão."

try {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)

    $isAdmin = $currentPrincipal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}
catch {
    Write-Host "ERRO ao verificar privilegios administrativos:"
    Write-Host $_.Exception.Message
    exit 1
}

if (-not $isAdmin) {

    Write-Host "Solicitando privilegios de administrador..."

    try {

        $psi = New-Object System.Diagnostics.ProcessStartInfo

        $psi.FileName = "powershell.exe"

        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""

        $psi.Verb = "runas"

        $psi.UseShellExecute = $true

        [System.Diagnostics.Process]::Start($psi) | Out-Null

    }
    catch {

        Write-Host "Elevacao cancelada pelo usuario."
        Write-Host $_.Exception.Message
    }

    exit
}

# ============================================================
# CARREGAR COMPONENTES
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ============================================================
# CONFIGURACAO DO BOTAO EXTERNO
# ============================================================

$CustomScriptUrl   = "https://get.activated.win"
$CustomScriptLabel = "Ativar Windows"

# ============================================================
# LISTA DE APLICATIVOS
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
    "9WZDNCRFJBMP"
)

# ============================================================
# DIRETORIOS DE LOG
# ============================================================

$ScriptDir = Split-Path -Parent $scriptPath

if ([string]::IsNullOrWhiteSpace($ScriptDir)) {
    $ScriptDir = Join-Path $env:TEMP "MCNTVInstaller"
}

$LogsDir = Join-Path $ScriptDir "logs"

if (-not (Test-Path -LiteralPath $LogsDir)) {
    New-Item -Path $LogsDir -ItemType Directory -Force | Out-Null
}

$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

$LogFilePath = Join-Path $LogsDir "provisionamento_$Timestamp.log"

$ReportPath = Join-Path $LogsDir "relatorio_$Timestamp.txt"

$script:Results = [ordered]@{}

$script:CancelRequested = $false

# ============================================================
# FUNCOES DE PROVISIONAMENTO
# ============================================================

function Step-RestorePoint {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke("== Ponto de restauracao ==")

    if ($DryRun) {
        $Log.Invoke("[SIMULACAO] Criaria um ponto de restauracao antes das alteracoes.")
        return
    }

    try {

        Enable-ComputerRestore `
            -Drive "$env:SystemDrive\" `
            -ErrorAction SilentlyContinue

        Checkpoint-Computer `
            -Description "Antes do provisionamento" `
            -RestorePointType "MODIFY_SETTINGS" `
            -ErrorAction Stop

        $Log.Invoke("Ponto de restauracao criado.")

    }
    catch {

        $Log.Invoke(
            "Aviso: nao foi possivel criar ponto de restauracao. " +
            $_.Exception.Message
        )
    }
}

# ============================================================

function Step-VersoesAnteriores {

    param(
        $Log,
        [bool]$DryRun
    )

    $drive = $env:SystemDrive

    $Log.Invoke(
        "== Habilitar Versoes Anteriores (Shadow Copies) em $drive =="
    )

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULACAO] Ativaria System Restore em $drive, " +
            "reservaria 10% do volume para copias de sombra " +
            "e criaria snapshots a cada 4h."
        )

        return
    }

    try {

        Enable-ComputerRestore `
            -Drive "$drive\" `
            -ErrorAction Stop

        $Log.Invoke("System Restore ativado em $drive.")

    }
    catch {

        $Log.Invoke(
            "Aviso ao ativar System Restore: $($_.Exception.Message)"
        )
    }

    try {

        $Log.Invoke(
            "Reservando espaco para copias de sombra (10% do volume)..."
        )

        vssadmin resize shadowstorage `
            /for="$drive" `
            /on="$drive" `
            /maxsize=10% 2>&1 |
            ForEach-Object {
                $Log.Invoke($_)
            }

    }
    catch {

        $Log.Invoke(
            "Erro ao reservar espaco para Shadow Copy: $($_.Exception.Message)"
        )
    }

    try {

        $Log.Invoke("Criando snapshot inicial...")

        vssadmin create shadow `
            /for="$drive" 2>&1 |
            ForEach-Object {
                $Log.Invoke($_)
            }

    }
    catch {

        $Log.Invoke(
            "Erro ao criar snapshot: $($_.Exception.Message)"
        )
    }

    try {

        schtasks /create `
            /tn "VersoesAnteriores_ShadowCopy" `
            /tr "vssadmin create shadow /for=$drive" `
            /sc hourly `
            /mo 4 `
            /ru "SYSTEM" `
            /rl highest `
            /f | Out-Null

        $Log.Invoke(
            "Tarefa 'VersoesAnteriores_ShadowCopy' criada."
        )

        $Log.Invoke(
            "Snapshots programados a cada 4 horas."
        )

    }
    catch {

        $Log.Invoke(
            "Erro ao criar tarefa: $($_.Exception.Message)"
        )
    }
}

# ============================================================

function Step-IconesAreaTrabalho {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke(
        "== Icones Este Computador / Pasta do Usuario =="
    )

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULACAO] Ativaria os icones e reiniciaria o Explorer."
        )

        return
    }

    try {

        $path =
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\" +
            "Explorer\HideDesktopIcons\NewStartPanel"

        New-Item `
            -Path $path `
            -Force |
            Out-Null

        New-ItemProperty `
            -Path $path `
            -Name "{20D04FE0-3AEA-1069-A2D8-08002B30309D}" `
            -PropertyType DWord `
            -Value 0 `
            -Force |
            Out-Null

        New-ItemProperty `
            -Path $path `
            -Name "{59031a47-3f72-44a7-89c5-5595fe6b30ee}" `
            -PropertyType DWord `
            -Value 0 `
            -Force |
            Out-Null

        Stop-Process `
            -Name explorer `
            -Force `
            -ErrorAction SilentlyContinue

        Start-Process explorer.exe

        $Log.Invoke(
            "Icones configurados e Explorer reiniciado."
        )

    }
    catch {

        $Log.Invoke(
            "Erro ao configurar icones: $($_.Exception.Message)"
        )
    }
}

# ============================================================

function Step-Telemetria {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke("== Telemetria ==")

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULACAO] Desativaria a telemetria via politica local."
        )

        return
    }

    try {

        $path =
            "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"

        New-Item `
            -Path $path `
            -Force |
            Out-Null

        Set-ItemProperty `
            -Path $path `
            -Name "AllowTelemetry" `
            -Value 0 `
            -Force

        $Log.Invoke(
            "Politica de telemetria configurada."
        )

    }
    catch {

        $Log.Invoke(
            "Erro ao configurar telemetria: $($_.Exception.Message)"
        )
    }
}

# ============================================================

function Step-Energia {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke("== Plano de energia ==")

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULACAO] Ajustaria monitor, disco, suspensao " +
            "e hibernacao para nunca desligar."
        )

        return
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

    }
    catch {

        $Log.Invoke(
            "Erro ao configurar energia: $($_.Exception.Message)"
        )
    }
}

# ============================================================

function Step-RegiaoIdioma {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke(
        "== Fuso horario e localizacao (Brasil) =="
    )

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULACAO] Definiria fuso de Brasilia e localizacao Brasil."
        )

        return
    }

    try {

        Set-TimeZone `
            -Id "E. South America Standard Time" `
            -ErrorAction Stop

        Set-WinHomeLocation `
            -GeoId 76 `
            -ErrorAction SilentlyContinue

        $Log.Invoke(
            "Fuso horario de Brasilia configurado."
        )

        $Log.Invoke(
            "Localizacao do Windows configurada para Brasil."
        )

    }
    catch {

        $Log.Invoke(
            "Aviso ao ajustar regiao: $($_.Exception.Message)"
        )
    }
}

# ============================================================

function Step-Debloat {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke(
        "== Remover apps padrao =="
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
            "[SIMULACAO] Removeria: $($apps -join ', ')"
        )

        return
    }

    foreach ($a in $apps) {

        try {

            Get-AppxPackage "*$a*" `
                -ErrorAction SilentlyContinue |
                Remove-AppxPackage `
                -ErrorAction SilentlyContinue

            Get-AppxProvisionedPackage -Online `
                -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.DisplayName -like "*$a*"
                } |
                Remove-AppxProvisionedPackage `
                -Online `
                -ErrorAction SilentlyContinue |
                Out-Null

            $Log.Invoke(
                "Processado: $a"
            )

        }
        catch {

            $Log.Invoke(
                "Aviso ao remover $a : $($_.Exception.Message)"
            )
        }
    }
}

# ============================================================
# CHOCOLATEY
# ============================================================

function Ensure-ChocoAvailable {

    param($Log)

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
        Join-Path $env:ProgramData "chocolatey\bin"

    $chocoExe =
        Join-Path $chocoBin "choco.exe"

    if (Test-Path -LiteralPath $chocoExe) {

        $env:Path += ";$chocoBin"

        return $true
    }

    if ($Log) {

        $Log.Invoke(
            "Chocolatey nao encontrado."
        )

    }

    return $false
}

# ============================================================

function Step-Chocolatey {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke("== Chocolatey ==")

    if (Ensure-ChocoAvailable -Log $null) {

        $Log.Invoke(
            "Chocolatey ja instalado."
        )

        return
    }

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULACAO] Instalaria o Chocolatey."
        )

        return
    }

    try {

        Set-ExecutionPolicy `
            Bypass `
            -Scope Process `
            -Force

        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor 3072

        $installScript =
            (New-Object System.Net.WebClient).DownloadString(
                "https://community.chocolatey.org/install.ps1"
            )

        Invoke-Expression $installScript

        $env:Path += ";$env:ProgramData\chocolatey\bin"

        if (Get-Command choco -ErrorAction SilentlyContinue) {

            $Log.Invoke(
                "Chocolatey instalado com sucesso."
            )

        }
        else {

            $Log.Invoke(
                "Aviso: instalacao executada, mas choco nao foi localizado."
            )
        }

    }
    catch {

        $Log.Invoke(
            "ERRO ao instalar Chocolatey: $($_.Exception.Message)"
        )

        throw
    }
}

# ============================================================
# WINGET
# ============================================================

function Step-WingetUpgradeAll {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke(
        "== Preparando winget e atualizando aplicativos =="
    )

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULACAO] Executaria winget upgrade --all."
        )

        return
    }

    try {

        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {

            $Log.Invoke(
                "winget nao foi encontrado neste Windows."
            )

            return
        }

        try {

            Install-PackageProvider `
                -Name NuGet `
                -Force `
                -ErrorAction Stop |
                Out-Null

        }
        catch {

            $Log.Invoke(
                "Aviso ao instalar provider NuGet: $($_.Exception.Message)"
            )
        }

        try {

            if (-not (
                Get-Module `
                    -ListAvailable `
                    -Name Microsoft.WinGet.Client
            )) {

                Install-Module `
                    -Name Microsoft.WinGet.Client `
                    -Force `
                    -Repository PSGallery `
                    -Confirm:$false `
                    -ErrorAction Stop
            }

        }
        catch {

            $Log.Invoke(
                "Aviso ao preparar Microsoft.WinGet.Client: $($_.Exception.Message)"
            )
        }

        try {

            if (Get-Command Repair-WinGetPackageManager -ErrorAction SilentlyContinue) {

                Repair-WinGetPackageManager `
                    -ErrorAction SilentlyContinue
            }

        }
        catch {
        }

        try {

            winget source update 2>&1 |
                ForEach-Object {
                    $Log.Invoke($_)
                }

        }
        catch {

            $Log.Invoke(
                "Aviso ao atualizar fontes do winget."
            )
        }

        $Log.Invoke(
            "Atualizando aplicativos via winget..."
        )

        winget upgrade --all `
            --accept-source-agreements `
            --accept-package-agreements `
            --silent 2>&1 |
            ForEach-Object {
                $Log.Invoke($_)
            }

        $Log.Invoke(
            "Atualizacao via winget finalizada."
        )

    }
    catch {

        $Log.Invoke(
            "ERRO no winget: $($_.Exception.Message)"
        )
    }
}

# ============================================================
# TAREFA DE LIMPEZA
# ============================================================

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
            "[SIMULACAO] Criaria tarefa LimpezaDisco."
        )

        return
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
            /f |
            Out-Null

        $Log.Invoke(
            "Tarefa LimpezaDisco criada/atualizada."
        )

    }
    catch {

        $Log.Invoke(
            "ERRO ao criar tarefa: $($_.Exception.Message)"
        )
    }
}

# ============================================================
# CATALOGO DE APLICATIVOS
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

# ============================================================
# PROGRAMAS INSTALADOS
# ============================================================

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
# INSTALACAO SITEF
# ============================================================

function Install-Sitef {

    $log = $script:SitefLogDelegate

    $log.Invoke("=== INICIANDO INSTALACAO SITEF ===")
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

    # --------------------------------------------------------
    # CRIAR DIRETORIO
    # --------------------------------------------------------

    try {

        if (-not (Test-Path -LiteralPath $sitefDir)) {

            $log.Invoke(
                "Criando diretorio $sitefDir..."
            )

            New-Item `
                -ItemType Directory `
                -Path $sitefDir `
                -Force |
                Out-Null

        }

        $log.Invoke(
            "Diretorio SITEF pronto."
        )

    }
    catch {

        $log.Invoke(
            "ERRO ao criar diretorio: $($_.Exception.Message)"
        )

        return
    }

    # --------------------------------------------------------
    # PROGRESSO
    # --------------------------------------------------------

    $progressSitef.Maximum = $zipUrls.Count * 2

    $progressSitef.Value = 0

    # --------------------------------------------------------
    # STATUS INDIVIDUAL
    # --------------------------------------------------------

    $itemStatus = @{}

    foreach ($item in $zipUrls) {

        $url = $item.url

        $fileName = $item.nome

        $zipPath =
            Join-Path $sitefDir $fileName

        $extractPath =
            Join-Path `
                $sitefDir `
                ([System.IO.Path]::GetFileNameWithoutExtension($fileName))

        $itemStatus[$fileName] = $false

        # ----------------------------------------------------
        # ARQUIVO EXISTENTE
        # ----------------------------------------------------

        if (Test-Path -LiteralPath $zipPath) {

            $log.Invoke(
                "Arquivo $fileName ja existe."
            )

            try {

                if (Test-Path -LiteralPath $extractPath) {

                    Remove-Item `
                        -Path $extractPath `
                        -Recurse `
                        -Force `
                        -ErrorAction SilentlyContinue
                }

                New-Item `
                    -ItemType Directory `
                    -Path $extractPath `
                    -Force |
                    Out-Null

                Expand-Archive `
                    -Path $zipPath `
                    -DestinationPath $extractPath `
                    -Force `
                    -ErrorAction Stop

                $log.Invoke(
                    "$fileName extraido com sucesso."
                )

                $progressSitef.Value =
                    [Math]::Min(
                        $progressSitef.Maximum,
                        $progressSitef.Value + 2
                    )

                $itemStatus[$fileName] = $true

                continue
            }
            catch {

                $log.Invoke(
                    "Arquivo existente invalido ou corrompido."
                )

                Remove-Item `
                    -Path $zipPath `
                    -Force `
                    -ErrorAction SilentlyContinue

                Remove-Item `
                    -Path $extractPath `
                    -Recurse `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }

        # ----------------------------------------------------
        # DOWNLOAD
        # ----------------------------------------------------

        $log.Invoke(
            "Baixando $fileName..."
        )

        try {

            $webClient =
                New-Object System.Net.WebClient

            $webClient.Headers.Add(
                "User-Agent",
                "Mozilla/5.0 Windows MCNTV-Installer"
            )

            $webClient.DownloadFile(
                $url,
                $zipPath
            )

            $webClient.Dispose()

            $log.Invoke(
                "Download concluido: $zipPath"
            )

            $progressSitef.Value =
                [Math]::Min(
                    $progressSitef.Maximum,
                    $progressSitef.Value + 1
                )
        }
        catch {

            $log.Invoke(
                "ERRO ao baixar $url"
            )

            $log.Invoke(
                $_.Exception.Message
            )

            continue
        }

        # ----------------------------------------------------
        # VALIDAR ZIP
        # ----------------------------------------------------

        try {

            $bytes =
                [System.IO.File]::ReadAllBytes($zipPath)

            $isZip =
                $bytes.Count -ge 4 -and
                $bytes[0] -eq 0x50 -and
                $bytes[1] -eq 0x4B -and
                $bytes[2] -eq 0x03 -and
                $bytes[3] -eq 0x04

        }
        catch {

            $isZip = $false
        }

        if (-not $isZip) {

            $log.Invoke(
                "ERRO: $fileName nao e um ZIP valido."
            )

            Remove-Item `
                -Path $zipPath `
                -Force `
                -ErrorAction SilentlyContinue

            continue
        }

        # ----------------------------------------------------
        # EXTRAIR
        # ----------------------------------------------------

        $log.Invoke(
            "Extraindo $fileName..."
        )

        try {

            New-Item `
                -ItemType Directory `
                -Path $extractPath `
                -Force |
                Out-Null

            Expand-Archive `
                -Path $zipPath `
                -DestinationPath $extractPath `
                -Force `
                -ErrorAction Stop

            $log.Invoke(
                "$fileName extraido com sucesso."
            )

            $progressSitef.Value =
                [Math]::Min(
                    $progressSitef.Maximum,
                    $progressSitef.Value + 1
                )

            $itemStatus[$fileName] = $true
        }
        catch {

            $log.Invoke(
                "Expand-Archive falhou."
            )

            $log.Invoke(
                "Tentando metodo alternativo..."
            )

            try {

                [System.IO.Compression.ZipFile]::ExtractToDirectory(
                    $zipPath,
                    $extractPath,
                    $true
                )

                $log.Invoke(
                    "Extracao alternativa concluida."
                )

                $progressSitef.Value =
                    [Math]::Min(
                        $progressSitef.Maximum,
                        $progressSitef.Value + 1
                    )

                $itemStatus[$fileName] = $true

            }
            catch {

                $log.Invoke(
                    "ERRO ao extrair $fileName : " +
                    $_.Exception.Message
                )

                Remove-Item `
                    -Path $zipPath `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
    }

    # ========================================================
    # RESULTADO DOS DOWNLOADS
    # ========================================================

    $log.Invoke("")
    $log.Invoke("=== RESULTADO DOS ARQUIVOS ===")

    $falhas =
        @(
            $itemStatus.GetEnumerator() |
            Where-Object {
                -not $_.Value
            } |
            ForEach-Object {
                $_.Key
            }
        )

    if ($falhas.Count -gt 0) {

        $log.Invoke(
            "Falharam: $($falhas -join ', ')"
        )

    }
    else {

        $log.Invoke(
            "Todos os arquivos foram baixados e extraidos."
        )
    }

    # ========================================================
    # PROCURAR INSTALADORES
    # ========================================================

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
            "ERRO: GSurfRSA_Listener_Setup.msi nao encontrado."
        )

        $log.Invoke(
            "Instalacao abortada."
        )

        return
    }

    if (-not $exePath) {

        $log.Invoke(
            "ERRO: InstaladorGSurf.exe nao encontrado."
        )

        $log.Invoke(
            "Instalacao abortada."
        )

        return
    }

    # ========================================================
    # INSTALAR MSI
    # ========================================================

    $log.Invoke("")
    $log.Invoke(
        "Executando MSI:"
    )

    $log.Invoke(
        $msiPath.FullName
    )

    try {

        $msiArgs =
            "/i `"$($msiPath.FullName)`" /norestart"

        $process =
            Start-Process `
                -FilePath "msiexec.exe" `
                -ArgumentList $msiArgs `
                -Wait `
                -PassThru

        $log.Invoke(
            "MSI finalizado. Codigo: $($process.ExitCode)"
        )

    }
    catch {

        $log.Invoke(
            "ERRO ao executar MSI: $($_.Exception.Message)"
        )
    }

    # ========================================================
    # INSTALAR EXE
    # ========================================================

    $log.Invoke("")
    $log.Invoke(
        "Executando EXE:"
    )

    $log.Invoke(
        $exePath.FullName
    )

    try {

        $process =
            Start-Process `
                -FilePath $exePath.FullName `
                -Wait `
                -PassThru

        $log.Invoke(
            "EXE finalizado. Codigo: $($process.ExitCode)"
        )

    }
    catch {

        $log.Invoke(
            "ERRO ao executar EXE: $($_.Exception.Message)"
        )
    }

    # ========================================================
    # SERVICO
    # ========================================================

    $log.Invoke("")
    $log.Invoke(
        "Aguardando 5 segundos..."
    )

    Start-Sleep -Seconds 5

    $serviceName =
        "GSurfRSA Listener"

    $log.Invoke(
        "Verificando servico '$serviceName'..."
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
                    "Servico iniciado com sucesso."
                )

            }
            catch {

                $log.Invoke(
                    "ERRO ao iniciar servico: " +
                    $_.Exception.Message
                )
            }

        }
        else {

            $log.Invoke(
                "Servico ja esta em execucao. Status: $($svc.Status)"
            )
        }

    }
    else {

        $log.Invoke(
            "Servico '$serviceName' nao encontrado."
        )
    }

    $log.Invoke("")
    $log.Invoke(
        "=== INSTALACAO SITEF CONCLUIDA ==="
    )

    $progressSitef.Value =
        $progressSitef.Maximum

    [System.Windows.Forms.MessageBox]::Show(
        "Instalacao SITEF concluida!`n`nVerifique o log para detalhes.",
        "SITEF",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}

# ============================================================
# CORES
# ============================================================

$ColorBackground =
    [System.Drawing.Color]::FromArgb(245,247,250)

$ColorSurface =
    [System.Drawing.Color]::White

$ColorText =
    [System.Drawing.Color]::FromArgb(35,38,42)

$ColorMuted =
    [System.Drawing.Color]::FromArgb(95,102,110)

$ColorPrimary =
    [System.Drawing.Color]::FromArgb(0,120,215)

$ColorSuccess =
    [System.Drawing.Color]::FromArgb(40,150,90)

$ColorDanger =
    [System.Drawing.Color]::FromArgb(190,55,55)

$ColorBorder =
    [System.Drawing.Color]::FromArgb(210,215,222)

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

# ============================================================
# FORMULARIO
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

$form.ClientSize =
    New-Object System.Drawing.Size(
        1100,
        750
    )

$form.MinimumSize =
    New-Object System.Drawing.Size(
        800,
        600
    )

$form.BackColor =
    $ColorBackground

$form.Font =
    $FontNormal

# ============================================================
# PAINEL PRINCIPAL
# ============================================================

$mainPanel =
    New-Object System.Windows.Forms.Panel

$mainPanel.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$mainPanel.AutoScroll =
    $true

$form.Controls.Add(
    $mainPanel
)

# ============================================================
# CABECALHO
# ============================================================

$headerPanel =
    New-Object System.Windows.Forms.Panel

$headerPanel.Dock =
    [System.Windows.Forms.DockStyle]::Top

$headerPanel.Height = 70

$headerPanel.BackColor =
    $ColorBackground

$mainPanel.Controls.Add(
    $headerPanel
)

$lblMainTitle =
    New-Object System.Windows.Forms.Label

$lblMainTitle.Text =
    "MCNTV Installer"

$lblMainTitle.Font =
    $FontTitle

$lblMainTitle.ForeColor =
    $ColorText

$lblMainTitle.Location =
    New-Object System.Drawing.Point(
        20,
        10
    )

$lblMainTitle.Size =
    New-Object System.Drawing.Size(
        500,
        30
    )

$headerPanel.Controls.Add(
    $lblMainTitle
)

$lblSubtitle =
    New-Object System.Windows.Forms.Label

$lblSubtitle.Text =
    "Instale, configure e gerencie este computador"

$lblSubtitle.Font =
    $FontNormal

$lblSubtitle.ForeColor =
    $ColorMuted

$lblSubtitle.Location =
    New-Object System.Drawing.Point(
        20,
        40
    )

$lblSubtitle.Size =
    New-Object System.Drawing.Size(
        500,
        22
    )

$headerPanel.Controls.Add(
    $lblSubtitle
)

# ============================================================
# CONTEUDO
# ============================================================

$contentPanel =
    New-Object System.Windows.Forms.Panel

$contentPanel.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$contentPanel.BackColor =
    $ColorBackground

$mainPanel.Controls.Add(
    $contentPanel
)

# ============================================================
# STATUS
# ============================================================

$statusPanel =
    New-Object System.Windows.Forms.Panel

$statusPanel.Dock =
    [System.Windows.Forms.DockStyle]::Bottom

$statusPanel.Height = 210

$statusPanel.BackColor =
    $ColorBackground

$contentPanel.Controls.Add(
    $statusPanel
)

# ============================================================
# TABS
# ============================================================

$tabControl =
    New-Object System.Windows.Forms.TabControl

$tabControl.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$tabControl.Font =
    $FontNormal

$contentPanel.Controls.Add(
    $tabControl
)

# ============================================================
# ABA PROVISIONAMENTO
# ============================================================

$tabProvisioning =
    New-Object System.Windows.Forms.TabPage

$tabProvisioning.Text =
    "Provisionamento"

$tabProvisioning.BackColor =
    $ColorBackground

$tabControl.Controls.Add(
    $tabProvisioning
)

# ============================================================
# TABLE PRINCIPAL
# ============================================================

$tableLayout =
    New-Object System.Windows.Forms.TableLayoutPanel

$tableLayout.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$tableLayout.ColumnCount = 3

$tableLayout.RowCount = 1

[void]$tableLayout.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Percent,
        33.33
    ))
)

[void]$tableLayout.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Percent,
        33.33
    ))
)

[void]$tableLayout.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Percent,
        33.34
    ))
)

[void]$tableLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Percent,
        100
    ))
)

$tableLayout.Padding =
    New-Object System.Windows.Forms.Padding(
        10,
        10,
        10,
        10
    )

$tableLayout.BackColor =
    $ColorBackground

$tabProvisioning.Controls.Add(
    $tableLayout
)

# ============================================================
# GRUPO 1
# ============================================================

$grpSystem =
    New-Object System.Windows.Forms.GroupBox

$grpSystem.Text =
    "1. Configuracao do sistema"

$grpSystem.Font =
    $FontHeader

$grpSystem.ForeColor =
    $ColorText

$grpSystem.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$grpSystem.Padding =
    New-Object System.Windows.Forms.Padding(
        10,
        20,
        10,
        10
    )

$tableLayout.Controls.Add(
    $grpSystem,
    0,
    0
)

$panelSystem =
    New-Object System.Windows.Forms.Panel

$panelSystem.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$panelSystem.AutoScroll =
    $true

$grpSystem.Controls.Add(
    $panelSystem
)

# ============================================================
# ETAPAS
# ============================================================

$steps = [ordered]@{

    "Ponto de Restauracao" = {
        param($l,$d)
        Step-RestorePoint -Log $l -DryRun $d
    }

    "Versoes Anteriores (Shadow Copy)" = {
        param($l,$d)
        Step-VersoesAnteriores -Log $l -DryRun $d
    }

    "Icones da Area de Trabalho" = {
        param($l,$d)
        Step-IconesAreaTrabalho -Log $l -DryRun $d
    }

    "Desativar Telemetria" = {
        param($l,$d)
        Step-Telemetria -Log $l -DryRun $d
    }

    "Ajustar Plano de Energia" = {
        param($l,$d)
        Step-Energia -Log $l -DryRun $d
    }

    "Fuso Horario / Localizacao (BR)" = {
        param($l,$d)
        Step-RegiaoIdioma -Log $l -DryRun $d
    }

    "Remover Apps Padrao (Debloat)" = {
        param($l,$d)
        Step-Debloat -Log $l -DryRun $d
    }

    "Instalar/Atualizar Chocolatey" = {
        param($l,$d)
        Step-Chocolatey -Log $l -DryRun $d
    }

    "Atualizar Apps (winget upgrade)" = {
        param($l,$d)
        Step-WingetUpgradeAll -Log $l -DryRun $d
    }

    "Criar Tarefa de Limpeza Semanal" = {
        param($l,$d)
        Step-TarefaLimpeza -Log $l -DryRun $d
    }
}

$UncheckedByDefault = @(
    "Versoes Anteriores (Shadow Copy)"
)

$checkboxes = @{}

$y = 10

foreach ($key in $steps.Keys) {

    $cb =
        New-Object System.Windows.Forms.CheckBox

    $cb.Text =
        $key

    $cb.Checked =
        -not (
            $UncheckedByDefault -contains $key
        )

    $cb.Location =
        New-Object System.Drawing.Point(
            10,
            $y
        )

    $cb.Size =
        New-Object System.Drawing.Size(
            350,
            22
        )

    $cb.Font =
        $FontNormal

    $cb.ForeColor =
        $ColorText

    $cb.Anchor =
        [System.Windows.Forms.AnchorStyles]::Top `
        -bor [System.Windows.Forms.AnchorStyles]::Left `
        -bor [System.Windows.Forms.AnchorStyles]::Right

    $panelSystem.Controls.Add($cb)

    $checkboxes[$key] = $cb

    $y += 26
}

# ============================================================
# DRY RUN
# ============================================================

$chkDryRun =
    New-Object System.Windows.Forms.CheckBox

$chkDryRun.Text =
    "Modo Simulacao (dry-run)"

$yDryRun =
    $y + 3

$chkDryRun.Location =
    New-Object System.Drawing.Point(
        10,
        $yDryRun
    )

$chkDryRun.Size =
    New-Object System.Drawing.Size(
        350,
        22
    )

$chkDryRun.Font =
    $FontNormal

$chkDryRun.ForeColor =
    [System.Drawing.Color]::DarkBlue

$panelSystem.Controls.Add(
    $chkDryRun
)

# ============================================================
# BOTOES SELECAO
# ============================================================

$yButtons =
    $y + 35

$btnSelAll =
    New-Object System.Windows.Forms.Button

$btnSelAll.Text =
    "Marcar todos"

$btnSelAll.Location =
    New-Object System.Drawing.Point(
        10,
        $yButtons
    )

$btnSelAll.Size =
    New-Object System.Drawing.Size(
        150,
        30
    )

$btnSelAll.Font =
    $FontButton

$btnSelAll.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnSelAll.FlatAppearance.BorderColor =
    $ColorBorder

$btnSelAll.BackColor =
    $ColorSurface

$btnSelAll.Add_Click({
    $checkboxes.Values |
        ForEach-Object {
            $_.Checked = $true
        }
})

$panelSystem.Controls.Add(
    $btnSelAll
)

$btnSelNone =
    New-Object System.Windows.Forms.Button

$btnSelNone.Text =
    "Desmarcar todos"

$btnSelNone.Location =
    New-Object System.Drawing.Point(
        180,
        $yButtons
    )

$btnSelNone.Size =
    New-Object System.Drawing.Size(
        150,
        30
    )

$btnSelNone.Font =
    $FontButton

$btnSelNone.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnSelNone.FlatAppearance.BorderColor =
    $ColorBorder

$btnSelNone.BackColor =
    $ColorSurface

$btnSelNone.Add_Click({
    $checkboxes.Values |
        ForEach-Object {
            $_.Checked = $false
        }
})

$panelSystem.Controls.Add(
    $btnSelNone
)

# ============================================================
# BOTAO EXECUTAR
# ============================================================

$yBtnRun =
    $y + 80

$btnRun =
    New-Object System.Windows.Forms.Button

$btnRun.Text =
    "Executar configuracao"

$btnRun.Location =
    New-Object System.Drawing.Point(
        10,
        $yBtnRun
    )

$btnRun.Size =
    New-Object System.Drawing.Size(
        320,
        30
    )

$btnRun.Font =
    $FontButton

$btnRun.BackColor =
    $ColorPrimary

$btnRun.ForeColor =
    [System.Drawing.Color]::White

$btnRun.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnRun.FlatAppearance.BorderSize = 0

$panelSystem.Controls.Add(
    $btnRun
)

# ============================================================
# GRUPO 2 - INSTALACAO
# ============================================================

$grpInstall =
    New-Object System.Windows.Forms.GroupBox

$grpInstall.Text =
    "2. Instalar aplicativos"

$grpInstall.Font =
    $FontHeader

$grpInstall.ForeColor =
    $ColorText

$grpInstall.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$grpInstall.Padding =
    New-Object System.Windows.Forms.Padding(
        10,
        20,
        10,
        10
    )

$tableLayout.Controls.Add(
    $grpInstall,
    1,
    0
)

$panelInstall =
    New-Object System.Windows.Forms.Panel

$panelInstall.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$panelInstall.AutoScroll =
    $true

$grpInstall.Controls.Add(
    $panelInstall
)

# ============================================================
# BUSCA
# ============================================================

$lblInstallInfo =
    New-Object System.Windows.Forms.Label

$lblInstallInfo.Text =
    "Buscar:"

$lblInstallInfo.Location =
    New-Object System.Drawing.Point(
        10,
        10
    )

$lblInstallInfo.Size =
    New-Object System.Drawing.Size(
        50,
        22
    )

$lblInstallInfo.ForeColor =
    $ColorMuted

$panelInstall.Controls.Add(
    $lblInstallInfo
)

$txtSearchInstall =
    New-Object System.Windows.Forms.TextBox

$txtSearchInstall.Location =
    New-Object System.Drawing.Point(
        60,
        10
    )

$txtSearchInstall.Size =
    New-Object System.Drawing.Size(
        250,
        22
    )

$txtSearchInstall.Anchor =
    [System.Windows.Forms.AnchorStyles]::Top `
    -bor [System.Windows.Forms.AnchorStyles]::Left `
    -bor [System.Windows.Forms.AnchorStyles]::Right

$panelInstall.Controls.Add(
    $txtSearchInstall
)

# ============================================================
# LISTA DE INSTALACAO
# ============================================================

$clbInstall =
    New-Object System.Windows.Forms.CheckedListBox

$clbInstall.Location =
    New-Object System.Drawing.Point(
        10,
        40
    )

$clbInstall.Size =
    New-Object System.Drawing.Size(
        300,
        230
    )

$clbInstall.CheckOnClick = $true

$clbInstall.Font =
    $FontNormal

$clbInstall.Anchor =
    [System.Windows.Forms.AnchorStyles]::Top `
    -bor [System.Windows.Forms.AnchorStyles]::Left `
    -bor [System.Windows.Forms.AnchorStyles]::Right `
    -bor [System.Windows.Forms.AnchorStyles]::Bottom

$allLabels =
    Build-AppCatalogLabels

$clbInstall.Tag =
    $allLabels

foreach ($label in $allLabels) {

    [void]$clbInstall.Items.Add(
        $label,
        $true
    )
}

$panelInstall.Controls.Add(
    $clbInstall
)

# ============================================================
# FILTRO
# ============================================================

$txtSearchInstall.Add_TextChanged({

    $search =
        $txtSearchInstall.Text.Trim().ToLower()

    $clbInstall.BeginUpdate()

    try {

        $clbInstall.Items.Clear()

        $all =
            $clbInstall.Tag

        foreach ($item in $all) {

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

# ============================================================
# BOTAO INSTALAR
# ============================================================

$btnInstallSelected =
    New-Object System.Windows.Forms.Button

$btnInstallSelected.Text =
    "INSTALAR SELECIONADOS"

$btnInstallSelected.Location =
    New-Object System.Drawing.Point(
        10,
        275
    )

$btnInstallSelected.Size =
    New-Object System.Drawing.Size(
        300,
        40
    )

$btnInstallSelected.Font =
    New-Object System.Drawing.Font(
        "Segoe UI Semibold",
        10
    )

$btnInstallSelected.BackColor =
    $ColorSuccess

$btnInstallSelected.ForeColor =
    [System.Drawing.Color]::White

$btnInstallSelected.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnInstallSelected.FlatAppearance.BorderSize = 0

$panelInstall.Controls.Add(
    $btnInstallSelected
)

# ============================================================
# GRUPO 3 - DESINSTALACAO
# ============================================================

$grpUninstall =
    New-Object System.Windows.Forms.GroupBox

$grpUninstall.Text =
    "3. Gerenciar aplicativos instalados"

$grpUninstall.Font =
    $FontHeader

$grpUninstall.ForeColor =
    $ColorText

$grpUninstall.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$grpUninstall.Padding =
    New-Object System.Windows.Forms.Padding(
        10,
        20,
        10,
        10
    )

$tableLayout.Controls.Add(
    $grpUninstall,
    2,
    0
)

$tableUninstall =
    New-Object System.Windows.Forms.TableLayoutPanel

$tableUninstall.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$tableUninstall.ColumnCount = 1

$tableUninstall.RowCount = 4

[void]$tableUninstall.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::AutoSize
    ))
)

[void]$tableUninstall.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Percent,
        100
    ))
)

[void]$tableUninstall.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::AutoSize
    ))
)

[void]$tableUninstall.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::AutoSize
    ))
)

$grpUninstall.Controls.Add(
    $tableUninstall
)

# ============================================================
# LABEL
# ============================================================

$lblUninstallInfo =
    New-Object System.Windows.Forms.Label

$lblUninstallInfo.Text =
    "Atualize a lista e selecione o que deseja remover:"

$lblUninstallInfo.Font =
    $FontNormal

$lblUninstallInfo.ForeColor =
    $ColorMuted

$lblUninstallInfo.Dock =
    [System.Windows.Forms.DockStyle]::Top

$lblUninstallInfo.Height = 22

$tableUninstall.Controls.Add(
    $lblUninstallInfo,
    0,
    0
)

# ============================================================
# LISTA
# ============================================================

$clbUninstall =
    New-Object System.Windows.Forms.CheckedListBox

$clbUninstall.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$clbUninstall.CheckOnClick = $true

$clbUninstall.Font =
    $FontNormal

$tableUninstall.Controls.Add(
    $clbUninstall,
    0,
    1
)

# ============================================================
# BOTOES DESINSTALACAO
# ============================================================

$panelUninstallButtons =
    New-Object System.Windows.Forms.TableLayoutPanel

$panelUninstallButtons.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$panelUninstallButtons.Height = 38

$panelUninstallButtons.ColumnCount = 2

$panelUninstallButtons.RowCount = 1

[void]$panelUninstallButtons.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Percent,
        50
    ))
)

[void]$panelUninstallButtons.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Percent,
        50
    ))
)

$tableUninstall.Controls.Add(
    $panelUninstallButtons,
    0,
    2
)

$btnRefreshInstalled =
    New-Object System.Windows.Forms.Button

$btnRefreshInstalled.Text =
    "Atualizar lista"

$btnRefreshInstalled.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$btnRefreshInstalled.Font =
    $FontButton

$btnRefreshInstalled.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnRefreshInstalled.FlatAppearance.BorderColor =
    $ColorBorder

$btnRefreshInstalled.BackColor =
    $ColorSurface

$panelUninstallButtons.Controls.Add(
    $btnRefreshInstalled,
    0,
    0
)

$btnUninstallSelected =
    New-Object System.Windows.Forms.Button

$btnUninstallSelected.Text =
    "Desinstalar"

$btnUninstallSelected.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$btnUninstallSelected.Font =
    $FontButton

$btnUninstallSelected.BackColor =
    $ColorDanger

$btnUninstallSelected.ForeColor =
    [System.Drawing.Color]::White

$btnUninstallSelected.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnUninstallSelected.FlatAppearance.BorderSize = 0

$panelUninstallButtons.Controls.Add(
    $btnUninstallSelected,
    1,
    0
)

# ============================================================
# BOTAO CUSTOMIZADO
# ============================================================

$btnCustom =
    New-Object System.Windows.Forms.Button

$btnCustom.Text =
    $CustomScriptLabel

$btnCustom.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$btnCustom.Height = 32

$btnCustom.Font =
    $FontButton

$btnCustom.BackColor =
    $ColorSurface

$btnCustom.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnCustom.FlatAppearance.BorderColor =
    $ColorBorder

$tableUninstall.Controls.Add(
    $btnCustom,
    0,
    3
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

$panelSitef =
    New-Object System.Windows.Forms.Panel

$panelSitef.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$panelSitef.AutoScroll =
    $true

$panelSitef.Padding =
    New-Object System.Windows.Forms.Padding(
        20
    )

$tabSitef.Controls.Add(
    $panelSitef
)

$lblSitefTitle =
    New-Object System.Windows.Forms.Label

$lblSitefTitle.Text =
    "Instalacao do Ambiente SITEF"

$lblSitefTitle.Font =
    New-Object System.Drawing.Font(
        "Segoe UI Semibold",
        12
    )

$lblSitefTitle.ForeColor =
    $ColorText

$lblSitefTitle.Location =
    New-Object System.Drawing.Point(
        0,
        0
    )

$lblSitefTitle.Size =
    New-Object System.Drawing.Size(
        500,
        25
    )

$panelSitef.Controls.Add(
    $lblSitefTitle
)

$lblSitefDesc =
    New-Object System.Windows.Forms.Label

$lblSitefDesc.Text =
    "Esta etapa ira baixar, extrair e executar os instaladores do SITEF.`n" +
    "Apos a execucao, voce devera configurar manualmente os programas.`n" +
    "Ao fechar os instaladores, o servico 'GSurfRSA Listener' sera iniciado."

$lblSitefDesc.Font =
    $FontNormal

$lblSitefDesc.ForeColor =
    $ColorMuted

$lblSitefDesc.Location =
    New-Object System.Drawing.Point(
        0,
        35
    )

$lblSitefDesc.Size =
    New-Object System.Drawing.Size(
        750,
        60
    )

$panelSitef.Controls.Add(
    $lblSitefDesc
)

# ============================================================
# BOTAO SITEF
# ============================================================

$btnSitefInstall =
    New-Object System.Windows.Forms.Button

$btnSitefInstall.Text =
    "Instalar SITEF"

$btnSitefInstall.Location =
    New-Object System.Drawing.Point(
        0,
        110
    )

$btnSitefInstall.Size =
    New-Object System.Drawing.Size(
        180,
        35
    )

$btnSitefInstall.Font =
    New-Object System.Drawing.Font(
        "Segoe UI Semibold",
        10
    )

$btnSitefInstall.BackColor =
    $ColorPrimary

$btnSitefInstall.ForeColor =
    [System.Drawing.Color]::White

$btnSitefInstall.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnSitefInstall.FlatAppearance.BorderSize = 0

$panelSitef.Controls.Add(
    $btnSitefInstall
)

# ============================================================
# ABRIR SITEF
# ============================================================

$btnSitefOpenFolder =
    New-Object System.Windows.Forms.Button

$btnSitefOpenFolder.Text =
    "Abrir pasta C:\SITEF"

$btnSitefOpenFolder.Location =
    New-Object System.Drawing.Point(
        200,
        110
    )

$btnSitefOpenFolder.Size =
    New-Object System.Drawing.Size(
        160,
        35
    )

$btnSitefOpenFolder.Font =
    $FontButton

$btnSitefOpenFolder.BackColor =
    $ColorSurface

$btnSitefOpenFolder.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnSitefOpenFolder.FlatAppearance.BorderColor =
    $ColorBorder

$panelSitef.Controls.Add(
    $btnSitefOpenFolder
)

# ============================================================
# PROGRESSO SITEF
# ============================================================

$progressSitef =
    New-Object System.Windows.Forms.ProgressBar

$progressSitef.Location =
    New-Object System.Drawing.Point(
        0,
        160
    )

$progressSitef.Size =
    New-Object System.Drawing.Size(
        700,
        20
    )

$progressSitef.Minimum = 0

$progressSitef.Maximum = 100

$progressSitef.Anchor =
    [System.Windows.Forms.AnchorStyles]::Top `
    -bor [System.Windows.Forms.AnchorStyles]::Left `
    -bor [System.Windows.Forms.AnchorStyles]::Right

$panelSitef.Controls.Add(
    $progressSitef
)

# ============================================================
# LOG SITEF
# ============================================================

$lblSitefLog =
    New-Object System.Windows.Forms.Label

$lblSitefLog.Text =
    "Log da instalacao SITEF:"

$lblSitefLog.Font =
    $FontNormal

$lblSitefLog.ForeColor =
    $ColorMuted

$lblSitefLog.Location =
    New-Object System.Drawing.Point(
        0,
        195
    )

$lblSitefLog.Size =
    New-Object System.Drawing.Size(
        300,
        22
    )

$panelSitef.Controls.Add(
    $lblSitefLog
)

$txtSitefLog =
    New-Object System.Windows.Forms.TextBox

$txtSitefLog.Multiline = $true

$txtSitefLog.ScrollBars =
    "Vertical"

$txtSitefLog.ReadOnly = $true

$txtSitefLog.Location =
    New-Object System.Drawing.Point(
        0,
        220
    )

$txtSitefLog.Size =
    New-Object System.Drawing.Size(
        700,
        200
    )

$txtSitefLog.Font =
    New-Object System.Drawing.Font(
        "Consolas",
        8
    )

$txtSitefLog.BackColor =
    [System.Drawing.Color]::White

$txtSitefLog.Anchor =
    [System.Windows.Forms.AnchorStyles]::Top `
    -bor [System.Windows.Forms.AnchorStyles]::Left `
    -bor [System.Windows.Forms.AnchorStyles]::Right `
    -bor [System.Windows.Forms.AnchorStyles]::Bottom

$panelSitef.Controls.Add(
    $txtSitefLog
)

# ============================================================
# STATUS GERAL
# ============================================================

$grpStatus =
    New-Object System.Windows.Forms.GroupBox

$grpStatus.Text =
    "Status Geral"

$grpStatus.Font =
    $FontHeader

$grpStatus.ForeColor =
    $ColorText

$grpStatus.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$grpStatus.Padding =
    New-Object System.Windows.Forms.Padding(
        10,
        20,
        10,
        10
    )

$statusPanel.Controls.Add(
    $grpStatus
)

$panelStatusInner =
    New-Object System.Windows.Forms.Panel

$panelStatusInner.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$grpStatus.Controls.Add(
    $panelStatusInner
)

# ============================================================
# PROGRESSO GERAL
# ============================================================

$progressBar =
    New-Object System.Windows.Forms.ProgressBar

$progressBar.Location =
    New-Object System.Drawing.Point(
        10,
        10
    )

$progressBar.Size =
    New-Object System.Drawing.Size(
        700,
        20
    )

$progressBar.Minimum = 0

$progressBar.Maximum = 100

$progressBar.Anchor =
    [System.Windows.Forms.AnchorStyles]::Top `
    -bor [System.Windows.Forms.AnchorStyles]::Left `
    -bor [System.Windows.Forms.AnchorStyles]::Right

$panelStatusInner.Controls.Add(
    $progressBar
)

$lblStatus =
    New-Object System.Windows.Forms.Label

$lblStatus.Text =
    "Pronto para instalar"

$lblStatus.Font =
    $FontNormal

$lblStatus.ForeColor =
    $ColorSuccess

$lblStatus.Location =
    New-Object System.Drawing.Point(
        10,
        35
    )

$lblStatus.Size =
    New-Object System.Drawing.Size(
        700,
        22
    )

$panelStatusInner.Controls.Add(
    $lblStatus
)

# ============================================================
# LOG GERAL
# ============================================================

$txtLog =
    New-Object System.Windows.Forms.TextBox

$txtLog.Multiline = $true

$txtLog.ScrollBars =
    "Vertical"

$txtLog.ReadOnly = $true

$txtLog.Location =
    New-Object System.Drawing.Point(
        10,
        62
    )

$txtLog.Size =
    New-Object System.Drawing.Size(
        700,
        120
    )

$txtLog.Font =
    New-Object System.Drawing.Font(
        "Consolas",
        8
    )

$txtLog.BackColor =
    [System.Drawing.Color]::White

$txtLog.Anchor =
    [System.Windows.Forms.AnchorStyles]::Top `
    -bor [System.Windows.Forms.AnchorStyles]::Left `
    -bor [System.Windows.Forms.AnchorStyles]::Right `
    -bor [System.Windows.Forms.AnchorStyles]::Bottom

$panelStatusInner.Controls.Add(
    $txtLog
)

# ============================================================
# LOG
# ============================================================

$AppendLog = {

    param($msg)

    $line =
        "$msg"

    try {

        $txtLog.AppendText(
            "$line`r`n"
        )

        $txtLog.SelectionStart =
            $txtLog.Text.Length

        $txtLog.ScrollToCaret()

    }
    catch {
    }

    try {

        Add-Content `
            -Path $LogFilePath `
            -Value $line `
            -Encoding UTF8

    }
    catch {
    }

    [System.Windows.Forms.Application]::DoEvents()
}

# ============================================================
# LOG SITEF
# ============================================================

$script:SitefLogDelegate = {

    param($msg)

    $line =
        "$msg"

    try {

        $txtSitefLog.AppendText(
            "$line`r`n"
        )

        $txtSitefLog.SelectionStart =
            $txtSitefLog.Text.Length

        $txtSitefLog.ScrollToCaret()

    }
    catch {
    }

    [System.Windows.Forms.Application]::DoEvents()
}

# ============================================================
# EVENTO - EXECUTAR PROVISIONAMENTO
# ============================================================

$btnRun.Add_Click({

    $btnRun.Enabled = $false

    $btnSelAll.Enabled = $false

    $btnSelNone.Enabled = $false

    $txtLog.Clear()

    $script:CancelRequested = $false

    $DryRun =
        $chkDryRun.Checked

    # IMPORTANTE:
    # @() garante que o resultado seja SEMPRE um array.

    $selectedSteps =
        @(
            $steps.Keys |
            Where-Object {
                $checkboxes[$_].Checked
            }
        )

    if ($selectedSteps.Count -eq 0) {

        [System.Windows.Forms.MessageBox]::Show(
            "Nenhuma etapa selecionada.",
            "Aviso",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        $btnRun.Enabled = $true
        $btnSelAll.Enabled = $true
        $btnSelNone.Enabled = $true

        return
    }

    # Limpar resultados anteriores
    $script:Results = [ordered]@{}

    $AppendLog.Invoke(
        "=== INICIANDO PROVISIONAMENTO ==="
    )

    if ($DryRun) {

        $AppendLog.Invoke(
            "Modo: SIMULACAO"
        )

    }
    else {

        $AppendLog.Invoke(
            "Modo: EXECUCAO REAL"
        )
    }

    $AppendLog.Invoke("")

    $progressBar.Maximum =
        $selectedSteps.Count

    $progressBar.Value = 0

    foreach ($key in $selectedSteps) {

        $lblStatus.Text =
            "Executando: $key ..."

        $AppendLog.Invoke("")
        $AppendLog.Invoke(
            ">>> $key"
        )

        try {

            & $steps[$key] `
                $AppendLog `
                $DryRun

            if ($DryRun) {

                $script:Results[$key] =
                    "SIMULADO"

            }
            else {

                $script:Results[$key] =
                    "OK"
            }

        }
        catch {

            $msg =
                $_.Exception.Message

            $AppendLog.Invoke(
                "ERRO em '$key': $msg"
            )

            $script:Results[$key] =
                "FALHA: $msg"
        }

        if (
            $progressBar.Value `
            -lt $progressBar.Maximum
        ) {

            $progressBar.Value++
        }

        [System.Windows.Forms.Application]::DoEvents()
    }

    # ========================================================
    # RELATORIO
    # ========================================================

    $AppendLog.Invoke("")
    $AppendLog.Invoke(
        "=== PROVISIONAMENTO CONCLUIDO ==="
    )

    $reportLines = @()

    $reportLines +=
        "Relatorio de Provisionamento - $Timestamp"

    if ($DryRun) {

        $reportLines +=
            "Modo: SIMULACAO"

    }
    else {

        $reportLines +=
            "Modo: EXECUCAO REAL"
    }

    $reportLines += ""

    foreach ($k in $script:Results.Keys) {

        $reportLines +=
            ("{0,-45} {1}" -f $k, $script:Results[$k])
    }

    try {

        $reportLines |
            Set-Content `
                -Path $ReportPath `
                -Encoding UTF8

        $AppendLog.Invoke(
            "Relatorio salvo em: $ReportPath"
        )

    }
    catch {

        $AppendLog.Invoke(
            "Erro ao salvar relatorio: $($_.Exception.Message)"
        )
    }

    $btnRun.Enabled = $true

    $btnSelAll.Enabled = $true

    $btnSelNone.Enabled = $true

    $lblStatus.Text =
        "Pronto."

    [System.Windows.Forms.MessageBox]::Show(
        "Provisionamento concluido.`n`nRelatorio:`n$ReportPath",
        "Finalizado",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
})

# ============================================================
# EVENTO - INSTALAR PROGRAMAS
# ============================================================

$btnInstallSelected.Add_Click({

    $selectedLabels =
        @(
            $clbInstall.CheckedItems
        )

    if ($selectedLabels.Count -eq 0) {

        [System.Windows.Forms.MessageBox]::Show(
            "Selecione ao menos um programa na lista.",
            "Aviso"
        )

        return
    }

    $btnInstallSelected.Enabled =
        $false

    $AppendLog.Invoke(
        "== Instalando programas selecionados =="
    )

    $AppendLog.Invoke(
        "Total: $($selectedLabels.Count) aplicativos"
    )

    $precisaChoco =
        @(
            $selectedLabels |
            Where-Object {
                $script:AppCatalogMap[$_].Manager -eq "choco"
            }
        )

    if ($precisaChoco.Count -gt 0) {

        $chocoOk =
            Ensure-ChocoAvailable `
                -Log $AppendLog

        if (-not $chocoOk) {

            $AppendLog.Invoke(
                "Chocolatey nao disponivel."
            )

            $btnInstallSelected.Enabled =
                $true

            return
        }
    }

    # --------------------------------------------------------
    # Verificar winget
    # --------------------------------------------------------

    $precisaWinget =
        @(
            $selectedLabels |
            Where-Object {
                $script:AppCatalogMap[$_].Manager -in @(
                    "winget",
                    "wingetStore"
                )
            }
        )

    if (
        $precisaWinget.Count -gt 0 -and
        -not (Get-Command winget -ErrorAction SilentlyContinue)
    ) {

        $AppendLog.Invoke(
            "ERRO: winget nao esta disponivel neste Windows."
        )

        $btnInstallSelected.Enabled =
            $true

        return
    }

    # --------------------------------------------------------
    # INSTALACAO SEQUENCIAL
    #
    # Em vez de Start-Job, executamos diretamente.
    # Isso evita problemas de ambiente com winget/choco,
    # PATH e processos elevados.
    # --------------------------------------------------------

    $totalJobs =
        $selectedLabels.Count

    $completed = 0

    $progressBar.Maximum =
        $totalJobs

    $progressBar.Value = 0

    foreach ($label in $selectedLabels) {

        $info =
            $script:AppCatalogMap[$label]

        if (-not $info) {
            continue
        }

        $lblStatus.Text =
            "Instalando: $($info.Id)..."

        $AppendLog.Invoke("")
        $AppendLog.Invoke(
            ">>> $label"
        )

        try {

            switch ($info.Manager) {

                "choco" {

                    $AppendLog.Invoke(
                        "Instalando via Chocolatey: $($info.Id)"
                    )

                    choco install `
                        $info.Id `
                        -y `
                        --force `
                        --ignore-checksums 2>&1 |
                        ForEach-Object {
                            $AppendLog.Invoke($_)
                        }
                }

                "winget" {

                    $AppendLog.Invoke(
                        "Instalando via winget: $($info.Id)"
                    )

                    winget install `
                        -e `
                        --id $info.Id `
                        --accept-source-agreements `
                        --accept-package-agreements `
                        --silent 2>&1 |
                        ForEach-Object {
                            $AppendLog.Invoke($_)
                        }
                }

                "wingetStore" {

                    $AppendLog.Invoke(
                        "Instalando via Microsoft Store: $($info.Id)"
                    )

                    winget install `
                        --id $info.Id `
                        --source msstore `
                        --accept-source-agreements `
                        --accept-package-agreements `
                        --silent 2>&1 |
                        ForEach-Object {
                            $AppendLog.Invoke($_)
                        }
                }
            }

        }
        catch {

            $AppendLog.Invoke(
                "ERRO ao instalar $($info.Id): " +
                $_.Exception.Message
            )
        }

        $completed++

        $progressBar.Value =
            [Math]::Min(
                $progressBar.Maximum,
                $completed
            )

        $lblStatus.Text =
            "Instalando... $completed de $totalJobs"

        [System.Windows.Forms.Application]::DoEvents()
    }

    $AppendLog.Invoke("")
    $AppendLog.Invoke(
        "=== INSTALACAO CONCLUIDA ==="
    )

    $lblStatus.Text =
        "Instalacao concluida."

    $btnInstallSelected.Enabled =
        $true

    [System.Windows.Forms.MessageBox]::Show(
        "Instalacao dos programas selecionados concluida.`n`nVerifique o log para detalhes.",
        "Instalacao concluida"
    )
})

# ============================================================
# EVENTO - SCRIPT EXTERNO
# ============================================================

$btnCustom.Add_Click({

    if (
        [string]::IsNullOrWhiteSpace($CustomScriptUrl)
    ) {

        [System.Windows.Forms.MessageBox]::Show(
            "URL do script externo nao configurada.",
            "Configuracao"
        )

        return
    }

    $confirm =
        [System.Windows.Forms.MessageBox]::Show(
            "Isso vai baixar e executar o script:`n`n" +
            "$CustomScriptUrl`n`n" +
            "Execute somente se voce confiar na fonte.`n`n" +
            "Deseja continuar?",
            "Confirmar execucao de script remoto",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

    if (
        $confirm -ne
        [System.Windows.Forms.DialogResult]::Yes
    ) {

        return
    }

    $btnCustom.Enabled =
        $false

    $AppendLog.Invoke(
        "== Executando script externo: $CustomScriptLabel =="
    )

    $AppendLog.Invoke(
        "URL: $CustomScriptUrl"
    )

    $tempScript =
        Join-Path `
            $env:TEMP `
            "MCNTV_custom_$(Get-Random).ps1"

    try {

        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor 3072

        $webClient =
            New-Object System.Net.WebClient

        $webClient.Headers.Add(
            "User-Agent",
            "Mozilla/5.0 Windows MCNTV-Installer"
        )

        $webClient.DownloadFile(
            $CustomScriptUrl,
            $tempScript
        )

        $webClient.Dispose()

        $AppendLog.Invoke(
            "Script baixado para:"
        )

        $AppendLog.Invoke(
            $tempScript
        )

        & powershell.exe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $tempScript 2>&1 |
            ForEach-Object {
                $AppendLog.Invoke($_)
            }

        $AppendLog.Invoke(
            "Script '$CustomScriptLabel' concluido."
        )

    }
    catch {

        $AppendLog.Invoke(
            "ERRO ao executar '$CustomScriptLabel': " +
            $_.Exception.Message
        )
    }
    finally {

        Remove-Item `
            -Path $tempScript `
            -Force `
            -ErrorAction SilentlyContinue

        $btnCustom.Enabled =
            $true
    }
})

# ============================================================
# MAPA DE DESINSTALACAO
# ============================================================

$script:UninstallMap = @{}

# ============================================================
# ATUALIZAR PROGRAMAS
# ============================================================

$btnRefreshInstalled.Add_Click({

    $btnRefreshInstalled.Enabled =
        $false

    try {

        $AppendLog.Invoke(
            "Consultando programas instalados..."
        )

        $clbUninstall.Items.Clear()

        $script:UninstallMap =
            @{}

        $programs =
            @(Get-InstalledProgramsList)

        foreach ($p in $programs) {

            if (
                -not $script:UninstallMap.ContainsKey(
                    $p.DisplayName
                )
            ) {

                $cmd =
                    if ($p.QuietUninstallString) {
                        $p.QuietUninstallString
                    }
                    else {
                        $p.UninstallString
                    }

                $script:UninstallMap[
                    $p.DisplayName
                ] = $cmd

                [void]$clbUninstall.Items.Add(
                    $p.DisplayName
                )
            }
        }

        $AppendLog.Invoke(
            "$($clbUninstall.Items.Count) programas encontrados."
        )

    }
    catch {

        $AppendLog.Invoke(
            "Erro ao consultar programas: " +
            $_.Exception.Message
        )
    }
    finally {

        $btnRefreshInstalled.Enabled =
            $true
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
            "Selecione ao menos um programa para remover.",
            "Aviso"
        )

        return
    }

    $confirm =
        [System.Windows.Forms.MessageBox]::Show(
            "Desinstalar os seguintes programas?`n`n" +
            ($selected -join "`n"),
            "Confirmar remocao",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

    if (
        $confirm -ne
        [System.Windows.Forms.DialogResult]::Yes
    ) {

        return
    }

    $btnUninstallSelected.Enabled =
        $false

    try {

        $AppendLog.Invoke(
            "== Desinstalando programas selecionados =="
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
                    $cmd -match "(?i)msiexec"
                ) {

                    if (
                        $cmd -notmatch "(?i)/qn|/quiet"
                    ) {

                        $cmd =
                            "$cmd /quiet /norestart"
                    }
                }

                Start-Process `
                    -FilePath "cmd.exe" `
                    -ArgumentList "/c $cmd" `
                    -Wait `
                    -ErrorAction Stop

                $AppendLog.Invoke(
                    "Concluido: $name"
                )

            }
            catch {

                $AppendLog.Invoke(
                    "ERRO ao desinstalar '$name': " +
                    $_.Exception.Message
                )
            }
        }

        $AppendLog.Invoke(
            "Remocao concluida."
        )

        $AppendLog.Invoke(
            "Clique em 'Atualizar lista' para atualizar."
        )

    }
    finally {

        $btnUninstallSelected.Enabled =
            $true
    }
})

# ============================================================
# BOTAO INSTALAR SITEF
# ============================================================

$btnSitefInstall.Add_Click({

    $btnSitefInstall.Enabled =
        $false

    $txtSitefLog.Clear()

    $progressSitef.Value = 0

    try {

        Install-Sitef

    }
    catch {

        $txtSitefLog.AppendText(
            "ERRO inesperado: " +
            $_.Exception.Message +
            "`r`n"
        )
    }
    finally {

        $btnSitefInstall.Enabled =
            $true
    }
})

# ============================================================
# ABRIR PASTA SITEF
# ============================================================

$btnSitefOpenFolder.Add_Click({

    $sitefDir =
        "C:\SITEF"

    if (
        Test-Path -LiteralPath $sitefDir
    ) {

        Start-Process `
            -FilePath "explorer.exe" `
            -ArgumentList "`"$sitefDir`""

    }
    else {

        [System.Windows.Forms.MessageBox]::Show(
            "A pasta C:\SITEF ainda nao existe.`n`nExecute a instalacao primeiro.",
            "Pasta nao encontrada"
        )
    }
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
            "Erro ao carregar lista inicial: " +
            $_.Exception.Message
        )
    }
})

# ============================================================
# FINAL
# ============================================================

[void]$form.ShowDialog()
