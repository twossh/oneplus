# Changelog

## 0.2.0 — 2026-08-10
- Adicionada gestão de usuários SSH via terminal.
- Criação de usuários regulares sem armazenamento de senha pelo OnePlus.
- Adicionadas contas de teste com senha aleatória exibida uma única vez.
- Validade por períodos de 24 horas, data exata ou sem expiração.
- Adicionada escolha individual da ação ao expirar: bloquear, remover preservando home ou remover home validado.
- Adicionados bloqueio, desbloqueio e encerramento das sessões do usuário.
- Adicionado limite individual de conexões simultâneas.
- Criado `/etc/security/limits.d/90-oneplus.conf` para integração com `pam_limits` quando disponível.
- Adicionado monitor complementar de processos SSH para corrigir excesso de conexões, inclusive conexões sem TTY.
- Adicionados `oneplus-user-maintenance.service` e `.timer`, com execução a cada 15 segundos.
- Contas regulares expiradas são bloqueadas por padrão; contas de teste expiradas são removidas automaticamente com validações de UID, grupo e home.
- Reutilização de username é recusada quando `/home/<usuario>` já existe, evitando herança acidental de arquivos/UID.
- Metadados de usuários armazenados em `/var/lib/oneplus/users` com permissão `0700` no diretório e `0600` por arquivo.
- A identidade gerenciada exige UID original, UID diferente de zero e associação ao grupo `oneplus-users`.
- Adicionado comando `oneplus users`.
- Instalador passa a incluir `passwd`, `libpam-modules` e `openssl` explicitamente.
- `oneplus --check` passa a validar o subsistema de usuários e seu timer.
- Validador estático ampliado para arquivos e proteções da Fase 2.

## 0.1.2 — 2026-08-10
- Adicionado `setup.sh` para instalação direta a partir de `github.com/twossh/oneplus`.
- Adicionado `scripts/validate.sh` com validação de sintaxe, CRLF, permissões, arquivos obrigatórios, versão e padrões inseguros.
- Adicionado `oneplus --check`, `oneplus --version` e `oneplus --help`.
- BadVPN agora é obtido de um commit upstream fixado e conferido antes da compilação.
- Instalador executa validação da árvore antes de qualquer alteração no sistema.
- Instalador valida as unidades `systemd` antes de concluir.
- Adicionado `.gitignore`, `.gitattributes` e workflow do GitHub Actions.
- README atualizado com o repositório oficial e instalação por um único comando.

## 0.1.1 — 2026-08-10
- Corrigido o launcher `/usr/local/bin/oneplus` quando instalado como link simbólico.
- O comando agora resolve o caminho real de `/opt/oneplus/bin/oneplus` antes de carregar `lib/` e `modules/`.
- Mantida compatibilidade com reinstalação sobre a v0.1.0 sem sobrescrever configurações persistentes em `/etc/oneplus`.

## 0.1.0 — 2026-08-10
- Primeira base do OnePlus.
- Instalador para Ubuntu 24.04+.
- OpenSSH por snippets validados.
- BadVPN UDPGW compilado localmente.
- SlowDNS/dnstt v1.20260501.0.
- Serviços systemd com hardening.
