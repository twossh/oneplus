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
- [ ] rotação assistida de PKI/chaves com janela de migração

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
- [ ] publicar a primeira release assinada e validar v0.5.1 -> próxima versão

## Próximas fases
- [ ] OpenVPN mTLS opcional por dispositivo
- [ ] rotação assistida de certificados/chaves
- [ ] snapshots históricos de tráfego sem banco pesado
- [ ] política opcional de hardening do host com modo audit-only por padrão
- [ ] testes de integração reais automatizados em VM Ubuntu 24.04
