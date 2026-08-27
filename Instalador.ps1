<#
    MCNTV Installer
    Provisionamento de maquinas Windows

    REVISAO:
    - Corrigida auto-elevacao para Administrador
    - Corrigido funcionamento via irm | iex
    - Corrigido New-Object System.Drawing.Point com expressoes
    - Layout principal totalmente responsivo
    - Aba SITEF preservada
    - Botoes das tres colunas preservados
    - SITEF reorganizado com TableLayoutPanel
    - Status geral reorganizado
    - Corrigido selectedSteps
    - Melhor tratamento de erros
    - Melhor compatibilidade com PowerShell 5.1
#>

# ============================================================
# CONFIGURACAO DE EXECUCAO
# ============================================================

$scriptPath = $PSCommandPath

# Quando executado via:
# irm URL | iex
# $PSCommandPath pode estar vazio.
if ([string]::IsNullOrWhiteSpace($scriptPath)) {

    $bootstrapDir = Join-Path $env:TEMP "MCNTVInstaller"

    if (-not (Test-Path $bootstrapDir)) {
        New-Item -Path $bootstrapDir -ItemType Directory -Force | Out-Null
    }

    $scriptPath = Join-Path $bootstrapDir "ProvisioningTool.ps1"

    try {
        $scriptContent = $MyInvocation.MyCommand.Definition

        [System.IO.File]::WriteAllText(
            $scriptPath,
            $scriptContent,
            (New-Object System.Text.UTF8Encoding($false))
        )
    }
    catch {
        Write-Host "Erro ao criar copia temporaria do script:"
        Write-Host $_.Exception.Message
        exit 1
    }
}

# ============================================================
# AUTO-ELEVACAO
# ============================================================

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()

$principal = New-Object System.Security.Principal.WindowsPrincipal($currentIdentity)

$isAdmin = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {

    try {

        $psi = New-Object System.Diagnostics.ProcessStartInfo

        $psi.FileName = "powershell.exe"

        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""

        $psi.Verb = "runas"

        [System.Diagnostics.Process]::Start($psi) | Out-Null

    }
    catch {

        [System.Windows.Forms.MessageBox]::Show(
            "A execucao como Administrador foi cancelada.",
            "MCNTV Installer",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
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

# ============================================================
# CONFIGURACOES
# ============================================================

$CustomScriptUrl   = "https://get.activated.win"
$CustomScriptLabel = "Ativar Windows"

# ============================================================
# CATALOGO DE PROGRAMAS
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
# LOGS
# ============================================================

$ScriptDir = Split-Path -Parent $scriptPath

$LogsDir = Join-Path $ScriptDir "logs"

if (-not (Test-Path $LogsDir)) {
    New-Item -Path $LogsDir -ItemType Directory -Force | Out-Null
}

$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

$LogFilePath = Join-Path $LogsDir "provisionamento_$Timestamp.log"

$ReportPath = Join-Path $LogsDir "relatorio_$Timestamp.txt"

$script:Results = [ordered]@{}

$script:CancelRequested = $false

# ============================================================
# FUNCOES
# ============================================================

function Step-RestorePoint {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke("== Ponto de restauracao ==")

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULACAO] Criaria um ponto de restauracao antes das alteracoes."
        )

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
            "Aviso: nao foi possivel criar ponto de restauracao. $($_.Exception.Message)"
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
        "== Habilitar Versoes Anteriores / Shadow Copies em $drive =="
    )

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULACAO] Ativaria System Restore, reservaria 10% do volume e criaria snapshots."
        )

        return
    }

    try {

        Enable-ComputerRestore `
            -Drive "$drive\" `
            -ErrorAction Stop

        $Log.Invoke(
            "System Restore ativado em $drive"
        )

    }
    catch {

        $Log.Invoke(
            "Aviso ao ativar System Restore: $($_.Exception.Message)"
        )
    }

    try {

        $Log.Invoke(
            "Reservando espaco para Shadow Copies..."
        )

        vssadmin resize shadowstorage `
            /for="$drive" `
            /on="$drive" `
            /maxsize=10% `
            2>&1 |
            ForEach-Object {
                $Log.Invoke($_)
            }

    }
    catch {

        $Log.Invoke(
            "Erro ao configurar Shadow Storage: $($_.Exception.Message)"
        )
    }

    try {

        $Log.Invoke(
            "Criando snapshot inicial..."
        )

        vssadmin create shadow `
            /for="$drive" `
            2>&1 |
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
            /f |
            Out-Null

        $Log.Invoke(
            "Tarefa de Shadow Copy criada."
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
            "[SIMULACAO] Ativaria os icones."
        )

        return
    }

    try {

        $path =
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"

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

        Start-Process explorer

        $Log.Invoke(
            "Icones configurados."
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
            "Telemetria desativada."
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

    $Log.Invoke(
        "== Plano de energia =="
    )

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULACAO] Configuraria energia para nao desligar monitor, disco e suspensao."
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
        "== Fuso horario e localizacao Brasil =="
    )

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULACAO] Definiria fuso de Brasilia e Brasil."
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
            "Localizacao Brasil configurada."
        )

    }
    catch {

        $Log.Invoke(
            "Aviso ao configurar regiao: $($_.Exception.Message)"
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
        "== Remover aplicativos padrao =="
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
        Join-Path $env:ProgramData "chocolatey\bin"

    $chocoExe =
        Join-Path $chocoBin "choco.exe"

    if (Test-Path $chocoExe) {

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

    if (Get-Command choco -ErrorAction SilentlyContinue) {

        $Log.Invoke(
            "Chocolatey ja instalado."
        )

        return
    }

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULACAO] Instalaria Chocolatey."
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

        $Log.Invoke(
            "Chocolatey instalado."
        )

    }
    catch {

        throw "Falha ao instalar Chocolatey: $($_.Exception.Message)"
    }
}

# ============================================================

function Step-WingetUpgradeAll {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke(
        "== Preparando winget =="
    )

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULACAO] Executaria winget upgrade --all"
        )

        return
    }

    try {

        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {

            $Log.Invoke(
                "winget nao encontrado neste Windows."
            )

            return
        }

        winget source update 2>&1 |
            ForEach-Object {
                $Log.Invoke($_)
            }

        $Log.Invoke(
            "Atualizando aplicativos..."
        )

        winget upgrade `
            --all `
            --accept-source-agreements `
            --accept-package-agreements `
            --silent `
            2>&1 |
            ForEach-Object {
                $Log.Invoke($_)
            }

    }
    catch {

        $Log.Invoke(
            "Aviso no winget: $($_.Exception.Message)"
        )
    }
}

# ============================================================

function Step-TarefaLimpeza {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke(
        "== Tarefa de limpeza de disco =="
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
            "Erro ao criar tarefa: $($_.Exception.Message)"
        )
    }
}

# ============================================================
# CATALOGO
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

    $log.Invoke("========================================")
    $log.Invoke("INICIANDO INSTALACAO SITEF")
    $log.Invoke("========================================")
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

    if (-not (Test-Path $sitefDir)) {

        try {

            New-Item `
                -ItemType Directory `
                -Path $sitefDir `
                -Force |
                Out-Null

            $log.Invoke(
                "Diretorio C:\SITEF criado."
            )

        }
        catch {

            $log.Invoke(
                "ERRO ao criar C:\SITEF: $($_.Exception.Message)"
            )

            return
        }
    }

    $progressSitef.Maximum =
        $zipUrls.Count * 2

    $progressSitef.Value = 0

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
        # ARQUIVO JA EXISTENTE
        # ----------------------------------------------------

        if (Test-Path $zipPath) {

            $log.Invoke(
                "Arquivo existente: $fileName"
            )

            try {

                if (-not (Test-Path $extractPath)) {

                    New-Item `
                        -ItemType Directory `
                        -Path $extractPath `
                        -Force |
                        Out-Null
                }

                Expand-Archive `
                    -Path $zipPath `
                    -DestinationPath $extractPath `
                    -Force

                $log.Invoke(
                    "Arquivo existente extraido."
                )

                $progressSitef.Value += 2

                $itemStatus[$fileName] = $true

                continue
            }
            catch {

                $log.Invoke(
                    "Arquivo existente invalido. Sera baixado novamente."
                )

                Remove-Item `
                    $zipPath `
                    -Force `
                    -ErrorAction SilentlyContinue

                Remove-Item `
                    $extractPath `
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
                "Mozilla/5.0"
            )

            $webClient.DownloadFile(
                $url,
                $zipPath
            )

            $log.Invoke(
                "Download concluido: $fileName"
            )

            $progressSitef.Value += 1

        }
        catch {

            $log.Invoke(
                "ERRO ao baixar $fileName : $($_.Exception.Message)"
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

            if (-not $isZip) {

                $log.Invoke(
                    "ERRO: $fileName nao e um ZIP valido."
                )

                Remove-Item `
                    $zipPath `
                    -Force `
                    -ErrorAction SilentlyContinue

                continue
            }

        }
        catch {

            $log.Invoke(
                "ERRO ao validar ZIP: $($_.Exception.Message)"
            )

            continue
        }

        # ----------------------------------------------------
        # EXTRACAO
        # ----------------------------------------------------

        $log.Invoke(
            "Extraindo $fileName..."
        )

        try {

            if (-not (Test-Path $extractPath)) {

                New-Item `
                    -ItemType Directory `
                    -Path $extractPath `
                    -Force |
                    Out-Null
            }

            Expand-Archive `
                -Path $zipPath `
                -DestinationPath $extractPath `
                -Force

            $log.Invoke(
                "Extracao concluida."
            )

            $progressSitef.Value += 1

            $itemStatus[$fileName] = $true

        }
        catch {

            $log.Invoke(
                "Expand-Archive falhou."
            )

            try {

                [System.IO.Compression.ZipFile]::ExtractToDirectory(
                    $zipPath,
                    $extractPath,
                    $true
                )

                $log.Invoke(
                    "Extracao concluida via metodo alternativo."
                )

                $progressSitef.Value += 1

                $itemStatus[$fileName] = $true

            }
            catch {

                $log.Invoke(
                    "ERRO ao extrair $fileName : $($_.Exception.Message)"
                )
            }
        }
    }

    # ========================================================
    # VALIDACAO
    # ========================================================

    $log.Invoke("")
    $log.Invoke("Verificando arquivos necessarios...")

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
    # LOCALIZAR MSI
    # ========================================================

    $msiPath =
        Get-ChildItem `
            -Path $sitefDir `
            -Recurse `
            -Filter "GSurfRSA_Listener_Setup.msi" `
            -ErrorAction SilentlyContinue |
        Select-Object -First 1

    # ========================================================
    # LOCALIZAR EXE
    # ========================================================

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

        return
    }

    if (-not $exePath) {

        $log.Invoke(
            "ERRO: InstaladorGSurf.exe nao encontrado."
        )

        return
    }

    # ========================================================
    # MSI
    # ========================================================

    $log.Invoke("")
    $log.Invoke(
        "Executando MSI:"
    )

    $log.Invoke(
        $msiPath.FullName
    )

    try {

        $msiProcess =
            Start-Process `
                -FilePath "msiexec.exe" `
                -ArgumentList "/i `"$($msiPath.FullName)`"" `
                -Wait `
                -PassThru

        $log.Invoke(
            "MSI finalizado. Codigo: $($msiProcess.ExitCode)"
        )

    }
    catch {

        $log.Invoke(
            "ERRO MSI: $($_.Exception.Message)"
        )
    }

    # ========================================================
    # EXE
    # ========================================================

    $log.Invoke("")
    $log.Invoke(
        "Executando instalador EXE:"
    )

    $log.Invoke(
        $exePath.FullName
    )

    try {

        $exeProcess =
            Start-Process `
                -FilePath $exePath.FullName `
                -Wait `
                -PassThru

        $log.Invoke(
            "EXE finalizado. Codigo: $($exeProcess.ExitCode)"
        )

    }
    catch {

        $log.Invoke(
            "ERRO EXE: $($_.Exception.Message)"
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
                    "ERRO ao iniciar servico: $($_.Exception.Message)"
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

    $progressSitef.Value =
        $progressSitef.Maximum

    $log.Invoke("")
    $log.Invoke(
        "========================================"
    )
    $log.Invoke(
        "INSTALACAO SITEF FINALIZADA"
    )
    $log.Invoke(
        "========================================"
    )

    [System.Windows.Forms.MessageBox]::Show(
        "Processo de instalacao do SITEF finalizado.`n`nVerifique o log para detalhes.",
        "SITEF",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}

# ============================================================
# CORES
# ============================================================

$ColorBackground =
    [System.Drawing.Color]::FromArgb(
        245,
        247,
        250
    )

$ColorSurface =
    [System.Drawing.Color]::White

$ColorText =
    [System.Drawing.Color]::FromArgb(
        35,
        38,
        42
    )

$ColorMuted =
    [System.Drawing.Color]::FromArgb(
        95,
        102,
        110
    )

$ColorPrimary =
    [System.Drawing.Color]::FromArgb(
        0,
        120,
        215
    )

$ColorSuccess =
    [System.Drawing.Color]::FromArgb(
        40,
        150,
        90
    )

$ColorDanger =
    [System.Drawing.Color]::FromArgb(
        190,
        55,
        55
    )

$ColorBorder =
    [System.Drawing.Color]::FromArgb(
        210,
        215,
        222
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
        1150,
        780
    )

$form.MinimumSize =
    New-Object System.Drawing.Size(
        900,
        650
    )

$form.BackColor =
    $ColorBackground

$form.Font =
    $FontNormal

# ============================================================
# LAYOUT PRINCIPAL
# ============================================================

$rootLayout =
    New-Object System.Windows.Forms.TableLayoutPanel

$rootLayout.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$rootLayout.ColumnCount = 1
$rootLayout.RowCount = 3

$rootLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        70
    ))
) | Out-Null

$rootLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Percent,
        100
    ))
) | Out-Null

$rootLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        210
    ))
) | Out-Null

$rootLayout.BackColor =
    $ColorBackground

$form.Controls.Add(
    $rootLayout
)

# ============================================================
# CABECALHO
# ============================================================

$headerPanel =
    New-Object System.Windows.Forms.Panel

$headerPanel.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$headerPanel.BackColor =
    $ColorBackground

$rootLayout.Controls.Add(
    $headerPanel,
    0,
    0
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
        8
    )

$lblMainTitle.Size =
    New-Object System.Drawing.Size(
        600,
        32
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
        42
    )

$lblSubtitle.Size =
    New-Object System.Drawing.Size(
        600,
        22
    )

$headerPanel.Controls.Add(
    $lblSubtitle
)

# ============================================================
# CONTEUDO CENTRAL
# ============================================================

$contentPanel =
    New-Object System.Windows.Forms.Panel

$contentPanel.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$contentPanel.Padding =
    New-Object System.Windows.Forms.Padding(
        8
    )

$contentPanel.BackColor =
    $ColorBackground

$rootLayout.Controls.Add(
    $contentPanel,
    0,
    1
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

$tableLayout =
    New-Object System.Windows.Forms.TableLayoutPanel

$tableLayout.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$tableLayout.ColumnCount = 3
$tableLayout.RowCount = 1

$tableLayout.Padding =
    New-Object System.Windows.Forms.Padding(
        8
    )

$tableLayout.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Percent,
        33.33
    ))
) | Out-Null

$tableLayout.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Percent,
        33.33
    ))
) | Out-Null

$tableLayout.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Percent,
        33.34
    ))
) | Out-Null

$tableLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Percent,
        100
    ))
) | Out-Null

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

$panelSystem.AutoScroll = $true

$grpSystem.Controls.Add(
    $panelSystem
)

# ============================================================
# ETAPAS
# ============================================================

$steps =
    [ordered]@{

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
            5,
            $y
        )

    $cb.Size =
        New-Object System.Drawing.Size(
            350,
            24
        )

    $cb.Font =
        $FontNormal

    $cb.ForeColor =
        $ColorText

    $cb.Anchor =
        [System.Windows.Forms.AnchorStyles]::Top -bor
        [System.Windows.Forms.AnchorStyles]::Left -bor
        [System.Windows.Forms.AnchorStyles]::Right

    $panelSystem.Controls.Add(
        $cb
    )

    $checkboxes[$key] =
        $cb

    $y += 27
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
        5,
        $yDryRun
    )

$chkDryRun.Size =
    New-Object System.Drawing.Size(
        350,
        24
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
    $y + 38

$btnSelAll =
    New-Object System.Windows.Forms.Button

$btnSelAll.Text =
    "Marcar todos"

$btnSelAll.Location =
    New-Object System.Drawing.Point(
        5,
        $yButtons
    )

$btnSelAll.Size =
    New-Object System.Drawing.Size(
        145,
        32
    )

$btnSelAll.Font =
    $FontButton

$btnSelAll.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

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
        160,
        $yButtons
    )

$btnSelNone.Size =
    New-Object System.Drawing.Size(
        145,
        32
    )

$btnSelNone.Font =
    $FontButton

$btnSelNone.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

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

$btnRun =
    New-Object System.Windows.Forms.Button

$btnRun.Text =
    "EXECUTAR CONFIGURACAO"

$btnRun.Location =
    New-Object System.Drawing.Point(
        5,
        ($yButtons + 42)
    )

$btnRun.Size =
    New-Object System.Drawing.Size(
        300,
        38
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

$installLayout =
    New-Object System.Windows.Forms.TableLayoutPanel

$installLayout.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$installLayout.ColumnCount = 1
$installLayout.RowCount = 3

$installLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        30
    ))
) | Out-Null

$installLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Percent,
        100
    ))
) | Out-Null

$installLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        48
    ))
) | Out-Null

$grpInstall.Controls.Add(
    $installLayout
)

# ============================================================
# BUSCA
# ============================================================

$txtSearchInstall =
    New-Object System.Windows.Forms.TextBox

$txtSearchInstall.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$txtSearchInstall.Font =
    $FontNormal

$txtSearchInstall.Margin =
    New-Object System.Windows.Forms.Padding(
        0,
        0,
        0,
        5
    )

$txtSearchInstall.Text =
    ""

$installLayout.Controls.Add(
    $txtSearchInstall,
    0,
    0
)

# ============================================================
# CHECKED LIST
# ============================================================

$clbInstall =
    New-Object System.Windows.Forms.CheckedListBox

$clbInstall.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$clbInstall.CheckOnClick =
    $true

$clbInstall.Font =
    $FontNormal

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

$installLayout.Controls.Add(
    $clbInstall,
    0,
    1
)

# ============================================================
# BOTAO INSTALAR
# ============================================================

$btnInstallSelected =
    New-Object System.Windows.Forms.Button

$btnInstallSelected.Text =
    "INSTALAR SELECIONADOS"

$btnInstallSelected.Dock =
    [System.Windows.Forms.DockStyle]::Fill

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

$installLayout.Controls.Add(
    $btnInstallSelected,
    0,
    2
)

# ============================================================
# FILTRO
# ============================================================

$txtSearchInstall.Add_TextChanged({

    $search =
        $txtSearchInstall.Text.Trim().ToLower()

    $clbInstall.BeginUpdate()

    $clbInstall.Items.Clear()

    $all =
        $clbInstall.Tag

    foreach ($item in $all) {

        if (
            [string]::IsNullOrWhiteSpace($search) -or
            $item.ToLower().Contains($search)
        ) {

            [void]$clbInstall.Items.Add(
                $item,
                $true
            )
        }
    }

    $clbInstall.EndUpdate()
})

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

$uninstallLayout =
    New-Object System.Windows.Forms.TableLayoutPanel

$uninstallLayout.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$uninstallLayout.ColumnCount = 1
$uninstallLayout.RowCount = 3

$uninstallLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        30
    ))
) | Out-Null

$uninstallLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Percent,
        100
    ))
) | Out-Null

$uninstallLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        78
    ))
) | Out-Null

$grpUninstall.Controls.Add(
    $uninstallLayout
)

# ============================================================
# LABEL
# ============================================================

$lblUninstallInfo =
    New-Object System.Windows.Forms.Label

$lblUninstallInfo.Text =
    "Programas instalados:"

$lblUninstallInfo.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$lblUninstallInfo.ForeColor =
    $ColorMuted

$uninstallLayout.Controls.Add(
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

$clbUninstall.CheckOnClick =
    $true

$clbUninstall.Font =
    $FontNormal

$uninstallLayout.Controls.Add(
    $clbUninstall,
    0,
    1
)

# ============================================================
# BOTOES DESINSTALACAO
# ============================================================

$uninstallButtons =
    New-Object System.Windows.Forms.TableLayoutPanel

$uninstallButtons.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$uninstallButtons.ColumnCount = 2
$uninstallButtons.RowCount = 1

$uninstallButtons.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Percent,
        50
    ))
) | Out-Null

$uninstallButtons.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Percent,
        50
    ))
) | Out-Null

$uninstallLayout.Controls.Add(
    $uninstallButtons,
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

$btnRefreshInstalled.BackColor =
    $ColorSurface

$btnRefreshInstalled.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$uninstallButtons.Controls.Add(
    $btnRefreshInstalled,
    0,
    0
)

$btnUninstallSelected =
    New-Object System.Windows.Forms.Button

$btnUninstallSelected.Text =
    "DESINSTALAR"

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

$uninstallButtons.Controls.Add(
    $btnUninstallSelected,
    1,
    0
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

# ============================================================
# LAYOUT SITEF
# ============================================================

$sitefLayout =
    New-Object System.Windows.Forms.TableLayoutPanel

$sitefLayout.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$sitefLayout.Padding =
    New-Object System.Windows.Forms.Padding(
        20
    )

$sitefLayout.ColumnCount = 1
$sitefLayout.RowCount = 5

$sitefLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        35
    ))
) | Out-Null

$sitefLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        65
    ))
) | Out-Null

$sitefLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        45
    ))
) | Out-Null

$sitefLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        25
    ))
) | Out-Null

$sitefLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Percent,
        100
    ))
) | Out-Null

$tabSitef.Controls.Add(
    $sitefLayout
)

# ============================================================
# TITULO SITEF
# ============================================================

$lblSitefTitle =
    New-Object System.Windows.Forms.Label

$lblSitefTitle.Text =
    "Instalacao do Ambiente SITEF"

$lblSitefTitle.Font =
    New-Object System.Drawing.Font(
        "Segoe UI Semibold",
        13
    )

$lblSitefTitle.ForeColor =
    $ColorText

$lblSitefTitle.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$sitefLayout.Controls.Add(
    $lblSitefTitle,
    0,
    0
)

# ============================================================
# DESCRICAO
# ============================================================

$lblSitefDesc =
    New-Object System.Windows.Forms.Label

$lblSitefDesc.Text =
    "Esta etapa baixa, extrai e executa os instaladores do SITEF.`r`n" +
    "Os instaladores devem ser configurados manualmente quando necessario.`r`n" +
    "Ao final, o servico GSurfRSA Listener sera verificado."

$lblSitefDesc.Font =
    $FontNormal

$lblSitefDesc.ForeColor =
    $ColorMuted

$lblSitefDesc.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$sitefLayout.Controls.Add(
    $lblSitefDesc,
    0,
    1
)

# ============================================================
# BOTOES SITEF
# ============================================================

$sitefButtons =
    New-Object System.Windows.Forms.TableLayoutPanel

$sitefButtons.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$sitefButtons.ColumnCount = 2
$sitefButtons.RowCount = 1

$sitefButtons.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        180
    ))
) | Out-Null

$sitefButtons.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        180
    ))
) | Out-Null

$sitefLayout.Controls.Add(
    $sitefButtons,
    0,
    2
)

$btnSitefInstall =
    New-Object System.Windows.Forms.Button

$btnSitefInstall.Text =
    "INSTALAR SITEF"

$btnSitefInstall.Dock =
    [System.Windows.Forms.DockStyle]::Fill

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

$sitefButtons.Controls.Add(
    $btnSitefInstall,
    0,
    0
)

$btnSitefOpenFolder =
    New-Object System.Windows.Forms.Button

$btnSitefOpenFolder.Text =
    "Abrir C:\SITEF"

$btnSitefOpenFolder.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$btnSitefOpenFolder.Font =
    $FontButton

$btnSitefOpenFolder.BackColor =
    $ColorSurface

$btnSitefOpenFolder.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$sitefButtons.Controls.Add(
    $btnSitefOpenFolder,
    1,
    0
)

# ============================================================
# PROGRESS SITEF
# ============================================================

$progressSitef =
    New-Object System.Windows.Forms.ProgressBar

$progressSitef.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$progressSitef.Minimum = 0
$progressSitef.Maximum = 100
$progressSitef.Value = 0

$sitefLayout.Controls.Add(
    $progressSitef,
    0,
    3
)

# ============================================================
# LOG SITEF
# ============================================================

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
        8
    )

$txtSitefLog.BackColor =
    [System.Drawing.Color]::White

$sitefLayout.Controls.Add(
    $txtSitefLog,
    0,
    4
)

# ============================================================
# STATUS GERAL
# ============================================================

$statusPanel =
    New-Object System.Windows.Forms.Panel

$statusPanel.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$statusPanel.Padding =
    New-Object System.Windows.Forms.Padding(
        8,
        0,
        8,
        8
    )

$statusPanel.BackColor =
    $ColorBackground

$rootLayout.Controls.Add(
    $statusPanel,
    0,
    2
)

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

$statusLayout =
    New-Object System.Windows.Forms.TableLayoutPanel

$statusLayout.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$statusLayout.ColumnCount = 1
$statusLayout.RowCount = 3

$statusLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        25
    ))
) | Out-Null

$statusLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        25
    ))
) | Out-Null

$statusLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Percent,
        100
    ))
) | Out-Null

$grpStatus.Controls.Add(
    $statusLayout
)

$progressBar =
    New-Object System.Windows.Forms.ProgressBar

$progressBar.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$progressBar.Minimum = 0
$progressBar.Maximum = 100
$progressBar.Value = 0

$statusLayout.Controls.Add(
    $progressBar,
    0,
    0
)

$lblStatus =
    New-Object System.Windows.Forms.Label

$lblStatus.Text =
    "Pronto para instalar"

$lblStatus.ForeColor =
    $ColorSuccess

$lblStatus.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$statusLayout.Controls.Add(
    $lblStatus,
    0,
    1
)

$txtLog =
    New-Object System.Windows.Forms.TextBox

$txtLog.Multiline = $true

$txtLog.ScrollBars =
    [System.Windows.Forms.ScrollBars]::Vertical

$txtLog.ReadOnly = $true

$txtLog.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$txtLog.Font =
    New-Object System.Drawing.Font(
        "Consolas",
        8
    )

$txtLog.BackColor =
    [System.Drawing.Color]::White

$statusLayout.Controls.Add(
    $txtLog,
    0,
    2
)

# ============================================================
# LOG
# ============================================================

$AppendLog = {

    param(
        $msg
    )

    $line =
        "$msg"

    try {

        $txtLog.AppendText(
            "$line`r`n"
        )

        $txtLog.SelectionStart =
            $txtLog.Text.Length

        $txtLog.ScrollToCaret()

        Add-Content `
            -Path $LogFilePath `
            -Value $line `
            -Encoding UTF8

    }
    catch {
    }

    [System.Windows.Forms.Application]::DoEvents()
}

$script:SitefLogDelegate = {

    param(
        $msg
    )

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
# EXECUTAR CONFIGURACAO
# ============================================================

$btnRun.Add_Click({

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

        return
    }

    $btnRun.Enabled = $false
    $btnSelAll.Enabled = $false
    $btnSelNone.Enabled = $false

    $txtLog.Clear()

    $script:CancelRequested = $false

    $DryRun =
        $chkDryRun.Checked

    $script:Results =
        [ordered]@{}

    $AppendLog.Invoke(
        "========================================"
    )

    $AppendLog.Invoke(
        "INICIANDO PROVISIONAMENTO"
    )

    $AppendLog.Invoke(
        "Modo: $(if ($DryRun) {'SIMULACAO'} else {'EXECUCAO REAL'})"
    )

    $AppendLog.Invoke(
        "========================================"
    )

    $progressBar.Maximum =
        $selectedSteps.Count

    $progressBar.Value = 0

    foreach ($key in $selectedSteps) {

        $lblStatus.Text =
            "Executando: $key"

        $AppendLog.Invoke("")
        $AppendLog.Invoke(
            ">>> $key"
        )

        try {

            & $steps[$key] `
                $AppendLog `
                $DryRun

            $script:Results[$key] =
                if ($DryRun) {
                    "SIMULADO"
                }
                else {
                    "OK"
                }

        }
        catch {

            $script:Results[$key] =
                "FALHA: $($_.Exception.Message)"

            $AppendLog.Invoke(
                "ERRO: $($_.Exception.Message)"
            )
        }

        if (
            $progressBar.Value -lt
            $progressBar.Maximum
        ) {

            $progressBar.Value++
        }

        [System.Windows.Forms.Application]::DoEvents()
    }

    $AppendLog.Invoke("")
    $AppendLog.Invoke(
        "========================================"
    )
    $AppendLog.Invoke(
        "PROVISIONAMENTO CONCLUIDO"
    )
    $AppendLog.Invoke(
        "========================================"
    )

    $reportLines = @()

    $reportLines +=
        "Relatorio de Provisionamento - $Timestamp"

    $reportLines +=
        "Modo: $(if ($DryRun) {'SIMULACAO'} else {'EXECUCAO REAL'})"

    $reportLines += ""

    foreach ($k in $script:Results.Keys) {

        $reportLines +=
            ("{0,-45} {1}" -f
                $k,
                $script:Results[$k]
            )
    }

    $reportLines |
        Set-Content `
            -Path $ReportPath `
            -Encoding UTF8

    $AppendLog.Invoke(
        "Relatorio salvo em: $ReportPath"
    )

    $lblStatus.Text =
        "Provisionamento concluido."

    $btnRun.Enabled = $true
    $btnSelAll.Enabled = $true
    $btnSelNone.Enabled = $true

    [System.Windows.Forms.MessageBox]::Show(
        "Provisionamento concluido.`n`nRelatorio:`n$ReportPath",
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
            "Selecione ao menos um programa.",
            "Aviso"
        )

        return
    }

    $btnInstallSelected.Enabled =
        $false

    $AppendLog.Invoke("")
    $AppendLog.Invoke(
        "== INSTALACAO DE APLICATIVOS =="
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

    foreach ($label in $selectedLabels) {

        $info =
            $script:AppCatalogMap[$label]

        if (-not $info) {
            continue
        }

        $AppendLog.Invoke(
            "Instalando: $($info.Id)"
        )

        try {

            switch ($info.Manager) {

                "choco" {

                    $output =
                        choco install `
                            $info.Id `
                            -y `
                            --force `
                            --ignore-checksums `
                            2>&1

                }

                "winget" {

                    $output =
                        winget install `
                            -e `
                            --id $info.Id `
                            --accept-source-agreements `
                            --accept-package-agreements `
                            --silent `
                            2>&1
                }

                "wingetStore" {

                    $output =
                        winget install `
                            --id $info.Id `
                            --source msstore `
                            --accept-source-agreements `
                            --accept-package-agreements `
                            --silent `
                            2>&1
                }
            }

            foreach ($line in $output) {

                $AppendLog.Invoke(
                    $line
                )
            }

        }
        catch {

            $AppendLog.Invoke(
                "ERRO ao instalar $($info.Id): $($_.Exception.Message)"
            )
        }
    }

    $AppendLog.Invoke(
        "Instalacao de aplicativos concluida."
    )

    $lblStatus.Text =
        "Instalacao concluida."

    $btnInstallSelected.Enabled =
        $true
})

# ============================================================
# BOTAO ATIVACAO
# ============================================================

$btnCustom =
    New-Object System.Windows.Forms.Button

# Botao opcional colocado na barra inferior da coluna 3.
# Adicionamos abaixo do layout de desinstalacao.
# Mantido fora da area principal para nao esconder a lista.

$btnCustom.Text =
    $CustomScriptLabel

$btnCustom.Font =
    $FontButton

$btnCustom.BackColor =
    $ColorSurface

$btnCustom.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnCustom.FlatAppearance.BorderColor =
    $ColorBorder

# ============================================================
# EXECUTAR SCRIPT EXTERNO
# ============================================================

$btnCustom.Add_Click({

    if (
        [string]::IsNullOrWhiteSpace(
            $CustomScriptUrl
        )
    ) {

        return
    }

    $confirm =
        [System.Windows.Forms.MessageBox]::Show(
            "Isso vai baixar e executar:`n`n$CustomScriptUrl`n`nConfirma?",
            "Confirmar",
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

    try {

        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor 3072

        $tempScript =
            Join-Path `
                $env:TEMP `
                "MCNTV_custom_$(Get-Random).ps1"

        $wc =
            New-Object System.Net.WebClient

        $wc.DownloadFile(
            $CustomScriptUrl,
            $tempScript
        )

        $AppendLog.Invoke(
            "Script baixado."
        )

        & $tempScript 2>&1 |
            ForEach-Object {
                $AppendLog.Invoke($_)
            }

        Remove-Item `
            $tempScript `
            -Force `
            -ErrorAction SilentlyContinue

    }
    catch {

        $AppendLog.Invoke(
            "ERRO: $($_.Exception.Message)"
        )
    }

    $btnCustom.Enabled =
        $true
})

# ============================================================
# DESINSTALACAO
# ============================================================

$script:UninstallMap = @{}

$btnRefreshInstalled.Add_Click({

    $btnRefreshInstalled.Enabled =
        $false

    $AppendLog.Invoke(
        "Consultando programas instalados..."
    )

    $clbUninstall.Items.Clear()

    $script:UninstallMap =
        @{}

    $programs =
        Get-InstalledProgramsList

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

    $btnRefreshInstalled.Enabled =
        $true
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
            "Desinstalar:`n`n$($selected -join "`n")",
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

    foreach ($name in $selected) {

        $cmd =
            $script:UninstallMap[$name]

        if (-not $cmd) {
            continue
        }

        $AppendLog.Invoke(
            "Desinstalando: $name"
        )

        try {

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
                "ERRO: $($_.Exception.Message)"
            )
        }
    }

    $AppendLog.Invoke(
        "Remocao concluida."
    )

    $btnUninstallSelected.Enabled =
        $true
})

# ============================================================
# SITEF
# ============================================================

$btnSitefInstall.Add_Click({

    $btnSitefInstall.Enabled =
        $false

    $txtSitefLog.Clear()

    $progressSitef.Value =
        0

    try {

        Install-Sitef

    }
    catch {

        $txtSitefLog.AppendText(
            "ERRO inesperado: $($_.Exception.Message)`r`n"
        )
    }

    $btnSitefInstall.Enabled =
        $true
})

# ============================================================

$btnSitefOpenFolder.Add_Click({

    $sitefDir =
        "C:\SITEF"

    if (Test-Path $sitefDir) {

        Start-Process explorer.exe $sitefDir

    }
    else {

        [System.Windows.Forms.MessageBox]::Show(
            "A pasta C:\SITEF ainda nao existe.",
            "Pasta nao encontrada"
        )
    }
})

# ============================================================
# ADICIONAR BOTAO ATIVAR WINDOWS
# ============================================================

# O botao fica abaixo da lista de programas instalados.
# Para evitar que ele altere o tamanho da lista,
# criamos uma barra inferior no GroupBox 3.

$grpUninstall.Controls.Add(
    $btnCustom
)

$btnCustom.Dock =
    [System.Windows.Forms.DockStyle]::Bottom

$btnCustom.Height =
    32

$btnCustom.BringToFront()

# ============================================================
# CARREGAR PROGRAMAS AO ABRIR
# ============================================================

$form.Add_Shown({

    try {

        $btnRefreshInstalled.PerformClick()

    }
    catch {

        $AppendLog.Invoke(
            "Erro ao carregar programas: $($_.Exception.Message)"
        )
    }
})

# ============================================================
# EXIBIR
# ============================================================

[void]$form.ShowDialog()
