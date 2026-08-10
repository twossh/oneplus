# OnePlus v0.1.2

Gerenciador CLI de servidor via SSH, criado do zero para Ubuntu 24.04 ou superior.

## Instalação direta pelo GitHub

Repositório oficial:

`https://github.com/twossh/oneplus`

Em uma VPS Ubuntu 24.04+ como root:

```bash
apt-get update && apt-get install -y curl ca-certificates && bash <(curl -fsSL https://raw.githubusercontent.com/twossh/oneplus/main/setup.sh)
```

O `setup.sh` instala o Git quando necessário, baixa a árvore do OnePlus, corrige permissões executáveis, executa a validação estática, chama o instalador principal e finaliza com `oneplus --check`.

Também é possível instalar manualmente:

```bash
git clone https://github.com/twossh/oneplus.git
cd oneplus
chmod +x setup.sh install.sh uninstall.sh bin/oneplus lib/*.sh modules/*.sh libexec/* scripts/*.sh
bash scripts/validate.sh
bash install.sh
oneplus --check
oneplus
```

Para instalar uma branch ou tag específica pelo bootstrap:

```bash
ONEPLUS_REF=v0.1.2 bash <(curl -fsSL https://raw.githubusercontent.com/twossh/oneplus/main/setup.sh)
```

> O comando acima exige que a tag `v0.1.2` já exista no GitHub. Para desenvolvimento, o padrão é `main`.

## Objetivos desta fase

- instalador seguro e idempotente;
- núcleo CLI `oneplus`;
- diagnóstico do sistema;
- gerenciamento seguro de configurações OpenSSH via `sshd_config.d`;
- BadVPN UDPGW compilado localmente a partir de commit fixado;
- SlowDNS baseado no `dnstt` v1.20260501.0 e executado por `systemd`;
- nenhuma alteração destrutiva em `/bin`, crontab, firewall ou configuração global do SSH;
- BadVPN e SlowDNS instalados, porém desabilitados até configuração explícita;
- validação automática no GitHub Actions.

## Comandos

```bash
oneplus             # abre o menu
oneplus --version   # mostra a versão
oneplus --check     # diagnóstico da instalação
```

## Layout instalado

- `/opt/oneplus`: aplicação;
- `/etc/oneplus`: configuração persistente;
- `/usr/local/lib/oneplus/bin`: binários externos compilados;
- `/usr/local/bin/oneplus`: comando global;
- `journalctl -u oneplus-badvpn`: logs BadVPN;
- `journalctl -u oneplus-slowdns`: logs DNSTT.

## OpenSSH

O OnePlus não substitui `/etc/ssh/sshd_config`. Quando solicitado, cria apenas:

`/etc/ssh/sshd_config.d/60-oneplus.conf`

Toda alteração é validada com `sshd -t` antes de ser aplicada. Em caso de falha, o snippet anterior é restaurado.

## BadVPN

O OnePlus compila somente `badvpn-udpgw`, necessário para compatibilidade com clientes SSH que utilizam UDPGW. O código-fonte é obtido do repositório oficial e o commit esperado é fixado no módulo para evitar compilar silenciosamente uma revisão diferente. Por padrão, o serviço escuta em `127.0.0.1:7300`.

## SlowDNS

Implementado com `dnstt v1.20260501.0`. O serviço requer um domínio/subdomínio delegado e uma chave gerada localmente no servidor. A chave privada fica em `/etc/oneplus/slowdns/server.key` e nunca é armazenada no repositório.

Por padrão o `dnstt-server` escuta em `0.0.0.0:53/UDP` após configuração explícita e encaminha o túnel para `127.0.0.1:22`.

## Validação do código

Antes de publicar ou instalar:

```bash
bash scripts/validate.sh
```

O validador verifica arquivos obrigatórios, versão, sintaxe Bash, CRLF, permissões executáveis, ausência de padrões destrutivos conhecidos, ausência de chaves privadas e leitura segura dos arquivos `.env`.

## Estado do projeto

Esta é a fase inicial. As próximas versões adicionarão gerenciamento completo de usuários SSH, expiração, limites de conexão, monitoramento, backups seguros e atualização do próprio OnePlus.
