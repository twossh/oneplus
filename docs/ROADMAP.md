# Roadmap OnePlus

## Fase 1 — Núcleo e protocolos básicos
- [x] instalador Ubuntu 24.04+
- [x] CLI principal
- [x] OpenSSH seguro
- [x] BadVPN UDPGW
- [x] SlowDNS / dnstt
- [x] systemd e journald

## Fase 2 — Usuários SSH
- [ ] criar usuário
- [ ] remover usuário
- [ ] alterar senha sem armazená-la
- [ ] expiração por data
- [ ] usuário teste/temporário
- [ ] limite simultâneo de conexões
- [ ] monitor de sessões
- [ ] remoção segura de expirados via systemd timer

## Fase 3 — Conectividade
- [ ] Dropbear moderno, se ainda necessário
- [ ] TLS/Stunnel opcional
- [ ] proxy WebSocket moderno
- [ ] OpenVPN opcional
- [ ] multiplexação de portas sem hacks destrutivos

## Fase 4 — Operação
- [ ] backup/restauração seguro
- [ ] atualização assinada/versionada do OnePlus
- [ ] auditoria de portas e firewall sem limpeza global de regras
- [ ] relatórios de tráfego/sessões
- [ ] diagnóstico e reparo
