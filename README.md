# OnePlus v0.8.2

Gerenciador CLI de usuários, SSH, VPN e serviços de conectividade para Ubuntu 24.04 ou superior, administrado exclusivamente pelo terminal.

O OnePlus é código novo. Não substitui o `sshd_config` completo, não armazena senhas em texto puro, não apaga `crontab`, não executa `iptables -F` e não executa `nft flush ruleset`.

### Correções e otimizações da v0.8.2 após a segunda integração real

A segunda execução real em Ubuntu 24.04 revelou um problema de upgrade mais sutil: o `rsync` podia considerar arquivos diferentes como iguais quando tinham o mesmo tamanho e o mesmo `mtime`. Isso ocorreu com `VERSION` (`0.8.0` → `0.8.1`, ambos com 6 bytes) em worktrees criados no mesmo segundo. A v0.8.2 sincroniza `/opt/oneplus` **por conteúdo (`--checksum`)**, atrasa atualizações/exclusões até o fim da transferência e verifica arquivos críticos após a cópia.

A instalação também foi organizada para evitar `apt-get update/install` desnecessário quando todas as dependências já estão presentes, o estado do OpenSSH agora reconhece `ssh.socket`, o workflow ganhou um teste de regressão específico para sincronização e a atualização completa do Ubuntu exige prévia e confirmação explícita.

## Instalação direta pelo GitHub

Repositório oficial: `https://github.com/twossh/oneplus`

Como `root` em Ubuntu 24.04+:

```bash
apt-get update && apt-get install -y curl ca-certificates && bash <(curl -fsSL https://raw.githubusercontent.com/twossh/oneplus/main/setup.sh)
```

Para uma tag/branch específica:

```bash
ONEPLUS_REF=v0.8.2 bash <(curl -fsSL https://raw.githubusercontent.com/twossh/oneplus/main/setup.sh)
```

Depois:

```bash
oneplus --version
oneplus --check
oneplus
```

O instalador v0.8.2 verifica os pacotes já presentes e evita repetir `apt-get update/install` em reinstalações quando as dependências estão satisfeitas. Isso reduz tempo, tráfego e efeitos colaterais. Atualizações gerais do Ubuntu permanecem uma ação separada em `oneplus` → Sistema, com simulação e confirmação explícita.

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
oneplus history
oneplus hardening
oneplus --check
```


## Histórico leve sem banco

A v0.7.0 adiciona snapshots históricos **opt-in** em NDJSON root-only. O coletor registra apenas métricas agregadas necessárias para operação: carga, memória disponível, uso do filesystem raiz, contadores RX/TX por interface, quantidade de contas OnePlus, sessões de login, clientes OpenVPN e estado dos serviços.

Ele **não persiste usernames, IPs remotos, comandos, senhas ou payloads**. A coleta periódica fica desabilitada após a instalação e só é ativada pelo administrador em `oneplus history`. Intervalos permitidos: 1, 5, 15, 30 ou 60 minutos; retenção: 1 a 90 dias.

Os dados ficam em:

```text
/var/lib/oneplus/history/YYYY-MM-DD.ndjson
```

O resumo calcula carga média/máxima, memória mínima disponível, pico de uso da raiz, máximos de sessões/clientes e deltas de tráfego entre snapshots, sem banco de dados.

## Hardening audit-only

`oneplus hardening` audita o host sem aplicar mudanças. Ele revisa sintaxe/estado efetivo do OpenSSH, root login, MaxAuthTries, banner Ubuntu, unattended-upgrades, AppArmor, NTP, units falhas, reboot pendente, permissões do OnePlus, validade de certificados, listeners, firewall e IPv4 forwarding.

O módulo **não instala/atualiza pacotes, não reinicia serviços, não altera sysctl, não edita SSH e não cria/remove regras de firewall**. Em hosts onde `ssh.socket` ainda não criou `/run/sshd`, o hardening apenas informa que a leitura efetiva do OpenSSH foi adiada; ele não cria o runtime porque isso violaria o contrato audit-only. Veja `docs/HARDENING.md`.


## OpenVPN mTLS opcional por dispositivo

A v0.6.1 mantém o modo padrão compatível de **usuário/senha via PAM**, mas adiciona um segundo modo opcional: **usuário/senha + certificado mTLS individual por dispositivo**. O certificado não substitui a conta OnePlus; ele funciona como um segundo fator criptográfico.

No modo híbrido, cada Android, iPhone, notebook ou outro dispositivo recebe um certificado próprio. O servidor exige `verify-client-cert require`, EKU de cliente e consulta uma CRL local antes de concluir a autenticação PAM.

Pelo menu `oneplus openvpn` é possível:

- emitir um perfil `.ovpn` individual para um usuário/dispositivo;
- listar certificados e seus seriais;
- revogar somente um dispositivo sem trocar a senha do usuário;
- rotacionar um certificado criando primeiro o novo perfil e mantendo o anterior válido por uma janela de 1 a 168 horas;
- gerar e verificar a CRL.

A chave privada do dispositivo é criada em diretório temporário, embutida apenas no perfil `0600` exportado e apagada do servidor em seguida. O servidor conserva somente o certificado público e metadados necessários para revogação.

No modo híbrido, a v0.6.1 também vincula o **serial do certificado à conta OnePlus**. O PAM continua validando a senha, enquanto um segundo verificador `via-file` confirma que o certificado apresentado foi emitido para o mesmo usuário. A senha não é lida por esse verificador. O mapa derivado fica em `/var/lib/oneplus/openvpn-authz`, contém somente `serial -> usuário`, é root-owned e não permite listagem por usuários comuns. Isso impede usar o certificado válido de um cliente como segundo fator junto da senha de outro cliente.

A manutenção da janela de migração de certificados de dispositivo roda por `oneplus-openvpn-pki-maintenance.timer` a cada cinco minutos. Ao fim da janela, o certificado antigo é revogado e a CRL é regenerada.

A v0.6.1 também adiciona uma **rotação coordenada da infraestrutura OpenVPN**, deliberadamente manual:

- pode rotacionar somente o certificado do servidor mantendo a CA;
- pode preparar uma nova CA, novo certificado de servidor e uma chave `tls-crypt-v2`;
- durante a preparação, a CA antiga e a nova coexistem em um bundle e o servidor aceita simultaneamente o `tls-crypt` legado e `tls-crypt-v2`;
- novos perfis de migração usam a próxima CA e uma chave `tls-crypt-v2` individual;
- um perfil da próxima geração pode ser revogado antes do cutover e reemitido sem cancelar toda a rotação;
- o OnePlus mostra quais dispositivos ainda não receberam perfil da nova geração;
- a promoção final exige confirmação explícita e nunca é executada pelo timer;
- antes da promoção é criado um rollback root-only em `/var/lib/oneplus/openvpn-pki-archives`;
- se o novo serviço não subir ou a PKI falhar na validação, a geração anterior é restaurada.

O OnePlus consegue comprovar que um perfil novo foi **emitido**, mas não consegue saber se ele foi realmente importado/testado no dispositivo. Por isso a finalização continua sendo uma decisão do administrador. Perfis antigos deixam de funcionar depois da promoção da nova CA. Veja `docs/OPENVPN-PKI-ROTATION.md`.

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
oneplus update --tag v0.6.1
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
oneplus-history.service
oneplus-history.timer
```

Os timers de manutenção de usuários e de PKI OpenVPN são habilitados automaticamente; o timer de PKI não altera nada enquanto não houver certificados com rotação agendada. O timer de histórico é instalado, mas permanece desabilitado até `oneplus history`. Protocolos, NAT e coleta histórica permanecem sob decisão explícita do administrador.

## Validação antes do GitHub

```bash
bash scripts/validate.sh
sudo bash scripts/test-users.sh
sudo bash scripts/test-openvpn.sh
bash scripts/test-mux.sh
bash scripts/test-operations.sh
python3 scripts/test-history.py
bash scripts/test-hardening.sh
bash scripts/test-integration-contract.sh
bash scripts/test-install-sync.sh
python3 scripts/test-websocket.py
systemd-analyze verify systemd/*.service systemd/*.timer
```

O GitHub Actions usa Ubuntu 24.04 e repete as validações compatíveis.

## Integração Ubuntu 24.04

A v0.8.x adiciona e amadurece uma suíte de integração que instala o OnePlus de verdade em uma VM descartável Ubuntu 24.04, testa upgrade/reinstalação, serviços em `systemd`, listeners de loopback e contratos de segurança. No GitHub ela roda em `ubuntu-24.04`; para reboot real existe um modo de retomada específico para VPS/VM descartável.

A suíte **não deve ser executada em produção**. Fora do GitHub Actions ela exige confirmação explícita:

```bash
sudo env ONEPLUS_INTEGRATION_CONFIRM=DESTROYABLE_VM \
  bash scripts/integration-ubuntu.sh --ci
```

Veja `docs/INTEGRATION-TESTS.md`.
