# Claude Hub

Abre **várias contas do Claude Desktop ao mesmo tempo** no Windows — uma janela por conta, cada uma com o próprio login.
Painel gráfico, atalhos no desktop e atualização do motor junto com o Claude instalado.

> **O repositório não contém contas, logins nem o Claude.** Quem baixa começa com o sistema vazio: você cria as contas e faz o login do Claude em cada uma.

## Requisitos
- Windows 10/11 com **Claude Desktop** instalado pela Microsoft Store (`winget install Anthropic.Claude` também serve).
- PowerShell 5.1 (já vem no Windows). Não precisa instalar mais nada nem rodar como administrador.

## Instalar
1. Baixe o repositório (**Code → Download ZIP** ou `git clone`) e extraia/deixe numa pasta fixa, por exemplo `C:\ClaudeHub`.
   Os perfis e o motor ficam **dentro dessa pasta**, então escolha um lugar onde ela possa ficar.
2. Dê dois cliques em **`Instalar.cmd`**. Ele cria o atalho **Claude Hub** no desktop e abre o painel.
3. No painel, **Nova conta** → digite um nome (ex.: *Trabalho*) → selecione a conta → **Abrir** → faça o login do Claude na janela que abrir.

Na primeira abertura o Hub copia o Claude instalado para a pasta `engine` (cerca de 700 MB) — leva alguns segundos.

## Usar
| No painel | Faz |
|---|---|
| **Abrir / Abrir todas / Fechar** | liga e desliga cada conta (só a escolhida) |
| **Nova conta** | cria um perfil vazio e um atalho no desktop (`Claude - Nome`) |
| **Atalho** | recria o atalho de uma conta |
| **Remover** | tira a conta da lista. A pasta do perfil (login e histórico) **não** é apagada |
| **Atualizar motor** | copia o Claude instalado para o Hub (com todas as contas fechadas) |
| **Baixar atualização** | pede ao `winget` o Claude mais novo e depois atualiza o motor. *Pode fechar o seu Claude principal* |
| **Importar do app antigo** | opcional: traz as contas do app "Multi Instance for Claude Desktop" |

Pela linha de comando: `ClaudeHub.ps1 -Listar`, `-Nova "Nome"`, `-Abrir "Nome"` (ou `-Todas`), `-Fechar "Nome"`, `-Atualizar [-Baixar]`, `-Atalho "Nome"`, `-Remover "Nome"`.

## Atualizações
- A **Microsoft Store** atualiza o Claude instalado (se a atualização automática estiver ligada).
- Ao **abrir uma conta**, o Hub confere se o Claude instalado é mais novo que o motor e **atualiza o motor sozinho** — desde que nenhuma outra conta do Hub esteja aberta. Se houver, ele abre na versão atual e avisa; feche as outras e abra de novo.
- O Hub nunca roda `winget upgrade` por conta própria (isso pode fechar o Claude principal): só pelo botão **Baixar atualização**.

## Como funciona
O Claude Desktop é um app Electron e cada pasta de dados (`--user-data-dir`) é uma conta independente. O Windows bloqueia abrir o Claude direto de `C:\Program Files\WindowsApps` com argumentos, e o Electron recente recusa rodar de pastas de pacote da Loja ("Sandboxed processes cannot read…"). Por isso o Hub mantém uma cópia do motor em `engine\`, numa pasta comum, e abre cada conta com `engine\claude.exe --user-data-dir="profiles\<conta>"`.

## Segurança
- `profiles/`, `engine/` e `contas.json` estão no `.gitignore`: **nunca** devem ser enviados ao Git. Cada perfil contém a sessão da conta (cookies e tokens).
- Se for compartilhar a pasta, **apague `profiles\` e `contas.json` antes**.
- Use só com contas **suas**. Este projeto não altera o Claude nem contorna limites; ele apenas abre instâncias separadas do app oficial.

## Problemas comuns
- **A janela abre e fecha na hora** → o motor está desatualizado ou foi criado de uma pasta protegida. Feche todas as contas e use **Atualizar motor**.
- **"Feche estas contas antes de atualizar"** → o Windows não deixa trocar arquivos do motor em uso; feche as contas listadas.
- **O PowerShell reclama de política de execução** → use o `Instalar.cmd` ou o atalho (eles passam `-ExecutionPolicy Bypass` só para aquele processo).
