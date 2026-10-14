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
| **Atualizar motor** | copia o Claude instalado para o Hub (com todas as contas fechadas). Se já está na mesma versão, não copia nada |
| **Baixar atualização** | pede ao `winget` o Claude mais novo e depois atualiza o motor. *Pode fechar o seu Claude principal* |
| **Importar do app antigo** | opcional: traz as contas do app "Multi Instance for Claude Desktop" |

Pela linha de comando: `ClaudeHub.ps1 -Listar`, `-Nova "Nome"`, `-Abrir "Nome"` (ou `-Todas`), `-Fechar "Nome"`, `-Atualizar [-Baixar] [-Forcar]`, `-Atalho "Nome"`, `-Remover "Nome"`.
`-Forcar` recopia o motor mesmo na mesma versão (conserto, se o motor ficou estranho).

O painel acompanha sozinho o estado das contas (a cada ~6 s, em segundo plano — a tela não trava) e, mesmo que você abra ou feche contas por atalho ou comando, a lista se corrige sozinha.

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

## Garantias (testadas)
- Contas com nomes parecidos (`T1` e `T10`) não se confundem: o Hub compara a pasta do perfil por inteiro.
- Duas contas abertas ao mesmo tempo por atalhos diferentes não se atropelam na hora de copiar o motor (uma atualização por vez).
- Se a cópia do motor for interrompida (queda de energia, janela fechada), a próxima abertura refaz a cópia sozinha.
- Um `contas.json` corrompido não é sobrescrito: o Hub guarda uma cópia (`contas.json.corrompido-…`) e explica o erro.
- Com o motor em uso, a atualização é recusada com o nome da conta a fechar — nunca copia por cima de arquivos em uso.

## Limitações
- Só Claude Desktop instalado pela **Microsoft Store** (é de onde o Hub copia o motor).
- As janelas das contas podem ficar agrupadas num único ícone da barra de tarefas.
- Fechar uma conta pelo Hub fecha também o que ela deixou rodando (por exemplo sessões do Claude Code daquele perfil).

## Problemas comuns
- **A janela abre e fecha na hora** → o motor está desatualizado ou foi criado de uma pasta protegida. Feche todas as contas e use **Atualizar motor**.
- **"Feche estas contas antes de atualizar"** → o Windows não deixa trocar arquivos do motor em uso; feche as contas listadas.
- **O PowerShell reclama de política de execução** → use o `Instalar.cmd` ou o atalho (eles passam `-ExecutionPolicy Bypass` só para aquele processo).
