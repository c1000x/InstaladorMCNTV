# ============================================================
#  ABA 5: SITEF (VERSÃO CORRIGIDA COM FLOWLAYOUTPANEL)
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
$tableSitef.Padding = New-Object System.Windows.Forms.Padding(10)
$tabSitef.Controls.Add($tableSitef)

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

# Painel de botões – usando FlowLayoutPanel (mais robusto)
$flowSitefButtons = New-Object System.Windows.Forms.FlowLayoutPanel
$flowSitefButtons.Dock = [System.Windows.Forms.DockStyle]::Fill
$flowSitefButtons.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$flowSitefButtons.AutoSize = $true
$flowSitefButtons.WrapContents = $true
$flowSitefButtons.Padding = New-Object System.Windows.Forms.Padding(5, 5, 5, 10)
$tableSitef.Controls.Add($flowSitefButtons, 0, 2)

# Botão: Instalar SITEF
$btnSitefInstall = New-Object System.Windows.Forms.Button
$btnSitefInstall.Text = "Instalar SITEF"
$btnSitefInstall.Font = $FontButtonBold
$btnSitefInstall.BackColor = $ColorPrimary
$btnSitefInstall.ForeColor = [System.Drawing.Color]::White
$btnSitefInstall.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSitefInstall.FlatAppearance.BorderSize = 0
$btnSitefInstall.Size = New-Object System.Drawing.Size(200, 40)
$btnSitefInstall.Margin = New-Object System.Windows.Forms.Padding(5, 0, 5, 5)
$flowSitefButtons.Controls.Add($btnSitefInstall)

# Botão: DLL_FLY
$btnDllFly = New-Object System.Windows.Forms.Button
$btnDllFly.Text = "DLL_FLY"
$btnDllFly.Font = $FontButtonBold
$btnDllFly.BackColor = $ColorPrimary
$btnDllFly.ForeColor = [System.Drawing.Color]::White
$btnDllFly.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnDllFly.FlatAppearance.BorderSize = 0
$btnDllFly.Size = New-Object System.Drawing.Size(200, 40)
$btnDllFly.Margin = New-Object System.Windows.Forms.Padding(5, 0, 5, 5)
$flowSitefButtons.Controls.Add($btnDllFly)

# Botão: DLL_FLY_EMBARCADO
$btnDllFlyEmbarcado = New-Object System.Windows.Forms.Button
$btnDllFlyEmbarcado.Text = "DLL_FLY_EMBARCADO"
$btnDllFlyEmbarcado.Font = $FontButtonBold
$btnDllFlyEmbarcado.BackColor = $ColorPrimary
$btnDllFlyEmbarcado.ForeColor = [System.Drawing.Color]::White
$btnDllFlyEmbarcado.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnDllFlyEmbarcado.FlatAppearance.BorderSize = 0
$btnDllFlyEmbarcado.Size = New-Object System.Drawing.Size(200, 40)
$btnDllFlyEmbarcado.Margin = New-Object System.Windows.Forms.Padding(5, 0, 5, 5)
$flowSitefButtons.Controls.Add($btnDllFlyEmbarcado)

# Botão: Abrir pasta
$btnSitefOpenFolder = New-Object System.Windows.Forms.Button
$btnSitefOpenFolder.Text = "Abrir pasta C:\SITEF"
$btnSitefOpenFolder.Font = $FontButton
$btnSitefOpenFolder.BackColor = $ColorSurface
$btnSitefOpenFolder.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSitefOpenFolder.FlatAppearance.BorderColor = $ColorBorder
$btnSitefOpenFolder.Size = New-Object System.Drawing.Size(200, 40)
$btnSitefOpenFolder.Margin = New-Object System.Windows.Forms.Padding(5, 0, 5, 5)
$flowSitefButtons.Controls.Add($btnSitefOpenFolder)

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
