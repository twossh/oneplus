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
- [x] limite simultâneo de conexões SSH
- [x] monitor OpenSSH + Dropbear
- [x] expiração automática segura via systemd timer
- [x] isolamento por UID original + grupo OnePlus

## Fase 2.1 — Validação real
- [ ] instalação limpa Ubuntu 24.04 LTS
- [ ] upgrade sobre release anterior
- [ ] shell interativo, SFTP e `ssh -N`
- [ ] limite combinado OpenSSH + Dropbear
- [ ] expiração de conta teste
- [ ] reboot

## Fase 3 — Conectividade
- [x] Dropbear oficial Ubuntu e serviço próprio
- [x] TLS/Stunnel opcional com TLS 1.2+
- [x] proxy WebSocket Python 3 com upstream fixo
- [x] OpenVPN opcional usando pacote Ubuntu
- [x] OpenVPN autenticado por PAM somente para `oneplus-users`
- [x] PKI de servidor local + `tls-crypt`
- [x] exportação de perfil `.ovpn`
- [x] interface de gerenciamento OpenVPN via Unix socket root-only
- [x] multiplexação de portas TCP via sslh sem modo transparente
- [x] backends do multiplexador restritos a loopback
- [x] rollback por conflito/falha de serviço
- [x] testes estáticos/integração dos módulos

## Fase 3.1 — Validação real
- [ ] login real via Dropbear com senha e chave
- [ ] encaminhamento local e bloqueio de `-R`
- [ ] WebSocket RFC6455 com cliente real
- [ ] TLS/Stunnel com certificado público e autoassinado/pin
- [ ] autenticação OpenVPN com usuário OnePlus real
- [ ] validar usuário bloqueado/expirado sendo recusado pelo PAM
- [ ] validar desconexão OpenVPN no bloqueio/expiração
- [ ] testar perfil `.ovpn` em Linux/Windows/Android/iOS
- [ ] OpenVPN TCP atrás do sslh em porta 443
- [ ] combinar SSH + TLS + OpenVPN + HTTP/WS no sslh
- [ ] validar concorrência/consumo de recursos
- [ ] validar reboot com combinações de serviços

## Fase 4 — Operação e segurança do host
- [ ] backup/restauração seguro e versionado
- [ ] atualização assinada/versionada do OnePlus
- [ ] auditoria de portas
- [ ] firewall/nftables em tabela própria, sem limpar regras existentes
- [ ] NAT/masquerade OpenVPN opcional com rollback
- [ ] relatórios de tráfego/sessões
- [ ] diagnóstico e reparo
- [ ] rotação/backup controlado de PKI e chaves
