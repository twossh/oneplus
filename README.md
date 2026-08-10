# OnePlus v0.4.0

Gerenciador CLI de usuários e serviços SSH/VPN para Ubuntu 24.04 ou superior, criado do zero para administração exclusivamente pelo terminal.

O OnePlus não instala painel web, não substitui o `sshd_config` completo, não armazena senhas de usuários em texto puro, não apaga `crontab` e não limpa regras globais de firewall.

## Instalação direta pelo GitHub

Repositório oficial:

`https://github.com/twossh/oneplus`

Em uma VPS Ubuntu 24.04+ como `root`:

```bash
apt-get update && apt-get install -y curl ca-certificates && bash <(curl -fsSL https://raw.githubusercontent.com/twossh/oneplus/main/setup.sh)
```

Para instalar uma tag/branch específica:

```bash
ONEPLUS_REF=v0.4.0 bash <(curl -fsSL https://raw.githubusercontent.com/twossh/oneplus/main/setup.sh)
```

O bootstrap valida o sistema, baixa o projeto em diretório temporário, restaura permissões executáveis, executa `scripts/validate.sh`, chama o instalador e termina com `oneplus --check`.

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

## Comandos

```bash
oneplus             # menu principal
oneplus users       # usuários gerenciados
oneplus dropbear    # Dropbear
oneplus websocket   # WebSocket
oneplus tls         # TLS/Stunnel
oneplus openvpn     # OpenVPN
oneplus mux         # multiplexador sslh
oneplus --version
oneplus --check
oneplus --help
```

## Fase 3 concluída — conectividade

### OpenVPN

A v0.4.0 adiciona OpenVPN usando o pacote mantido pelo Ubuntu. O OnePlus não baixa binários OpenVPN de terceiros e não compila uma versão paralela.

Arquivos principais:

```text
/etc/oneplus/openvpn.env
/etc/oneplus/openvpn/pki/ca.key
/etc/oneplus/openvpn/pki/ca.crt
/etc/oneplus/openvpn/pki/server.key
/etc/oneplus/openvpn/pki/server.crt
/etc/oneplus/openvpn/tls-crypt.key
/etc/pam.d/oneplus-openvpn
```

Serviço:

`oneplus-openvpn.service`

Padrões iniciais:

- escuta interna: `127.0.0.1:1194/TCP`;
- rede privada: `10.8.0.0/24`;
- máximo: `128` clientes;
- certificado do servidor e CA gerados localmente;
- controle TLS protegido por `tls-crypt`;
- TLS mínimo 1.2;
- `AES-256-GCM`, `AES-128-GCM` e ChaCha20-Poly1305 quando suportado;
- sem compressão;
- autenticação por usuário/senha via PAM;
- somente membros de `oneplus-users` podem autenticar;
- `root` não recebe acesso VPN por padrão porque não pertence ao grupo gerenciado;
- nenhuma senha é gravada pelo OnePlus;
- interface de gerenciamento somente em Unix socket local e restrita a root.

O cliente não precisa de certificado privado individual nesta primeira implementação. Ele valida o certificado do servidor usando a CA embutida no perfil e autentica com a mesma conta gerenciada pelo OnePlus. A chave privada da CA permanece somente no servidor e nunca é exportada.

**Trade-off de segurança:** autenticação somente por usuário/senha (`verify-client-cert none`) é menos forte para identificar o dispositivo/cliente do que exigir um certificado individual. O OnePlus mantém essa modalidade nesta fase para integrar diretamente as contas `oneplus-users`; uma camada opcional de mTLS por cliente pode ser adicionada em uma fase de hardening.

O menu exporta um `.ovpn` root-only contendo a CA pública e a chave `tls-crypt`.

**Importante:** a v0.4.0 não ativa `redirect-gateway`, NAT, masquerade ou encaminhamento global automaticamente. O OpenVPN entrega o túnel/rede privada. A publicação de Internet através da VPN será adicionada como recurso opcional na Fase 4, em uma tabela de firewall dedicada e sem limpar regras existentes.

Ao bloquear, expirar ou remover uma conta OnePlus, o módulo de usuários também tenta encerrar a sessão OpenVPN correspondente através do Unix socket de gerenciamento.

### Multiplexador de portas / sslh

A v0.4.0 adiciona `sslh` como multiplexador TCP opcional. Ele permite compartilhar uma porta TCP pública entre protocolos detectáveis, por exemplo:

```text
Internet :443/TCP
        |
        +-- SSH      -> 127.0.0.1:22
        +-- TLS      -> 127.0.0.1:8443
        +-- OpenVPN  -> 127.0.0.1:1194
        +-- HTTP/WS  -> 127.0.0.1:8080
```

Arquivos:

```text
/etc/oneplus/mux.env
oneplus-mux.service
```

Proteções:

- usa `sslh-select` do Ubuntu;
- não usa modo transparente;
- não cria regras `iptables`/`nftables`;
- todos os backends são obrigatoriamente `127.0.0.1`/`localhost`;
- exige pelo menos dois protocolos habilitados;
- roda como `oneplus-mux`, não como root;
- recebe somente `CAP_NET_BIND_SERVICE` para abrir portas privilegiadas;
- conflito na porta pública aborta a ativação e restaura a configuração anterior.

Como o modo transparente é deliberadamente desabilitado, serviços internos podem registrar o endereço do multiplexador como origem em vez do IP real do cliente. Essa é uma escolha de segurança para evitar manipulação automática de firewall nesta fase.

O multiplexador trabalha somente com TCP. Portanto, para publicar OpenVPN através dele, configure o OpenVPN em modo TCP.
O timeout padrão de detecção é **5 segundos**, favorecendo a identificação confiável do handshake OpenVPN antes do encaminhamento.

### Dropbear

O OnePlus usa `dropbear-bin` do Ubuntu em `oneplus-dropbear.service`, com chave host Ed25519 própria e login de root sempre bloqueado por `-w`. Encaminhamento remoto `-R` permanece desabilitado por padrão.

### WebSocket

Proxy próprio Python 3, sem dependências externas, com upstream fixo escolhido pelo administrador. Não aceita `X-Real-Host` para decidir destino e não funciona como open proxy. Possui limites de cabeçalho, frame e clientes.

### TLS / Stunnel

Usa `stunnel4` do Ubuntu. TLS mínimo 1.2/1.3, certificado/chave validados antes da instalação, suporte a certificado existente ou autoassinado para testes/pinning.

## Usuários

As contas criadas pelo OnePlus pertencem ao grupo:

`oneplus-users`

Metadados root-only:

`/var/lib/oneplus/users`

O sistema possui:

- criação de usuários regulares e temporários;
- alteração de senha sem persistir senha;
- validade por dias/data;
- limite individual de conexões SSH;
- bloqueio/desbloqueio;
- monitor de OpenSSH/Dropbear;
- tratamento automático de expiração;
- remoção segura validando UID, grupo e home;
- encerramento complementar de sessão OpenVPN ao bloquear/remover/expirar.

## OpenSSH

O OnePlus nunca substitui `/etc/ssh/sshd_config`. Alterações usam:

`/etc/ssh/sshd_config.d/60-oneplus.conf`

Antes de aplicar, executa:

```bash
sshd -t
```

Se a configuração nova for inválida, ocorre rollback.

## BadVPN e SlowDNS

- BadVPN UDPGW é compilado de commit upstream fixado e recebe hash SHA-256 local;
- UDPGW permanece em `127.0.0.1:7300` por padrão;
- SlowDNS usa `dnstt v1.20260501.0`;
- build Go usa verificação `GOSUMDB`;
- chave privada dnstt é criada localmente;
- SlowDNS não modifica `systemd-resolved`;
- conflitos de bind/porta abortam com rollback.

## Portas sugeridas

| Serviço | Padrão | Transporte |
|---|---:|---|
| OpenSSH | 22 | TCP |
| Dropbear | 442 | TCP |
| WebSocket | 80 | TCP |
| TLS/Stunnel | 443 | TCP |
| OpenVPN interno | 1194 em `127.0.0.1` | TCP |
| Multiplexador | 443 | TCP |
| BadVPN UDPGW | 7300 em `127.0.0.1` | TCP |
| SlowDNS | configurável | UDP |

TLS e multiplexador não podem ocupar a mesma porta pública ao mesmo tempo. Para usar TLS atrás do multiplexador, reconfigure o TLS para uma porta loopback interna, como `127.0.0.1:8443`.

## Serviços systemd

```text
oneplus-dropbear.service
oneplus-websocket.service
oneplus-tls.service
oneplus-openvpn.service
oneplus-mux.service
oneplus-badvpn.service
oneplus-slowdns.service
oneplus-user-maintenance.service
oneplus-user-maintenance.timer
```

Todos permanecem desabilitados até configuração explícita, exceto o timer seguro de manutenção de usuários.

## Validação

Antes de instalar:

```bash
bash scripts/validate.sh
sudo bash scripts/test-users.sh
bash scripts/test-openvpn.sh
bash scripts/test-mux.sh
python3 scripts/test-websocket.py
```

O GitHub Actions executa os mesmos testes estáticos/funcionais compatíveis e valida todas as unidades systemd em `ubuntu-24.04`.

O validador procura, entre outros pontos:

- erros de sintaxe Bash/Python;
- CRLF;
- bits executáveis;
- chaves privadas acidentalmente versionadas;
- comandos destrutivos;
- execução insegura de `.env`;
- OpenVPN com PAM restrito a `oneplus-users`;
- ausência de opções OpenVPN removidas/legadas;
- ausência de NAT/firewall automático no módulo OpenVPN;
- gerenciamento OpenVPN somente por Unix socket;
- backends sslh somente em loopback;
- ausência de modo transparente no sslh;
- Dropbear com root bloqueado;
- WebSocket com upstream fixo;
- TLS mínimo 1.2+;
- integridade BadVPN/dnstt.

## Atualização

Enquanto o atualizador versionado interno não está pronto, execute novamente o bootstrap:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/twossh/oneplus/main/setup.sh)
```

Configurações existentes em `/etc/oneplus` são preservadas. Novos arquivos padrão são criados apenas quando ainda não existem.

## Desinstalação

```bash
sudo ./uninstall.sh
```

A remoção desativa os serviços OnePlus, remove unidades, launcher e o arquivo PAM específico do OpenVPN. Por segurança, `/etc/oneplus`, PKI, metadados e contas de usuários são preservados.

## Estado desta versão

A Fase 3 está funcionalmente completa no código com OpenVPN e multiplexação. A v0.4.0 ainda deve ser validada em uma VPS Ubuntu 24.04 real antes de ser considerada pronta para produção, especialmente login OpenVPN real, perfil em desktop/mobile, OpenVPN atrás do sslh, reboot e combinações de portas.
