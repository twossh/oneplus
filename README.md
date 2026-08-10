# OnePlus v0.5.0

Gerenciador CLI de usuários, SSH, VPN e serviços de conectividade para Ubuntu 24.04 ou superior, administrado exclusivamente pelo terminal.

O OnePlus é código novo. Não substitui o `sshd_config` completo, não armazena senhas em texto puro, não apaga `crontab`, não executa `iptables -F` e não executa `nft flush ruleset`.

## Instalação direta pelo GitHub

Repositório oficial: `https://github.com/twossh/oneplus`

Como `root` em Ubuntu 24.04+:

```bash
apt-get update && apt-get install -y curl ca-certificates && bash <(curl -fsSL https://raw.githubusercontent.com/twossh/oneplus/main/setup.sh)
```

Para uma tag/branch específica:

```bash
ONEPLUS_REF=v0.5.0 bash <(curl -fsSL https://raw.githubusercontent.com/twossh/oneplus/main/setup.sh)
```

Depois:

```bash
oneplus --version
oneplus --check
oneplus
```

## Comandos principais

```bash
oneplus
oneplus users
oneplus dropbear
oneplus websocket
oneplus tls
oneplus openvpn
oneplus mux
oneplus firewall
oneplus backup
oneplus reports
oneplus diagnostics
oneplus update
oneplus --check
```

## Fase 4 — Operação e segurança

### Backup criptografado

`oneplus backup` cria backup de configurações e identidades gerenciadas pelo OnePlus usando `age` com senha informada interativamente.

O backup inclui, quando existentes:

- `/etc/oneplus` — inclusive PKI OpenVPN, TLS, SlowDNS e Dropbear;
- metadados de `/var/lib/oneplus/users`;
- snippet OpenSSH do OnePlus;
- limites PAM;
- PAM OpenVPN;
- configuração de forwarding do OnePlus;
- somente as entradas `passwd`/`shadow` dos usuários realmente gerenciados pelo OnePlus.

O OnePlus **não copia `/etc/shadow` inteiro** e não inclui diretórios `/home` por padrão.

O arquivo final é `*.tar.gz.age`, modo `0600`, acompanhado de SHA-256 externo. Internamente existe outro manifesto SHA-256. A restauração valida checksum, criptografia, caminhos do TAR e recusa links simbólicos antes de alterar o host.

Antes de aplicar uma restauração, o estado OnePlus atual é salvo em `/var/lib/oneplus/rollback` para recuperação local.

### Auditoria de portas e nftables

`oneplus firewall` mostra listeners TCP/UDP, tabelas nftables existentes e estado do UFW sem alterar regras externas.

Quando NAT OpenVPN é habilitado, o OnePlus gerencia somente:

```text
table inet oneplus_filter
table ip oneplus_nat
```

Nenhuma tabela global é limpa ou substituída. O NAT usa `masquerade` apenas para a rede `/24` configurada no OpenVPN e para a interface de saída escolhida pelo administrador.

O arquivo `/etc/sysctl.d/90-oneplus-forwarding.conf` habilita `net.ipv4.ip_forward=1` enquanto a função é configurada. Ao desabilitar o recurso, o OnePlus remove seu arquivo, mas **não força `ip_forward=0` em runtime**, pois outro software do servidor pode depender de forwarding.

Firewalls externos, UFW e security groups do provedor continuam independentes e podem exigir regras próprias.

### Full tunnel OpenVPN opcional

O OpenVPN continua sem manipular firewall diretamente. A opção de full tunnel pertence ao módulo `firewall`.

Quando explicitamente habilitado, o servidor passa a enviar:

```text
redirect-gateway def1 bypass-dhcp
```

DNS IPv4 pode ser informado pelo administrador. Nenhum DNS é imposto por padrão.

### Relatórios

`oneplus reports` fornece snapshots de:

- usuários gerenciados e validade;
- sessões OpenSSH/Dropbear;
- clientes OpenVPN pelo Unix socket local;
- listeners;
- RX/TX por interface;
- contadores das tabelas nftables OnePlus;
- serviços OnePlus;
- logins recentes.

Relatórios completos são salvos em `/var/log/oneplus/reports` com permissão root-only.

### Diagnóstico e reparo

`oneplus diagnostics` valida OpenSSH, hashes dos binários compilados, permissões de chaves, timers, nftables, dependências e unidades com falha.

O reparo reinstala somente arquivos/units do OnePlus, corrige permissões e regenera limites/PAM. Ele não executa `apt upgrade`, não habilita protocolos desativados e não limpa firewall externo.

## Atualização assinada

A v0.5.0 adiciona um atualizador estável **fail-closed** baseado em `minisign` + SHA-256.

Uma atualização por tag só é aceita quando:

1. existe uma chave pública confiável em `/etc/oneplus/update.pub`;
2. a tag contém `release/SHA256SUMS`;
3. existe `release/SHA256SUMS.minisig` válido;
4. todos os arquivos cobertos pelo manifesto passam no SHA-256;
5. `VERSION` corresponde à tag;
6. `scripts/validate.sh` passa antes de `install.sh`.

O atualizador não aceita downgrade e cria rollback local antes da instalação.

### Criar a chave de releases

Faça isso **fora da VPS de produção**, em uma estação administrativa confiável:

```bash
minisign -G -p oneplus-release.pub -s oneplus-release.key
```

A chave secreta é protegida por senha por padrão. **Nunca envie `oneplus-release.key` ao GitHub ou à VPS.**

Copie somente `oneplus-release.pub` para a VPS e importe em:

```bash
oneplus update
```

Para preparar uma release no computador de desenvolvimento:

```bash
bash scripts/release-sign.sh /caminho/seguro/oneplus-release.key
git add release/SHA256SUMS release/SHA256SUMS.minisig VERSION CHANGELOG.md
git commit -m "Release v0.5.1"
git tag v0.5.1
git push origin main --tags
```

O `setup.sh` usado na primeira instalação continua sendo um bootstrap via HTTPS/GitHub. Depois que a chave pública é confiada ao servidor, upgrades estáveis podem usar a cadeia assinada acima.

## Conectividade

O OnePlus mantém:

- OpenSSH por snippet validado com `sshd -t`;
- Dropbear oficial Ubuntu com root bloqueado;
- WebSocket Python 3 com upstream fixo;
- TLS/Stunnel TLS 1.2+;
- OpenVPN oficial Ubuntu com PAM restrito a `oneplus-users`;
- multiplexação TCP via `sslh` com backends loopback;
- BadVPN UDPGW compilado de commit fixado;
- SlowDNS/dnstt `v1.20260501.0`;
- manutenção automática de expiração/limites via systemd.

## Arquivos principais

```text
/opt/oneplus
/etc/oneplus
/var/lib/oneplus/users
/var/lib/oneplus/rollback
/var/lib/oneplus/update-rollback
/var/log/oneplus/reports
/etc/ssh/sshd_config.d/60-oneplus.conf
/etc/security/limits.d/90-oneplus.conf
/etc/pam.d/oneplus-openvpn
/etc/sysctl.d/90-oneplus-forwarding.conf
```

## Serviços systemd

```text
oneplus-dropbear.service
oneplus-websocket.service
oneplus-tls.service
oneplus-openvpn.service
oneplus-mux.service
oneplus-firewall.service
oneplus-badvpn.service
oneplus-slowdns.service
oneplus-user-maintenance.service
oneplus-user-maintenance.timer
```

Somente o timer de manutenção de usuários é habilitado automaticamente. Protocolos e NAT permanecem sob decisão explícita do administrador.

## Validação antes do GitHub

```bash
bash scripts/validate.sh
sudo bash scripts/test-users.sh
bash scripts/test-openvpn.sh
bash scripts/test-mux.sh
bash scripts/test-operations.sh
python3 scripts/test-websocket.py
systemd-analyze verify systemd/*.service systemd/*.timer
```

O GitHub Actions usa Ubuntu 24.04 e repete as validações compatíveis.
