# Roadmap OnePlus

## Fase 1 — Núcleo e protocolos básicos
- [x] instalador Ubuntu 24.04+
- [x] CLI principal
- [x] OpenSSH seguro
- [x] BadVPN UDPGW
- [x] SlowDNS / dnstt
- [x] systemd e journald

## Fase 2 — Usuários SSH
- [x] criar/remover/editar usuário
- [x] senha sem armazenamento em texto puro
- [x] expiração por data/dias
- [x] usuário teste/temporário
- [x] limite simultâneo de conexões
- [x] monitor OpenSSH + Dropbear
- [x] expiração automática via systemd timer
- [x] isolamento por UID original + grupo OnePlus

## Fase 3 — Conectividade
- [x] Dropbear oficial Ubuntu
- [x] TLS/Stunnel TLS 1.2+
- [x] WebSocket Python 3 com upstream fixo
- [x] OpenVPN oficial Ubuntu + PAM oneplus-users
- [x] PKI de servidor local + tls-crypt
- [x] perfil .ovpn
- [x] gerenciamento OpenVPN via Unix socket root-only
- [x] multiplexação TCP via sslh sem modo transparente
- [x] rollback de configuração

## Fase 4 — Operação e segurança do host
- [x] backup/restauração criptografado e versionado
- [x] atualização versionada com verificação minisign + SHA-256
- [x] canal estável via GitHub Release com pacote + manifesto interno assinados
- [x] consulta da release estável pela API GitHub com validação de metadados/assets
- [x] CLI `update --check/--latest/--tag` sem atualização silenciosa
- [x] extração segura de release sem symlink/hardlink/path traversal
- [x] geração offline assistida de chave e preparação de release
- [x] bloqueio de downgrade e rollback local de atualização
- [x] auditoria de portas/firewall
- [x] nftables em tabelas próprias sem limpeza global
- [x] NAT/masquerade OpenVPN opcional
- [x] full tunnel OpenVPN opcional
- [x] relatórios de tráfego/sessões
- [x] diagnóstico e reparo
- [x] backup controlado da PKI/chaves via arquivo age
- [x] mTLS híbrido opcional por dispositivo com CRL e revogação individual
- [x] rotação assistida de certificado de dispositivo com janela de migração
- [x] rotação coordenada da CA raiz, certificado do servidor e migração `tls-crypt` -> `tls-crypt-v2` com fase dual e rollback

## Validação real pendente
- [ ] instalação limpa em Ubuntu 24.04 LTS
- [ ] upgrade v0.5.0 -> v0.5.1
- [ ] reboot com combinações de serviços
- [ ] OpenSSH/Dropbear: shell, SFTP e túnel
- [ ] WebSocket RFC6455 com cliente real
- [ ] TLS/Stunnel com certificado público
- [ ] OpenVPN Android/iOS/Windows/Linux
- [ ] OpenVPN TCP atrás do sslh
- [ ] NAT OpenVPN + full tunnel em VPS real
- [ ] convivência com UFW/firewall do provedor
- [ ] criar backup age em uma VPS e restaurar em VPS limpa
- [ ] configurar chave minisign offline e validar upgrade por GitHub Release assinada
- [ ] publicar a primeira release assinada (candidata v0.7.0) e validar upgrade por GitHub Release
- [ ] validar `oneplus update --check` contra a primeira release assinada publicada
- [ ] validar `oneplus update --latest` com rollback em uma VPS de teste
- [ ] validar rotação completa OpenVPN atual -> próxima CA com clientes Android/Windows durante a fase dual
- [ ] validar rollback automático da promoção da PKI em VPS descartável
- [ ] validar histórico por 24h em VPS real e conferir deltas de tráfego após reboot
- [ ] executar hardening audit-only em VPS de produção e revisar falsos positivos

## Próximas fases
- [ ] validar em VPS real a fase dual de CA + `tls-crypt`/`tls-crypt-v2` e o cutover sem perda inesperada de clientes migrados
- [x] snapshots históricos de tráfego/sessões sem banco pesado, opt-in e sem dados sensíveis desnecessários
- [x] política de hardening do host em modo audit-only por padrão
- [ ] testes de integração reais automatizados em VM Ubuntu 24.04
- [ ] baseline opcional de segurança por perfil, sempre com diff/rollback antes de qualquer aplicação
