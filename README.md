# OnePlus v0.3.0

Gerenciador CLI de serviços SSH e conectividade para Ubuntu 24.04 ou superior, criado do zero para administração exclusivamente pelo terminal.

O OnePlus não instala painel web, não substitui o `sshd_config` completo, não armazena senhas de usuários em texto puro e não limpa regras globais de firewall ou crontab.

## Instalação direta pelo GitHub

Repositório oficial:

`https://github.com/twossh/oneplus`

Em uma VPS Ubuntu 24.04+ como `root`:

```bash
apt-get update && apt-get install -y curl ca-certificates && bash <(curl -fsSL https://raw.githubusercontent.com/twossh/oneplus/main/setup.sh)
```

O `setup.sh`:

1. valida Ubuntu 24.04+ e execução como root;
2. instala as dependências mínimas do bootstrap;
3. clona `twossh/oneplus` em diretório temporário;
4. restaura permissões executáveis que podem ser perdidas em upload pelo navegador;
5. executa `scripts/validate.sh`;
6. chama `install.sh`;
7. executa `oneplus --check` depois da instalação.

Para instalar uma tag ou branch específica:

```bash
ONEPLUS_REF=v0.3.0 bash <(curl -fsSL https://raw.githubusercontent.com/twossh/oneplus/main/setup.sh)
```

> A referência precisa existir no GitHub. O padrão é `main`.

### Instalação manual

```bash
git clone https://github.com/twossh/oneplus.git
cd oneplus
chmod +x setup.sh install.sh uninstall.sh bin/oneplus lib/*.sh modules/*.sh libexec/* scripts/*.sh scripts/*.py
bash scripts/validate.sh
bash install.sh
oneplus --check
oneplus
```

## Comandos principais

```bash
oneplus             # menu principal
oneplus users       # usuários SSH
oneplus dropbear    # Dropbear
oneplus websocket   # proxy WebSocket
oneplus tls         # TLS/Stunnel
oneplus --version   # versão instalada
oneplus --check     # diagnóstico pós-instalação
oneplus --help      # ajuda
```

## Fase 3 — Conectividade

### Dropbear SSH

O OnePlus utiliza `dropbear-bin` fornecido pelo Ubuntu e cria um serviço separado:

`oneplus-dropbear.service`

Configuração persistente:

`/etc/oneplus/dropbear.env`

Chave host Ed25519 dedicada:

`/etc/oneplus/dropbear/dropbear_ed25519_host_key`

Padrões iniciais:

- escuta: `0.0.0.0:442`;
- autenticação por senha: habilitável no menu;
- encaminhamento local `-L/-D`: habilitado por padrão;
- encaminhamento remoto `-R`: desabilitado por padrão e exige confirmação explícita;
- login de `root`: sempre bloqueado pelo wrapper OnePlus com `-w`;
- serviço: permanece desabilitado até configuração explícita.

O OnePlus instala somente os binários do Dropbear e usa sua própria unidade systemd; não depende do serviço padrão da distribuição.

> Dropbear autentica contas válidas do sistema operacional. A proteção `-w` bloqueia root, mas o Dropbear não é apresentado como mecanismo de `AllowGroups`. Mantenha apenas as contas Linux que realmente devem poder autenticar no servidor.

### WebSocket

Foi criado um proxy próprio em Python 3 usando somente a biblioteca padrão:

`/opt/oneplus/libexec/websocket_proxy.py`

Serviço:

`oneplus-websocket.service`

Configuração:

`/etc/oneplus/websocket.env`

Padrões:

- escuta: `0.0.0.0:80`;
- destino fixo: `127.0.0.1:22`;
- caminho: `/`;
- modo: `auto`;
- clientes simultâneos: `256`.

Modos disponíveis:

- `rfc6455`: WebSocket padrão, com framing, máscara de cliente, ping/pong e fechamento;
- `legacy`: HTTP Upgrade seguido de TCP bruto, somente para clientes antigos compatíveis;
- `auto`: seleciona RFC6455 quando existe uma chave WebSocket válida e, sem chave, usa legacy.

Proteções importantes:

- o destino é definido somente pelo administrador;
- `X-Real-Host` ou cabeçalhos equivalentes não escolhem o destino;
- não funciona como open proxy;
- versão RFC6455 e `Sec-WebSocket-Key` são verificadas antes da conexão ao upstream;
- cabeçalho HTTP limitado a 64 KiB no máximo;
- frame WebSocket limitado a 64 MiB no máximo;
- clientes simultâneos limitados a 4096 no máximo;
- serviço executado como usuário dedicado `oneplus-ws`;
- porta privilegiada é permitida somente com `CAP_NET_BIND_SERVICE`.

### TLS / Stunnel

O OnePlus utiliza `stunnel4` do Ubuntu por meio do serviço:

`oneplus-tls.service`

Configuração:

`/etc/oneplus/tls.env`

Arquivos TLS:

```text
/etc/oneplus/tls/server.crt
/etc/oneplus/tls/server.key
```

Padrões:

- escuta: `0.0.0.0:443`;
- destino: `127.0.0.1:22`;
- TLS mínimo: `TLSv1.2`;
- serviço desabilitado até configuração explícita.

O menu permite importar um certificado/chave PEM existentes ou gerar um certificado autoassinado para testes. Antes da instalação do par, o OnePlus verifica:

- certificado X.509 válido;
- chave privada PEM válida e sem senha interativa;
- chave pública do certificado correspondente à chave privada;
- chave armazenada com acesso restrito ao serviço.

Para exposição pública, use certificado emitido por CA/ACME. O autoassinado é indicado somente para testes ou clientes que façam pin explícito do certificado.

## Usuários SSH — Fase 2

As funcionalidades da v0.2.0 permanecem disponíveis:

- usuários regulares e temporários;
- alteração de senha sem persistir a senha no OnePlus;
- expiração por dias ou data;
- limite individual de conexões;
- bloqueio/desbloqueio;
- monitor de conexões;
- tratamento automático de expirados;
- remoção segura com validação de UID, grupo e home.

As contas criadas pelo OnePlus pertencem ao grupo:

`oneplus-users`

Os metadados ficam em:

`/var/lib/oneplus/users`

O monitor da v0.3.0 reconhece sessões OpenSSH e Dropbear para aplicação complementar dos limites.

## OpenSSH

O OnePlus nunca substitui `/etc/ssh/sshd_config` inteiro.

Quando o administrador escolhe aplicar uma configuração pelo menu, é utilizado:

`/etc/ssh/sshd_config.d/60-oneplus.conf`

Antes de reiniciar o OpenSSH, o projeto executa:

```bash
sshd -t
```

Em caso de configuração inválida, a alteração não deve ser aplicada e o arquivo anterior é restaurado.

## BadVPN e SlowDNS

Os módulos da Fase 1 também receberam revisão na v0.3.0:

- BadVPN UDPGW é compilado do código-fonte original em um commit fixado;
- o OnePlus não baixa binários BadVPN prontos de repositórios de terceiros;
- recompilação é feita antes de substituir o binário anterior e há restauração quando um serviço ativo não reinicia;
- UDPGW permanece em `127.0.0.1:7300` por padrão e escuta externa exige confirmação explícita;
- limites de clientes, conexões e buffer são validados antes da execução;
- SlowDNS permanece fixado em `dnstt v1.20260501.0`;
- o build Go força verificação pelo `GOSUMDB`;
- BadVPN e dnstt recebem hash SHA-256 local após instalação e `oneplus --check` verifica a integridade;
- a chave privada SlowDNS é criada localmente e o wrapper aceita somente `/etc/oneplus/slowdns/server.key`;
- SlowDNS recomenda bind no IPv4 específico da interface, evitando modificar ou desabilitar `systemd-resolved`;
- conflito real de porta UDP faz a configuração abortar e restaurar o estado anterior;
- os serviços permanecem desabilitados até configuração explícita.

## Portas padrão

As portas abaixo são somente padrões sugeridos; o instalador não habilita os serviços automaticamente:

| Serviço | Porta padrão | Transporte |
|---|---:|---|
| OpenSSH | 22 | TCP |
| Dropbear OnePlus | 442 | TCP |
| WebSocket | 80 | TCP |
| TLS/Stunnel | 443 | TCP |
| BadVPN UDPGW | 7300 em `127.0.0.1` | TCP |
| SlowDNS | configurável | UDP |

O OnePlus verifica conflito de porta antes de habilitar Dropbear, WebSocket ou TLS. Ele não cria nem apaga regras globais de firewall automaticamente.

## Serviços systemd

```text
oneplus-dropbear.service
oneplus-websocket.service
oneplus-tls.service
oneplus-badvpn.service
oneplus-slowdns.service
oneplus-user-maintenance.service
oneplus-user-maintenance.timer
```

Os serviços WebSocket e TLS executam com contas dedicadas e hardening do systemd. Dropbear precisa iniciar com privilégios suficientes para autenticar e trocar para o UID do usuário, porém root login permanece bloqueado na linha de comando do servidor.

## Validação do projeto

Antes de instalar:

```bash
bash scripts/validate.sh
sudo bash scripts/test-users.sh
python3 scripts/test-websocket.py
```

O validador confere, entre outros pontos:

- sintaxe Bash;
- sintaxe Python quando Python 3 já está disponível;
- arquivos obrigatórios;
- versão do README;
- permissões executáveis;
- CRLF em scripts;
- presença acidental de chaves privadas;
- padrões destrutivos proibidos;
- leitura segura dos `.env` sem `source`/`eval`;
- root bloqueado no Dropbear;
- upstream WebSocket fixo;
- limites de recursos do proxy;
- TLS mínimo 1.2+;
- usuários de serviço separados.

O workflow `.github/workflows/validate.yml` executa as verificações a cada `push` e `pull_request`.

## Atualização

Enquanto o atualizador versionado interno ainda não está implementado, rode novamente o bootstrap oficial:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/twossh/oneplus/main/setup.sh)
```

O instalador preserva as configurações existentes em `/etc/oneplus` em reinstalações normais.

## Desinstalação

A partir de uma árvore do mesmo release:

```bash
sudo ./uninstall.sh
```

A remoção desabilita os serviços OnePlus e remove os executáveis do projeto. Por segurança, `/etc/oneplus`, metadados e contas SSH gerenciadas não são apagados automaticamente.

## Estado desta versão

A v0.3.0 deve ser validada em VPS real Ubuntu 24.04 antes de ser considerada pronta para produção. A Fase 3 adiciona conectividade, mas OpenVPN e multiplexação de portas continuam planejados para uma etapa posterior.
