<#
    ProvisioningTool.ps1
    MCNTV Installer - Provisionamento Windows

    VERSÃO REVISADA

    Principais correções:
    - Compatível com execução local e irm ... | iex
    - Autoelevação para Administrador
    - Layout responsivo com TableLayoutPanel
    - Instalação de aplicativos controlada/sequencial
    - Validação de ExitCode do winget/choco/MSI/EXE
    - Pesquisa sem perder seleção dos aplicativos
    - Pesquisa na lista de programas instalados
    - Desinstalação com validação de retorno
    - Resultados zerados a cada execução
    - Log principal e log SITEF integrados
    - Download SITEF com validação dos ZIPs
    - Validação dos instaladores SITEF
    - Verificação do serviço GSurfRSA Listener
    - Relatório final detalhado
    - Modo Dry-Run
    - Cancelamento de execução
#>

# ============================================================
# CONFIGURAÇÃO DE EXECUÇÃO
# ============================================================

$scriptPath = $PSCommandPath

if ([string]::IsNullOrWhiteSpace($scriptPath)) {

    $bootstrapDir = Join-Path $env:TEMP "MCNTVInstaller"

    if (-not (Test-Path $bootstrapDir)) {
        New-Item `
            -Path $bootstrapDir `
            -ItemType Directory `
            -Force |
            Out-Null
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
    [Security.Principal.WindowsPrincipal]
    [Security.Principal.WindowsIdentity]::GetCurrent()
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

        Write-Host "Elevação cancelada pelo usuário."

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

$CustomScriptUrl   = "https://get.activated.win"
$CustomScriptLabel = "Ativar Windows"

# ============================================================
# CATÁLOGO DE APLICATIVOS
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
# DIRETÓRIOS DE LOG
# ============================================================

$ScriptDir = Split-Path -Parent $scriptPath

$LogsDir = Join-Path $ScriptDir "logs"

if (-not (Test-Path $LogsDir)) {

    New-Item `
        -Path $LogsDir `
        -ItemType Directory `
        -Force |
        Out-Null
}

$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

$LogFilePath = Join-Path `
    $LogsDir `
    "provisionamento_$Timestamp.log"

$ReportPath = Join-Path `
    $LogsDir `
    "relatorio_$Timestamp.txt"

# ============================================================
# ESTADO GLOBAL
# ============================================================

$script:Results = [ordered]@{}

$script:CancelRequested = $false

$script:IsBusy = $false

$script:UninstallMap = @{}

$script:AppCatalogMap = @{}

# ============================================================
# FUNÇÃO AUXILIAR DE CANCELAMENTO
# ============================================================

function Test-CancelRequested {

    if ($script:CancelRequested) {

        throw "Operação cancelada pelo usuário."

    }

}

# ============================================================
# FUNÇÃO AUXILIAR DE LOG
# ============================================================

function Write-Log {

    param(
        [string]$Message
    )

    $line = "$Message"

    try {

        if ($txtLog -and -not $txtLog.IsDisposed) {

            $txtLog.AppendText(
                "$line`r`n"
            )

            $txtLog.SelectionStart = $txtLog.Text.Length

            $txtLog.ScrollToCaret()

        }

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

    try {

        [System.Windows.Forms.Application]::DoEvents()

    }
    catch {
    }
}

# ============================================================
# LOG SITEF
# ============================================================

function Write-SitefLog {

    param(
        [string]$Message
    )

    $line = "$Message"

    try {

        if ($txtSitefLog -and -not $txtSitefLog.IsDisposed) {

            $txtSitefLog.AppendText(
                "$line`r`n"
            )

            $txtSitefLog.SelectionStart = $txtSitefLog.Text.Length

            $txtSitefLog.ScrollToCaret()

        }

    }
    catch {
    }

    try {

        Add-Content `
            -Path $LogFilePath `
            -Value "[SITEF] $line" `
            -Encoding UTF8

    }
    catch {
    }

    try {

        [System.Windows.Forms.Application]::DoEvents()

    }
    catch {
    }
}

# ============================================================
# EXECUÇÃO DE PROCESSO
# ============================================================

function Invoke-ExternalProcess {

    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string]$Arguments,

        [scriptblock]$Log,

        [string]$Description = $FilePath
    )

    if ($Log) {
        & $Log "Executando: $Description"
        & $Log "Comando: $FilePath $Arguments"
    }

    try {

        $process = Start-Process `
            -FilePath $FilePath `
            -ArgumentList $Arguments `
            -Wait `
            -PassThru `
            -WindowStyle Hidden `
            -ErrorAction Stop

        $exitCode = $process.ExitCode

        if ($Log) {
            & $Log "ExitCode: $exitCode"
        }

        return $exitCode

    }
    catch {

        if ($Log) {
            & $Log "ERRO ao executar processo: $($_.Exception.Message)"
        }

        return -1
    }
}

# ============================================================
# ETAPA - PONTO DE RESTAURAÇÃO
# ============================================================

function Step-RestorePoint {

    param(
        $Log,
        [bool]$DryRun
    )

    & $Log "== Ponto de restauração =="

    if ($DryRun) {

        & $Log "[SIMULAÇÃO] Criaria um ponto de restauração antes das alterações."

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

        & $Log "Ponto de restauração criado."

    }
    catch {

        & $Log "AVISO: não foi possível criar ponto de restauração."

        & $Log $_.Exception.Message
    }
}

# ============================================================
# ETAPA - VERSÕES ANTERIORES / SHADOW COPY
# ============================================================

function Step-VersoesAnteriores {

    param(
        $Log,
        [bool]$DryRun
    )

    $drive = $env:SystemDrive

    & $Log "== Habilitar Versões Anteriores (Shadow Copy) em $drive =="

    if ($DryRun) {

        & $Log "[SIMULAÇÃO] Ativaria System Restore."

        & $Log "[SIMULAÇÃO] Reservaria 10% do volume para Shadow Copies."

        & $Log "[SIMULAÇÃO] Criaria snapshot inicial."

        & $Log "[SIMULAÇÃO] Criaria tarefa para snapshot a cada 4 horas."

        return
    }

    try {

        Enable-ComputerRestore `
            -Drive "$drive\" `
            -ErrorAction Stop

        & $Log "System Restore ativado em $drive"

    }
    catch {

        & $Log "AVISO ao ativar System Restore: $($_.Exception.Message)"
    }

    & $Log "Configurando armazenamento de Shadow Copy..."

    try {

        vssadmin resize shadowstorage `
            /for="$drive" `
            /on="$drive" `
            /maxsize=10% `
            2>&1 |
            ForEach-Object {
                & $Log $_
            }

    }
    catch {

        & $Log "AVISO: erro ao configurar Shadow Storage."

    }

    & $Log "Criando snapshot inicial..."

    try {

        vssadmin create shadow `
            /for="$drive" `
            2>&1 |
            ForEach-Object {
                & $Log $_
            }

    }
    catch {

        & $Log "AVISO: erro ao criar snapshot inicial."
    }

    & $Log "Criando tarefa agendada..."

    $taskResult = schtasks `
        /create `
        /tn "VersoesAnteriores_ShadowCopy" `
        /tr "vssadmin create shadow /for=$drive" `
        /sc hourly `
        /mo 4 `
        /ru "SYSTEM" `
        /rl highest `
        /f `
        2>&1

    foreach ($line in $taskResult) {
        & $Log $line
    }

    if ($LASTEXITCODE -eq 0) {

        & $Log "Tarefa 'VersoesAnteriores_ShadowCopy' criada."

    }
    else {

        & $Log "AVISO: não foi possível criar a tarefa agendada."

    }

    & $Log "Snapshot automático configurado para cada 4 horas."
}

# ============================================================
# ETAPA - ÍCONES
# ============================================================

function Step-IconesAreaTrabalho {

    param(
        $Log,
        [bool]$DryRun
    )

    & $Log "== Ícones da Área de Trabalho =="

    if ($DryRun) {

        & $Log "[SIMULAÇÃO] Ativaria Este Computador."

        & $Log "[SIMULAÇÃO] Ativaria Pasta do Usuário."

        & $Log "[SIMULAÇÃO] Reiniciaria o Explorer."

        return
    }

    try {

        $path = `
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

        Start-Process explorer.exe

        & $Log "Ícones configurados e Explorer reiniciado."

    }
    catch {

        throw "Falha ao configurar ícones: $($_.Exception.Message)"
    }
}

# ============================================================
# ETAPA - TELEMETRIA
# ============================================================

function Step-Telemetria {

    param(
        $Log,
        [bool]$DryRun
    )

    & $Log "== Telemetria =="

    if ($DryRun) {

        & $Log "[SIMULAÇÃO] Desativaria telemetria via política local."

        return
    }

    try {

        $path = `
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

        & $Log "Política de telemetria configurada."

    }
    catch {

        throw "Falha ao configurar telemetria: $($_.Exception.Message)"
    }
}

# ============================================================
# ETAPA - ENERGIA
# ============================================================

function Step-Energia {

    param(
        $Log,
        [bool]$DryRun
    )

    & $Log "== Plano de energia =="

    if ($DryRun) {

        & $Log "[SIMULAÇÃO] Desativaria timeout do monitor."

        & $Log "[SIMULAÇÃO] Desativaria suspensão."

        & $Log "[SIMULAÇÃO] Desativaria hibernação."

        & $Log "[SIMULAÇÃO] Desativaria timeout do disco."

        return
    }

    $commands = @(
        "powercfg /change monitor-timeout-ac 0",
        "powercfg /change monitor-timeout-dc 0",
        "powercfg /change standby-timeout-ac 0",
        "powercfg /change standby-timeout-dc 0",
        "powercfg /change hibernate-timeout-ac 0",
        "powercfg /change hibernate-timeout-dc 0",
        "powercfg /change disk-timeout-ac 0",
        "powercfg /change disk-timeout-dc 0"
    )

    foreach ($command in $commands) {

        & $Log "Executando: $command"

        cmd.exe /c $command 2>&1 |
            ForEach-Object {
                & $Log $_
            }
    }

    & $Log "Plano de energia ajustado."
}

# ============================================================
# ETAPA - REGIÃO / FUSO
# ============================================================

function Step-RegiaoIdioma {

    param(
        $Log,
        [bool]$DryRun
    )

    & $Log "== Fuso horário e localização (Brasil) =="

    if ($DryRun) {

        & $Log "[SIMULAÇÃO] Definiria fuso horário de Brasília."

        & $Log "[SIMULAÇÃO] Definiria localização Brasil."

        return
    }

    try {

        Set-TimeZone `
            -Id "E. South America Standard Time" `
            -ErrorAction Stop

        & $Log "Fuso horário configurado."

    }
    catch {

        & $Log "AVISO ao configurar fuso: $($_.Exception.Message)"
    }

    try {

        if (Get-Command Set-WinHomeLocation -ErrorAction SilentlyContinue) {

            Set-WinHomeLocation `
                -GeoId 76 `
                -ErrorAction Stop

            & $Log "Localização Brasil configurada."

        }
        else {

            & $Log "Set-WinHomeLocation não está disponível neste Windows."

        }

    }
    catch {

        & $Log "AVISO ao configurar localização: $($_.Exception.Message)"
    }

    & $Log "Layout de teclado/idioma pode exigir configuração adicional."
}

# ============================================================
# ETAPA - DEBLOAT
# ============================================================

function Step-Debloat {

    param(
        $Log,
        [bool]$DryRun
    )

    & $Log "== Remover aplicativos padrão =="

    $apps = @(
        "3dbuilder",
        "bingweather",
        "xboxapp",
        "zunemusic",
        "officehub",
        "skypeapp"
    )

    if ($DryRun) {

        & $Log "[SIMULAÇÃO] Removeria: $($apps -join ', ')"

        return
    }

    foreach ($a in $apps) {

        Test-CancelRequested

        & $Log "Processando: $a"

        try {

            Get-AppxPackage `
                "*$a*" `
                -ErrorAction SilentlyContinue |
                Remove-AppxPackage `
                    -ErrorAction SilentlyContinue

        }
        catch {
        }

        try {

            Get-AppxProvisionedPackage `
                -Online `
                -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.DisplayName -like "*$a*"
                } |
                Remove-AppxProvisionedPackage `
                    -Online `
                    -ErrorAction SilentlyContinue |
                Out-Null

        }
        catch {
        }

        & $Log "Processado: $a"
    }

    & $Log "Debloat concluído."
}

# ============================================================
# CHOCOLATEY - VERIFICAÇÃO
# ============================================================

function Ensure-ChocoAvailable {

    param(
        $Log
    )

    if (Get-Command choco -ErrorAction SilentlyContinue) {

        return $true
    }

    $machinePath = `
        [System.Environment]::GetEnvironmentVariable(
            "Path",
            "Machine"
        )

    $userPath = `
        [System.Environment]::GetEnvironmentVariable(
            "Path",
            "User"
        )

    $env:Path = "$machinePath;$userPath"

    if (Get-Command choco -ErrorAction SilentlyContinue) {

        return $true
    }

    $chocoBin = `
        Join-Path `
            $env:ProgramData `
            "chocolatey\bin"

    $chocoExe = `
        Join-Path `
            $chocoBin `
            "choco.exe"

    if (Test-Path $chocoExe) {

        $env:Path += ";$chocoBin"

        return $true
    }

    if ($Log) {

        & $Log `
            "Chocolatey não encontrado."
    }

    return $false
}

# ============================================================
# ETAPA - CHOCOLATEY
# ============================================================

function Step-Chocolatey {

    param(
        $Log,
        [bool]$DryRun
    )

    & $Log "== Chocolatey =="

    if (Get-Command choco -ErrorAction SilentlyContinue) {

        & $Log "Chocolatey já está instalado."

        return
    }

    if ($DryRun) {

        & $Log "[SIMULAÇÃO] Instalaria Chocolatey."

        return
    }

    try {

        Set-ExecutionPolicy `
            Bypass `
            -Scope Process `
            -Force

        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor 3072

        & $Log "Baixando instalador oficial do Chocolatey..."

        $installScript = (
            New-Object System.Net.WebClient
        ).DownloadString(
            "https://community.chocolatey.org/install.ps1"
        )

        Invoke-Expression $installScript

        $env:Path += ";$env:ProgramData\chocolatey\bin"

        if (Get-Command choco -ErrorAction SilentlyContinue) {

            & $Log "Chocolatey instalado com sucesso."

        }
        else {

            throw "Chocolatey não foi localizado após a instalação."
        }

    }
    catch {

        throw `
            "Falha ao instalar Chocolatey: $($_.Exception.Message)"
    }
}

# ============================================================
# ETAPA - WINGET UPDATE
# ============================================================

function Step-WingetUpgradeAll {

    param(
        $Log,
        [bool]$DryRun
    )

    & $Log "== Winget - Atualizar aplicativos =="

    if ($DryRun) {

        & $Log "[SIMULAÇÃO] Executaria winget upgrade --all."

        return
    }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue

    if (-not $winget) {

        throw "winget.exe não está disponível neste computador."
    }

    & $Log "Atualizando fontes do winget..."

    try {

        & winget source update 2>&1 |
            ForEach-Object {
                & $Log $_
            }

    }
    catch {

        & $Log "AVISO ao atualizar fontes: $($_.Exception.Message)"
    }

    & $Log "Atualizando todos os aplicativos..."

    & winget upgrade `
        --all `
        --accept-source-agreements `
        --accept-package-agreements `
        --silent `
        --disable-interactivity `
        2>&1 |
        ForEach-Object {
            & $Log $_
        }

    $exitCode = $LASTEXITCODE

    & $Log "Winget upgrade finalizado. ExitCode: $exitCode"

    if ($exitCode -ne 0) {

        throw "winget upgrade retornou código $exitCode."
    }
}

# ============================================================
# ETAPA - LIMPEZA
# ============================================================

function Step-TarefaLimpeza {

    param(
        $Log,
        [bool]$DryRun
    )

    & $Log "== Tarefa agendada de limpeza de disco =="

    if ($DryRun) {

        & $Log "[SIMULAÇÃO] Criaria tarefa LimpezaDisco."

        return
    }

    $output = schtasks `
        /create `
        /tn "LimpezaDisco" `
        /tr "cleanmgr /sagerun:1" `
        /sc weekly `
        /d SUN `
        /st 03:00 `
        /ru "SYSTEM" `
        /rl highest `
        /f `
        2>&1

    foreach ($line in $output) {

        & $Log $line
    }

    if ($LASTEXITCODE -eq 0) {

        & $Log "Tarefa 'LimpezaDisco' criada/atualizada."

    }
    else {

        throw `
            "Falha ao criar tarefa LimpezaDisco. ExitCode: $LASTEXITCODE"
    }
}

# ============================================================
# CATÁLOGO
# ============================================================

function Build-AppCatalogLabels {

    $script:AppCatalogMap = @{}

    $labels = New-Object System.Collections.ArrayList

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

    return @($labels)
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

    $programs = @(
        Get-ItemProperty `
            -Path $paths `
            -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName `
            -and
            (-not $_.SystemComponent) `
            -and
            $_.UninstallString
        } |
        Select-Object `
            DisplayName,
            UninstallString,
            QuietUninstallString |
        Sort-Object DisplayName
    )

    return $programs
}

# ============================================================
# INSTALAÇÃO DE APLICATIVO
# ============================================================

function Install-App {

    param(
        [string]$Manager,
        [string]$Id,
        [scriptblock]$Log
    )

    Test-CancelRequested

    & $Log ""
    & $Log "----------------------------------------"
    & $Log "Instalando: $Id"
    & $Log "Gerenciador: $Manager"
    & $Log "----------------------------------------"

    try {

        switch ($Manager) {

            "choco" {

                if (-not (Ensure-ChocoAvailable -Log $Log)) {

                    throw `
                        "Chocolatey não está disponível."
                }

                & $Log "Executando Chocolatey..."

                & choco install `
                    $Id `
                    -y `
                    --no-progress `
                    2>&1 |
                    ForEach-Object {
                        & $Log $_
                    }

                $exitCode = $LASTEXITCODE
            }

            "winget" {

                if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {

                    throw `
                        "winget.exe não está disponível."
                }

                & $Log "Executando winget..."

                & winget install `
                    --id $Id `
                    --exact `
                    --accept-source-agreements `
                    --accept-package-agreements `
                    --silent `
                    --disable-interactivity `
                    2>&1 |
                    ForEach-Object {
                        & $Log $_
                    }

                $exitCode = $LASTEXITCODE
            }

            "wingetStore" {

                if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {

                    throw `
                        "winget.exe não está disponível."
                }

                & $Log "Executando Microsoft Store via winget..."

                & winget install `
                    --id $Id `
                    --source msstore `
                    --accept-source-agreements `
                    --accept-package-agreements `
                    --silent `
                    --disable-interactivity `
                    2>&1 |
                    ForEach-Object {
                        & $Log $_
                    }

                $exitCode = $LASTEXITCODE
            }

            default {

                throw `
                    "Gerenciador desconhecido: $Manager"
            }
        }

        & $Log "ExitCode: $exitCode"

        if ($exitCode -eq 0) {

            & $Log "OK: $Id instalado com sucesso."

            return $true
        }

        throw `
            "Instalação retornou código $exitCode."

    }
    catch {

        & $Log "FALHA: $Id"

        & $Log $_.Exception.Message

        return $false
    }
}

# ============================================================
# SITEF - VALIDA ZIP
# ============================================================

function Test-ZipFile {

    param(
        [string]$Path
    )

    if (-not (Test-Path $Path)) {

        return $false
    }

    try {

        $bytes = [System.IO.File]::ReadAllBytes($Path)

        if ($bytes.Length -lt 4) {

            return $false
        }

        return (
            $bytes[0] -eq 0x50 `
            -and
            $bytes[1] -eq 0x4B `
            -and
            (
                $bytes[2] -eq 0x03 `
                -or
                $bytes[2] -eq 0x05 `
                -or
                $bytes[2] -eq 0x07
            ) `
            -and
            (
                $bytes[3] -eq 0x04 `
                -or
                $bytes[3] -eq 0x06 `
                -or
                $bytes[3] -eq 0x08
            )
        )
    }
    catch {

        return $false
    }
}

# ============================================================
# SITEF - EXTRAÇÃO
# ============================================================

function Expand-SitefZip {

    param(
        [string]$ZipPath,
        [string]$Destination,
        [scriptblock]$Log
    )

    try {

        if (Test-Path $Destination) {

            Remove-Item `
                $Destination `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }

        New-Item `
            -Path $Destination `
            -ItemType Directory `
            -Force |
            Out-Null

        & $Log "Extraindo: $ZipPath"

        Expand-Archive `
            -Path $ZipPath `
            -DestinationPath $Destination `
            -Force `
            -ErrorAction Stop

        & $Log "Extração concluída."

        return $true

    }
    catch {

        & $Log "Expand-Archive falhou."

        & $Log $_.Exception.Message

        try {

            & $Log "Tentando método alternativo..."

            if (Test-Path $Destination) {

                Remove-Item `
                    $Destination `
                    -Recurse `
                    -Force `
                    -ErrorAction SilentlyContinue
            }

            New-Item `
                -Path $Destination `
                -ItemType Directory `
                -Force |
                Out-Null

            [System.IO.Compression.ZipFile]::ExtractToDirectory(
                $ZipPath,
                $Destination
            )

            & $Log "Extração alternativa concluída."

            return $true

        }
        catch {

            & $Log "Falha na extração alternativa."

            & $Log $_.Exception.Message

            return $false
        }
    }
}

# ============================================================
# SITEF
# ============================================================

function Install-Sitef {

    $log = ${function:Write-SitefLog}

    & $log "========================================"

    & $log "INICIANDO INSTALAÇÃO SITEF"

    & $log "========================================"

    $sitefDir = "C:\SITEF"

    $zipUrls = @(
        @{
            Url  = "http://gsurf.com.br/lib/win/certificado.zip"
            Name = "certificado.zip"
        },
        @{
            Url  = "http://gsurf.com.br/lib/win/gsclient.zip"
            Name = "gsclient.zip"
        }
    )

    try {

        if (-not (Test-Path $sitefDir)) {

            & $log "Criando $sitefDir..."

            New-Item `
                -Path $sitefDir `
                -ItemType Directory `
                -Force |
                Out-Null
        }

    }
    catch {

        & $log "ERRO ao criar C:\SITEF."

        & $log $_.Exception.Message

        return $false
    }

    $progressSitef.Minimum = 0
    $progressSitef.Maximum = 4
    $progressSitef.Value = 0

    $itemStatus = @{}

    foreach ($item in $zipUrls) {

        Test-CancelRequested

        $url = $item.Url

        $fileName = $item.Name

        $zipPath = Join-Path `
            $sitefDir `
            $fileName

        $extractPath = Join-Path `
            $sitefDir `
            ([System.IO.Path]::GetFileNameWithoutExtension($fileName))

        $itemStatus[$fileName] = $false

        & $log ""
        & $log "Processando $fileName"

        # ----------------------------------------------------
        # ARQUIVO EXISTENTE
        # ----------------------------------------------------

        if (Test-Path $zipPath) {

            & $log "Arquivo já existe."

            if (Test-ZipFile -Path $zipPath) {

                & $log "ZIP existente parece válido."

                if (
                    Expand-SitefZip `
                        -ZipPath $zipPath `
                        -Destination $extractPath `
                        -Log $log
                ) {

                    $itemStatus[$fileName] = $true

                    $progressSitef.Value += 2

                    continue
                }

                & $log "Falha na extração do arquivo existente."

            }
            else {

                & $log "Arquivo existente não é um ZIP válido."
            }

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

        # ----------------------------------------------------
        # DOWNLOAD
        # ----------------------------------------------------

        & $log "Baixando:"
        & $log $url

        try {

            [System.Net.ServicePointManager]::SecurityProtocol =
                [System.Net.ServicePointManager]::SecurityProtocol -bor 3072

            $webClient = New-Object System.Net.WebClient

            $webClient.Headers.Add(
                "User-Agent",
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
            )

            $webClient.DownloadFile(
                $url,
                $zipPath
            )

            $webClient.Dispose()

            & $log "Download concluído."

            $progressSitef.Value += 1
        }
        catch {

            & $log "ERRO no download."

            & $log $_.Exception.Message

            continue
        }

        # ----------------------------------------------------
        # VALIDA ZIP
        # ----------------------------------------------------

        if (-not (Test-ZipFile -Path $zipPath)) {

            & $log `
                "ERRO: $fileName não é um ZIP válido."

            Remove-Item `
                $zipPath `
                -Force `
                -ErrorAction SilentlyContinue

            continue
        }

        & $log "ZIP validado."

        # ----------------------------------------------------
        # EXTRAÇÃO
        # ----------------------------------------------------

        if (
            Expand-SitefZip `
                -ZipPath $zipPath `
                -Destination $extractPath `
                -Log $log
        ) {

            $itemStatus[$fileName] = $true

            $progressSitef.Value += 1
        }
        else {

            & $log `
                "ERRO: falha ao extrair $fileName."
        }
    }

    # ========================================================
    # RESULTADO DOS DOWNLOADS
    # ========================================================

    & $log ""

    $falhas = @(
        $itemStatus.GetEnumerator() |
        Where-Object {
            -not $_.Value
        } |
        ForEach-Object {
            $_.Key
        }
    )

    if ($falhas.Count -gt 0) {

        & $log `
            "Arquivos que falharam: $($falhas -join ', ')"

        & $log `
            "A instalação será interrompida."

        return $false
    }

    & $log "Todos os arquivos foram baixados e extraídos."

    # ========================================================
    # LOCALIZAR INSTALADORES
    # ========================================================

    & $log "Procurando instaladores..."

    $msiPath = Get-ChildItem `
        -Path $sitefDir `
        -Recurse `
        -Filter "GSurfRSA_Listener_Setup.msi" `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    $exePath = Get-ChildItem `
        -Path $sitefDir `
        -Recurse `
        -Filter "InstaladorGSurf.exe" `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $msiPath) {

        & $log `
            "ERRO: GSurfRSA_Listener_Setup.msi não encontrado."

        return $false
    }

    if (-not $exePath) {

        & $log `
            "ERRO: InstaladorGSurf.exe não encontrado."

        return $false
    }

    & $log "MSI encontrado:"
    & $log $msiPath.FullName

    & $log "EXE encontrado:"
    & $log $exePath.FullName

    # ========================================================
    # INSTALAR MSI
    # ========================================================

    Test-CancelRequested

    & $log ""
    & $log "Instalando GSurfRSA Listener..."

    try {

        $msiProcess = Start-Process `
            -FilePath "msiexec.exe" `
            -ArgumentList "/i `"$($msiPath.FullName)`" /norestart" `
            -Wait `
            -PassThru `
            -ErrorAction Stop

        $msiExitCode = $msiProcess.ExitCode

        & $log "MSI ExitCode: $msiExitCode"

        if ($msiExitCode -ne 0) {

            & $log "ERRO: instalação MSI falhou."

            return $false
        }

        & $log "MSI instalado com sucesso."

    }
    catch {

        & $log "ERRO ao executar MSI."

        & $log $_.Exception.Message

        return $false
    }

    # ========================================================
    # INSTALAR EXE
    # ========================================================

    Test-CancelRequested

    & $log ""
    & $log "Executando InstaladorGSurf.exe..."

    try {

        $exeProcess = Start-Process `
            -FilePath $exePath.FullName `
            -Wait `
            -PassThru `
            -ErrorAction Stop

        $exeExitCode = $exeProcess.ExitCode

        & $log "EXE ExitCode: $exeExitCode"

        if ($exeExitCode -ne 0) {

            & $log "ERRO: instalador EXE retornou código $exeExitCode."

            return $false
        }

        & $log "EXE executado com sucesso."

    }
    catch {

        & $log "ERRO ao executar EXE."

        & $log $_.Exception.Message

        return $false
    }

    # ========================================================
    # SERVIÇO
    # ========================================================

    & $log ""
    & $log "Aguardando 5 segundos..."

    Start-Sleep -Seconds 5

    $serviceName = "GSurfRSA Listener"

    & $log "Verificando serviço '$serviceName'..."

    $svc = Get-Service `
        -Name $serviceName `
        -ErrorAction SilentlyContinue

    if (-not $svc) {

        & $log `
            "AVISO: serviço '$serviceName' não foi encontrado."

        return $false
    }

    & $log "Serviço encontrado."

    if ($svc.Status -eq "Stopped") {

        & $log "Serviço parado. Iniciando..."

        try {

            Start-Service `
                -Name $serviceName `
                -ErrorAction Stop

            Start-Sleep -Seconds 2

            $svc.Refresh()

            if ($svc.Status -eq "Running") {

                & $log `
                    "Serviço iniciado com sucesso."

            }
            else {

                & $log `
                    "AVISO: serviço não entrou em Running."

                return $false
            }

        }
        catch {

            & $log `
                "ERRO ao iniciar serviço."

            & $log $_.Exception.Message

            return $false
        }

    }
    else {

        & $log `
            "Serviço já está em execução. Status: $($svc.Status)"
    }

    $progressSitef.Value = $progressSitef.Maximum

    & $log ""
    & $log "========================================"
    & $log "SITEF CONCLUÍDO COM SUCESSO"
    & $log "========================================"

    return $true
}

# ============================================================
# CORES
# ============================================================

$ColorBackground = `
    [System.Drawing.Color]::FromArgb(
        245,
        247,
        250
    )

$ColorSurface = `
    [System.Drawing.Color]::White

$ColorText = `
    [System.Drawing.Color]::FromArgb(
        35,
        38,
        42
    )

$ColorMuted = `
    [System.Drawing.Color]::FromArgb(
        95,
        102,
        110
    )

$ColorPrimary = `
    [System.Drawing.Color]::FromArgb(
        0,
        120,
        215
    )

$ColorSuccess = `
    [System.Drawing.Color]::FromArgb(
        40,
        150,
        90
    )

$ColorDanger = `
    [System.Drawing.Color]::FromArgb(
        190,
        55,
        55
    )

$ColorBorder = `
    [System.Drawing.Color]::FromArgb(
        210,
        215,
        222
    )

# ============================================================
# FONTES
# ============================================================

$FontNormal = New-Object `
    System.Drawing.Font(
        "Segoe UI",
        9
    )

$FontSmall = New-Object `
    System.Drawing.Font(
        "Segoe UI",
        8
    )

$FontHeader = New-Object `
    System.Drawing.Font(
        "Segoe UI Semibold",
        10
    )

$FontTitle = New-Object `
    System.Drawing.Font(
        "Segoe UI Semibold",
        18
    )

$FontButton = New-Object `
    System.Drawing.Font(
        "Segoe UI",
        9
    )

# ============================================================
# FORMULÁRIO
# ============================================================

$form = New-Object System.Windows.Forms.Form

$form.Text = "MCNTV Installer - Provisionamento Windows"

$form.StartPosition = "CenterScreen"

$form.FormBorderStyle = `
    [System.Windows.Forms.FormBorderStyle]::Sizable

$form.MaximizeBox = $true

$form.MinimizeBox = $true

$form.ClientSize = `
    New-Object System.Drawing.Size(
        1200,
        780
    )

$form.MinimumSize = `
    New-Object System.Drawing.Size(
        900,
        650
    )

$form.BackColor = $ColorBackground

$form.Font = $FontNormal

# ============================================================
# PAINEL PRINCIPAL
# ============================================================

$mainPanel = New-Object System.Windows.Forms.Panel

$mainPanel.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$mainPanel.AutoScroll = $true

$form.Controls.Add($mainPanel)

# ============================================================
# CABEÇALHO
# ============================================================

$headerPanel = New-Object System.Windows.Forms.Panel

$headerPanel.Dock = `
    [System.Windows.Forms.DockStyle]::Top

$headerPanel.Height = 70

$headerPanel.BackColor = $ColorBackground

$mainPanel.Controls.Add($headerPanel)

$lblMainTitle = New-Object System.Windows.Forms.Label

$lblMainTitle.Text = "MCNTV Installer"

$lblMainTitle.Font = $FontTitle

$lblMainTitle.ForeColor = $ColorText

$lblMainTitle.Location = `
    New-Object System.Drawing.Point(
        20,
        8
    )

$lblMainTitle.Size = `
    New-Object System.Drawing.Size(
        500,
        32
    )

$headerPanel.Controls.Add($lblMainTitle)

$lblSubtitle = New-Object System.Windows.Forms.Label

$lblSubtitle.Text = `
    "Instale, configure e gerencie este computador"

$lblSubtitle.Font = $FontNormal

$lblSubtitle.ForeColor = $ColorMuted

$lblSubtitle.Location = `
    New-Object System.Drawing.Point(
        20,
        40
    )

$lblSubtitle.Size = `
    New-Object System.Drawing.Size(
        600,
        22
    )

$headerPanel.Controls.Add($lblSubtitle)

# ============================================================
# STATUS
# ============================================================

$statusPanel = New-Object System.Windows.Forms.Panel

$statusPanel.Dock = `
    [System.Windows.Forms.DockStyle]::Bottom

$statusPanel.Height = 220

$statusPanel.BackColor = $ColorBackground

$mainPanel.Controls.Add($statusPanel)

# ============================================================
# CONTEÚDO
# ============================================================

$contentPanel = New-Object System.Windows.Forms.Panel

$contentPanel.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$contentPanel.BackColor = $ColorBackground

$mainPanel.Controls.Add($contentPanel)

# ============================================================
# TAB CONTROL
# ============================================================

$tabControl = New-Object System.Windows.Forms.TabControl

$tabControl.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$tabControl.Font = $FontNormal

$contentPanel.Controls.Add($tabControl)

# ============================================================
# ABA PROVISIONAMENTO
# ============================================================

$tabProvisioning = New-Object System.Windows.Forms.TabPage

$tabProvisioning.Text = "Provisionamento"

$tabProvisioning.BackColor = $ColorBackground

$tabControl.Controls.Add($tabProvisioning)

# ============================================================
# TABLE PRINCIPAL
# ============================================================

$tableLayout = New-Object System.Windows.Forms.TableLayoutPanel

$tableLayout.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$tableLayout.ColumnCount = 3

$tableLayout.RowCount = 1

$tableLayout.Padding = `
    New-Object System.Windows.Forms.Padding(
        10,
        10,
        10,
        10
    )

$tableLayout.BackColor = $ColorBackground

for ($i = 0; $i -lt 3; $i++) {

    $percentage = 33.33

    if ($i -eq 2) {
        $percentage = 33.34
    }

    $tableLayout.ColumnStyles.Add(
        (New-Object System.Windows.Forms.ColumnStyle(
            [System.Windows.Forms.SizeType]::Percent,
            $percentage
        ))
    ) | Out-Null
}

$tableLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Percent,
        100
    ))
) | Out-Null

$tabProvisioning.Controls.Add($tableLayout)

# ============================================================
# GRUPO 1
# ============================================================

$grpSystem = New-Object System.Windows.Forms.GroupBox

$grpSystem.Text = "1. Configuração do sistema"

$grpSystem.Font = $FontHeader

$grpSystem.ForeColor = $ColorText

$grpSystem.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$grpSystem.Padding = `
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

$panelSystem = New-Object System.Windows.Forms.Panel

$panelSystem.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$panelSystem.AutoScroll = $true

$grpSystem.Controls.Add($panelSystem)

# ============================================================
# ETAPAS
# ============================================================

$steps = [ordered]@{

    "Ponto de Restauração" = {
        param($l,$d)

        Step-RestorePoint `
            -Log $l `
            -DryRun $d
    }

    "Versões Anteriores (Shadow Copy)" = {
        param($l,$d)

        Step-VersoesAnteriores `
            -Log $l `
            -DryRun $d
    }

    "Ícones da Área de Trabalho" = {
        param($l,$d)

        Step-IconesAreaTrabalho `
            -Log $l `
            -DryRun $d
    }

    "Desativar Telemetria" = {
        param($l,$d)

        Step-Telemetria `
            -Log $l `
            -DryRun $d
    }

    "Ajustar Plano de Energia" = {
        param($l,$d)

        Step-Energia `
            -Log $l `
            -DryRun $d
    }

    "Fuso Horário / Localização (BR)" = {
        param($l,$d)

        Step-RegiaoIdioma `
            -Log $l `
            -DryRun $d
    }

    "Remover Apps Padrão (Debloat)" = {
        param($l,$d)

        Step-Debloat `
            -Log $l `
            -DryRun $d
    }

    "Instalar/Atualizar Chocolatey" = {
        param($l,$d)

        Step-Chocolatey `
            -Log $l `
            -DryRun $d
    }

    "Atualizar Apps (winget upgrade)" = {
        param($l,$d)

        Step-WingetUpgradeAll `
            -Log $l `
            -DryRun $d
    }

    "Criar Tarefa de Limpeza Semanal" = {
        param($l,$d)

        Step-TarefaLimpeza `
            -Log $l `
            -DryRun $d
    }
}

$UncheckedByDefault = @(
    "Versões Anteriores (Shadow Copy)"
)

$checkboxes = @{}

$y = 10

foreach ($key in $steps.Keys) {

    $cb = New-Object System.Windows.Forms.CheckBox

    $cb.Text = $key

    $cb.Checked = `
        -not (
            $UncheckedByDefault `
            -contains $key
        )

    $cb.Location = `
        New-Object System.Drawing.Point(
            10,
            $y
        )

    $cb.Size = `
        New-Object System.Drawing.Size(
            330,
            22
        )

    $cb.Font = $FontNormal

    $cb.ForeColor = $ColorText

    $cb.Anchor =
        [System.Windows.Forms.AnchorStyles]::Top `
        -bor
        [System.Windows.Forms.AnchorStyles]::Left `
        -bor
        [System.Windows.Forms.AnchorStyles]::Right

    $panelSystem.Controls.Add($cb)

    $checkboxes[$key] = $cb

    $y += 26
}

# ============================================================
# DRY RUN
# ============================================================

$chkDryRun = New-Object System.Windows.Forms.CheckBox

$chkDryRun.Text = "Modo Simulação (Dry-Run)"

$yDryRun = $y + 3

$chkDryRun.Location = `
    New-Object System.Drawing.Point(
        10,
        $yDryRun
    )

$chkDryRun.Size = `
    New-Object System.Drawing.Size(
        330,
        22
    )

$chkDryRun.Font = $FontNormal

$chkDryRun.ForeColor = [System.Drawing.Color]::DarkBlue

$panelSystem.Controls.Add($chkDryRun)

# ============================================================
# BOTÕES SELEÇÃO
# ============================================================

$btnSelAll = New-Object System.Windows.Forms.Button

$btnSelAll.Text = "Marcar todos"

$btnSelAll.Location = `
    New-Object System.Drawing.Point(
        10,
        ($y + 35)
    )

$btnSelAll.Size = `
    New-Object System.Drawing.Size(
        150,
        32
    )

$btnSelAll.Font = $FontButton

$btnSelAll.FlatStyle = `
    [System.Windows.Forms.FlatStyle]::Flat

$btnSelAll.FlatAppearance.BorderColor = $ColorBorder

$btnSelAll.BackColor = $ColorSurface

$btnSelAll.Add_Click({

    foreach ($cb in $checkboxes.Values) {

        $cb.Checked = $true
    }
})

$panelSystem.Controls.Add($btnSelAll)

$btnSelNone = New-Object System.Windows.Forms.Button

$btnSelNone.Text = "Desmarcar todos"

$btnSelNone.Location = `
    New-Object System.Drawing.Point(
        170,
        ($y + 35)
    )

$btnSelNone.Size = `
    New-Object System.Drawing.Size(
        150,
        32
    )

$btnSelNone.Font = $FontButton

$btnSelNone.FlatStyle = `
    [System.Windows.Forms.FlatStyle]::Flat

$btnSelNone.FlatAppearance.BorderColor = $ColorBorder

$btnSelNone.BackColor = $ColorSurface

$btnSelNone.Add_Click({

    foreach ($cb in $checkboxes.Values) {

        $cb.Checked = $false
    }
})

$panelSystem.Controls.Add($btnSelNone)

# ============================================================
# BOTÃO EXECUTAR
# ============================================================

$btnRun = New-Object System.Windows.Forms.Button

$btnRun.Text = "Executar configuração"

$btnRun.Location = `
    New-Object System.Drawing.Point(
        10,
        ($y + 80)
    )

$btnRun.Size = `
    New-Object System.Drawing.Size(
        310,
        36
    )

$btnRun.Font = $FontButton

$btnRun.BackColor = $ColorPrimary

$btnRun.ForeColor = [System.Drawing.Color]::White

$btnRun.FlatStyle = `
    [System.Windows.Forms.FlatStyle]::Flat

$btnRun.FlatAppearance.BorderSize = 0

$panelSystem.Controls.Add($btnRun)

# ============================================================
# GRUPO 2 - INSTALAÇÃO
# ============================================================

$grpInstall = New-Object System.Windows.Forms.GroupBox

$grpInstall.Text = "2. Instalar aplicativos"

$grpInstall.Font = $FontHeader

$grpInstall.ForeColor = $ColorText

$grpInstall.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$grpInstall.Padding = `
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

$panelInstall = New-Object System.Windows.Forms.TableLayoutPanel

$panelInstall.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$panelInstall.ColumnCount = 1

$panelInstall.RowCount = 4

$panelInstall.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        28
    ))
) | Out-Null

$panelInstall.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        30
    ))
) | Out-Null

$panelInstall.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Percent,
        100
    ))
) | Out-Null

$panelInstall.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        48
    ))
) | Out-Null

$grpInstall.Controls.Add($panelInstall)

# ============================================================
# LABEL BUSCA
# ============================================================

$lblInstallInfo = New-Object System.Windows.Forms.Label

$lblInstallInfo.Text = "Aplicativos disponíveis:"

$lblInstallInfo.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$lblInstallInfo.TextAlign = `
    [System.Drawing.ContentAlignment]::MiddleLeft

$lblInstallInfo.ForeColor = $ColorMuted

$panelInstall.Controls.Add(
    $lblInstallInfo,
    0,
    0
)

# ============================================================
# BUSCA
# ============================================================

$txtSearchInstall = New-Object System.Windows.Forms.TextBox

$txtSearchInstall.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$txtSearchInstall.Font = $FontNormal

$txtSearchInstall.Margin = `
    New-Object System.Windows.Forms.Padding(
        0,
        2,
        0,
        2
    )

$panelInstall.Controls.Add(
    $txtSearchInstall,
    0,
    1
)

# ============================================================
# CHECKED LIST
# ============================================================

$clbInstall = New-Object System.Windows.Forms.CheckedListBox

$clbInstall.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$clbInstall.CheckOnClick = $true

$clbInstall.Font = $FontNormal

$clbInstall.IntegralHeight = $false

$allLabels = Build-AppCatalogLabels

$clbInstall.Tag = $allLabels

foreach ($label in $allLabels) {

    [void]$clbInstall.Items.Add(
        $label,
        $true
    )
}

$panelInstall.Controls.Add(
    $clbInstall,
    0,
    2
)

# ============================================================
# PESQUISA - MANTÉM SELEÇÃO
# ============================================================

$txtSearchInstall.Add_TextChanged({

    $search = `
        $txtSearchInstall.Text.Trim().ToLower()

    $selectedBefore = @(
        $clbInstall.CheckedItems
    )

    $clbInstall.BeginUpdate()

    try {

        $clbInstall.Items.Clear()

        $all = @(
            $clbInstall.Tag
        )

        foreach ($item in $all) {

            if (
                [string]::IsNullOrWhiteSpace($search) `
                -or
                $item.ToLower().Contains($search)
            ) {

                $isChecked = `
                    $selectedBefore -contains $item

                [void]$clbInstall.Items.Add(
                    $item,
                    $isChecked
                )
            }
        }

    }
    finally {

        $clbInstall.EndUpdate()
    }
})

# ============================================================
# BOTÃO INSTALAR
# ============================================================

$btnInstallSelected = New-Object System.Windows.Forms.Button

$btnInstallSelected.Text = `
    "INSTALAR SELECIONADOS"

$btnInstallSelected.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$btnInstallSelected.Font = `
    New-Object System.Drawing.Font(
        "Segoe UI Semibold",
        10
    )

$btnInstallSelected.BackColor = $ColorSuccess

$btnInstallSelected.ForeColor = `
    [System.Drawing.Color]::White

$btnInstallSelected.FlatStyle = `
    [System.Windows.Forms.FlatStyle]::Flat

$btnInstallSelected.FlatAppearance.BorderSize = 0

$panelInstall.Controls.Add(
    $btnInstallSelected,
    0,
    3
)

# ============================================================
# GRUPO 3
# ============================================================

$grpUninstall = New-Object System.Windows.Forms.GroupBox

$grpUninstall.Text = `
    "3. Gerenciar aplicativos instalados"

$grpUninstall.Font = $FontHeader

$grpUninstall.ForeColor = $ColorText

$grpUninstall.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$grpUninstall.Padding = `
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

# ============================================================
# TABLE UNINSTALL
# ============================================================

$tableUninstall = New-Object System.Windows.Forms.TableLayoutPanel

$tableUninstall.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$tableUninstall.ColumnCount = 1

$tableUninstall.RowCount = 5

$tableUninstall.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        24
    ))
) | Out-Null

$tableUninstall.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        30
    ))
) | Out-Null

$tableUninstall.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Percent,
        100
    ))
) | Out-Null

$tableUninstall.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        40
    ))
) | Out-Null

$tableUninstall.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        38
    ))
) | Out-Null

$grpUninstall.Controls.Add($tableUninstall)

# ============================================================
# LABEL
# ============================================================

$lblUninstallInfo = New-Object System.Windows.Forms.Label

$lblUninstallInfo.Text = `
    "Selecione o aplicativo que deseja remover:"

$lblUninstallInfo.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$lblUninstallInfo.ForeColor = $ColorMuted

$lblUninstallInfo.TextAlign = `
    [System.Drawing.ContentAlignment]::MiddleLeft

$tableUninstall.Controls.Add(
    $lblUninstallInfo,
    0,
    0
)

# ============================================================
# PESQUISA DESINSTALAÇÃO
# ============================================================

$txtSearchUninstall = New-Object System.Windows.Forms.TextBox

$txtSearchUninstall.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$txtSearchUninstall.Font = $FontNormal

$tableUninstall.Controls.Add(
    $txtSearchUninstall,
    0,
    1
)

# ============================================================
# LISTA DESINSTALAÇÃO
# ============================================================

$clbUninstall = New-Object System.Windows.Forms.CheckedListBox

$clbUninstall.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$clbUninstall.CheckOnClick = $true

$clbUninstall.Font = $FontNormal

$clbUninstall.IntegralHeight = $false

$tableUninstall.Controls.Add(
    $clbUninstall,
    0,
    2
)

# ============================================================
# BOTÕES
# ============================================================

$panelUninstallButtons = `
    New-Object System.Windows.Forms.TableLayoutPanel

$panelUninstallButtons.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$panelUninstallButtons.ColumnCount = 2

$panelUninstallButtons.RowCount = 1

$panelUninstallButtons.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Percent,
        50
    ))
) | Out-Null

$panelUninstallButtons.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Percent,
        50
    ))
) | Out-Null

$tableUninstall.Controls.Add(
    $panelUninstallButtons,
    0,
    3
)

$btnRefreshInstalled = New-Object System.Windows.Forms.Button

$btnRefreshInstalled.Text = "Atualizar"

$btnRefreshInstalled.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$btnRefreshInstalled.Margin = `
    New-Object System.Windows.Forms.Padding(
        0,
        3,
        3,
        3
    )

$btnRefreshInstalled.Font = $FontButton

$btnRefreshInstalled.FlatStyle = `
    [System.Windows.Forms.FlatStyle]::Flat

$btnRefreshInstalled.BackColor = $ColorSurface

$btnRefreshInstalled.FlatAppearance.BorderColor = $ColorBorder

$panelUninstallButtons.Controls.Add(
    $btnRefreshInstalled,
    0,
    0
)

$btnUninstallSelected = New-Object System.Windows.Forms.Button

$btnUninstallSelected.Text = "Desinstalar"

$btnUninstallSelected.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$btnUninstallSelected.Margin = `
    New-Object System.Windows.Forms.Padding(
        3,
        3,
        0,
        3
    )

$btnUninstallSelected.Font = $FontButton

$btnUninstallSelected.BackColor = $ColorDanger

$btnUninstallSelected.ForeColor = `
    [System.Drawing.Color]::White

$btnUninstallSelected.FlatStyle = `
    [System.Windows.Forms.FlatStyle]::Flat

$btnUninstallSelected.FlatAppearance.BorderSize = 0

$panelUninstallButtons.Controls.Add(
    $btnUninstallSelected,
    1,
    0
)

# ============================================================
# BOTÃO PERSONALIZADO
# ============================================================

$btnCustom = New-Object System.Windows.Forms.Button

$btnCustom.Text = $CustomScriptLabel

$btnCustom.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$btnCustom.Font = $FontButton

$btnCustom.BackColor = $ColorSurface

$btnCustom.FlatStyle = `
    [System.Windows.Forms.FlatStyle]::Flat

$btnCustom.FlatAppearance.BorderColor = $ColorBorder

$tableUninstall.Controls.Add(
    $btnCustom,
    0,
    4
)

# ============================================================
# ABA SITEF
# ============================================================

$tabSitef = New-Object System.Windows.Forms.TabPage

$tabSitef.Text = "SITEF"

$tabSitef.BackColor = $ColorBackground

$tabControl.Controls.Add($tabSitef)

$sitefLayout = New-Object System.Windows.Forms.TableLayoutPanel

$sitefLayout.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$sitefLayout.ColumnCount = 1

$sitefLayout.RowCount = 6

$sitefLayout.Padding = `
    New-Object System.Windows.Forms.Padding(
        20,
        20,
        20,
        20
    )

$sitefLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        30
    ))
) | Out-Null

$sitefLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        70
    ))
) | Out-Null

$sitefLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        42
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

$tabSitef.Controls.Add($sitefLayout)

# ============================================================
# SITEF TÍTULO
# ============================================================

$lblSitefTitle = New-Object System.Windows.Forms.Label

$lblSitefTitle.Text = `
    "Instalação do Ambiente SITEF"

$lblSitefTitle.Font = `
    New-Object System.Drawing.Font(
        "Segoe UI Semibold",
        12
    )

$lblSitefTitle.ForeColor = $ColorText

$lblSitefTitle.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$lblSitefTitle.TextAlign = `
    [System.Drawing.ContentAlignment]::MiddleLeft

$sitefLayout.Controls.Add(
    $lblSitefTitle,
    0,
    0
)

# ============================================================
# SITEF DESCRIÇÃO
# ============================================================

$lblSitefDesc = New-Object System.Windows.Forms.Label

$lblSitefDesc.Text = `
    "A instalação irá baixar e extrair os componentes do SITEF.`r`n" +
    "Depois serão executados o instalador MSI e o instalador GSurf.`r`n" +
    "Ao final, o serviço GSurfRSA Listener será verificado."

$lblSitefDesc.Font = $FontNormal

$lblSitefDesc.ForeColor = $ColorMuted

$lblSitefDesc.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$sitefLayout.Controls.Add(
    $lblSitefDesc,
    0,
    1
)

# ============================================================
# BOTÕES SITEF
# ============================================================

$panelSitefButtons = `
    New-Object System.Windows.Forms.TableLayoutPanel

$panelSitefButtons.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$panelSitefButtons.ColumnCount = 2

$panelSitefButtons.RowCount = 1

$panelSitefButtons.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Percent,
        50
    ))
) | Out-Null

$panelSitefButtons.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Percent,
        50
    ))
) | Out-Null

$sitefLayout.Controls.Add(
    $panelSitefButtons,
    0,
    2
)

$btnSitefInstall = New-Object System.Windows.Forms.Button

$btnSitefInstall.Text = "Instalar SITEF"

$btnSitefInstall.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$btnSitefInstall.Font = `
    New-Object System.Drawing.Font(
        "Segoe UI Semibold",
        10
    )

$btnSitefInstall.BackColor = $ColorPrimary

$btnSitefInstall.ForeColor = `
    [System.Drawing.Color]::White

$btnSitefInstall.FlatStyle = `
    [System.Windows.Forms.FlatStyle]::Flat

$btnSitefInstall.FlatAppearance.BorderSize = 0

$btnSitefInstall.Margin = `
    New-Object System.Windows.Forms.Padding(
        0,
        2,
        5,
        2
    )

$panelSitefButtons.Controls.Add(
    $btnSitefInstall,
    0,
    0
)

$btnSitefOpenFolder = New-Object System.Windows.Forms.Button

$btnSitefOpenFolder.Text = "Abrir C:\SITEF"

$btnSitefOpenFolder.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$btnSitefOpenFolder.Font = $FontButton

$btnSitefOpenFolder.BackColor = $ColorSurface

$btnSitefOpenFolder.FlatStyle = `
    [System.Windows.Forms.FlatStyle]::Flat

$btnSitefOpenFolder.FlatAppearance.BorderColor = $ColorBorder

$btnSitefOpenFolder.Margin = `
    New-Object System.Windows.Forms.Padding(
        5,
        2,
        0,
        2
    )

$panelSitefButtons.Controls.Add(
    $btnSitefOpenFolder,
    1,
    0
)

# ============================================================
# PROGRESS SITEF
# ============================================================

$progressSitef = New-Object System.Windows.Forms.ProgressBar

$progressSitef.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$progressSitef.Minimum = 0

$progressSitef.Maximum = 4

$sitefLayout.Controls.Add(
    $progressSitef,
    0,
    3
)

# ============================================================
# LABEL LOG SITEF
# ============================================================

$lblSitefLog = New-Object System.Windows.Forms.Label

$lblSitefLog.Text = "Log da instalação SITEF:"

$lblSitefLog.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$lblSitefLog.ForeColor = $ColorMuted

$lblSitefLog.TextAlign = `
    [System.Drawing.ContentAlignment]::MiddleLeft

$sitefLayout.Controls.Add(
    $lblSitefLog,
    0,
    4
)

# ============================================================
# LOG SITEF
# ============================================================

$txtSitefLog = New-Object System.Windows.Forms.TextBox

$txtSitefLog.Multiline = $true

$txtSitefLog.ScrollBars = "Vertical"

$txtSitefLog.ReadOnly = $true

$txtSitefLog.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$txtSitefLog.Font = `
    New-Object System.Drawing.Font(
        "Consolas",
        8
    )

$txtSitefLog.BackColor = `
    [System.Drawing.Color]::White

$txtSitefLog.WordWrap = $false

$sitefLayout.Controls.Add(
    $txtSitefLog,
    0,
    5
)

# ============================================================
# STATUS GERAL
# ============================================================

$grpStatus = New-Object System.Windows.Forms.GroupBox

$grpStatus.Text = "Status Geral"

$grpStatus.Font = $FontHeader

$grpStatus.ForeColor = $ColorText

$grpStatus.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$grpStatus.Padding = `
    New-Object System.Windows.Forms.Padding(
        10,
        20,
        10,
        10
    )

$statusPanel.Controls.Add($grpStatus)

$statusLayout = New-Object System.Windows.Forms.TableLayoutPanel

$statusLayout.Dock = `
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
        28
    ))
) | Out-Null

$statusLayout.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Percent,
        100
    ))
) | Out-Null

$grpStatus.Controls.Add($statusLayout)

# ============================================================
# PROGRESS GERAL
# ============================================================

$progressBar = New-Object System.Windows.Forms.ProgressBar

$progressBar.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$progressBar.Minimum = 0

$statusLayout.Controls.Add(
    $progressBar,
    0,
    0
)

# ============================================================
# STATUS LABEL
# ============================================================

$lblStatus = New-Object System.Windows.Forms.Label

$lblStatus.Text = "Pronto para instalar"

$lblStatus.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$lblStatus.ForeColor = $ColorSuccess

$lblStatus.TextAlign = `
    [System.Drawing.ContentAlignment]::MiddleLeft

$statusLayout.Controls.Add(
    $lblStatus,
    0,
    1
)

# ============================================================
# LOG GERAL
# ============================================================

$txtLog = New-Object System.Windows.Forms.TextBox

$txtLog.Multiline = $true

$txtLog.ScrollBars = "Vertical"

$txtLog.ReadOnly = $true

$txtLog.Dock = `
    [System.Windows.Forms.DockStyle]::Fill

$txtLog.Font = `
    New-Object System.Drawing.Font(
        "Consolas",
        8
    )

$txtLog.BackColor = `
    [System.Drawing.Color]::White

$txtLog.WordWrap = $false

$statusLayout.Controls.Add(
    $txtLog,
    0,
    2
)

# ============================================================
# BOTÃO CANCELAR
# ============================================================

$btnCancel = New-Object System.Windows.Forms.Button

$btnCancel.Text = "Cancelar"

$btnCancel.Enabled = $false

$btnCancel.Size = `
    New-Object System.Drawing.Size(
        100,
        30
    )

$btnCancel.Anchor =
    [System.Windows.Forms.AnchorStyles]::Top `
    -bor
    [System.Windows.Forms.AnchorStyles]::Right

$btnCancel.Location = `
    New-Object System.Drawing.Point(
        1080,
        35
    )

$btnCancel.BackColor = $ColorDanger

$btnCancel.ForeColor = `
    [System.Drawing.Color]::White

$btnCancel.FlatStyle = `
    [System.Windows.Forms.FlatStyle]::Flat

$btnCancel.FlatAppearance.BorderSize = 0

$headerPanel.Controls.Add($btnCancel)

# ============================================================
# FUNÇÃO - CONTROLE DE INTERFACE
# ============================================================

function Set-InterfaceBusy {

    param(
        [bool]$Busy
    )

    $script:IsBusy = $Busy

    $btnRun.Enabled = -not $Busy

    $btnSelAll.Enabled = -not $Busy

    $btnSelNone.Enabled = -not $Busy

    $btnInstallSelected.Enabled = -not $Busy

    $btnRefreshInstalled.Enabled = -not $Busy

    $btnUninstallSelected.Enabled = -not $Busy

    $btnCustom.Enabled = -not $Busy

    $btnSitefInstall.Enabled = -not $Busy

    $btnSitefOpenFolder.Enabled = -not $Busy

    $btnCancel.Enabled = $Busy

    if ($Busy) {

        $lblStatus.ForeColor = $ColorPrimary

    }
    else {

        $lblStatus.ForeColor = $ColorSuccess
    }

    [System.Windows.Forms.Application]::DoEvents()
}

# ============================================================
# EXECUTAR PROVISIONAMENTO
# ============================================================

$btnRun.Add_Click({

    if ($script:IsBusy) {
        return
    }

    $selectedSteps = @(
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

    $confirmMessage = `
        "Executar $($selectedSteps.Count) etapa(s)?`r`n`r`n" +
        ($selectedSteps -join "`r`n")

    if ($chkDryRun.Checked) {

        $confirmMessage += `
            "`r`n`r`nModo SIMULAÇÃO ativado."
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        $confirmMessage,
        "Confirmar provisionamento",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    Set-InterfaceBusy -Busy $true

    $txtLog.Clear()

    $script:CancelRequested = $false

    # IMPORTANTE:
    # Limpa resultados de execuções anteriores.
    $script:Results = [ordered]@{}

    $dryRun = $chkDryRun.Checked

    & $script:Write-Log "========================================"

    & $script:Write-Log "INICIANDO PROVISIONAMENTO"

    & $script:Write-Log "Modo: $(if ($dryRun) { 'SIMULAÇÃO' } else { 'EXECUÇÃO REAL' })"

    & $script:Write-Log "========================================"

    $progressBar.Minimum = 0

    $progressBar.Maximum = $selectedSteps.Count

    $progressBar.Value = 0

    $successCount = 0

    $failCount = 0

    try {

        foreach ($key in $selectedSteps) {

            Test-CancelRequested

            $lblStatus.Text = `
                "Executando: $key"

            & $script:Write-Log ""

            & $script:Write-Log ">>> $key"

            try {

                & $steps[$key] `
                    $script:Write-Log `
                    $dryRun

                $script:Results[$key] =
                    if ($dryRun) {
                        "SIMULADO"
                    }
                    else {
                        "OK"
                    }

                $successCount++

            }
            catch {

                if ($_.Exception.Message -eq `
                    "Operação cancelada pelo usuário.") {

                    throw
                }

                $message = `
                    $_.Exception.Message

                & $script:Write-Log `
                    "ERRO em '$key': $message"

                $script:Results[$key] = `
                    "FALHA: $message"

                $failCount++
            }

            $progressBar.Value++

            [System.Windows.Forms.Application]::DoEvents()
        }

    }
    catch {

        if ($_.Exception.Message -eq `
            "Operação cancelada pelo usuário.") {

            & $script:Write-Log ""
            & $script:Write-Log "OPERAÇÃO CANCELADA PELO USUÁRIO."

            $lblStatus.Text = "Cancelado."

        }
        else {

            & $script:Write-Log ""
            & $script:Write-Log `
                "ERRO GERAL: $($_.Exception.Message)"

            $lblStatus.Text = "Erro."
        }
    }

    # ========================================================
    # RELATÓRIO
    # ========================================================

    & $script:Write-Log ""

    & $script:Write-Log "========================================"

    & $script:Write-Log "PROVISIONAMENTO FINALIZADO"

    & $script:Write-Log "Sucesso: $successCount"

    & $script:Write-Log "Falhas: $failCount"

    & $script:Write-Log "========================================"

    $reportLines = @()

    $reportLines += `
        "Relatório de Provisionamento"

    $reportLines += `
        "Data: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')"

    $reportLines += `
        "Modo: $(if ($dryRun) { 'SIMULAÇÃO' } else { 'EXECUÇÃO REAL' })"

    $reportLines += ""

    foreach ($key in $script:Results.Keys) {

        $reportLines += `
            ("{0,-50} {1}" -f `
                $key,
                $script:Results[$key]
            )
    }

    $reportLines += ""

    $reportLines += `
        "Sucessos: $successCount"

    $reportLines += `
        "Falhas: $failCount"

    try {

        $reportLines |
            Set-Content `
                -Path $ReportPath `
                -Encoding UTF8

        & $script:Write-Log `
            "Relatório salvo em: $ReportPath"

    }
    catch {

        & $script:Write-Log `
            "ERRO ao salvar relatório: $($_.Exception.Message)"
    }

    if (-not $script:CancelRequested) {

        $lblStatus.Text = `
            "Concluído."

    }

    Set-InterfaceBusy -Busy $false

    [System.Windows.Forms.MessageBox]::Show(
        "Provisionamento finalizado.`r`n`r`nSucesso: $successCount`r`nFalhas: $failCount`r`n`r`nRelatório:`r`n$ReportPath",
        "Provisionamento",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $(if ($failCount -gt 0) {
            [System.Windows.Forms.MessageBoxIcon]::Warning
        }
        else {
            [System.Windows.Forms.MessageBoxIcon]::Information
        })
    )
})

# ============================================================
# INSTALAR APLICATIVOS
# ============================================================

$btnInstallSelected.Add_Click({

    if ($script:IsBusy) {
        return
    }

    $selectedLabels = @(
        $clbInstall.CheckedItems
    )

    if ($selectedLabels.Count -eq 0) {

        [System.Windows.Forms.MessageBox]::Show(
            "Selecione ao menos um programa.",
            "Aviso"
        )

        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Instalar $($selectedLabels.Count) aplicativo(s)?`r`n`r`n$($selectedLabels -join "`r`n")",
        "Confirmar instalação",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    Set-InterfaceBusy -Busy $true

    $script:CancelRequested = $false

    & $script:Write-Log ""

    & $script:Write-Log "========================================"

    & $script:Write-Log "INSTALAÇÃO DE APLICATIVOS"

    & $script:Write-Log "Total: $($selectedLabels.Count)"

    & $script:Write-Log "Modo: SEQUENCIAL"

    & $script:Write-Log "========================================"

    $progressBar.Minimum = 0

    $progressBar.Maximum = $selectedLabels.Count

    $progressBar.Value = 0

    $successCount = 0

    $failCount = 0

    try {

        foreach ($label in $selectedLabels) {

            Test-CancelRequested

            $info = $script:AppCatalogMap[$label]

            if (-not $info) {

                & $script:Write-Log `
                    "Aplicativo não encontrado no catálogo: $label"

                $failCount++

                $progressBar.Value++

                continue
            }

            $lblStatus.Text = `
                "Instalando: $($info.Id)"

            $success = Install-App `
                -Manager $info.Manager `
                -Id $info.Id `
                -Log $script:Write-Log

            if ($success) {

                $successCount++

            }
            else {

                $failCount++
            }

            $progressBar.Value++

            [System.Windows.Forms.Application]::DoEvents()
        }

    }
    catch {

        if ($_.Exception.Message -eq `
            "Operação cancelada pelo usuário.") {

            & $script:Write-Log `
                "Instalação cancelada pelo usuário."

            $lblStatus.Text = "Cancelado."

        }
        else {

            & $script:Write-Log `
                "Erro geral: $($_.Exception.Message)"
        }
    }

    & $script:Write-Log ""

    & $script:Write-Log `
        "Instalação finalizada."

    & $script:Write-Log `
        "Sucesso: $successCount"

    & $script:Write-Log `
        "Falhas: $failCount"

    $progressBar.Value = 0

    $lblStatus.Text = `
        "Instalação concluída."

    Set-InterfaceBusy -Busy $false

    [System.Windows.Forms.MessageBox]::Show(
        "Instalação finalizada.`r`n`r`nSucesso: $successCount`r`nFalhas: $failCount",
        "Instalação",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $(if ($failCount -gt 0) {
            [System.Windows.Forms.MessageBoxIcon]::Warning
        }
        else {
            [System.Windows.Forms.MessageBoxIcon]::Information
        })
    )
})

# ============================================================
# SCRIPT PERSONALIZADO
# ============================================================

$btnCustom.Add_Click({

    if ($script:IsBusy) {
        return
    }

    if (
        [string]::IsNullOrWhiteSpace($CustomScriptUrl)
    ) {

        [System.Windows.Forms.MessageBox]::Show(
            "URL do script não configurada.",
            "Configuração"
        )

        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "ATENÇÃO:`r`n`r`nEste botão irá baixar e executar um script PowerShell remoto:`r`n`r`n$CustomScriptUrl`r`n`r`nExecute somente se você confia na fonte.`r`n`r`nDeseja continuar?",
        "Executar script remoto",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    Set-InterfaceBusy -Busy $true

    try {

        & $script:Write-Log ""
        & $script:Write-Log "Executando: $CustomScriptLabel"
        & $script:Write-Log "URL: $CustomScriptUrl"

        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor 3072

        $tempScript = Join-Path `
            $env:TEMP `
            "MCNTV_custom_$(Get-Random).ps1"

        $webClient = New-Object System.Net.WebClient

        $webClient.Headers.Add(
            "User-Agent",
            "MCNTV-Installer"
        )

        $webClient.DownloadFile(
            $CustomScriptUrl,
            $tempScript
        )

        $webClient.Dispose()

        & $script:Write-Log `
            "Script baixado para: $tempScript"

        & $script:Write-Log `
            "Executando script..."

        & powershell.exe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $tempScript `
            2>&1 |
            ForEach-Object {
                & $script:Write-Log $_
            }

        $exitCode = $LASTEXITCODE

        & $script:Write-Log `
            "ExitCode: $exitCode"

        if ($exitCode -eq 0) {

            & $script:Write-Log `
                "Script concluído com sucesso."

        }
        else {

            & $script:Write-Log `
                "Script retornou código $exitCode."
        }

        Remove-Item `
            $tempScript `
            -Force `
            -ErrorAction SilentlyContinue

    }
    catch {

        & $script:Write-Log `
            "ERRO: $($_.Exception.Message)"
    }

    Set-InterfaceBusy -Busy $false
})

# ============================================================
# ATUALIZAR LISTA DE PROGRAMAS
# ============================================================

function Refresh-InstalledPrograms {

    $selectedBefore = @(
        $clbUninstall.CheckedItems
    )

    $search = `
        $txtSearchUninstall.Text.Trim().ToLower()

    $clbUninstall.BeginUpdate()

    try {

        $clbUninstall.Items.Clear()

        $script:UninstallMap = @{}

        $programs = @(
            Get-InstalledProgramsList
        )

        foreach ($p in $programs) {

            $name = $p.DisplayName

            if (
                [string]::IsNullOrWhiteSpace($name)
            ) {
                continue
            }

            if (
                -not $script:UninstallMap.ContainsKey($name)
            ) {

                $cmd =
                    if ($p.QuietUninstallString) {
                        $p.QuietUninstallString
                    }
                    else {
                        $p.UninstallString
                    }

                $script:UninstallMap[$name] = $cmd

                if (
                    [string]::IsNullOrWhiteSpace($search) `
                    -or
                    $name.ToLower().Contains($search)
                ) {

                    $isChecked =
                        $selectedBefore -contains $name

                    [void]$clbUninstall.Items.Add(
                        $name,
                        $isChecked
                    )
                }
            }
        }

    }
    finally {

        $clbUninstall.EndUpdate()
    }

    & $script:Write-Log `
        "$($clbUninstall.Items.Count) programas exibidos."

}

# ============================================================
# BOTÃO ATUALIZAR
# ============================================================

$btnRefreshInstalled.Add_Click({

    if ($script:IsBusy) {
        return
    }

    & $script:Write-Log ""
    & $script:Write-Log `
        "Consultando programas instalados..."

    try {

        Refresh-InstalledPrograms

    }
    catch {

        & $script:Write-Log `
            "Erro ao atualizar lista: $($_.Exception.Message)"
    }
})

# ============================================================
# PESQUISA DESINSTALAÇÃO
# ============================================================

$txtSearchUninstall.Add_TextChanged({

    if (-not $script:IsBusy) {

        Refresh-InstalledPrograms
    }
})

# ============================================================
# DESINSTALAR
# ============================================================

$btnUninstallSelected.Add_Click({

    if ($script:IsBusy) {
        return
    }

    $selected = @(
        $clbUninstall.CheckedItems
    )

    if ($selected.Count -eq 0) {

        [System.Windows.Forms.MessageBox]::Show(
            "Selecione ao menos um programa para remover.",
            "Aviso"
        )

        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Desinstalar os seguintes programas?`r`n`r`n$($selected -join "`r`n")",
        "Confirmar remoção",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    Set-InterfaceBusy -Busy $true

    $script:CancelRequested = $false

    $progressBar.Minimum = 0

    $progressBar.Maximum = $selected.Count

    $progressBar.Value = 0

    $successCount = 0

    $failCount = 0

    try {

        foreach ($name in $selected) {

            Test-CancelRequested

            $cmd = $script:UninstallMap[$name]

            if ([string]::IsNullOrWhiteSpace($cmd)) {

                & $script:Write-Log `
                    "Comando de desinstalação não encontrado: $name"

                $failCount++

                $progressBar.Value++

                continue
            }

            $lblStatus.Text = `
                "Desinstalando: $name"

            & $script:Write-Log ""

            & $script:Write-Log `
                "Desinstalando: $name"

            & $script:Write-Log `
                "Comando: $cmd"

            try {

                $exitCode = Invoke-ExternalProcess `
                    -FilePath "cmd.exe" `
                    -Arguments "/c $cmd" `
                    -Log $script:Write-Log `
                    -Description "Desinstalação de $name"

                if ($exitCode -eq 0) {

                    & $script:Write-Log `
                        "OK: $name"

                    $successCount++

                }
                else {

                    & $script:Write-Log `
                        "FALHA: $name - ExitCode $exitCode"

                    $failCount++
                }

            }
            catch {

                & $script:Write-Log `
                    "ERRO: $($_.Exception.Message)"

                $failCount++
            }

            $progressBar.Value++

            [System.Windows.Forms.Application]::DoEvents()
        }

    }
    catch {

        if ($_.Exception.Message -eq `
            "Operação cancelada pelo usuário.") {

            & $script:Write-Log `
                "Operação cancelada pelo usuário."

            $lblStatus.Text = "Cancelado."
        }
    }

    & $script:Write-Log ""

    & $script:Write-Log `
        "Desinstalação finalizada."

    & $script:Write-Log `
        "Sucesso: $successCount"

    & $script:Write-Log `
        "Falhas: $failCount"

    $progressBar.Value = 0

    Set-InterfaceBusy -Busy $false

    Refresh-InstalledPrograms

    $lblStatus.Text = `
        "Desinstalação concluída."

    [System.Windows.Forms.MessageBox]::Show(
        "Desinstalação finalizada.`r`n`r`nSucesso: $successCount`r`nFalhas: $failCount",
        "Desinstalação",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $(if ($failCount -gt 0) {
            [System.Windows.Forms.MessageBoxIcon]::Warning
        }
        else {
            [System.Windows.Forms.MessageBoxIcon]::Information
        })
    )
})

# ============================================================
# SITEF - INSTALAR
# ============================================================

$btnSitefInstall.Add_Click({

    if ($script:IsBusy) {
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Iniciar instalação do SITEF?`r`n`r`nOs arquivos serão baixados e os instaladores serão executados como Administrador.",
        "Confirmar SITEF",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    Set-InterfaceBusy -Busy $true

    $script:CancelRequested = $false

    $txtSitefLog.Clear()

    $progressSitef.Value = 0

    $lblStatus.Text = `
        "Instalando SITEF..."

    try {

        $success = Install-Sitef

        if ($success) {

            $lblStatus.Text = `
                "SITEF instalado com sucesso."

            [System.Windows.Forms.MessageBox]::Show(
                "Instalação do SITEF concluída com sucesso.`r`n`r`nConsulte o log para detalhes.",
                "SITEF",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )

        }
        else {

            $lblStatus.Text = `
                "SITEF apresentou falhas."

            [System.Windows.Forms.MessageBox]::Show(
                "A instalação do SITEF não foi concluída corretamente.`r`n`r`nConsulte o log.",
                "SITEF",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
        }

    }
    catch {

        & $script:Write-SitefLog `
            "ERRO INESPERADO: $($_.Exception.Message)"

        $lblStatus.Text = `
            "Erro na instalação SITEF."
    }

    Set-InterfaceBusy -Busy $false
})

# ============================================================
# ABRIR PASTA SITEF
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
# CANCELAR
# ============================================================

$btnCancel.Add_Click({

    if ($script:IsBusy) {

        $script:CancelRequested = $true

        & $script:Write-Log ""
        & $script:Write-Log `
            "Solicitação de cancelamento recebida..."

        $lblStatus.Text = `
            "Cancelando..."
    }
})

# ============================================================
# FECHAR FORMULÁRIO
# ============================================================

$form.Add_FormClosing({

    if ($script:IsBusy) {

        $result = [System.Windows.Forms.MessageBox]::Show(
            "Existe uma operação em andamento.`r`n`r`nDeseja realmente fechar o programa?",
            "Confirmar saída",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {

            $_.Cancel = $true

            return
        }

        $script:CancelRequested = $true
    }
})

# ============================================================
# CARREGAR LISTA AO ABRIR
# ============================================================

$form.Add_Shown({

    try {

        & $script:Write-Log `
            "MCNTV Installer iniciado."

        & $script:Write-Log `
            "Executando como Administrador."

        & $script:Write-Log `
            "Log: $LogFilePath"

        Refresh-InstalledPrograms

        $lblStatus.Text = `
            "Pronto para instalar."

    }
    catch {

        & $script:Write-Log `
            "Erro ao carregar lista inicial: $($_.Exception.Message)"
    }
})

# ============================================================
# EXECUTAR
# ============================================================

[void]$form.ShowDialog()
