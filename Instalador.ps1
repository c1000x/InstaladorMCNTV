```powershell
<#
    ProvisioningTool.ps1
    Interface grafica para provisionamento de maquinas Windows.

    Recursos:
      - Janela maximizada e redimensionavel
      - Configuracao do sistema
      - Instalacao de aplicativos via Chocolatey/Winget
      - Gerenciamento/desinstalacao de aplicativos
      - Modo simulacao (dry-run)
      - Logs e relatorios
      - Botao externo "Ativar Windows"

    ATENCAO:
      O botao "Ativar Windows" baixa e executa um script remoto.
      Use somente se voce confiar na fonte.
#>

# ============================================================
# EXECUCAO LOCAL OU VIA "irm ... | iex"
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
        [System.Text.UTF8Encoding]::new($false)
    )
}

# ============================================================
# AUTO-ELEVACAO
# ============================================================

$isAdmin = (
    [Security.Principal.WindowsPrincipal]
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    $psi.Verb = "runas"
    $psi.UseShellExecute = $true

    try {
        [System.Diagnostics.Process]::Start($psi) | Out-Null
    }
    catch {
        Write-Host "Elevacao cancelada pelo usuario."
    }

    exit
}

# ============================================================
# ASSEMBLIES
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================
# BOTAO PERSONALIZADO
# ============================================================

$CustomScriptUrl   = "https://get.activated.win"
$CustomScriptLabel = "Ativar Windows"

# ============================================================
# DIRETORIOS / LOG
# ============================================================

$ScriptDir = Split-Path -Parent $scriptPath

$LogsDir = Join-Path $ScriptDir "logs"

if (-not (Test-Path $LogsDir)) {
    New-Item -Path $LogsDir -ItemType Directory -Force | Out-Null
}

$Timestamp   = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$LogFilePath = Join-Path $LogsDir "provisionamento_$Timestamp.log"
$ReportPath  = Join-Path $LogsDir "relatorio_$Timestamp.txt"

$script:Results = [ordered]@{}

# ============================================================
# APPS.JSON
# ============================================================

$AppsJsonPath = Join-Path $ScriptDir "apps.json"

$DefaultApps = @{
    choco = @(
        "googlechrome"
    )

    winget = @(
        "AnyDesk.AnyDesk",
        "Adobe.Acrobat.Reader.64-bit",
        "Oracle.JavaRuntimeEnvironment",
        "Mozilla.Firefox.pt-BR",
        "7zip.7zip"
    )

    wingetStore = @(
        "9WZDNCRFJBMP"
    )
}

if (-not (Test-Path $AppsJsonPath)) {
    $DefaultApps |
        ConvertTo-Json -Depth 5 |
        Set-Content -Path $AppsJsonPath -Encoding UTF8
}

try {
    $AppsConfig = Get-Content -Path $AppsJsonPath -Raw |
        ConvertFrom-Json
}
catch {
    $AppsConfig = [PSCustomObject]$DefaultApps
}

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
            "Aviso: nao foi possivel criar ponto de restauracao. $($_.Exception.Message)"
        )
    }
}

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
            "[SIMULACAO] Ativaria System Restore em $drive, reservaria 10% do volume para copias de sombra e agendaria snapshots a cada 4h."
        )

        return
    }

    try {

        Enable-ComputerRestore `
            -Drive "$drive\" `
            -ErrorAction Stop

        $Log.Invoke("System Restore ativado em $drive")
    }
    catch {

        $Log.Invoke(
            "Aviso ao ativar System Restore: $($_.Exception.Message)"
        )
    }

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

    $Log.Invoke("Criando snapshot inicial...")

    vssadmin create shadow `
        /for="$drive" 2>&1 |
        ForEach-Object {
            $Log.Invoke($_)
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
        "Tarefa agendada 'VersoesAnteriores_ShadowCopy' criada."
    )
}

function Step-IconesAreaTrabalho {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke("== Icones Este Computador / Pasta do Usuario ==")

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULACAO] Ativaria os icones e reiniciaria o Explorer."
        )

        return
    }

    $path =
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"

    New-Item -Path $path -Force | Out-Null

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

    Start-Process explorer

    $Log.Invoke("Icones configurados e Explorer reiniciado.")
}

function Step-Telemetria {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke("== Telemetria ==")

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULACAO] Desativaria a telemetria via GPO local."
        )

        return
    }

    $path =
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"

    New-Item -Path $path -Force | Out-Null

    Set-ItemProperty `
        -Path $path `
        -Name "AllowTelemetry" `
        -Value 0 `
        -Force

    $Log.Invoke("Telemetria desativada.")
}

function Step-Energia {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke("== Plano de energia ==")

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULACAO] Ajustaria monitor/disco/suspensao/hibernacao para nunca desligar."
        )

        return
    }

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

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke(
        "== Fuso horario e localizacao (Brasil) =="
    )

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULACAO] Definiria fuso horario de Brasilia e localizacao Brasil."
        )

        return
    }

    try {

        Set-TimeZone `
            -Id "E. South America Standard Time" `
            -ErrorAction Stop

        Set-WinHomeLocation -GeoId 76

        $Log.Invoke(
            "Fuso horario e localizacao definidos."
        )
    }
    catch {

        $Log.Invoke(
            "Aviso ao ajustar regiao/idioma: $($_.Exception.Message)"
        )
    }
}

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
            "Removido (se existia): $a"
        )
    }
}

function Ensure-ChocoAvailable {

    param($Log)

    if (Get-Command choco -ErrorAction SilentlyContinue) {
        return $true
    }

    $machinePath =
        [System.Environment]::GetEnvironmentVariable(
            "Path",
            "Machine"
        )

    $userPath =
        [System.Environment]::GetEnvironmentVariable(
            "Path",
            "User"
        )

    $env:Path = "$machinePath;$userPath"

    if (Get-Command choco -ErrorAction SilentlyContinue) {
        return $true
    }

    $chocoBin =
        Join-Path $env:ProgramData "chocolatey\bin"

    if (
        Test-Path (
            Join-Path $chocoBin "choco.exe"
        )
    ) {

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

function Step-Chocolatey {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke("== Chocolatey ==")

    if (Get-Command choco -ErrorAction SilentlyContinue) {

        $Log.Invoke(
            "Chocolatey ja instalado, pulando."
        )

        return
    }

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULACAO] Instalaria o Chocolatey."
        )

        return
    }

    Set-ExecutionPolicy `
        Bypass `
        -Scope Process `
        -Force

    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.ServicePointManager]::SecurityProtocol -bor 3072

    $webClient =
        [System.Net.WebClient]::new()

    $installScript =
        $webClient.DownloadString(
            "https://community.chocolatey.org/install.ps1"
        )

    Invoke-Expression $installScript

    $env:Path += ";$env:ProgramData\chocolatey\bin"

    $Log.Invoke(
        "Chocolatey instalado."
    )
}

function Step-WingetUpgradeAll {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke(
        "== Preparando winget e atualizando todos os apps =="
    )

    if (-not $DryRun) {

        try {

            Install-PackageProvider `
                -Name NuGet `
                -Force `
                -ErrorAction Stop |
                Out-Null

            if (
                -not (
                    Get-Module `
                        -ListAvailable `
                        -Name Microsoft.WinGet.Client
                )
            ) {

                Install-Module `
                    -Name Microsoft.WinGet.Client `
                    -Force `
                    -Repository PSGallery `
                    -Confirm:$false `
                    -ErrorAction Stop
            }

            Repair-WinGetPackageManager `
                -ErrorAction SilentlyContinue

            winget source update | Out-Null
        }
        catch {

            $Log.Invoke(
                "Aviso ao preparar winget: $($_.Exception.Message)"
            )
        }
    }

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULACAO] winget upgrade --all"
        )

        return
    }

    winget upgrade --all `
        --accept-source-agreements `
        --accept-package-agreements `
        --silent 2>&1 |
        ForEach-Object {
            $Log.Invoke($_)
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
            "[SIMULACAO] Criaria tarefa 'LimpezaDisco'."
        )

        return
    }

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
        "Tarefa 'LimpezaDisco' criada/atualizada."
    )
}

# ============================================================
# CATALOGO
# ============================================================

function Build-AppCatalogLabels {

    $script:AppCatalogMap = @{}

    $labels =
        [System.Collections.ArrayList]::new()

    foreach ($id in @($AppsConfig.choco)) {

        $label = "[Choco] $id"

        $script:AppCatalogMap[$label] = @{
            Manager = "choco"
            Id      = $id
        }

        [void]$labels.Add($label)
    }

    foreach ($id in @($AppsConfig.winget)) {

        $label = "[Winget] $id"

        $script:AppCatalogMap[$label] = @{
            Manager = "winget"
            Id      = $id
        }

        [void]$labels.Add($label)
    }

    foreach ($id in @($AppsConfig.wingetStore)) {

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
            $_.DisplayName `
            -and (-not $_.SystemComponent) `
            -and $_.UninstallString
        } |
        Select-Object `
            DisplayName,
            UninstallString,
            QuietUninstallString |
        Sort-Object DisplayName
}

# ============================================================
# CORES / FONTES
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

$FontNormal =
    [System.Drawing.Font]::new(
        "Segoe UI",
        9
    )

$FontSmall =
    [System.Drawing.Font]::new(
        "Segoe UI",
        8
    )

$FontHeader =
    [System.Drawing.Font]::new(
        "Segoe UI Semibold",
        10
    )

$FontTitle =
    [System.Drawing.Font]::new(
        "Segoe UI Semibold",
        18
    )

$FontButton =
    [System.Drawing.Font]::new(
        "Segoe UI",
        9
    )

# ============================================================
# FORMULARIO
# ============================================================

$form =
    [System.Windows.Forms.Form]::new()

$form.Text =
    "MCNTV Installer - Provisionamento Windows"

$form.StartPosition =
    [System.Windows.Forms.FormStartPosition]::CenterScreen

$form.FormBorderStyle =
    [System.Windows.Forms.FormBorderStyle]::Sizable

$form.MaximizeBox = $true
$form.MinimizeBox = $true
$form.BackColor = $ColorBackground
$form.Font = $FontNormal

# Abre maximizada
$form.WindowState =
    [System.Windows.Forms.FormWindowState]::Maximized

# ============================================================
# LAYOUT PRINCIPAL
# ============================================================

$mainLayout =
    [System.Windows.Forms.TableLayoutPanel]::new()

$mainLayout.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$mainLayout.Padding =
    [System.Windows.Forms.Padding]::new(
        20,
        15,
        20,
        15
    )

$mainLayout.ColumnCount = 3
$mainLayout.RowCount = 3

[void]$mainLayout.ColumnStyles.Add(
    [System.Windows.Forms.ColumnStyle]::new(
        [System.Windows.Forms.SizeType]::Percent,
        33.33
    )
)

[void]$mainLayout.ColumnStyles.Add(
    [System.Windows.Forms.ColumnStyle]::new(
        [System.Windows.Forms.SizeType]::Percent,
        33.33
    )
)

[void]$mainLayout.ColumnStyles.Add(
    [System.Windows.Forms.ColumnStyle]::new(
        [System.Windows.Forms.SizeType]::Percent,
        33.34
    )
)

[void]$mainLayout.RowStyles.Add(
    [System.Windows.Forms.RowStyle]::new(
        [System.Windows.Forms.SizeType]::Absolute,
        65
    )
)

[void]$mainLayout.RowStyles.Add(
    [System.Windows.Forms.RowStyle]::new(
        [System.Windows.Forms.SizeType]::Percent,
        68
    )
)

[void]$mainLayout.RowStyles.Add(
    [System.Windows.Forms.RowStyle]::new(
        [System.Windows.Forms.SizeType]::Percent,
        32
    )
)

$form.Controls.Add($mainLayout)

# ============================================================
# CABECALHO
# ============================================================

$headerPanel =
    [System.Windows.Forms.Panel]::new()

$headerPanel.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$mainLayout.Controls.Add(
    $headerPanel,
    0,
    0
)

$mainLayout.SetColumnSpan(
    $headerPanel,
    3
)

$lblMainTitle =
    [System.Windows.Forms.Label]::new()

$lblMainTitle.Text =
    "MCNTV Installer"

$lblMainTitle.Font = $FontTitle
$lblMainTitle.ForeColor = $ColorText
$lblMainTitle.Location =
    [System.Drawing.Point]::new(0,0)

$lblMainTitle.Size =
    [System.Drawing.Size]::new(500,35)

$headerPanel.Controls.Add($lblMainTitle)

$lblSubtitle =
    [System.Windows.Forms.Label]::new()

$lblSubtitle.Text =
    "Instale, configure e gerencie este computador"

$lblSubtitle.Font = $FontNormal
$lblSubtitle.ForeColor = $ColorMuted

$lblSubtitle.Location =
    [System.Drawing.Point]::new(0,35)

$lblSubtitle.Size =
    [System.Drawing.Size]::new(600,25)

$headerPanel.Controls.Add($lblSubtitle)

# ============================================================
# GRUPO 1
# ============================================================

$grpSystem =
    [System.Windows.Forms.GroupBox]::new()

$grpSystem.Text =
    "1. Configuracao do sistema"

$grpSystem.Font = $FontHeader
$grpSystem.ForeColor = $ColorText
$grpSystem.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$grpSystem.Margin =
    [System.Windows.Forms.Padding]::new(5)

$mainLayout.Controls.Add(
    $grpSystem,
    0,
    1
)

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

$UncheckedByDefault =
    @(
        "Versoes Anteriores (Shadow Copy)"
    )

$checkboxes = @{}

$systemPanel =
    [System.Windows.Forms.Panel]::new()

$systemPanel.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$systemPanel.AutoScroll = $true
$systemPanel.Padding =
    [System.Windows.Forms.Padding]::new(10,10,10,10)

$grpSystem.Controls.Add($systemPanel)

$y = 10

foreach ($key in $steps.Keys) {

    $cb =
        [System.Windows.Forms.CheckBox]::new()

    $cb.Text = $key

    $cb.Checked =
        -not (
            $UncheckedByDefault -contains $key
        )

    $cb.Location =
        [System.Drawing.Point]::new(5,$y)

    $cb.Size =
        [System.Drawing.Size]::new(500,25)

    $cb.Font = $FontNormal
    $cb.ForeColor = $ColorText

    $systemPanel.Controls.Add($cb)

    $checkboxes[$key] = $cb

    $y += 28
}

$chkDryRun =
    [System.Windows.Forms.CheckBox]::new()

$chkDryRun.Text =
    "Modo Simulacao (dry-run)"

$chkDryRun.Location =
    [System.Drawing.Point]::new(5,($y + 3))

$chkDryRun.Size =
    [System.Drawing.Size]::new(500,25)

$chkDryRun.ForeColor =
    [System.Drawing.Color]::DarkBlue

$systemPanel.Controls.Add($chkDryRun)

# ============================================================
# BOTOES DO GRUPO 1
# ============================================================

$buttonPanel =
    [System.Windows.Forms.TableLayoutPanel]::new()

$buttonPanel.Location =
    [System.Drawing.Point]::new(5,($y + 40))

$buttonPanel.Size =
    [System.Drawing.Size]::new(500,75)

$buttonPanel.ColumnCount = 2
$buttonPanel.RowCount = 2

[void]$buttonPanel.ColumnStyles.Add(
    [System.Windows.Forms.ColumnStyle]::new(
        [System.Windows.Forms.SizeType]::Percent,
        50
    )
)

[void]$buttonPanel.ColumnStyles.Add(
    [System.Windows.Forms.ColumnStyle]::new(
        [System.Windows.Forms.SizeType]::Percent,
        50
    )
)

[void]$buttonPanel.RowStyles.Add(
    [System.Windows.Forms.RowStyle]::new(
        [System.Windows.Forms.SizeType]::Percent,
        50
    )
)

[void]$buttonPanel.RowStyles.Add(
    [System.Windows.Forms.RowStyle]::new(
        [System.Windows.Forms.SizeType]::Percent,
        50
    )
)

$systemPanel.Controls.Add($buttonPanel)

$btnSelAll =
    [System.Windows.Forms.Button]::new()

$btnSelAll.Text = "Marcar todos"
$btnSelAll.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$btnSelAll.Margin =
    [System.Windows.Forms.Padding]::new(3)

$btnSelAll.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnSelAll.BackColor = $ColorSurface

$buttonPanel.Controls.Add(
    $btnSelAll,
    0,
    0
)

$btnSelNone =
    [System.Windows.Forms.Button]::new()

$btnSelNone.Text =
    "Desmarcar todos"

$btnSelNone.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$btnSelNone.Margin =
    [System.Windows.Forms.Padding]::new(3)

$btnSelNone.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnSelNone.BackColor =
    $ColorSurface

$buttonPanel.Controls.Add(
    $btnSelNone,
    1,
    0
)

$btnEditApps =
    [System.Windows.Forms.Button]::new()

$btnEditApps.Text =
    "Editar apps.json"

$btnEditApps.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$btnEditApps.Margin =
    [System.Windows.Forms.Padding]::new(3)

$btnEditApps.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnEditApps.BackColor =
    $ColorSurface

$buttonPanel.Controls.Add(
    $btnEditApps,
    0,
    1
)

$btnRun =
    [System.Windows.Forms.Button]::new()

$btnRun.Text =
    "Executar configuracao"

$btnRun.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$btnRun.Margin =
    [System.Windows.Forms.Padding]::new(3)

$btnRun.BackColor =
    $ColorPrimary

$btnRun.ForeColor =
    [System.Drawing.Color]::White

$btnRun.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnRun.FlatAppearance.BorderSize = 0

$buttonPanel.Controls.Add(
    $btnRun,
    1,
    1
)

$btnSelAll.Add_Click({
    $checkboxes.Values |
        ForEach-Object {
            $_.Checked = $true
        }
})

$btnSelNone.Add_Click({
    $checkboxes.Values |
        ForEach-Object {
            $_.Checked = $false
        }
})

$btnEditApps.Add_Click({
    Start-Process notepad.exe $AppsJsonPath
})

# ============================================================
# GRUPO 2 - INSTALAR
# ============================================================

$grpInstall =
    [System.Windows.Forms.GroupBox]::new()

$grpInstall.Text =
    "2. Instalar aplicativos"

$grpInstall.Font = $FontHeader
$grpInstall.ForeColor = $ColorText
$grpInstall.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$grpInstall.Margin =
    [System.Windows.Forms.Padding]::new(5)

$mainLayout.Controls.Add(
    $grpInstall,
    1,
    1
)

$installLayout =
    [System.Windows.Forms.TableLayoutPanel]::new()

$installLayout.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$installLayout.Padding =
    [System.Windows.Forms.Padding]::new(10)

$installLayout.ColumnCount = 1
$installLayout.RowCount = 3

[void]$installLayout.RowStyles.Add(
    [System.Windows.Forms.RowStyle]::new(
        [System.Windows.Forms.SizeType]::Absolute,
        30
    )
)

[void]$installLayout.RowStyles.Add(
    [System.Windows.Forms.RowStyle]::new(
        [System.Windows.Forms.SizeType]::Percent,
        100
    )
)

[void]$installLayout.RowStyles.Add(
    [System.Windows.Forms.RowStyle]::new(
        [System.Windows.Forms.SizeType]::Absolute,
        50
    )
)

$grpInstall.Controls.Add($installLayout)

$lblInstallInfo =
    [System.Windows.Forms.Label]::new()

$lblInstallInfo.Text =
    "Selecione os aplicativos que deseja instalar:"

$lblInstallInfo.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$lblInstallInfo.ForeColor =
    $ColorMuted

$installLayout.Controls.Add(
    $lblInstallInfo,
    0,
    0
)

$clbInstall =
    [System.Windows.Forms.CheckedListBox]::new()

$clbInstall.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$clbInstall.CheckOnClick = $true
$clbInstall.Font = $FontNormal

foreach ($label in (Build-AppCatalogLabels)) {

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

$btnInstallSelected =
    [System.Windows.Forms.Button]::new()

$btnInstallSelected.Text =
    "INSTALAR SELECIONADOS"

$btnInstallSelected.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$btnInstallSelected.Margin =
    [System.Windows.Forms.Padding]::new(3)

$btnInstallSelected.Font =
    [System.Drawing.Font]::new(
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
# GRUPO 3 - REMOVER
# ============================================================

$grpUninstall =
    [System.Windows.Forms.GroupBox]::new()

$grpUninstall.Text =
    "3. Gerenciar aplicativos instalados"

$grpUninstall.Font = $FontHeader
$grpUninstall.ForeColor = $ColorText

$grpUninstall.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$grpUninstall.Margin =
    [System.Windows.Forms.Padding]::new(5)

$mainLayout.Controls.Add(
    $grpUninstall,
    2,
    1
)

$uninstallLayout =
    [System.Windows.Forms.TableLayoutPanel]::new()

$uninstallLayout.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$uninstallLayout.Padding =
    [System.Windows.Forms.Padding]::new(10)

$uninstallLayout.ColumnCount = 1
$uninstallLayout.RowCount = 4

[void]$uninstallLayout.RowStyles.Add(
    [System.Windows.Forms.RowStyle]::new(
        [System.Windows.Forms.SizeType]::Absolute,
        30
    )
)

[void]$uninstallLayout.RowStyles.Add(
    [System.Windows.Forms.RowStyle]::new(
        [System.Windows.Forms.SizeType]::Percent,
        100
    )
)

[void]$uninstallLayout.RowStyles.Add(
    [System.Windows.Forms.RowStyle]::new(
        [System.Windows.Forms.SizeType]::Absolute,
        45
    )
)

[void]$uninstallLayout.RowStyles.Add(
    [System.Windows.Forms.RowStyle]::new(
        [System.Windows.Forms.SizeType]::Absolute,
        45
    )
)

$grpUninstall.Controls.Add($uninstallLayout)

$lblUninstallInfo =
    [System.Windows.Forms.Label]::new()

$lblUninstallInfo.Text =
    "Atualize a lista e selecione o que deseja remover:"

$lblUninstallInfo.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$lblUninstallInfo.ForeColor =
    $ColorMuted

$uninstallLayout.Controls.Add(
    $lblUninstallInfo,
    0,
    0
)

$clbUninstall =
    [System.Windows.Forms.CheckedListBox]::new()

$clbUninstall.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$clbUninstall.CheckOnClick = $true
$clbUninstall.Font = $FontNormal

$uninstallLayout.Controls.Add(
    $clbUninstall,
    0,
    1
)

$uninstallButtonLayout =
    [System.Windows.Forms.TableLayoutPanel]::new()

$uninstallButtonLayout.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$uninstallButtonLayout.ColumnCount = 2

[void]$uninstallButtonLayout.ColumnStyles.Add(
    [System.Windows.Forms.ColumnStyle]::new(
        [System.Windows.Forms.SizeType]::Percent,
        50
    )
)

[void]$uninstallButtonLayout.ColumnStyles.Add(
    [System.Windows.Forms.ColumnStyle]::new(
        [System.Windows.Forms.SizeType]::Percent,
        50
    )
)

$uninstallLayout.Controls.Add(
    $uninstallButtonLayout,
    0,
    2
)

$btnRefreshInstalled =
    [System.Windows.Forms.Button]::new()

$btnRefreshInstalled.Text =
    "Atualizar lista"

$btnRefreshInstalled.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$btnRefreshInstalled.Margin =
    [System.Windows.Forms.Padding]::new(3)

$btnRefreshInstalled.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnRefreshInstalled.BackColor =
    $ColorSurface

$uninstallButtonLayout.Controls.Add(
    $btnRefreshInstalled,
    0,
    0
)

$btnUninstallSelected =
    [System.Windows.Forms.Button]::new()

$btnUninstallSelected.Text =
    "Desinstalar selecionados"

$btnUninstallSelected.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$btnUninstallSelected.Margin =
    [System.Windows.Forms.Padding]::new(3)

$btnUninstallSelected.BackColor =
    $ColorDanger

$btnUninstallSelected.ForeColor =
    [System.Drawing.Color]::White

$btnUninstallSelected.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnUninstallSelected.FlatAppearance.BorderSize = 0

$uninstallButtonLayout.Controls.Add(
    $btnUninstallSelected,
    1,
    0
)

# ============================================================
# BOTAO ATIVAR WINDOWS
# ============================================================

$btnCustom =
    [System.Windows.Forms.Button]::new()

$btnCustom.Text =
    $CustomScriptLabel

$btnCustom.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$btnCustom.Margin =
    [System.Windows.Forms.Padding]::new(3)

$btnCustom.Font = $FontButton
$btnCustom.BackColor = $ColorSurface

$btnCustom.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnCustom.FlatAppearance.BorderColor =
    $ColorBorder

$uninstallLayout.Controls.Add(
    $btnCustom,
    0,
    3
)

# ============================================================
# STATUS / LOG
# ============================================================

$grpStatus =
    [System.Windows.Forms.GroupBox]::new()

$grpStatus.Text = "Status"
$grpStatus.Font = $FontHeader
$grpStatus.ForeColor = $ColorText
$grpStatus.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$grpStatus.Margin =
    [System.Windows.Forms.Padding]::new(5)

$mainLayout.Controls.Add(
    $grpStatus,
    0,
    2
)

$mainLayout.SetColumnSpan(
    $grpStatus,
    3
)

$statusLayout =
    [System.Windows.Forms.TableLayoutPanel]::new()

$statusLayout.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$statusLayout.Padding =
    [System.Windows.Forms.Padding]::new(10)

$statusLayout.ColumnCount = 1
$statusLayout.RowCount = 3

[void]$statusLayout.RowStyles.Add(
    [System.Windows.Forms.RowStyle]::new(
        [System.Windows.Forms.SizeType]::Absolute,
        25
    )
)

[void]$statusLayout.RowStyles.Add(
    [System.Windows.Forms.RowStyle]::new(
        [System.Windows.Forms.SizeType]::Absolute,
        25
    )
)

[void]$statusLayout.RowStyles.Add(
    [System.Windows.Forms.RowStyle]::new(
        [System.Windows.Forms.SizeType]::Percent,
        100
    )
)

$grpStatus.Controls.Add($statusLayout)

$progressBar =
    [System.Windows.Forms.ProgressBar]::new()

$progressBar.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$progressBar.Minimum = 0

$statusLayout.Controls.Add(
    $progressBar,
    0,
    0
)

$lblStatus =
    [System.Windows.Forms.Label]::new()

$lblStatus.Text =
    "Pronto para instalar"

$lblStatus.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$lblStatus.ForeColor =
    $ColorSuccess

$statusLayout.Controls.Add(
    $lblStatus,
    0,
    1
)

$txtLog =
    [System.Windows.Forms.TextBox]::new()

$txtLog.Multiline = $true
$txtLog.ScrollBars =
    [System.Windows.Forms.ScrollBars]::Vertical

$txtLog.ReadOnly = $true

$txtLog.Dock =
    [System.Windows.Forms.DockStyle]::Fill

$txtLog.Font =
    [System.Drawing.Font]::new(
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

    param($msg)

    $line = "$msg"

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

    [System.Windows.Forms.Application]::DoEvents()
}

# ============================================================
# ATIVAR WINDOWS
# ============================================================

$btnCustom.Add_Click({

    if (
        [string]::IsNullOrWhiteSpace(
            $CustomScriptUrl
        )
    ) {

        [System.Windows.Forms.MessageBox]::Show(
            "Configure a URL do ativador.",
            "Configure o link"
        ) | Out-Null

        return
    }

    $confirm =
        [System.Windows.Forms.MessageBox]::Show(
            "Isso vai baixar e executar o script em:`n`n$CustomScriptUrl`n`nTem certeza que confia nesta fonte?",
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

    $btnCustom.Enabled = $false

    $AppendLog.Invoke(
        "== Executando script externo: $CustomScriptLabel =="
    )

    $AppendLog.Invoke(
        "URL: $CustomScriptUrl"
    )

    try {

        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor 3072

        $webClient =
            [System.Net.WebClient]::new()

        $scriptContent =
            $webClient.DownloadString(
                $CustomScriptUrl
            )

        Invoke-Expression $scriptContent 2>&1 |
            ForEach-Object {
                $AppendLog.Invoke($_)
            }

        $AppendLog.Invoke(
            "Script '$CustomScriptLabel' concluido."
        )
    }
    catch {

        $AppendLog.Invoke(
            "ERRO ao executar '$CustomScriptLabel': $($_.Exception.Message)"
        )
    }

    $btnCustom.Enabled = $true
})

# ============================================================
# EXECUTAR CONFIGURACAO
# ============================================================

$btnRun.Add_Click({

    $btnRun.Enabled = $false
    $btnSelAll.Enabled = $false
    $btnSelNone.Enabled = $false
    $btnEditApps.Enabled = $false

    $txtLog.Clear()

    $script:Results.Clear()

    $DryRun =
        $chkDryRun.Checked

    $selected =
        @(
            $steps.Keys |
            Where-Object {
                $checkboxes[$_].Checked
            }
        )

    $progressBar.Maximum =
        [Math]::Max(
            1,
            $selected.Count
        )

    $progressBar.Value = 0

    $modo =
        if ($DryRun) {
            "SIMULACAO (nada sera alterado)"
        }
        else {
            "EXECUCAO REAL"
        }

    $AppendLog.Invoke(
        "Iniciando provisionamento - Modo: $modo"
    )

    $AppendLog.Invoke(
        "Log completo salvo em: $LogFilePath"
    )

    $AppendLog.Invoke("")

    foreach ($key in $steps.Keys) {

        if ($checkboxes[$key].Checked) {

            $lblStatus.Text =
                "Executando: $key"

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

                $AppendLog.Invoke(
                    "ERRO em '$key': $($_.Exception.Message)"
                )

                $script:Results[$key] =
                    "FALHA: $($_.Exception.Message)"
            }

            $progressBar.Value =
                [Math]::Min(
                    $progressBar.Maximum,
                    $progressBar.Value + 1
                )
        }
        else {

            $script:Results[$key] =
                "PULADO"
        }
    }

    $AppendLog.Invoke("")
    $AppendLog.Invoke("=== Concluido ===")

    $lblStatus.Text =
        "Provisionamento concluido"

    # --------------------------------------------------------
    # RELATORIO
    # --------------------------------------------------------

    $reportLines = @()

    $reportLines +=
        "Relatorio de Provisionamento - $Timestamp"

    $reportLines +=
        "Modo: $modo"

    $reportLines += ""

    foreach ($k in $script:Results.Keys) {

        $reportLines +=
            (
                "{0,-45} {1}" -f
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

    $btnRun.Enabled = $true
    $btnSelAll.Enabled = $true
    $btnSelNone.Enabled = $true
    $btnEditApps.Enabled = $true

    [System.Windows.Forms.MessageBox]::Show(
        "Provisionamento concluido ($modo).`n`nRelatorio em:`n$ReportPath",
        "Finalizado"
    ) | Out-Null
})

# ============================================================
# INSTALAR PROGRAMAS
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
        ) | Out-Null

        return
    }

    $btnInstallSelected.Enabled = $false

    $AppendLog.Invoke(
        "== Instalando programas selecionados =="
    )

    $precisaChoco =
        $selectedLabels |
        Where-Object {
            $script:AppCatalogMap[$_].Manager -eq "choco"
        }

    $chocoOk =
        if ($precisaChoco) {
            Ensure-ChocoAvailable -Log $AppendLog
        }
        else {
            $true
        }

    foreach ($label in $selectedLabels) {

        $info =
            $script:AppCatalogMap[$label]

        if (-not $info) {
            continue
        }

        if (
            $info.Manager -eq "choco" -and
            -not $chocoOk
        ) {

            $AppendLog.Invoke(
                "Pulando '$($info.Id)': Chocolatey indisponivel."
            )

            continue
        }

        try {

            switch ($info.Manager) {

                "choco" {

                    $AppendLog.Invoke(
                        "Instalando (choco): $($info.Id)"
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
                        "Instalando (winget): $($info.Id)"
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
                        "Instalando (msstore): $($info.Id)"
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
                "ERRO ao instalar '$($info.Id)': $($_.Exception.Message)"
            )
        }
    }

    $AppendLog.Invoke(
        "Instalacao dos selecionados concluida."
    )

    $btnInstallSelected.Enabled = $true
})

# ============================================================
# LISTAR PROGRAMAS
# ============================================================

$script:UninstallMap = @{}

$btnRefreshInstalled.Add_Click({

    $btnRefreshInstalled.Enabled = $false

    $AppendLog.Invoke(
        "Consultando programas instalados no registro..."
    )

    $clbUninstall.Items.Clear()

    $script:UninstallMap = @{}

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

    $btnRefreshInstalled.Enabled = $true
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
        ) | Out-Null

        return
    }

    $confirm =
        [System.Windows.Forms.MessageBox]::Show(
            "Desinstalar os seguintes programas?`n`n$($selected -join "`n")",
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

    $btnUninstallSelected.Enabled = $false

    $AppendLog.Invoke(
        "== Desinstalando programas selecionados =="
    )

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
                "Concluido: $name"
            )
        }
        catch {

            $AppendLog.Invoke(
                "ERRO ao desinstalar '$name': $($_.Exception.Message)"
            )
        }
    }

    $AppendLog.Invoke(
        "Remocao concluida."
    )

    $AppendLog.Invoke(
        "Clique em 'Atualizar lista' para atualizar."
    )

    $btnUninstallSelected.Enabled = $true
})

# ============================================================
# ATUALIZAR LISTA AUTOMATICAMENTE AO ABRIR
# ============================================================

$form.Add_Shown({

    $btnRefreshInstalled.PerformClick()

    $lblStatus.Text =
        "Pronto para instalar"

    $progressBar.Value = 0
})

# ============================================================
# EXECUTAR
# ============================================================

[void]$form.ShowDialog()
```
