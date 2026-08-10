# OnePlus v0.6.0

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
ONEPLUS_REF=v0.6.0 bash <(curl -fsSL https://raw.githubusercontent.com/twossh/oneplus/main/setup.sh)
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


## OpenVPN mTLS opcional por dispositivo

A v0.6.0 mantém o modo padrão compatível de **usuário/senha via PAM**, mas adiciona um segundo modo opcional: **usuário/senha + certificado mTLS individual por dispositivo**. O certificado não substitui a conta OnePlus; ele funciona como um segundo fator criptográfico.

No modo híbrido, cada Android, iPhone, notebook ou outro dispositivo recebe um certificado próprio. O servidor exige `verify-client-cert require`, EKU de cliente e consulta uma CRL local antes de concluir a autenticação PAM.

Pelo menu `oneplus openvpn` é possível:

- emitir um perfil `.ovpn` individual para um usuário/dispositivo;
- listar certificados e seus seriais;
- revogar somente um dispositivo sem trocar a senha do usuário;
- rotacionar um certificado criando primeiro o novo perfil e mantendo o anterior válido por uma janela de 1 a 168 horas;
- gerar e verificar a CRL.

A chave privada do dispositivo é criada em diretório temporário, embutida apenas no perfil `0600` exportado e apagada do servidor em seguida. O servidor conserva somente o certificado público e metadados necessários para revogação.

A manutenção da janela de migração roda por `oneplus-openvpn-pki-maintenance.timer` a cada cinco minutos. Ao fim da janela, o certificado antigo é revogado e a CRL é regenerada. A CA raiz, a chave `tls-crypt` e o certificado do servidor **não são rotacionados automaticamente nesta versão**.

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

A v0.5.2 completa o canal estável: o OnePlus passa a atualizar por **GitHub Release assinada**, não executando código novo diretamente de uma tag antes de validar o pacote.

A atualização exige:

1. chave pública Minisign confiável em `/etc/oneplus/update.pub`;
2. `OnePlus-vX.Y.Z.tar.gz`;
3. checksum `.sha256` assinado por Minisign;
4. SHA-256 correto do pacote;
5. inspeção do TAR sem symlink, hardlink, device, FIFO, path traversal ou setuid/setgid;
6. `release/SHA256SUMS` interno assinado;
7. SHA-256 de toda a árvore;
8. `VERSION` correspondente à release;
9. `scripts/validate.sh` aprovado antes de `install.sh`.

Downgrade é recusado. Antes da instalação é criado rollback local com os arquivos e o estado das unidades `systemd`; após sucesso, a retenção padrão é de três rollbacks.

A v0.5.2 consulta a API oficial de GitHub Releases somente quando o administrador solicita. O JSON retornado é validado antes de usar qualquer `browser_download_url`: draft/prerelease são recusados, a tag deve ser `vX.Y.Z` e os três assets esperados precisam existir com URL e tamanho válidos.

Comandos diretos:

```bash
oneplus update --check
oneplus update --latest
oneplus update --tag v0.5.2
```

`--check` apenas consulta e informa; não instala nada. `--latest` e `--tag` continuam exigindo chave Minisign confiável, validação completa e confirmação `ATUALIZAR`.

### Gerar a chave de releases

Faça uma única vez, **fora da VPS de produção e fora do repositório**:

```bash
bash scripts/release-keygen.sh "$HOME/.config/oneplus-release"
```

O script cria a chave privada e a pública com permissões restritas e recusa gerar a chave dentro do projeto. **Nunca envie `oneplus-release.key` ao GitHub ou à VPS.**

Copie somente a chave pública para a VPS, confira seu SHA-256 por um canal independente e importe em:

```bash
oneplus update
```

### Preparar uma release

Depois de atualizar `VERSION`/`CHANGELOG.md` e fazer commit do código:

```bash
bash scripts/release-prepare.sh \
  "$HOME/.config/oneplus-release/oneplus-release.key" \
  "$HOME/.config/oneplus-release/oneplus-release.pub"
```

O processo gera o manifesto interno assinado e os três assets para a GitHub Release. As instruções completas estão em `docs/RELEASES.md`.

O `setup.sh` usado na primeira instalação continua sendo um bootstrap via HTTPS/GitHub. Depois que a chave pública é instalada e conferida, os upgrades estáveis usam a cadeia Minisign descrita acima.

## Conectividade

O OnePlus mantém:

- OpenSSH por snippet validado com `sshd -t`;
- Dropbear oficial Ubuntu com root bloqueado;
- WebSocket Python 3 com upstream fixo;
- TLS/Stunnel TLS 1.2+;
- OpenVPN oficial Ubuntu com PAM restrito a `oneplus-users` e mTLS híbrido opcional por dispositivo;
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
oneplus-openvpn-pki-maintenance.service
oneplus-openvpn-pki-maintenance.timer
oneplus-mux.service
oneplus-firewall.service
oneplus-badvpn.service
oneplus-slowdns.service
oneplus-user-maintenance.service
oneplus-user-maintenance.timer
```

Os timers de manutenção de usuários e de PKI OpenVPN são habilitados automaticamente; o timer de PKI não altera nada enquanto não houver certificados com rotação agendada. Protocolos e NAT permanecem sob decisão explícita do administrador.

## Validação antes do GitHub

```bash
bash scripts/validate.sh
sudo bash scripts/test-users.sh
sudo bash scripts/test-openvpn.sh
bash scripts/test-mux.sh
bash scripts/test-operations.sh
python3 scripts/test-websocket.py
systemd-analyze verify systemd/*.service systemd/*.timer
```

O GitHub Actions usa Ubuntu 24.04 e repete as validações compatíveis.
