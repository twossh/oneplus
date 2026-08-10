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
- [ ] testar reinstalação/upgrade sobre v0.2.0
- [ ] validar limites com shell interativo, SFTP e túnel `ssh -N`
- [ ] validar limite combinado OpenSSH + Dropbear
- [ ] validar expiração de conta teste em ambiente real
- [ ] validar atualização após reboot

## Fase 3 — Conectividade
- [x] Dropbear usando pacote oficial Ubuntu e serviço próprio
- [x] TLS/Stunnel opcional com TLS 1.2+
- [x] proxy WebSocket Python 3 com upstream fixo
- [x] rollback por conflito/falha de serviço nos novos módulos
- [x] teste de integração RFC6455/legacy do WebSocket
- [ ] OpenVPN opcional
- [ ] multiplexação de portas sem hacks destrutivos

## Fase 3.1 — Validação real
- [ ] testar login real via Dropbear
- [ ] testar senha e chave pública via Dropbear
- [ ] testar encaminhamento local e bloqueio de `-R`
- [ ] testar WebSocket RFC6455 com cliente real
- [ ] testar modo legacy somente onde houver necessidade
- [ ] testar TLS/Stunnel com certificado público
- [ ] testar TLS autoassinado com pin explícito
- [ ] validar concorrência e consumo de recursos
- [ ] validar reboot com cada combinação de serviços habilitados

## Fase 4 — Operação
- [ ] backup/restauração seguro
- [ ] atualização assinada/versionada do OnePlus
- [ ] auditoria de portas e firewall sem limpeza global de regras
- [ ] relatórios de tráfego/sessões
- [ ] diagnóstico e reparo
