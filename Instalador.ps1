<#
    MCNTV Installer
    Provisionamento Windows

    Correções:
      - Compatibilidade com PowerShell 5.1
      - Correção dos New-Object System.Drawing.Point
      - Correção da verificação de administrador
      - Janela inicia maximizada
      - Redimensionamento correto dos controles
      - Mantém instalação via Chocolatey/Winget
      - Mantém gerenciamento de programas
      - Botão de ativação abre as configurações oficiais do Windows
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
# ELEVAÇÃO PARA ADMINISTRADOR
# ============================================================

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)

$isAdmin = $currentPrincipal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {

    $psi = New-Object System.Diagnostics.ProcessStartInfo

    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    $psi.Verb = "runas"
    $psi.UseShellExecute = $true

    try {
        [System.Diagnostics.Process]::Start($psi) | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "A execução como Administrador foi cancelada.",
            "MCNTV Installer"
        ) | Out-Null
    }

    exit
}

# ============================================================
# WINDOWS FORMS
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# ============================================================
# DIRETÓRIOS / LOGS
# ============================================================

$ScriptDir = Split-Path -Parent $scriptPath

$LogsDir = Join-Path $ScriptDir "logs"

if (-not (Test-Path $LogsDir)) {
    New-Item -Path $LogsDir -ItemType Directory -Force | Out-Null
}

$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

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

    $AppsConfig = Get-Content `
        -Path $AppsJsonPath `
        -Raw |
        ConvertFrom-Json

}
catch {

    $AppsConfig = [PSCustomObject]$DefaultApps
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
        $Log.Invoke("[SIMULAÇÃO] Criaria um ponto de restauração.")
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

        $Log.Invoke("Ponto de restauração criado.")
    }
    catch {

        $Log.Invoke(
            "Aviso: não foi possível criar ponto de restauração: $($_.Exception.Message)"
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
        "== Versões Anteriores / Shadow Copy em $drive =="
    )

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULAÇÃO] Ativaria System Restore e configuraria Shadow Copy."
        )

        return
    }

    try {

        Enable-ComputerRestore `
            -Drive "$drive\" `
            -ErrorAction Stop

        $Log.Invoke("System Restore ativado.")
    }
    catch {

        $Log.Invoke(
            "Aviso ao ativar System Restore: $($_.Exception.Message)"
        )
    }

    try {

        $Log.Invoke(
            "Reservando espaço para Shadow Copy..."
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
            "Tarefa Shadow Copy criada."
        )
    }
    catch {

        $Log.Invoke(
            "Erro Shadow Copy: $($_.Exception.Message)"
        )
    }
}

function Step-IconesAreaTrabalho {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke(
        "== Ícones da Área de Trabalho =="
    )

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULAÇÃO] Ativaria Este Computador e Pasta do Usuário."
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
            "Ícones configurados."
        )
    }
    catch {

        $Log.Invoke(
            "Erro ao configurar ícones: $($_.Exception.Message)"
        )
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
            "[SIMULAÇÃO] Configuraria a política de telemetria."
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
            "Política de telemetria configurada."
        )
    }
    catch {

        $Log.Invoke(
            "Erro na telemetria: $($_.Exception.Message)"
        )
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
            "[SIMULAÇÃO] Ajustaria monitor, disco, suspensão e hibernação."
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

    $Log.Invoke(
        "Plano de energia ajustado."
    )
}

function Step-RegiaoIdioma {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke(
        "== Fuso horário e localização =="
    )

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULAÇÃO] Configuraria fuso de Brasília e localização Brasil."
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
            "Fuso horário e localização configurados."
        )
    }
    catch {

        $Log.Invoke(
            "Aviso: $($_.Exception.Message)"
        )
    }
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
            "Processado: $a"
        )
    }
}

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

    $env:Path =
        "$machinePath;$userPath"

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

    $Log.Invoke(
        "Chocolatey não encontrado."
    )

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
            "Chocolatey já instalado."
        )

        return
    }

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULAÇÃO] Instalaria Chocolatey."
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

        $webClient =
            New-Object System.Net.WebClient

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
    catch {

        throw
    }
}

function Step-WingetUpgradeAll {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke(
        "== Winget / atualização de aplicativos =="
    )

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULAÇÃO] Executaria winget upgrade --all."
        )

        return
    }

    try {

        if (Get-Command winget -ErrorAction SilentlyContinue) {

            winget source update 2>&1 |
                ForEach-Object {
                    $Log.Invoke($_)
                }

            winget upgrade --all `
                --accept-source-agreements `
                --accept-package-agreements `
                --silent 2>&1 |
                ForEach-Object {
                    $Log.Invoke($_)
                }

        }
        else {

            $Log.Invoke(
                "Winget não encontrado neste Windows."
            )
        }
    }
    catch {

        $Log.Invoke(
            "Aviso Winget: $($_.Exception.Message)"
        )
    }
}

function Step-TarefaLimpeza {

    param(
        $Log,
        [bool]$DryRun
    )

    $Log.Invoke(
        "== Limpeza de disco =="
    )

    if ($DryRun) {

        $Log.Invoke(
            "[SIMULAÇÃO] Criaria tarefa semanal LimpezaDisco."
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
            "Erro: $($_.Exception.Message)"
        )
    }
}

# ============================================================
# CATÁLOGO
# ============================================================

function Build-AppCatalogLabels {

    $script:AppCatalogMap = @{}

    $labels =
        New-Object System.Collections.ArrayList

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

$form.MinimumSize =
    New-Object System.Drawing.Size(
        1050,
        700
    )

$form.BackColor =
    $ColorBackground

$form.Font =
    $FontNormal

# inicia maximizado
$form.WindowState =
    [System.Windows.Forms.FormWindowState]::Maximized

# ============================================================
# CABEÇALHO
# ============================================================

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
        15
    )

$lblMainTitle.Size =
    New-Object System.Drawing.Size(
        500,
        30
    )

$form.Controls.Add($lblMainTitle)

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
        45
    )

$lblSubtitle.Size =
    New-Object System.Drawing.Size(
        600,
        22
    )

$form.Controls.Add($lblSubtitle)

# ============================================================
# ÁREA PRINCIPAL
# ============================================================

$grpSystem =
    New-Object System.Windows.Forms.GroupBox

$grpInstall =
    New-Object System.Windows.Forms.GroupBox

$grpUninstall =
    New-Object System.Windows.Forms.GroupBox

# ------------------------------------------------------------
# GRUPO SISTEMA
# ------------------------------------------------------------

$grpSystem.Text =
    "1. Configuração do sistema"

$grpSystem.Font =
    $FontHeader

$grpSystem.ForeColor =
    $ColorText

$grpSystem.Location =
    New-Object System.Drawing.Point(
        20,
        78
    )

$grpSystem.Size =
    New-Object System.Drawing.Size(
        350,
        430
    )

$form.Controls.Add($grpSystem)

$steps = [ordered]@{

    "Ponto de Restauração" = {
        param($l,$d)
        Step-RestorePoint $l $d
    }

    "Versões Anteriores (Shadow Copy)" = {
        param($l,$d)
        Step-VersoesAnteriores $l $d
    }

    "Ícones da Área de Trabalho" = {
        param($l,$d)
        Step-IconesAreaTrabalho $l $d
    }

    "Desativar Telemetria" = {
        param($l,$d)
        Step-Telemetria $l $d
    }

    "Ajustar Plano de Energia" = {
        param($l,$d)
        Step-Energia $l $d
    }

    "Fuso Horário / Localização (BR)" = {
        param($l,$d)
        Step-RegiaoIdioma $l $d
    }

    "Remover Apps Padrão (Debloat)" = {
        param($l,$d)
        Step-Debloat $l $d
    }

    "Instalar/Atualizar Chocolatey" = {
        param($l,$d)
        Step-Chocolatey $l $d
    }

    "Atualizar Apps (Winget)" = {
        param($l,$d)
        Step-WingetUpgradeAll $l $d
    }

    "Criar Tarefa de Limpeza Semanal" = {
        param($l,$d)
        Step-TarefaLimpeza $l $d
    }
}

$checkboxes = @{}

$y = 35

foreach ($key in $steps.Keys) {

    $cb =
        New-Object System.Windows.Forms.CheckBox

    $cb.Text =
        $key

    $cb.Checked =
        $true

    if ($key -eq "Versões Anteriores (Shadow Copy)") {
        $cb.Checked = $false
    }

    # CORREÇÃO IMPORTANTE:
    # não usar New-Object Point(15,$y+3)
    $cb.Location =
        [System.Drawing.Point]::new(
            15,
            $y
        )

    $cb.Size =
        New-Object System.Drawing.Size(
            320,
            22
        )

    $cb.ForeColor =
        $ColorText

    $grpSystem.Controls.Add($cb)

    $checkboxes[$key] =
        $cb

    $y += 24
}

$chkDryRun =
    New-Object System.Windows.Forms.CheckBox

$chkDryRun.Text =
    "Modo Simulação (dry-run)"

$chkDryRun.Location =
    [System.Drawing.Point]::new(
        15,
        ($y + 3)
    )

$chkDryRun.Size =
    New-Object System.Drawing.Size(
        320,
        22
    )

$chkDryRun.ForeColor =
    [System.Drawing.Color]::DarkBlue

$grpSystem.Controls.Add($chkDryRun)

# ============================================================
# BOTÕES SISTEMA
# ============================================================

$btnSelAll =
    New-Object System.Windows.Forms.Button

$btnSelAll.Text =
    "Marcar todos"

$btnSelAll.Location =
    [System.Drawing.Point]::new(
        15,
        335
    )

$btnSelAll.Size =
    New-Object System.Drawing.Size(
        150,
        30
    )

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

$grpSystem.Controls.Add($btnSelAll)

$btnSelNone =
    New-Object System.Windows.Forms.Button

$btnSelNone.Text =
    "Desmarcar todos"

$btnSelNone.Location =
    [System.Drawing.Point]::new(
        180,
        335
    )

$btnSelNone.Size =
    New-Object System.Drawing.Size(
        150,
        30
    )

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

$grpSystem.Controls.Add($btnSelNone)

$btnEditApps =
    New-Object System.Windows.Forms.Button

$btnEditApps.Text =
    "Editar apps.json"

$btnEditApps.Location =
    [System.Drawing.Point]::new(
        15,
        375
    )

$btnEditApps.Size =
    New-Object System.Drawing.Size(
        150,
        30
    )

$btnEditApps.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnEditApps.BackColor =
    $ColorSurface

$btnEditApps.Add_Click({

    Start-Process notepad.exe `
        -ArgumentList "`"$AppsJsonPath`""
})

$grpSystem.Controls.Add($btnEditApps)

$btnRun =
    New-Object System.Windows.Forms.Button

$btnRun.Text =
    "Executar configuração"

$btnRun.Location =
    [System.Drawing.Point]::new(
        180,
        375
    )

$btnRun.Size =
    New-Object System.Drawing.Size(
        150,
        30
    )

$btnRun.BackColor =
    $ColorPrimary

$btnRun.ForeColor =
    [System.Drawing.Color]::White

$btnRun.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnRun.FlatAppearance.BorderSize = 0

$grpSystem.Controls.Add($btnRun)

# ============================================================
# GRUPO INSTALAÇÃO
# ============================================================

$grpInstall.Text =
    "2. Instalar aplicativos"

$grpInstall.Font =
    $FontHeader

$grpInstall.ForeColor =
    $ColorText

$grpInstall.Location =
    New-Object System.Drawing.Point(
        385,
        78
    )

$grpInstall.Size =
    New-Object System.Drawing.Size(
        350,
        430
    )

$form.Controls.Add($grpInstall)

$lblInstallInfo =
    New-Object System.Windows.Forms.Label

$lblInstallInfo.Text =
    "Selecione os aplicativos que deseja instalar:"

$lblInstallInfo.Location =
    New-Object System.Drawing.Point(
        15,
        32
    )

$lblInstallInfo.Size =
    New-Object System.Drawing.Size(
        320,
        22
    )

$grpInstall.Controls.Add($lblInstallInfo)

$clbInstall =
    New-Object System.Windows.Forms.CheckedListBox

$clbInstall.Location =
    New-Object System.Drawing.Point(
        15,
        58
    )

$clbInstall.Size =
    New-Object System.Drawing.Size(
        320,
        300
    )

$clbInstall.CheckOnClick = $true

foreach ($label in (Build-AppCatalogLabels)) {

    [void]$clbInstall.Items.Add(
        $label,
        $true
    )
}

$grpInstall.Controls.Add($clbInstall)

$btnInstallSelected =
    New-Object System.Windows.Forms.Button

$btnInstallSelected.Text =
    "INSTALAR SELECIONADOS"

$btnInstallSelected.Location =
    New-Object System.Drawing.Point(
        15,
        370
    )

$btnInstallSelected.Size =
    New-Object System.Drawing.Size(
        320,
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

$grpInstall.Controls.Add($btnInstallSelected)

# ============================================================
# GRUPO DESINSTALAÇÃO
# ============================================================

$grpUninstall.Text =
    "3. Gerenciar aplicativos instalados"

$grpUninstall.Font =
    $FontHeader

$grpUninstall.ForeColor =
    $ColorText

$grpUninstall.Location =
    New-Object System.Drawing.Point(
        750,
        78
    )

$grpUninstall.Size =
    New-Object System.Drawing.Size(
        350,
        430
    )

$form.Controls.Add($grpUninstall)

$lblUninstallInfo =
    New-Object System.Windows.Forms.Label

$lblUninstallInfo.Text =
    "Atualize a lista e selecione o que deseja remover:"

$lblUninstallInfo.Location =
    New-Object System.Drawing.Point(
        15,
        32
    )

$lblUninstallInfo.Size =
    New-Object System.Drawing.Size(
        320,
        22
    )

$grpUninstall.Controls.Add($lblUninstallInfo)

$clbUninstall =
    New-Object System.Windows.Forms.CheckedListBox

$clbUninstall.Location =
    New-Object System.Drawing.Point(
        15,
        58
    )

$clbUninstall.Size =
    New-Object System.Drawing.Size(
        320,
        270
    )

$clbUninstall.CheckOnClick = $true

$grpUninstall.Controls.Add($clbUninstall)

$btnRefreshInstalled =
    New-Object System.Windows.Forms.Button

$btnRefreshInstalled.Text =
    "Atualizar lista"

$btnRefreshInstalled.Location =
    New-Object System.Drawing.Point(
        15,
        340
    )

$btnRefreshInstalled.Size =
    New-Object System.Drawing.Size(
        150,
        30
    )

$btnRefreshInstalled.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnRefreshInstalled.BackColor =
    $ColorSurface

$grpUninstall.Controls.Add($btnRefreshInstalled)

$btnUninstallSelected =
    New-Object System.Windows.Forms.Button

$btnUninstallSelected.Text =
    "Desinstalar"

$btnUninstallSelected.Location =
    New-Object System.Drawing.Point(
        180,
        340
    )

$btnUninstallSelected.Size =
    New-Object System.Drawing.Size(
        150,
        30
    )

$btnUninstallSelected.BackColor =
    $ColorDanger

$btnUninstallSelected.ForeColor =
    [System.Drawing.Color]::White

$btnUninstallSelected.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnUninstallSelected.FlatAppearance.BorderSize = 0

$grpUninstall.Controls.Add($btnUninstallSelected)

# ============================================================
# BOTÃO ATIVAÇÃO OFICIAL
# ============================================================

$btnActivation =
    New-Object System.Windows.Forms.Button

$btnActivation.Text =
    "Ativação do Windows"

$btnActivation.Location =
    New-Object System.Drawing.Point(
        15,
        380
    )

$btnActivation.Size =
    New-Object System.Drawing.Size(
        315,
        30
    )

$btnActivation.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$btnActivation.BackColor =
    $ColorSurface

$btnActivation.Add_Click({

    try {

        Start-Process `
            "ms-settings:activation"

    }
    catch {

        [System.Windows.Forms.MessageBox]::Show(
            "Não foi possível abrir as configurações de ativação.",
            "Ativação"
        ) | Out-Null
    }
})

$grpUninstall.Controls.Add($btnActivation)

# ============================================================
# STATUS / LOG
# ============================================================

$grpStatus =
    New-Object System.Windows.Forms.GroupBox

$grpStatus.Text =
    "Status / Log"

$grpStatus.Font =
    $FontHeader

$grpStatus.ForeColor =
    $ColorText

$grpStatus.Location =
    New-Object System.Drawing.Point(
        20,
        525
    )

$grpStatus.Size =
    New-Object System.Drawing.Size(
        1080,
        205
    )

$form.Controls.Add($grpStatus)

$progressBar =
    New-Object System.Windows.Forms.ProgressBar

$progressBar.Location =
    New-Object System.Drawing.Point(
        15,
        32
    )

$progressBar.Size =
    New-Object System.Drawing.Size(
        1050,
        20
    )

$progressBar.Minimum = 0

$grpStatus.Controls.Add($progressBar)

$lblStatus =
    New-Object System.Windows.Forms.Label

$lblStatus.Text =
    "Pronto para instalar"

$lblStatus.ForeColor =
    $ColorSuccess

$lblStatus.Location =
    New-Object System.Drawing.Point(
        15,
        57
    )

$lblStatus.Size =
    New-Object System.Drawing.Size(
        500,
        22
    )

$grpStatus.Controls.Add($lblStatus)

$txtLog =
    New-Object System.Windows.Forms.TextBox

$txtLog.Multiline = $true

$txtLog.ScrollBars =
    [System.Windows.Forms.ScrollBars]::Vertical

$txtLog.ReadOnly = $true

$txtLog.Location =
    New-Object System.Drawing.Point(
        15,
        82
    )

$txtLog.Size =
    New-Object System.Drawing.Size(
        1050,
        105
    )

$txtLog.Font =
    New-Object System.Drawing.Font(
        "Consolas",
        8
    )

$txtLog.BackColor =
    [System.Drawing.Color]::White

$grpStatus.Controls.Add($txtLog)

# ============================================================
# REDIMENSIONAMENTO AUTOMÁTICO
# ============================================================

$form.Add_Resize({

    $w = $form.ClientSize.Width
    $h = $form.ClientSize.Height

    $margin = 20
    $gap = 15

    $availableWidth =
        $w - ($margin * 2)

    $colW =
        [int](($availableWidth - ($gap * 2)) / 3)

    if ($colW -lt 300) {
        $colW = 300
    }

    $grpSystem.Width = $colW
    $grpInstall.Width = $colW
    $grpUninstall.Width = $colW

    $grpInstall.Left =
        $margin + $colW + $gap

    $grpUninstall.Left =
        $margin + (($colW + $gap) * 2)

    $grpSystem.Top = 78
    $grpInstall.Top = 78
    $grpUninstall.Top = 78

    $grpStatus.Left = $margin
    $grpStatus.Width =
        $w - ($margin * 2)

    $grpStatus.Top =
        [Math]::Max(
            525,
            $h - 225
        )

    $grpStatus.Height =
        $h - $grpStatus.Top - 15

    $progressBar.Width =
        $grpStatus.ClientSize.Width - 30

    $txtLog.Width =
        $grpStatus.ClientSize.Width - 30

    $txtLog.Height =
        $grpStatus.ClientSize.Height - 100
})

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
# EXECUTAR CONFIGURAÇÃO
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
            "SIMULAÇÃO"
        }
        else {
            "EXECUÇÃO REAL"
        }

    $lblStatus.Text =
        "Executando: $modo"

    $AppendLog.Invoke(
        "========================================"
    )

    $AppendLog.Invoke(
        "MCNTV Installer"
    )

    $AppendLog.Invoke(
        "Modo: $modo"
    )

    $AppendLog.Invoke(
        "Log: $LogFilePath"
    )

    $AppendLog.Invoke(
        "========================================"
    )

    foreach ($key in $steps.Keys) {

        if ($checkboxes[$key].Checked) {

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

                $script:Results[$key] =
                    "FALHA: $($_.Exception.Message)"

                $AppendLog.Invoke(
                    "ERRO em '$key': $($_.Exception.Message)"
                )
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
    $AppendLog.Invoke("=== CONCLUÍDO ===")

    $reportLines = @()

    $reportLines +=
        "Relatório de Provisionamento - $Timestamp"

    $reportLines +=
        "Modo: $modo"

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
        "Relatório salvo em: $ReportPath"
    )

    $lblStatus.Text =
        "Concluído - $modo"

    $btnRun.Enabled = $true

    $btnSelAll.Enabled = $true
    $btnSelNone.Enabled = $true
    $btnEditApps.Enabled = $true

    [System.Windows.Forms.MessageBox]::Show(
        "Provisionamento concluído.`n`nRelatório:`n$ReportPath",
        "MCNTV Installer"
    ) | Out-Null
})

# ============================================================
# INSTALAÇÃO DE PROGRAMAS
# ============================================================

$btnInstallSelected.Add_Click({

    $selectedLabels =
        @($clbInstall.CheckedItems)

    if ($selectedLabels.Count -eq 0) {

        [System.Windows.Forms.MessageBox]::Show(
            "Selecione pelo menos um programa.",
            "Aviso"
        ) | Out-Null

        return
    }

    $btnInstallSelected.Enabled = $false

    $AppendLog.Invoke(
        "== Instalando programas selecionados =="
    )

    $precisaChoco =
        @(
            $selectedLabels |
            Where-Object {
                $script:AppCatalogMap[$_].Manager -eq "choco"
            }
        )

    $chocoOk =
        if ($precisaChoco.Count -gt 0) {
            Ensure-ChocoAvailable $AppendLog
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
                "Pulando '$($info.Id)': Chocolatey indisponível."
            )

            continue
        }

        try {

            switch ($info.Manager) {

                "choco" {

                    $AppendLog.Invoke(
                        "Instalando via Chocolatey: $($info.Id)"
                    )

                    choco install `
                        $info.Id `
                        -y `
                        --force 2>&1 |
                        ForEach-Object {
                            $AppendLog.Invoke($_)
                        }
                }

                "winget" {

                    $AppendLog.Invoke(
                        "Instalando via Winget: $($info.Id)"
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
                "ERRO ao instalar '$($info.Id)': $($_.Exception.Message)"
            )
        }
    }

    $AppendLog.Invoke(
        "Instalação concluída."
    )

    $btnInstallSelected.Enabled = $true
})

# ============================================================
# ATUALIZAR PROGRAMAS INSTALADOS
# ============================================================

$script:UninstallMap = @{}

$btnRefreshInstalled.Add_Click({

    $btnRefreshInstalled.Enabled = $false

    $AppendLog.Invoke(
        "Consultando programas instalados..."
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
        @($clbUninstall.CheckedItems)

    if ($selected.Count -eq 0) {

        [System.Windows.Forms.MessageBox]::Show(
            "Selecione pelo menos um programa.",
            "Aviso"
        ) | Out-Null

        return
    }

    $confirm =
        [System.Windows.Forms.MessageBox]::Show(
            "Desinstalar os programas selecionados?",
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
                "Concluído: $name"
            )
        }
        catch {

            $AppendLog.Invoke(
                "ERRO: $($_.Exception.Message)"
            )
        }
    }

    $AppendLog.Invoke(
        "Remoção concluída."
    )

    $btnUninstallSelected.Enabled = $true
})

# ============================================================
# CARREGAR LISTA INICIAL
# ============================================================

$btnRefreshInstalled.PerformClick()

# ============================================================
# EXIBIR
# ============================================================

$form.Add_Shown({

    $form.Activate()

    # força maximização após criação dos controles
    $form.WindowState =
        [System.Windows.Forms.FormWindowState]::Maximized
})

[void]$form.ShowDialog()
