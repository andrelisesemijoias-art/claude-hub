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
#       ClaudeHub.ps1 -Fechar "Trabalho"    fecha so essa instancia (e o que ela deixou rodando)
#       ClaudeHub.ps1 -Atualizar            copia o Claude instalado para o motor do Hub (-Forcar recopia mesmo se a versao for igual)
#       ClaudeHub.ps1 -Atualizar -Baixar    antes, pede ao winget a versao mais nova do Claude (pode fechar o Claude principal!)
#       ClaudeHub.ps1 -Atalho "Trabalho"    cria o atalho da conta no desktop
#       ClaudeHub.ps1 -Remover "Trabalho"   tira da lista (a pasta do perfil, com o login, NAO e apagada)
#       ClaudeHub.ps1 -Importar             opcional: traz as contas do app "Multi Instance for Claude Desktop" (mesmos perfis, login mantido)

param(
  [switch]$Gui, [switch]$Listar, [string]$Nova, [string]$Abrir, [switch]$Todas, [string]$Fechar,
  [switch]$Atualizar, [switch]$Baixar, [switch]$Forcar, [switch]$Importar, [string]$Atalho, [string]$Remover,
  [switch]$SoFuncoes   # uso interno: so define as funcoes (o painel coleta dados em segundo plano com isto)
)
$ErrorActionPreference = 'Stop'
$Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$Engine    = Join-Path $Root 'engine'
$EngineExe = Join-Path $Engine 'claude.exe'
$Profiles  = Join-Path $Root 'profiles'
$Cfg       = Join-Path $Root 'contas.json'
$Cores     = @('#D97757', '#7C5CFF', '#2563EB', '#16A34A', '#DB2777', '#CA8A04', '#0891B2', '#9333EA')
$script:Pump = $null   # o painel coloca aqui um bombeador de eventos para a tela nao congelar durante copias longas

# ------------------------------------------------------------------ contas
function Get-Contas {
  if (-not (Test-Path $Cfg)) { return @() }
  $raw = (Get-Content $Cfg -Raw -Encoding UTF8).Trim()
  if (-not $raw) { return @() }
  try { $parsed = $raw | ConvertFrom-Json }
  catch {
    $bk = "$Cfg.corrompido-" + (Get-Date -Format 'yyyyMMdd-HHmmss'); Copy-Item $Cfg $bk
    throw "contas.json esta corrompido (copia guardada em $bk). Corrija o arquivo ou apague-o para recomecar."
  }
  $out = @(); foreach ($i in $parsed) { $out += $i }   # PS 5.1 devolve o array embrulhado: desembrulha
  return $out
}
function Save-Contas($lista) {
  $arr = @($lista)
  $json = if ($arr.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject $arr -Depth 4 }
  $tmp = "$Cfg.tmp"; Set-Content $tmp $json -Encoding UTF8; Move-Item $tmp $Cfg -Force   # grava inteiro ou nao grava: nunca um arquivo pela metade
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
# Uma unica consulta ao Windows serve para todas as contas.
function Get-ClaudeProcs { @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" | Where-Object { $_.CommandLine }) }
# O --user-data-dir da linha de comando e EXATAMENTE este perfil (a conta T1 nao pode "ver" os processos da T10).
function Test-Dentro($cmd, $dir) {
  $m = [regex]::Match($cmd, '--user-data-dir=(?:"([^"]*)"|(\S+))')
  if (-not $m.Success) { return $false }
  $v = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
  return ($v.TrimEnd('\') -ieq $dir.TrimEnd('\'))
}
# Todos os processos da conta: os que levam o --user-data-dir dela + os executaveis que moram dentro da pasta do perfil (ex.: o Claude Code).
function Get-Procs($conta, $todos = $null) {
  if ($null -eq $todos) { $todos = Get-ClaudeProcs }
  $dir = $conta.profileDir.TrimEnd('\')
  @($todos | Where-Object { (Test-Dentro $_.CommandLine $dir) -or ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($dir + '\', [StringComparison]::OrdinalIgnoreCase)) })
}
# "Aberta" = o processo PRINCIPAL do motor do Hub (nao conta processo auxiliar nem o Claude Code que sobrou rodando).
function Test-Running($conta, $todos = $null) {
  return (@(Get-Procs $conta $todos | Where-Object { $_.CommandLine -notmatch '--type=' -and $_.ExecutablePath -and ($_.ExecutablePath -ieq $EngineExe) }).Count -gt 0)
}
function Get-EmUso($todos = $null) {   # processos usando arquivos do motor (impedem a copia por cima)
  if ($null -eq $todos) { $todos = Get-ClaudeProcs }
  @($todos | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($Engine + '\', [StringComparison]::OrdinalIgnoreCase) })
}

# ------------------------------------------------------------------ motor e atualizacao
function Get-Instalado {
  $p = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Where-Object { $_.InstallLocation -and (Test-Path (Join-Path $_.InstallLocation 'app\Claude.exe')) } | Sort-Object Version -Descending | Select-Object -First 1
  if (-not $p) { return $null }
  return [pscustomobject]@{ Versao = [string]$p.Version; Pasta = (Join-Path $p.InstallLocation 'app') }
}
function Get-MotorVersao {
  $f = Join-Path $Engine '.hub-versao'
  if (Test-Path $f) { return (Get-Content $f -Raw).Trim() }
  return $null
}
function Test-Defasado($instalada, $motor) {
  if (-not $instalada -or -not $motor) { return $false }
  try { return ([version]$instalada -gt [version]$motor) } catch { return ($instalada -ne $motor) }
}
function Test-MotorDefasado { $i = Get-Instalado; return (Test-Defasado $(if ($i) { $i.Versao }) (Get-MotorVersao)) }
function Get-MutexNome {
  $h = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Root.ToLower()))).Replace('-', '').Substring(0, 16)
  return "Local\ClaudeHubMotor_$h"
}
function Update-Engine([switch]$ViaWinget, [switch]$Forcar) {
  if ($ViaWinget) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'winget nao encontrado neste computador.' }
    & winget upgrade --id Anthropic.Claude --silent --accept-package-agreements --accept-source-agreements | Out-Null
  }
  $inst = Get-Instalado
  if (-not $inst) { throw 'O Claude Desktop (Microsoft Store) nao foi encontrado neste computador. Instale-o e tente de novo.' }
  # Uma atualizacao por vez: dois atalhos clicados juntos nao podem copiar por cima um do outro.
  $mx = New-Object System.Threading.Mutex($false, (Get-MutexNome)); $tem = $false
  try {
    try { $tem = $mx.WaitOne(180000) } catch [System.Threading.AbandonedMutexException] { $tem = $true }
    if (-not $tem) { throw 'Outra atualizacao do motor esta em andamento ha mais de 3 minutos. Tente de novo.' }
    if (-not $Forcar -and (Get-MotorVersao) -eq $inst.Versao -and (Test-Path $EngineExe)) { return $inst.Versao }   # outro processo ja atualizou
    $emUso = Get-EmUso
    if ($emUso.Count) {
      $nomes = @(Get-Contas | Where-Object { Test-Running $_ } | ForEach-Object { $_.nome })
      throw ('Feche as contas do Hub antes de atualizar o motor' + $(if ($nomes.Count) { ': ' + ($nomes -join ', ') } else { ' (ha processos do Claude usando o motor).' }))
    }
    New-Item -ItemType Directory -Force $Engine | Out-Null
    Remove-Item (Join-Path $Engine '.hub-versao') -Force -ErrorAction SilentlyContinue   # marca "copia em andamento": se for interrompida, a proxima abertura refaz
    $rc = Start-Process -FilePath robocopy -ArgumentList "`"$($inst.Pasta)`" `"$Engine`" /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP" -PassThru -WindowStyle Hidden
    while (-not $rc.HasExited) { Start-Sleep -Milliseconds 150; if ($script:Pump) { & $script:Pump } }
    $rc.WaitForExit()
    if ($rc.ExitCode -ge 8) { throw "Falha ao copiar o Claude (robocopy codigo $($rc.ExitCode))." }
    if (-not (Test-Path $EngineExe)) { throw 'A copia terminou, mas o claude.exe nao esta no motor.' }
    Set-Content (Join-Path $Engine '.hub-versao') $inst.Versao -Encoding ASCII
    return $inst.Versao
  } finally { if ($tem) { try { $mx.ReleaseMutex() } catch {} }; $mx.Dispose() }
}

# ------------------------------------------------------------------ abrir / fechar
function Open-Conta($conta) {
  $aviso = ''
  if (-not (Test-Path $EngineExe) -or -not (Get-MotorVersao)) {
    [void](Update-Engine)                       # primeira vez (ou copia interrompida): cria o motor
  } elseif (Test-MotorDefasado) {
    # Ha um Claude mais novo instalado. So da para trocar o motor se nenhuma conta do Hub estiver aberta.
    try { $v = Update-Engine; $aviso = " (motor atualizado para $v)" }
    catch { $aviso = ' (aviso: ha uma versao mais nova do Claude; feche as outras contas do Hub e abra de novo para atualizar)' }
  }
  if (Test-Running $conta) { return 'ja estava aberta' }
  Start-Process -FilePath $EngineExe -ArgumentList "--user-data-dir=`"$($conta.profileDir)`"" | Out-Null
  return "aberta$aviso"
}
function Close-Conta($conta) {
  $procs = Get-Procs $conta
  foreach ($m in ($procs | Where-Object { $_.CommandLine -notmatch '--type=' -and $_.ExecutablePath -ieq $EngineExe })) { try { (Get-Process -Id $m.ProcessId).CloseMainWindow() | Out-Null } catch {} }
  for ($i = 0; $i -lt 8 -and (Test-Running $conta); $i++) { Start-Sleep -Milliseconds 500 }   # espera sair sozinho (ate 4 s)
  foreach ($x in (Get-Procs $conta)) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue }
}

# ------------------------------------------------------------------ atalhos
function New-Atalho($conta) {
  $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "Claude - $($conta.nome).lnk"
  $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
  # O atalho chama o Hub (e nao o claude.exe direto) para o motor se atualizar sozinho quando houver Claude novo.
  $s.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
  $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Abrir `"$($conta.nome)`""
  $s.WorkingDirectory = $Root
  if (Test-Path $EngineExe) { $s.IconLocation = "$EngineExe,0" }
  $s.Description = "Claude - $($conta.nome)"; $s.Save()
  return $lnk
}

# ------------------------------------------------------------------ estado (coletado em segundo plano pelo painel)
function Get-Estado {
  try {
    $todos = Get-ClaudeProcs; $contas = @(Get-Contas); $est = @{}
    foreach ($c in $contas) { $est[$c.nome] = (Test-Running $c $todos) }
    $inst = Get-Instalado; $iv = $(if ($inst) { $inst.Versao } else { $null }); $mv = Get-MotorVersao
    return [pscustomobject]@{ Erro = $null; Contas = $contas; Estado = $est; Instalado = $iv; Motor = $mv; Defasado = (Test-Defasado $iv $mv) }
  } catch {
    return [pscustomobject]@{ Erro = $_.Exception.Message; Contas = @(); Estado = @{}; Instalado = $null; Motor = $null; Defasado = $false }
  }
}

if ($SoFuncoes) { return }

# ------------------------------------------------------------------ painel
function Show-Painel {
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
  [System.Windows.Forms.Application]::EnableVisualStyles()
  $hub = $PSCommandPath
  $f = New-Object System.Windows.Forms.Form
  $f.Text = 'Claude Hub - varias contas ao mesmo tempo'; $f.Size = New-Object System.Drawing.Size(820, 470); $f.StartPosition = 'CenterScreen'; $f.MinimumSize = New-Object System.Drawing.Size(720, 380)
  $f.Font = New-Object System.Drawing.Font('Segoe UI', 10)
  $lv = New-Object System.Windows.Forms.ListView
  $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $false; $lv.HideSelection = $false; $lv.Dock = 'Fill'
  [void]$lv.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($lv, $true, $null)   # sem isso a lista "pisca" ao atualizar
  [void]$lv.Columns.Add('Conta', 200); [void]$lv.Columns.Add('Estado', 110); [void]$lv.Columns.Add('Pasta do perfil', 460)
  $bar = New-Object System.Windows.Forms.FlowLayoutPanel; $bar.Dock = 'Top'; $bar.Height = 52; $bar.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 0)
  $st = New-Object System.Windows.Forms.Label; $st.Dock = 'Bottom'; $st.Height = 46; $st.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 0)
  $f.Controls.Add($lv); $f.Controls.Add($st); $f.Controls.Add($bar)
  $fonteNormal = $lv.Font; $fonteNegrito = New-Object System.Drawing.Font($lv.Font, 'Bold')
  $script:estado = @{}; $script:longo = $false; $script:ar = $null; $script:ps = $null; $script:ultimo = Get-Date
  $script:Pump = { [System.Windows.Forms.Application]::DoEvents() }
  function Add-Btn($txt, $w, $acao) { $b = New-Object System.Windows.Forms.Button; $b.Text = $txt; $b.Width = $w; $b.Height = 34; $b.Add_Click($acao); $bar.Controls.Add($b); return $b }
  $erro = { param($e) [System.Windows.Forms.MessageBox]::Show($e.Exception.Message, 'Claude Hub', 'OK', 'Warning') | Out-Null }
  $sel = { if ($lv.SelectedItems.Count) { return $lv.SelectedItems[0].Tag } else { throw 'Selecione uma conta na lista.' } }

  # Aplica o estado na tela mexendo SO no que mudou (nada de apagar e recriar a lista a cada ciclo).
  $aplicar = { param($d)
    if ($d.Erro) { if ($st.Text -ne $d.Erro) { $st.Text = $d.Erro }; return }
    $nomesTela = @($lv.Items | ForEach-Object { $_.Text }); $nomesNovos = @($d.Contas | ForEach-Object { $_.nome })
    $rotulo = @{}; foreach ($c in $d.Contas) { $rotulo[$c.nome] = $(if ($d.Estado[$c.nome]) { 'Aberta' } else { 'Fechada' }) }
    if (($nomesTela -join '|') -ne ($nomesNovos -join '|')) {
      $keep = if ($lv.SelectedItems.Count) { $lv.SelectedItems[0].Text } else { $null }
      $lv.BeginUpdate(); $lv.Items.Clear()
      foreach ($c in $d.Contas) {
        $it = New-Object System.Windows.Forms.ListViewItem($c.nome); [void]$it.SubItems.Add($rotulo[$c.nome]); [void]$it.SubItems.Add($c.profileDir)
        $it.Tag = $c; try { $it.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($c.cor) } catch {}
        $it.Font = $(if ($rotulo[$c.nome] -eq 'Aberta') { $fonteNegrito } else { $fonteNormal })
        [void]$lv.Items.Add($it); if ($keep -and $c.nome -eq $keep) { $it.Selected = $true }
      }
      $lv.EndUpdate()
    } else {
      foreach ($it in $lv.Items) {
        $n = $it.Text
        if ($it.SubItems[1].Text -ne $rotulo[$n]) { $it.SubItems[1].Text = $rotulo[$n]; $it.Font = $(if ($rotulo[$n] -eq 'Aberta') { $fonteNegrito } else { $fonteNormal }) }
      }
    }
    $txt = "Motor do Hub: $(if ($d.Motor) { $d.Motor } else { 'ainda nao criado' })   |   Claude instalado: $(if ($d.Instalado) { $d.Instalado } else { 'nao encontrado (instale o Claude Desktop pela Microsoft Store)' })"
    if ($d.Defasado) { $txt += "`r`nHa uma versao mais nova do Claude. Ela e aplicada sozinha ao abrir uma conta (com as outras fechadas) ou em 'Atualizar motor'." }
    elseif ($d.Instalado -and -not $d.Motor) { $txt += "`r`nO motor sera criado ao abrir a primeira conta (ou em 'Atualizar motor')." }
    if ($st.Text -ne $txt) { $st.Text = $txt }
    if ($env:CLAUDEHUB_DUMP) { try { (@($lv.Items | ForEach-Object { '{0}={1}' -f $_.Text, $_.SubItems[1].Text }) -join ';') | Set-Content $env:CLAUDEHUB_DUMP -Encoding ASCII } catch {} }   # diagnostico opcional (testes): grava o que a lista mostra
  }
  # Coleta em outra thread: a tela nunca congela esperando o Windows responder.
  $iniciar = {
    if ($script:ar) { return }
    $script:ps = [powershell]::Create()
    [void]$script:ps.AddScript({ param($h) . $h -SoFuncoes; Get-Estado }).AddArgument($hub)
    $script:ar = $script:ps.BeginInvoke()
  }
  $coletarAgora = { & $aplicar (Get-Estado) }   # so na abertura do painel (uma vez)

  $longo = { param($texto, [scriptblock]$acao)   # operacao demorada: trava os botoes (nada de clique duplo) e mantem a tela viva
    $script:longo = $true; $bar.Enabled = $false; $lv.Enabled = $false; $f.Cursor = 'WaitCursor'; if ($texto) { $st.Text = $texto }; [System.Windows.Forms.Application]::DoEvents()
    try { & $acao } catch { & $erro $_ } finally { $script:longo = $false; $bar.Enabled = $true; $lv.Enabled = $true; $f.Cursor = 'Default'; & $iniciar }
  }
  [void](Add-Btn 'Abrir' 80 { & $longo 'Abrindo...' { $c = & $sel; [void](Open-Conta $c); Start-Sleep -Milliseconds 800 } })
  [void](Add-Btn 'Abrir todas' 100 { & $longo 'Abrindo todas as contas...' { foreach ($c in (Get-Contas)) { [void](Open-Conta $c); Start-Sleep -Milliseconds 600 } } })
  [void](Add-Btn 'Fechar' 80 { & $longo 'Fechando...' { $c = & $sel; Close-Conta $c } })
  [void](Add-Btn 'Nova conta' 100 { try { $n = [Microsoft.VisualBasic.Interaction]::InputBox('Nome da nova conta (ex.: Trabalho, Pessoal):', 'Nova conta', ''); if ($n.Trim()) { $c = New-Conta $n; [void](New-Atalho $c); & $iniciar } } catch { & $erro $_ } })
  [void](Add-Btn 'Atalho' 70 { try { $c = & $sel; $l = New-Atalho $c; [System.Windows.Forms.MessageBox]::Show("Atalho criado no desktop:`r`n$l", 'Claude Hub') | Out-Null } catch { & $erro $_ } })
  [void](Add-Btn 'Remover' 80 { try { $c = & $sel; if ([System.Windows.Forms.MessageBox]::Show("Tirar '$($c.nome)' da lista?`r`nA pasta do perfil (login e historico) NAO e apagada.", 'Remover', 'YesNo', 'Question') -eq 'Yes') { [void](Remove-Conta $c.nome); & $iniciar } } catch { & $erro $_ } })
  [void](Add-Btn 'Importar do app antigo' 160 { try { $n = Import-MICD; [System.Windows.Forms.MessageBox]::Show("$n conta(s) importada(s) do Multi Instance for Claude Desktop (mesmos perfis, login mantido).", 'Claude Hub') | Out-Null; & $iniciar } catch { & $erro $_ } })
  [void](Add-Btn 'Atualizar motor' 120 { & $longo 'Copiando o Claude instalado para o motor do Hub (cerca de 700 MB)...' { $v = Update-Engine; [System.Windows.Forms.MessageBox]::Show("Motor na versao $v.", 'Claude Hub') | Out-Null } })
  [void](Add-Btn 'Baixar atualizacao' 140 {
      if ([System.Windows.Forms.MessageBox]::Show("Isto pede ao winget a versao mais nova do Claude.`r`nSe houver atualizacao, o Windows pode FECHAR o seu Claude principal. Salve o que estiver fazendo. Continuar?", 'Baixar atualizacao', 'YesNo', 'Warning') -ne 'Yes') { return }
      & $longo 'Procurando e baixando a atualizacao (winget)...' { $v = Update-Engine -ViaWinget; [System.Windows.Forms.MessageBox]::Show("Pronto. Motor na versao $v.", 'Claude Hub') | Out-Null } })
  $lv.Add_DoubleClick({ & $longo 'Abrindo...' { $c = & $sel; [void](Open-Conta $c); Start-Sleep -Milliseconds 800 } })
  # Nao deixa fechar a janela no meio de uma copia do motor (a copia continuaria solta em segundo plano).
  $f.Add_FormClosing({ if ($script:longo) { $_.Cancel = $true; [System.Windows.Forms.MessageBox]::Show('Aguarde: o Hub esta no meio de uma operacao.', 'Claude Hub') | Out-Null } })
  $f.Add_FormClosed({ try { if ($script:ps) { $script:ps.Stop(); $script:ps.Dispose() } } catch {} })

  # A cada 1 s so olha se a coleta em segundo plano terminou; uma nova coleta comeca a cada 6 s (e nao com a janela minimizada).
  $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 1000
  $timer.Add_Tick({
    if ($script:ar) {
      if ($script:ar.IsCompleted) {
        $r = $null; try { $r = $script:ps.EndInvoke($script:ar) } catch {}
        try { $script:ps.Dispose() } catch {}; $script:ps = $null; $script:ar = $null; $script:ultimo = Get-Date
        if ($r -and $r.Count) { & $aplicar $r[0] }
      }
    } elseif (-not $script:longo -and $f.WindowState -ne 'Minimized' -and ((Get-Date) - $script:ultimo).TotalSeconds -ge 6) { & $iniciar }
  })
  & $coletarAgora
  $timer.Start()
  [void]$f.ShowDialog()
  $timer.Stop()
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
  if ($Atualizar) { "Motor na versao " + (Update-Engine -ViaWinget:$Baixar -Forcar:$Forcar); return }
  if ($Importar)  { "$(Import-MICD) conta(s) importada(s)."; return }
  if ($Atalho)    { "Atalho: " + (New-Atalho (Find-Conta $Atalho)); return }
  Show-Painel
} catch {
  Write-Host "ERRO: $($_.Exception.Message)" -ForegroundColor Red
  if ($Abrir -or $Nova -or -not ($Listar -or $Todas -or $Fechar -or $Remover -or $Atualizar -or $Importar -or $Atalho)) {   # atalho/painel rodam sem janela de console: mostra o erro numa caixa
    try { Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Claude Hub', 'OK', 'Warning') | Out-Null } catch {}
  }
  exit 1
}
