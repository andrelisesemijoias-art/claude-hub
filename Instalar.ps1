# Instala o Claude Hub nesta pasta: confere o Claude Desktop, cria o atalho "Claude Hub" no desktop e abre o painel.
# Nao cria contas nem copia nenhum login: o sistema comeca vazio.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$hub  = Join-Path $Root 'ClaudeHub.ps1'
Get-ChildItem $Root -Recurse -Include *.ps1, *.cmd -ErrorAction SilentlyContinue | Unblock-File   # arquivos baixados do GitHub vem "bloqueados"

if (-not (Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue)) {
  Write-Host 'O Claude Desktop nao esta instalado. Instale pela Microsoft Store (ou: winget install Anthropic.Claude) e rode este instalador de novo.' -ForegroundColor Yellow
  exit 1
}
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude Hub.lnk'
$s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
$s.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$s.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$hub`""
$s.WorkingDirectory = $Root; $s.Description = 'Claude Hub'; $s.Save()
Write-Host "Atalho criado: $lnk" -ForegroundColor Green
Write-Host 'No painel: "Nova conta" cria um perfil vazio; abra-o e faca o login do Claude naquela janela.'
Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$hub`""
