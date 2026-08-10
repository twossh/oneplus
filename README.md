# OnePlus v0.2.0

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

Para instalar uma branch ou tag específica:

```bash
ONEPLUS_REF=v0.2.0 bash <(curl -fsSL https://raw.githubusercontent.com/twossh/oneplus/main/setup.sh)
```

> A tag precisa existir no GitHub. Para desenvolvimento, o padrão é `main`.

## Comandos

```bash
oneplus             # menu principal
oneplus users       # abre diretamente a gestão de usuários SSH
oneplus --version   # mostra a versão
oneplus --check     # diagnóstico da instalação
oneplus --help      # ajuda
```

## Fase 2 — Gestão de usuários SSH

A versão 0.2.0 adiciona contas SSH gerenciadas sem armazenar senhas em texto puro.

Recursos:

- criar usuário SSH regular;
- criar conta de teste temporária;
- alterar senha usando `passwd` diretamente;
- validade por número de dias (períodos de 24 horas), data exata ou sem expiração;
- bloqueio e desbloqueio;
- ação por conta ao expirar: bloquear, remover preservando home ou remover home validado;
- limite individual de conexões simultâneas;
- monitor de conexões SSH ativas;
- encerramento automático de conexões excedentes;
- expiração automática por `systemd timer`;
- remoção automática segura de contas de teste expiradas;
- remoção manual com opção de preservar ou excluir `/home`;
- metadados root-only em `/var/lib/oneplus/users`;
- nenhuma senha persistida pelo OnePlus.

### Isolamento das contas

Todas as contas criadas pelo OnePlus entram no grupo:

`oneplus-users`

Para executar ações destrutivas como bloquear, desconectar ou remover uma conta, o OnePlus confere simultaneamente:

1. nome de usuário em formato permitido;
2. arquivo de metadados existente;
3. UID atual diferente de zero;
4. UID atual igual ao UID registrado na criação;
5. associação ao grupo `oneplus-users`.

O OnePlus não gerencia automaticamente `root`, contas administrativas existentes ou usuários criados fora dele.

### Senhas

Usuários regulares usam o próprio comando `passwd`, portanto a senha não passa por arquivo de configuração do OnePlus.

Contas de teste recebem uma senha aleatória gerada com `openssl`. Ela é enviada ao `chpasswd` por stdin, exibida uma única vez no terminal e não é gravada nos metadados.

### Expiração

Contas regulares usam `chage` como proteção nativa adicional e também são acompanhadas pelo timer do OnePlus. O timer mantém a precisão em segundos; o `chage` é configurado como uma proteção de retaguarda para nunca antecipar o vencimento definido no OnePlus.

Por padrão:

- usuário regular expirado: é bloqueado e suas sessões são encerradas;
- usuário de teste expirado: conta e `/home/<usuario>` são removidos, somente após validação de identidade e do caminho do home.

O timer roda a cada 15 segundos:

```bash
systemctl status oneplus-user-maintenance.timer
journalctl -u oneplus-user-maintenance.service
```

As preferências iniciais ficam em:

`/etc/oneplus/users.conf`

### Limites de conexão

O OnePlus gera:

`/etc/security/limits.d/90-oneplus.conf`

Quando `pam_limits.so` está presente no stack PAM do SSH, `maxlogins` fornece uma primeira camada de limite. Como esse mecanismo pode ter corrida em logins simultâneos e não é a mesma coisa que `MaxSessions` do OpenSSH, o OnePlus também monitora os processos SSH pertencentes somente às contas gerenciadas e encerra o excedente mais recente, preservando as conexões mais antigas.

Definir limite `0` significa ilimitado.

## Layout instalado

- `/opt/oneplus`: aplicação;
- `/etc/oneplus`: configuração persistente;
- `/var/lib/oneplus/users`: metadados de contas, modo `0700`;
- `/etc/security/limits.d/90-oneplus.conf`: limites PAM gerados;
- `/usr/local/lib/oneplus/bin`: binários externos compilados;
- `/usr/local/bin/oneplus`: comando global;
- `journalctl -u oneplus-badvpn`: logs BadVPN;
- `journalctl -u oneplus-slowdns`: logs DNSTT;
- `journalctl -u oneplus-user-maintenance`: expiração e limites.

## OpenSSH

O OnePlus não substitui `/etc/ssh/sshd_config`. Quando solicitado, cria apenas:

`/etc/ssh/sshd_config.d/60-oneplus.conf`

Toda alteração é validada com `sshd -t` antes de ser aplicada. Em caso de falha, o snippet anterior é restaurado.

## BadVPN

O OnePlus compila somente `badvpn-udpgw`, necessário para compatibilidade com clientes SSH que utilizam UDPGW. O código-fonte é obtido do repositório oficial em um commit fixado. Por padrão, o serviço escuta em `127.0.0.1:7300`.

## SlowDNS

Implementado com `dnstt v1.20260501.0`. O serviço requer um domínio/subdomínio delegado e uma chave gerada localmente no servidor. A chave privada fica em `/etc/oneplus/slowdns/server.key` e nunca é armazenada no repositório.

Por padrão o `dnstt-server` escuta em `0.0.0.0:53/UDP` após configuração explícita e encaminha o túnel para `127.0.0.1:22`.

## Validação do código

Antes de publicar ou instalar:

```bash
bash scripts/validate.sh
```

O validador verifica arquivos obrigatórios, versão, sintaxe Bash, CRLF, permissões executáveis, ausência de padrões destrutivos conhecidos, ausência de chaves privadas, leitura segura dos `.env` e proteções mínimas do módulo de usuários.

## Atualização sobre versão anterior

A v0.2.0 pode ser instalada sobre a v0.1.2. Configurações existentes em `/etc/oneplus` são preservadas. O novo módulo cria apenas os arquivos que ainda não existirem.

## Estado do projeto

A Fase 1 e a Fase 2 estão implementadas. O próximo ciclo será dedicado à conectividade complementar e, antes disso, aos testes reais desta versão em Ubuntu 24.04+.
