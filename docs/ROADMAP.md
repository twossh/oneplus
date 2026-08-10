# Roadmap OnePlus

## Fase 1 — Núcleo e protocolos básicos
- [x] instalador Ubuntu 24.04+
- [x] CLI principal
- [x] OpenSSH seguro
- [x] BadVPN UDPGW
- [x] SlowDNS / dnstt
- [x] systemd e journald

## Fase 2 — Usuários SSH
- [x] criar usuário
- [x] remover usuário
- [x] alterar senha sem armazená-la
- [x] expiração por data/dias
- [x] usuário teste/temporário
- [x] limite simultâneo de conexões
- [x] monitor de conexões
- [x] tratamento automático seguro de expirados via systemd timer
- [x] remoção automática de contas temporárias expiradas
- [x] isolamento por UID original + grupo OnePlus

## Fase 2.1 — Validação real
- [ ] testar instalação limpa em Ubuntu 24.04 LTS
- [ ] testar reinstalação sobre v0.1.2
- [ ] validar limites com shell interativo, SFTP e túnel `ssh -N`
- [ ] validar expiração de conta teste em ambiente real
- [ ] validar atualização após reboot

## Fase 3 — Conectividade
- [ ] Dropbear moderno, somente se necessário
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
