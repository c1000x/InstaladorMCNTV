# ============================================================
#  LAYOUT DOS BOTOES
# ============================================================
# Os botoes foram alinhados no mesmo eixo vertical (mesmo Y),
# mantendo as posições horizontais existentes.

<#
    ProvisioningTool.ps1
    Interface grafica para provisionamento de maquinas Windows.
    Pode ser executado localmente ou diretamente do GitHub via: irm <RAW_URL> | iex.

    Coluna esquerda: etapas gerais de provisionamento (roda tudo junto em "Executar").
    Coluna direita:  instalar programas individuais (apps.json) ou remover programas
                      ja instalados na maquina, um a um.

    Arquivos usados na mesma pasta:
      - apps.json           -> lista de apps instalados via choco/winget (editavel, criado automaticamente se nao existir)
      - logs\provisionamento_<data>.log  -> log completo de cada execucao
      - logs\relatorio_<data>.txt        -> resumo final (sucesso/falha por etapa)
#>

# ============================================================
#  EXECUCAO LOCAL OU VIA "irm ... | iex"
# ============================================================
# Quando executado normalmente, $PSCommandPath aponta para este .ps1.
# Quando executado via "irm URL | iex", nao existe um arquivo associado.
# Neste caso, salvamos o proprio script em %TEMP% para que:
#   1) a elevacao para Administrador possa usar -File;
#   2) o script tenha uma pasta de trabalho para logs/apps.json.
$scriptPath = $PSCommandPath

if ([string]::IsNullOrWhiteSpace($scriptPath)) {
    $bootstrapDir = Join-Path $env:TEMP "ProvisioningTool"
    if (-not (Test-Path $bootstrapDir)) {
        New-Item -Path $bootstrapDir -ItemType Directory -Force | Out-Null
    }

    $scriptPath = Join-Path $bootstrapDir "ProvisioningTool.ps1"

    try {
        $scriptContent = $MyInvocation.MyCommand.Definition
        if ([string]::IsNullOrWhiteSpace($scriptContent)) {
            throw "Nao foi possivel obter o conteudo do script recebido pelo iex."
        }

        [System.IO.File]::WriteAllText(
            $scriptPath,
            $scriptContent,
            (New-Object System.Text.UTF8Encoding($false))
        )
    } catch {
        Write-Host "Erro ao preparar o script para execucao: $($_.Exception.Message)"
        exit 1
    }
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
    try {
        [System.Diagnostics.Process]::Start($psi) | Out-Null
    } catch {
        Write-Host "Elevacao cancelada pelo usuario."
    }
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================
#  BOTAO PERSONALIZADO (script externo do GitHub)
#  Edite as duas linhas abaixo: link raw do script e o texto do botao.
#  Dica: use a URL "raw.githubusercontent.com", nao a pagina normal do GitHub.
# ============================================================
$CustomScriptUrl   = "https://get.activated.win"
$CustomScriptLabel = "Ativar Windows"

$ScriptDir = Split-Path -Parent $scriptPath
$LogsDir   = Join-Path $ScriptDir "logs"
if (-not (Test-Path $LogsDir)) { New-Item -Path $LogsDir -ItemType Directory -Force | Out-Null }

$Timestamp   = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$LogFilePath = Join-Path $LogsDir "provisionamento_$Timestamp.log"
$ReportPath  = Join-Path $LogsDir "relatorio_$Timestamp.txt"

# resultado de cada etapa para o relatorio final: chave = nome, valor = "OK" / "FALHA" / "SIMULADO" / "PULADO"
$script:Results = [ordered]@{}

# ============================================================
#  APPS.JSON (lista de apps editavel sem tocar no script)
# ============================================================
$AppsJsonPath = Join-Path $ScriptDir "apps.json"
$DefaultApps = @{
    choco = @("googlechrome")
    winget = @(
        "AnyDesk.AnyDesk",
        "Adobe.Acrobat.Reader.64-bit",
        "Oracle.JavaRuntimeEnvironment",
        "Mozilla.Firefox.pt-BR",
        "7zip.7zip"
    )
    wingetStore = @("9WZDNCRFJBMP")
}
if (-not (Test-Path $AppsJsonPath)) {
    $DefaultApps | ConvertTo-Json -Depth 5 | Set-Content -Path $AppsJsonPath -Encoding UTF8
}
try {
    $AppsConfig = Get-Content -Path $AppsJsonPath -Raw | ConvertFrom-Json
} catch {
    $AppsConfig = [PSCustomObject]$DefaultApps
}

# ============================================================
#  FUNCOES DE CADA ETAPA (cada uma escreve no log via callback)
#  $DryRun = $true -> so mostra o que faria, nao executa nada
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

    # PATH do processo atual pode estar desatualizado (choco instalado em outra sessao) - recarrega do registro
    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath    = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"

    if (Get-Command choco -ErrorAction SilentlyContinue) { return $true }

    # fallback: caminho padrao de instalacao do Chocolatey
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
#  CATALOGO DE PROGRAMAS (coluna da direita - instalar individualmente)
# ============================================================
function Build-AppCatalogLabels {
    $script:AppCatalogMap = @{}
    $labels = New-Object System.Collections.ArrayList
    foreach ($id in @($AppsConfig.choco)) {
        $label = "[Choco] $id"
        $script:AppCatalogMap[$label] = @{ Manager = "choco"; Id = $id }
        [void]$labels.Add($label)
    }
    foreach ($id in @($AppsConfig.winget)) {
        $label = "[Winget] $id"
        $script:AppCatalogMap[$label] = @{ Manager = "winget"; Id = $id }
        [void]$labels.Add($label)
    }
    foreach ($id in @($AppsConfig.wingetStore)) {
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
#  INTERFACE GRAFICA (3 colunas: Etapas | Instalar | Remover)
# ============================================================

$colW  = 330
$col1X = 20
$col2X = $col1X + $colW + 25
$col3X = $col2X + $colW + 25
$formWidth = $col3X + $colW + 30

$form = New-Object System.Windows.Forms.Form
$form.Text = "Provisionamento Windows"
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "Sizable"
$form.MaximizeBox = $true

# ---------- COLUNA 1: etapas gerais ----------
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "Etapas do sistema:"
$lblTitle.Location = New-Object System.Drawing.Point($col1X, 15)
$lblTitle.Size = New-Object System.Drawing.Size($colW, 20)
$form.Controls.Add($lblTitle)

# nome -> scriptblock da etapa
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
$y = 45
foreach ($key in $steps.Keys) {
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $key
    $cb.Checked = -not ($UncheckedByDefault -contains $key)
    $cb.Location = New-Object System.Drawing.Point($col1X, $y)
    $cb.Size = New-Object System.Drawing.Size($colW, 22)
    $form.Controls.Add($cb)
    $checkboxes[$key] = $cb
    $y += 24
}

$y += 6
$chkDryRun = New-Object System.Windows.Forms.CheckBox
$chkDryRun.Text = "Modo Simulacao (dry-run)"
$chkDryRun.Location = New-Object System.Drawing.Point($col1X, $y)
$chkDryRun.Size = New-Object System.Drawing.Size($colW, 22)
$chkDryRun.ForeColor = [System.Drawing.Color]::DarkBlue
$form.Controls.Add($chkDryRun)

$y += 30
$btnSelAll = New-Object System.Windows.Forms.Button
$btnSelAll.Text = "Marcar todos"
$btnSelAll.Location = New-Object System.Drawing.Point($col1X, $y)
$btnSelAll.Size = New-Object System.Drawing.Size((($colW - 10) / 2), 26)
$btnSelAll.Add_Click({ $checkboxes.Values | ForEach-Object { $_.Checked = $true } })
$form.Controls.Add($btnSelAll)

$btnSelNone = New-Object System.Windows.Forms.Button
$btnSelNone.Text = "Desmarcar todos"
$btnSelNone.Location = New-Object System.Drawing.Point(($col1X + (($colW - 10) / 2) + 10), $y)
$btnSelNone.Size = New-Object System.Drawing.Size((($colW - 10) / 2), 26)
$btnSelNone.Add_Click({ $checkboxes.Values | ForEach-Object { $_.Checked = $false } })
$form.Controls.Add($btnSelNone)

$y += 32
$btnEditApps = New-Object System.Windows.Forms.Button
$btnEditApps.Text = "Editar apps.json"
$btnEditApps.Location = New-Object System.Drawing.Point($col1X, $y)
$btnEditApps.Size = New-Object System.Drawing.Size($colW, 28)
$btnEditApps.Add_Click({ Start-Process notepad.exe $AppsJsonPath })
$form.Controls.Add($btnEditApps)

$y += 34
$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = "Executar"
$btnRun.Location = New-Object System.Drawing.Point($col1X, $y)
$btnRun.Size = New-Object System.Drawing.Size($colW, 32)
$btnRun.BackColor = [System.Drawing.Color]::LightGreen
$form.Controls.Add($btnRun)

$y += 40
$btnCustom = New-Object System.Windows.Forms.Button
$btnCustom.Text = $CustomScriptLabel
$btnCustom.Location = New-Object System.Drawing.Point($col1X, $y)
$btnCustom.Size = New-Object System.Drawing.Size($colW, 30)
$btnCustom.BackColor = [System.Drawing.Color]::LightSkyBlue
$form.Controls.Add($btnCustom)

$col1Bottom = $y + 30

# ---------- COLUNA 2: instalar programas ----------
$lblInstall = New-Object System.Windows.Forms.Label
$lblInstall.Text = "Instalar programas (apps.json):"
$lblInstall.Location = New-Object System.Drawing.Point($col2X, 15)
$lblInstall.Size = New-Object System.Drawing.Size($colW, 20)
$form.Controls.Add($lblInstall)

$clbInstall = New-Object System.Windows.Forms.CheckedListBox
$clbInstall.Location = New-Object System.Drawing.Point($col2X, 45)
$clbInstallHeight = 300
$clbInstall.Size = New-Object System.Drawing.Size($colW, $clbInstallHeight)
$clbInstall.CheckOnClick = $true
foreach ($label in (Build-AppCatalogLabels)) { [void]$clbInstall.Items.Add($label, $true) }
$form.Controls.Add($clbInstall)

$btnInstallSelected = New-Object System.Windows.Forms.Button
$btnInstallSelected.Text = "Instalar Programas Selecionados"
$btnInstallSelected.Location = New-Object System.Drawing.Point($col2X, (45 + $clbInstallHeight + 10))
$btnInstallSelected.Size = New-Object System.Drawing.Size($colW, 32)
$btnInstallSelected.BackColor = [System.Drawing.Color]::LightGreen
$form.Controls.Add($btnInstallSelected)

$col2Bottom = 45 + $clbInstallHeight + 10 + 32

# ---------- COLUNA 3: remover programas (lista alinhada com as outras colunas, botoes embaixo) ----------
$lblUninstall = New-Object System.Windows.Forms.Label
$lblUninstall.Text = "Remover programas instalados:"
$lblUninstall.Location = New-Object System.Drawing.Point($col3X, 15)
$lblUninstall.Size = New-Object System.Drawing.Size($colW, 20)
$form.Controls.Add($lblUninstall)

$clbUninstallY = 45
$minUninstallHeight = 150
$uninstallBtnH = 32
$gapBelowList = 10

# ---------- LOG E PROGRESSO (largura total, abaixo das 3 colunas) ----------
# A lista de "remover programas" estica para preencher o espaco ate aqui,
# em vez de deixar vazio quando uma coluna e mais curta que as outras.
$baseBottom = [Math]::Max($col1Bottom, $col2Bottom)
$col3ListHeight = [Math]::Max($minUninstallHeight, ($baseBottom - $clbUninstallY - $gapBelowList - $uninstallBtnH))
$col3ListBottom = $clbUninstallY + $col3ListHeight
$col3ButtonY = $col3ListBottom + $gapBelowList
$col3Bottom = $col3ButtonY + $uninstallBtnH
$commonY = [Math]::Max($baseBottom, $col3Bottom) + 20

$clbUninstall = New-Object System.Windows.Forms.CheckedListBox
$clbUninstall.Location = New-Object System.Drawing.Point($col3X, $clbUninstallY)
$clbUninstall.Size = New-Object System.Drawing.Size($colW, $col3ListHeight)
$clbUninstall.CheckOnClick = $true
$form.Controls.Add($clbUninstall)

$btnRefreshInstalled = New-Object System.Windows.Forms.Button
$btnRefreshInstalled.Text = "Atualizar Lista"
$btnRefreshInstalled.Location = New-Object System.Drawing.Point($col3X, $col3ButtonY)
$btnRefreshInstalled.Size = New-Object System.Drawing.Size((($colW - 10) / 2), $uninstallBtnH)
$form.Controls.Add($btnRefreshInstalled)

$btnUninstallSelected = New-Object System.Windows.Forms.Button
$btnUninstallSelected.Text = "Desinstalar"
$btnUninstallSelected.Location = New-Object System.Drawing.Point(($col3X + (($colW - 10) / 2) + 10), $col3ButtonY)
$btnUninstallSelected.Size = New-Object System.Drawing.Size((($colW - 10) / 2), $uninstallBtnH)
$btnUninstallSelected.BackColor = [System.Drawing.Color]::LightCoral
$form.Controls.Add($btnUninstallSelected)

$fullWidth = $formWidth - 30

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(15, $commonY)
$progressBar.Size = New-Object System.Drawing.Size($fullWidth, 20)
$progressBar.Minimum = 0
$progressBar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($progressBar)

$logY = $commonY + 30
$logHeight = 320
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Location = New-Object System.Drawing.Point(15, $logY)
$txtLog.Size = New-Object System.Drawing.Size($fullWidth, $logHeight)
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$txtLog.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($txtLog)

$form.Size = New-Object System.Drawing.Size(($formWidth + 15), ($logY + $logHeight + 60))
$form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized

# ============================================================
#  LOGICA
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

$btnCustom.Add_Click({
    if ([string]::IsNullOrWhiteSpace($CustomScriptUrl) -or $CustomScriptUrl -like "*usuario/repositorio*") {
        [System.Windows.Forms.MessageBox]::Show("Edite as variaveis `$CustomScriptUrl e `$CustomScriptLabel no topo do ProvisioningTool.ps1 antes de usar este botao.", "Configure o link") | Out-Null
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
        $scriptContent = (New-Object System.Net.WebClient).DownloadString($CustomScriptUrl)
        Invoke-Expression $scriptContent 2>&1 | ForEach-Object { $AppendLog.Invoke($_) }
        $AppendLog.Invoke("Script '$CustomScriptLabel' concluido.")
    } catch {
        $AppendLog.Invoke("ERRO ao executar '$CustomScriptLabel': $($_.Exception.Message)")
    }
    $btnCustom.Enabled = $true
})

$btnRun.Add_Click({
    $btnRun.Enabled = $false
    $btnSelAll.Enabled = $false
    $btnSelNone.Enabled = $false
    $btnEditApps.Enabled = $false
    $txtLog.Clear()
    $script:Results.Clear()

    $DryRun = $chkDryRun.Checked
    $selected = $steps.Keys | Where-Object { $checkboxes[$_].Checked }
    $progressBar.Maximum = [Math]::Max(1, $selected.Count)
    $progressBar.Value = 0

    $modo = if ($DryRun) { "SIMULACAO (nada sera alterado)" } else { "EXECUCAO REAL" }
    $AppendLog.Invoke("Iniciando provisionamento - Modo: $modo")
    $AppendLog.Invoke("Log completo salvo em: $LogFilePath")
    $AppendLog.Invoke("")

    foreach ($key in $steps.Keys) {
        if ($checkboxes[$key].Checked) {
            try {
                & $steps[$key] $AppendLog $DryRun
                $script:Results[$key] = if ($DryRun) { "SIMULADO" } else { "OK" }
            } catch {
                $AppendLog.Invoke("ERRO em '$key': $($_.Exception.Message)")
                $script:Results[$key] = "FALHA: $($_.Exception.Message)"
            }
            $progressBar.Value = [Math]::Min($progressBar.Maximum, $progressBar.Value + 1)
        } else {
            $script:Results[$key] = "PULADO"
        }
    }

    $AppendLog.Invoke("")
    $AppendLog.Invoke("=== Concluido ===")

    # relatorio final
    $reportLines = @()
    $reportLines += "Relatorio de Provisionamento - $Timestamp"
    $reportLines += "Modo: $modo"
    $reportLines += ""
    foreach ($k in $script:Results.Keys) {
        $reportLines += ("{0,-45} {1}" -f $k, $script:Results[$k])
    }
    $reportLines | Set-Content -Path $ReportPath -Encoding UTF8
    $AppendLog.Invoke("Relatorio salvo em: $ReportPath")

    $btnRun.Enabled = $true
    $btnSelAll.Enabled = $true
    $btnSelNone.Enabled = $true
    $btnEditApps.Enabled = $true
    [System.Windows.Forms.MessageBox]::Show("Provisionamento concluido ($modo). Relatorio em:`n$ReportPath", "Finalizado") | Out-Null
})

# ---------- Instalar programas selecionados (coluna direita) ----------
$btnInstallSelected.Add_Click({
    $selectedLabels = @($clbInstall.CheckedItems)
    if ($selectedLabels.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Selecione ao menos um programa na lista.", "Aviso") | Out-Null
        return
    }
    $btnInstallSelected.Enabled = $false
    $AppendLog.Invoke("== Instalando programas selecionados ==")
    $precisaChoco = $selectedLabels | Where-Object { $script:AppCatalogMap[$_].Manager -eq "choco" }
    $chocoOk = if ($precisaChoco) { Ensure-ChocoAvailable -Log $AppendLog } else { $true }
    foreach ($label in $selectedLabels) {
        $info = $script:AppCatalogMap[$label]
        if (-not $info) { continue }
        if ($info.Manager -eq "choco" -and -not $chocoOk) {
            $AppendLog.Invoke("Pulando '$($info.Id)': Chocolatey indisponivel.")
            continue
        }
        try {
            switch ($info.Manager) {
                "choco" {
                    $AppendLog.Invoke("Instalando (choco): $($info.Id)")
                    choco install $($info.Id) -y --force --ignore-checksums 2>&1 | ForEach-Object { $AppendLog.Invoke($_) }
                }
                "winget" {
                    $AppendLog.Invoke("Instalando (winget): $($info.Id)")
                    winget install -e --id $($info.Id) --accept-source-agreements --accept-package-agreements --silent 2>&1 | ForEach-Object { $AppendLog.Invoke($_) }
                }
                "wingetStore" {
                    $AppendLog.Invoke("Instalando (msstore): $($info.Id)")
                    winget install --id $($info.Id) --source msstore --accept-source-agreements --accept-package-agreements --silent 2>&1 | ForEach-Object { $AppendLog.Invoke($_) }
                }
            }
        } catch {
            $AppendLog.Invoke("ERRO ao instalar '$($info.Id)': $($_.Exception.Message)")
        }
    }
    $AppendLog.Invoke("Instalacao dos selecionados concluida.")
    $btnInstallSelected.Enabled = $true
})

# ---------- Listar / remover programas instalados (coluna direita) ----------
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
        [System.Windows.Forms.MessageBox]::Show("Selecione ao menos um programa para remover.", "Aviso") | Out-Null
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
    $AppendLog.Invoke("Remocao concluida. Alguns instaladores mostram sua propria janela/confirmacao.")
    $AppendLog.Invoke("Clique em 'Atualizar Lista de Instalados' para ver a lista atualizada.")
    $btnUninstallSelected.Enabled = $true
})

[void]$form.ShowDialog()
