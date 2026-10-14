# Claude Hub - varias contas do Claude Desktop ao mesmo tempo (uma instancia por conta, cada uma com o proprio perfil).
#
# Como funciona: o Claude e um app Electron; cada pasta de perfil (--user-data-dir) e uma conta separada, com login proprio.
# O Windows nao deixa abrir o Claude direto de WindowsApps com argumentos, e o Electron novo recusa rodar de pastas de pacote da Loja,
# entao o Hub mantem uma COPIA do motor em .\engine e a atualiza a partir do Claude instalado (a Loja mantem o instalado atualizado).
# Tudo (motor, perfis, contas.json) fica ao lado deste script e NUNCA vai para o Git (ver .gitignore).
#
# Uso:  ClaudeHub.ps1                       abre o painel
#       ClaudeHub.ps1 -Listar               mostra contas e estado
#       ClaudeHub.ps1 -Nova "Trabalho"      cria uma conta (perfil novo, vazio)
#       ClaudeHub.ps1 -Abrir "Trabalho"     abre a conta   (-Todas abre todas). Se houver Claude mais novo instalado, atualiza o motor antes.
#       ClaudeHub.ps1 -Fechar "Trabalho"    fecha so essa instancia
#       ClaudeHub.ps1 -Atualizar            copia o Claude instalado para o motor do Hub
#       ClaudeHub.ps1 -Atualizar -Baixar    antes, pede ao winget a versao mais nova do Claude (pode fechar o Claude principal!)
#       ClaudeHub.ps1 -Atalho "Trabalho"    cria o atalho da conta no desktop
#       ClaudeHub.ps1 -Remover "Trabalho"   tira da lista (a pasta do perfil, com o login, NAO e apagada)
#       ClaudeHub.ps1 -Importar             opcional: traz as contas do app "Multi Instance for Claude Desktop" (mesmos perfis, login mantido)

param(
  [switch]$Gui, [switch]$Listar, [string]$Nova, [string]$Abrir, [switch]$Todas, [string]$Fechar,
  [switch]$Atualizar, [switch]$Baixar, [switch]$Importar, [string]$Atalho, [string]$Remover
)
$ErrorActionPreference = 'Stop'
$Root     = Split-Path -Parent $MyInvocation.MyCommand.Path
$Engine   = Join-Path $Root 'engine'
$Profiles = Join-Path $Root 'profiles'
$Cfg      = Join-Path $Root 'contas.json'
$Cores    = @('#D97757', '#7C5CFF', '#2563EB', '#16A34A', '#DB2777', '#CA8A04', '#0891B2', '#9333EA')

# ------------------------------------------------------------------ contas
function Get-Contas {
  if (-not (Test-Path $Cfg)) { return @() }
  $raw = (Get-Content $Cfg -Raw -Encoding UTF8).Trim()
  if (-not $raw) { return @() }
  $parsed = $raw | ConvertFrom-Json
  $out = @(); foreach ($i in $parsed) { $out += $i }   # PS 5.1 devolve o array embrulhado: desembrulha
  return $out
}
function Save-Contas($lista) {
  $arr = @($lista)
  if ($arr.Count -eq 0) { Set-Content $Cfg '[]' -Encoding UTF8 } else { Set-Content $Cfg (ConvertTo-Json -InputObject $arr -Depth 4) -Encoding UTF8 }
}
function Find-Conta($nome) {
  $c = Get-Contas | Where-Object { $_.nome -ieq $nome } | Select-Object -First 1
  if (-not $c) { throw "Conta '$nome' nao encontrada. Use -Listar." }
  return $c
}
function New-Conta($nome) {
  $nome = ($nome -replace '\s+', ' ').Trim()
  if ($nome -notmatch '^[\p{L}\p{N}][\p{L}\p{N} _\-]{0,39}$') { throw "Nome invalido. Use 1 a 40 letras, numeros, espaco, - ou _." }
  $lista = @(Get-Contas)
  if ($lista | Where-Object { $_.nome -ieq $nome }) { throw "Ja existe uma conta chamada '$nome'." }
  $pasta = Join-Path $Profiles ($nome -replace '[^\p{L}\p{N}_\-]', '_')
  if (Test-Path $pasta) { $pasta = $pasta + '_' + (Get-Random -Maximum 9999) }
  New-Item -ItemType Directory -Force $pasta | Out-Null
  $conta = [pscustomobject]@{ nome = $nome; cor = $Cores[$lista.Count % $Cores.Count]; profileDir = $pasta; criada = (Get-Date).ToString('s') }
  Save-Contas ($lista + $conta)
  return $conta
}
function Remove-Conta($nome) {
  $c = Find-Conta $nome
  if (Test-Running $c) { throw "Feche a conta '$nome' antes de remover." }
  Save-Contas (@(Get-Contas) | Where-Object { $_.nome -ine $nome })
  $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "Claude - $($c.nome).lnk"
  if (Test-Path $lnk) { Remove-Item $lnk -Force }
  return $c   # a pasta do perfil NAO e apagada (tem o login e o historico); apague a mao se quiser
}
function Import-MICD {
  $f = Join-Path $env:LOCALAPPDATA 'Packages\42109FactoriaDatacenter.MultiInstanceforClaudeDesk_zaf1c6h4vqsbt\LocalCache\MultiInstanceClaudeDesktop\instances.json'
  if (-not (Test-Path $f)) { throw 'Nao achei o app Multi Instance for Claude Desktop neste computador.' }
  $lista = @(Get-Contas); $novas = 0
  foreach ($i in (Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json)) {
    if ($lista | Where-Object { $_.nome -ieq $i.name }) { continue }
    if (-not (Test-Path $i.profileDir)) { continue }
    $lista += [pscustomobject]@{ nome = $i.name; cor = $i.color; profileDir = $i.profileDir; criada = $i.created }
    $novas++
  }
  Save-Contas $lista
  return $novas
}

# ------------------------------------------------------------------ processos
# Uma unica consulta ao Windows serve para todas as contas (o painel consulta a cada poucos segundos).
function Get-ClaudeProcs { @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" | Where-Object { $_.CommandLine }) }
function Get-Procs($conta, $todos = $null) {
  if ($null -eq $todos) { $todos = Get-ClaudeProcs }
  $p = $conta.profileDir.ToLower()
  @($todos | Where-Object { $_.CommandLine.ToLower().Contains($p) })
}
function Test-Running($conta, $todos = $null) { return (@(Get-Procs $conta $todos | Where-Object { $_.CommandLine -notmatch '--type=' }).Count -gt 0) }

# ------------------------------------------------------------------ motor e atualizacao
function Get-Instalado {
  $p = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
  if (-not $p) { return $null }
  return [pscustomobject]@{ Versao = [string]$p.Version; Pasta = (Join-Path $p.InstallLocation 'app') }
}
function Get-MotorVersao {
  $f = Join-Path $Engine '.hub-versao'
  if (Test-Path $f) { return (Get-Content $f -Raw).Trim() }
  return $null
}
function Test-MotorDefasado {
  $inst = Get-Instalado; $mv = Get-MotorVersao
  if (-not $inst -or -not $mv) { return $false }
  try { return ([version]$inst.Versao -gt [version]$mv) } catch { return ($inst.Versao -ne $mv) }
}
function Update-Engine([switch]$ViaWinget) {
  if ($ViaWinget) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'winget nao encontrado neste computador.' }
    & winget upgrade --id Anthropic.Claude --silent --accept-package-agreements --accept-source-agreements | Out-Null
  }
  $inst = Get-Instalado
  if (-not $inst) { throw 'O Claude Desktop nao esta instalado (pacote "Claude" nao encontrado).' }
  $todos = Get-ClaudeProcs
  $abertas = @(Get-Contas | Where-Object { Test-Running $_ $todos })
  if ($abertas.Count) { throw ('Feche estas contas antes de atualizar o motor: ' + (($abertas | ForEach-Object { $_.nome }) -join ', ')) }
  New-Item -ItemType Directory -Force $Engine | Out-Null
  & robocopy $inst.Pasta $Engine /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "Falha ao copiar o Claude (robocopy codigo $LASTEXITCODE)." }
  Set-Content (Join-Path $Engine '.hub-versao') $inst.Versao -Encoding ASCII
  return $inst.Versao
}

# ------------------------------------------------------------------ abrir / fechar
function Open-Conta($conta) {
  $aviso = ''
  if (-not (Test-Path (Join-Path $Engine 'claude.exe'))) {
    [void](Update-Engine)                       # primeira vez: cria o motor
  } elseif (Test-MotorDefasado) {
    # Ha um Claude mais novo instalado. So da para trocar o motor se nenhuma conta do Hub estiver aberta.
    try { $v = Update-Engine; $aviso = " (motor atualizado para $v)" }
    catch { $aviso = ' (aviso: ha uma versao mais nova do Claude; feche as outras contas do Hub e abra de novo para atualizar)' }
  }
  if (Test-Running $conta) { return 'ja estava aberta' }
  Start-Process -FilePath (Join-Path $Engine 'claude.exe') -ArgumentList "--user-data-dir=`"$($conta.profileDir)`"" | Out-Null
  return "aberta$aviso"
}
function Close-Conta($conta) {
  $procs = Get-Procs $conta
  foreach ($m in ($procs | Where-Object { $_.CommandLine -notmatch '--type=' })) { try { (Get-Process -Id $m.ProcessId).CloseMainWindow() | Out-Null } catch {} }
  Start-Sleep -Seconds 4
  foreach ($x in (Get-Procs $conta)) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue }
}

# ------------------------------------------------------------------ atalhos
function New-Atalho($conta) {
  $eng = Join-Path $Engine 'claude.exe'
  $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "Claude - $($conta.nome).lnk"
  $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
  # O atalho chama o Hub (e nao o claude.exe direto) para o motor se atualizar sozinho quando houver Claude novo.
  $s.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
  $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Abrir `"$($conta.nome)`""
  $s.WorkingDirectory = $Root
  if (Test-Path $eng) { $s.IconLocation = "$eng,0" }
  $s.Description = "Claude - $($conta.nome)"; $s.Save()
  return $lnk
}

# ------------------------------------------------------------------ painel
function Show-Painel {
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
  [System.Windows.Forms.Application]::EnableVisualStyles()
  $f = New-Object System.Windows.Forms.Form
  $f.Text = 'Claude Hub - varias contas ao mesmo tempo'; $f.Size = New-Object System.Drawing.Size(820, 470); $f.StartPosition = 'CenterScreen'; $f.MinimumSize = New-Object System.Drawing.Size(720, 380)
  $f.Font = New-Object System.Drawing.Font('Segoe UI', 10)
  $lv = New-Object System.Windows.Forms.ListView
  $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $false; $lv.HideSelection = $false; $lv.Dock = 'Fill'
  # Desenho em buffer duplo: sem isso a lista "pisca" a cada atualizacao.
  [void]$lv.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($lv, $true, $null)
  [void]$lv.Columns.Add('Conta', 200); [void]$lv.Columns.Add('Estado', 110); [void]$lv.Columns.Add('Pasta do perfil', 460)
  $bar = New-Object System.Windows.Forms.FlowLayoutPanel; $bar.Dock = 'Top'; $bar.Height = 52; $bar.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 0)
  $st = New-Object System.Windows.Forms.Label; $st.Dock = 'Bottom'; $st.Height = 46; $st.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 0)
  $f.Controls.Add($lv); $f.Controls.Add($st); $f.Controls.Add($bar)
  $fonteNormal = $lv.Font; $fonteNegrito = New-Object System.Drawing.Font($lv.Font, 'Bold')
  $script:estado = @{}     # nome -> 'Aberta'/'Fechada' (o que esta na tela agora)
  $script:ocupado = $false
  function Add-Btn($txt, $w, $acao) { $b = New-Object System.Windows.Forms.Button; $b.Text = $txt; $b.Width = $w; $b.Height = 34; $b.Add_Click($acao); $bar.Controls.Add($b); return $b }
  $erro = { param($e) [System.Windows.Forms.MessageBox]::Show($e.Exception.Message, 'Claude Hub', 'OK', 'Warning') | Out-Null }
  $sel = { if ($lv.SelectedItems.Count) { return $lv.SelectedItems[0].Tag } else { throw 'Selecione uma conta na lista.' } }
  # Atualiza a tela SO no que mudou (nada de apagar e recriar a lista a cada tick).
  $refresh = {
    if ($script:ocupado) { return }
    $script:ocupado = $true
    try {
      $contas = @(Get-Contas); $todos = Get-ClaudeProcs
      $novo = @{}; foreach ($c in $contas) { $novo[$c.nome] = $(if (Test-Running $c $todos) { 'Aberta' } else { 'Fechada' }) }
      $nomesTela = @($lv.Items | ForEach-Object { $_.Text }); $nomesNovos = @($contas | ForEach-Object { $_.nome })
      if (($nomesTela -join '|') -ne ($nomesNovos -join '|')) {
        $keep = if ($lv.SelectedItems.Count) { $lv.SelectedItems[0].Text } else { $null }
        $lv.BeginUpdate(); $lv.Items.Clear()
        foreach ($c in $contas) {
          $it = New-Object System.Windows.Forms.ListViewItem($c.nome); [void]$it.SubItems.Add($novo[$c.nome]); [void]$it.SubItems.Add($c.profileDir)
          $it.Tag = $c; try { $it.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($c.cor) } catch {}
          $it.Font = $(if ($novo[$c.nome] -eq 'Aberta') { $fonteNegrito } else { $fonteNormal })
          [void]$lv.Items.Add($it); if ($keep -and $c.nome -eq $keep) { $it.Selected = $true }
        }
        $lv.EndUpdate(); $script:estado = $novo
      } else {
        foreach ($it in $lv.Items) {
          $n = $it.Text
          if ($script:estado[$n] -ne $novo[$n]) { $it.SubItems[1].Text = $novo[$n]; $it.Font = $(if ($novo[$n] -eq 'Aberta') { $fonteNegrito } else { $fonteNormal }) }
        }
        $script:estado = $novo
      }
      $inst = Get-Instalado; $mv = Get-MotorVersao
      $txt = "Motor do Hub: $(if ($mv) { $mv } else { 'ainda nao criado' })   |   Claude instalado: $(if ($inst) { $inst.Versao } else { 'nao encontrado' })"
      if (Test-MotorDefasado) { $txt += "`r`nHa uma versao mais nova do Claude. Ela e aplicada sozinha ao abrir uma conta (com as outras fechadas) ou em 'Atualizar motor'." }
      elseif ($inst -and -not $mv) { $txt += "`r`nO motor sera criado ao abrir a primeira conta (ou em 'Atualizar motor')." }
      if ($st.Text -ne $txt) { $st.Text = $txt }
    } finally { $script:ocupado = $false }
  }
  [void](Add-Btn 'Abrir' 80 { try { $c = & $sel; $f.Cursor = 'WaitCursor'; $st.Text = 'Abrindo...'; [System.Windows.Forms.Application]::DoEvents(); [void](Open-Conta $c); Start-Sleep -Milliseconds 800; & $refresh } catch { & $erro $_ } finally { $f.Cursor = 'Default' } })
  [void](Add-Btn 'Abrir todas' 100 { try { $f.Cursor = 'WaitCursor'; foreach ($c in (Get-Contas)) { [void](Open-Conta $c); Start-Sleep -Milliseconds 600 }; & $refresh } catch { & $erro $_ } finally { $f.Cursor = 'Default' } })
  [void](Add-Btn 'Fechar' 80 { try { $c = & $sel; $f.Cursor = 'WaitCursor'; Close-Conta $c; & $refresh } catch { & $erro $_ } finally { $f.Cursor = 'Default' } })
  [void](Add-Btn 'Nova conta' 100 { try { $n = [Microsoft.VisualBasic.Interaction]::InputBox('Nome da nova conta (ex.: Trabalho, Pessoal):', 'Nova conta', ''); if ($n.Trim()) { $c = New-Conta $n; [void](New-Atalho $c); & $refresh } } catch { & $erro $_ } })
  [void](Add-Btn 'Atalho' 70 { try { $c = & $sel; $l = New-Atalho $c; [System.Windows.Forms.MessageBox]::Show("Atalho criado no desktop:`r`n$l", 'Claude Hub') | Out-Null } catch { & $erro $_ } })
  [void](Add-Btn 'Remover' 80 { try { $c = & $sel; if ([System.Windows.Forms.MessageBox]::Show("Tirar '$($c.nome)' da lista?`r`nA pasta do perfil (login e historico) NAO e apagada.", 'Remover', 'YesNo', 'Question') -eq 'Yes') { [void](Remove-Conta $c.nome); & $refresh } } catch { & $erro $_ } })
  [void](Add-Btn 'Importar do app antigo' 160 { try { $n = Import-MICD; [System.Windows.Forms.MessageBox]::Show("$n conta(s) importada(s) do Multi Instance for Claude Desktop (mesmos perfis, login mantido).", 'Claude Hub') | Out-Null; & $refresh } catch { & $erro $_ } })
  [void](Add-Btn 'Atualizar motor' 120 { try { $f.Cursor = 'WaitCursor'; $st.Text = 'Copiando o Claude instalado para o motor do Hub (cerca de 700 MB)...'; [System.Windows.Forms.Application]::DoEvents(); $v = Update-Engine; & $refresh; [System.Windows.Forms.MessageBox]::Show("Motor atualizado para a versao $v.", 'Claude Hub') | Out-Null } catch { & $erro $_; & $refresh } finally { $f.Cursor = 'Default' } })
  [void](Add-Btn 'Baixar atualizacao' 140 { try {
        if ([System.Windows.Forms.MessageBox]::Show("Isto pede ao winget a versao mais nova do Claude.`r`nSe houver atualizacao, o Windows pode FECHAR o seu Claude principal. Salve o que estiver fazendo. Continuar?", 'Baixar atualizacao', 'YesNo', 'Warning') -ne 'Yes') { return }
        $f.Cursor = 'WaitCursor'; $st.Text = 'Procurando e baixando a atualizacao (winget)...'; [System.Windows.Forms.Application]::DoEvents()
        $v = Update-Engine -ViaWinget; & $refresh; [System.Windows.Forms.MessageBox]::Show("Pronto. Motor na versao $v.", 'Claude Hub') | Out-Null } catch { & $erro $_; & $refresh } finally { $f.Cursor = 'Default' } })
  $lv.Add_DoubleClick({ try { $c = & $sel; [void](Open-Conta $c); Start-Sleep -Milliseconds 800; & $refresh } catch { & $erro $_ } })
  $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 5000; $timer.Add_Tick({ & $refresh }); $timer.Start()
  & $refresh
  [void]$f.ShowDialog()
}

# ------------------------------------------------------------------ entrada
New-Item -ItemType Directory -Force $Profiles | Out-Null
try {
  if ($Listar) { $todos = Get-ClaudeProcs; Get-Contas | ForEach-Object { '{0,-20} {1,-8} {2}' -f $_.nome, $(if (Test-Running $_ $todos) { 'aberta' } else { 'fechada' }), $_.profileDir }; "motor: $(Get-MotorVersao) | instalado: $((Get-Instalado).Versao)"; return }
  if ($Nova)      { $c = New-Conta $Nova; [void](New-Atalho $c); "Conta '$($c.nome)' criada. Abra com: -Abrir '$($c.nome)' (faca o login do Claude na janela que abrir)."; return }
  if ($Abrir)     { "$Abrir : " + (Open-Conta (Find-Conta $Abrir)); return }
  if ($Todas)     { foreach ($c in (Get-Contas)) { "$($c.nome) : " + (Open-Conta $c); Start-Sleep -Milliseconds 600 }; return }
  if ($Fechar)    { Close-Conta (Find-Conta $Fechar); "$Fechar fechada."; return }
  if ($Remover)   { $c = Remove-Conta $Remover; "Removida da lista. Perfil mantido em $($c.profileDir)"; return }
  if ($Atualizar) { "Motor atualizado para a versao " + (Update-Engine -ViaWinget:$Baixar); return }
  if ($Importar)  { "$(Import-MICD) conta(s) importada(s)."; return }
  if ($Atalho)    { "Atalho: " + (New-Atalho (Find-Conta $Atalho)); return }
  Show-Painel
} catch {
  Write-Host "ERRO: $($_.Exception.Message)" -ForegroundColor Red
  if ($Abrir -or $Nova) { try { Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Claude Hub', 'OK', 'Warning') | Out-Null } catch {} }   # atalho roda sem janela: mostra o erro numa caixa
  exit 1
}
