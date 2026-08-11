# OnePlus hardening audit-only

O módulo de hardening da v0.7.0 é deliberadamente somente leitura sobre a configuração do host.
Ele pode criar um relatório root-only em `/var/log/oneplus/reports`, mas não altera políticas do
sistema operacional.

## Objetivos

- sinalizar configuração OpenSSH inválida ou `PermitRootLogin=yes`;
- inventariar o uso de autenticação por senha sem tratá-lo como erro, pois contas OnePlus podem
  depender desse método;
- verificar `unattended-upgrades`, AppArmor, NTP, unidades systemd falhas e reboot pendente;
- verificar permissões de `/etc/oneplus` e exposição de chaves privadas;
- alertar sobre certificados OnePlus com menos de 30 dias de validade;
- inventariar listeners públicos, UFW/nftables e IPv4 forwarding;
- nunca reiniciar SSH ou bloquear portas automaticamente.

## Por que audit-only?

Um gerenciador acessado exclusivamente por SSH não deve aplicar hardening que possa cortar o único
canal administrativo sem uma confirmação out-of-band. Mudanças futuras, se adicionadas, devem ser
opt-in, mostrar o diff, validar `sshd -t` e ter rollback.

## Referências operacionais

A documentação oficial do Ubuntu recomenda manter o sistema atualizado, permite usar snippets em
`/etc/ssh/sshd_config.d/` e recomenda validar a configuração com `sshd -t` antes de reiniciar o
serviço SSH. O OnePlus preserva esses princípios.

## OpenSSH e socket activation

O modo audit-only não cria `/run/sshd`. Se `sshd -t` retornar apenas que o diretório de privilege separation ainda não existe — situação possível antes da primeira ativação de `ssh.service` em hosts com `ssh.socket` — o relatório marca a verificação efetiva como informativa/adiada em vez de modificar o host. Ações operacionais do módulo SSH podem preparar esse runtime efêmero, mas a auditoria não.
