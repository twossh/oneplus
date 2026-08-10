# Changelog

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
