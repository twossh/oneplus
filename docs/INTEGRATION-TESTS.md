# OnePlus — testes de integração Ubuntu 24.04

A suíte desta pasta é **destrutiva para o ambiente de teste** no sentido operacional: instala pacotes, cria configurações em `/etc/oneplus`, grava em `/opt/oneplus`, compila BadVPN/dnstt e habilita serviços em portas altas de loopback.

Ela existe para VM/VPS descartável. **Não execute na VPS de produção.**

## GitHub Actions

`.github/workflows/integration-ubuntu.yml` roda em `ubuntu-24.04`, que é uma VM efêmera hospedada pelo GitHub. O fluxo:

1. valida a árvore;
2. procura uma versão anterior no histórico Git;
3. quando encontra, instala a versão anterior e atualiza para a atual;
4. caso contrário, faz instalação limpa;
5. repete a instalação atual para testar idempotência;
6. verifica preservação de `/etc/oneplus`;
7. executa `oneplus --check` e `sshd -t`;
8. inicia e testa Dropbear, WebSocket, TLS/Stunnel, BadVPN, SlowDNS e sslh em loopback/portas altas;
9. testa OpenVPN quando `/dev/net/tun` estiver disponível;
10. grava um snapshot real do histórico;
11. valida timers persistentes;
12. publica o relatório como artifact do workflow.

O workflow roda em push/PR que alterem código operacional, semanalmente e sob `workflow_dispatch`.

## Portas do ambiente de integração

Somente na VM de teste:

- 18022/TCP — servidor HTTP auxiliar local;
- 22442/TCP — Dropbear;
- 18080/TCP — WebSocket;
- 18443/TCP — TLS/Stunnel;
- 17300/TCP — BadVPN UDPGW;
- 15353/UDP — dnstt;
- 11194/TCP — OpenVPN, quando TUN existir;
- 19443/TCP — sslh.

Os listeners do OnePlus usados pelo teste são configurados em `127.0.0.1`, sem exposição externa.

## Teste manual em VPS descartável

No clone da versão a testar:

```bash
sudo env ONEPLUS_INTEGRATION_CONFIRM=DESTROYABLE_VM \
  bash scripts/integration-ubuntu.sh --ci
```

Se já houver `/opt/oneplus` na VM descartável e a intenção for testar por cima dela, é necessário também:

```bash
ONEPLUS_INTEGRATION_ALLOW_EXISTING=yes
```

Isso existe para impedir execução acidental em servidor real.

## Reboot real

GitHub-hosted runners são descartados ao fim do job e não permitem continuar o mesmo job depois de reiniciar a máquina. Para testar persistência **após reboot real**, use uma VPS/VM descartável após a suíte `--ci`:

```bash
sudo env ONEPLUS_INTEGRATION_CONFIRM=DESTROYABLE_VM \
  bash /opt/oneplus/scripts/integration-ubuntu.sh --arm-reboot

sudo reboot
```

O `--arm-reboot` instala temporariamente `oneplus-integration-resume.service`. Após o novo boot ele:

- exige mudança real do `boot_id`;
- executa `oneplus --check`;
- verifica cada unidade que estava habilitada antes do reboot;
- confirma que a configuração persistente continua presente;
- salva o resultado em `/var/lib/oneplus/integration/post-reboot.result`;
- remove a unidade temporária de retomada quando o teste passa.

Depois:

```bash
sudo cat /var/lib/oneplus/integration/post-reboot.result
sudo find /var/log/oneplus/integration -type f -maxdepth 1 -print
```

## O que esta suíte não afirma

Mesmo com CI verde, ainda são testes separados:

- cliente OpenVPN real em Android/iOS/Windows;
- DNS delegado público para SlowDNS;
- certificado TLS de CA pública/ACME;
- firewall de provedor de nuvem;
- rede móvel/CGNAT;
- carga de milhares de conexões;
- migração mTLS de dispositivos físicos.

CI reduz regressões; não substitui homologação em uma VPS descartável com clientes reais.
