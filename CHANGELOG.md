# Changelog

## 0.6.1 — 2026-08-10
- Adicionada rotação coordenada e assistida da infraestrutura OpenVPN no modo mTLS híbrido.
- Corrigido o modelo mTLS para vincular criptograficamente a autenticação ao usuário esperado: além do PAM, um hook `auth-user-pass-verify ... via-file` compara o serial do certificado com um mapa root-owned `serial -> usuário`; o helper lê somente a primeira linha do arquivo de credenciais e não processa a senha.
- O instalador reconstrói esse mapa a partir dos metadados de certificados existentes, preservando compatibilidade com perfis mTLS emitidos na v0.6.0.
- A preparação gera uma próxima CA RSA 3072, novo certificado de servidor, banco/CRL independentes e chave de servidor `tls-crypt-v2`.
- Durante a janela de migração, o runtime usa bundle de CA/CRL atual+próxima e aceita `tls-crypt` legado e `tls-crypt-v2` simultaneamente.
- Perfis da próxima geração recebem certificado assinado pela nova CA e chave `tls-crypt-v2` individual, sem persistir a chave privada do dispositivo no servidor.
- Adicionado painel de progresso que compara os dispositivos mTLS ativos com os perfis da próxima geração emitidos.
- Adicionada revogação de perfis da próxima geração antes do cutover, com atualização da próxima CRL, bundle e mapa de identidade.
- A promoção da nova CA é exclusivamente manual; o timer de PKI não pode finalizar a rotação automaticamente.
- Finalização com perfis pendentes exige confirmação reforçada `FINALIZAR-FORCAR`; sem pendências exige `FINALIZAR`.
- Antes da promoção é criado snapshot root-only da geração anterior, com rollback automático se a PKI promovida ou o serviço OpenVPN falhar.
- Adicionada rotação isolada do certificado do servidor mantendo a mesma CA, também com rollback.
- Após a promoção completa, o runtime passa para `tls-crypt-v2`; o `tls-crypt` compartilhado deixa de ser usado.
- Diagnóstico e `oneplus --check` ampliados para validar estado `legacy`, `dual` e `v2`, bundles de migração e permissões de chaves.
- Adicionado `docs/OPENVPN-PKI-ROTATION.md` com procedimento, limitações e checklist de migração.
- Testes OpenVPN ampliados para duas CAs, duas CRLs, perfil `tls-crypt-v2` e controle de dispositivos pendentes.
- Release preparada para ser a primeira publicação oficial assinada; nenhuma chave privada de release é incluída no código ou no ZIP.

## 0.6.0 — 2026-08-10
- Adicionado modo OpenVPN híbrido opcional: conta OnePlus via PAM + certificado mTLS individual por dispositivo.
- O modo padrão continua `password`, preservando compatibilidade com perfis existentes.
- Adicionado banco de CA OpenSSL sobre a CA já existente, sem substituir automaticamente a CA do servidor.
- Certificados de dispositivo usam EKU `clientAuth`; o servidor exige `verify-client-cert require`, `remote-cert-tls client` e CRL no modo híbrido.
- Adicionada emissão de perfil `.ovpn` por usuário/dispositivo; a chave privada cliente é temporária e não fica persistida no servidor.
- Adicionadas listagem e revogação individual de dispositivos por serial X.509.
- Adicionada rotação de certificado de dispositivo com janela de migração configurável de 1 a 168 horas.
- Adicionados `oneplus-openvpn-pki-maintenance.service` e `.timer`; o timer revoga automaticamente o certificado antigo ao fim da janela.
- CRL é regenerada de forma atômica e fica legível pelo daemon após redução de privilégios; novas conexões passam a respeitar revogações sem reinício global do OpenVPN.
- Diagnóstico, instalador, desinstalador, validação estática e GitHub Actions atualizados para a nova PKI.
- Teste OpenVPN ampliado para criar CA temporária, assinar um certificado clientAuth, revogá-lo e confirmar a rejeição via CRL.
- A rotação automática da CA raiz, certificado de servidor e `tls-crypt` continua deliberadamente fora desta versão.

## 0.5.2 — 2026-08-10
- Adicionada consulta da release estável mais recente pela API REST oficial do GitHub, sem atualização automática silenciosa.
- Adicionado `libexec/github_release.py` para validar JSON de release antes de qualquer URL de asset ser usada.
- Canal estável agora recusa explicitamente releases `draft` e `prerelease` e exige tag semântica `vX.Y.Z`.
- Os três assets obrigatórios são validados por nome, estado `uploaded`, tamanho máximo e URL exata em `github.com/twossh/oneplus/releases/download/...`.
- O digest SHA-256 publicado pelo GitHub, quando disponível, passa a ser verificado como camada adicional; Minisign + SHA-256 continuam sendo a raiz de confiança da release.
- Adicionados `oneplus update --check`, `oneplus update --latest` e `oneplus update --tag vX.Y.Z`.
- O menu de atualização ganhou verificação de release, atualização para a versão estável mais recente e atualização por tag específica.
- Notas da GitHub Release são sanitizadas antes de serem exibidas no terminal e limitadas em tamanho.
- Metadados JSON e assets têm limites de tamanho e timeouts de download.
- Adicionado `scripts/test-update-metadata.py` com testes de draft, prerelease, asset ausente/duplicado, URL externa, digest inválido e tamanho excessivo.
- GitHub Actions, validação estática, instalador e preparação de release passam a testar o novo parser de metadados.

## 0.5.1 — 2026-08-10
- Canal estável migrado de clone de tag para assets de GitHub Release assinados.
- Adicionada dupla verificação: checksum externo do `tar.gz` assinado por Minisign + manifesto interno `release/SHA256SUMS` também assinado.
- Adicionado `libexec/release_verify.py`, que recusa path traversal, symlink, hardlink, devices, FIFO, entradas fora do diretório esperado e bits setuid/setgid antes da extração.
- Pacotes de atualização passam a ser extraídos manualmente em diretório temporário somente após a assinatura externa e SHA-256 serem validados.
- Adicionado `scripts/release-keygen.sh` para gerar a chave Minisign fora do repositório com `umask 077` e bloqueio explícito de chave privada dentro do projeto.
- Adicionado `scripts/git-fix-modes.sh` para registrar `100755` no índice Git mesmo em fluxos Windows/GitHub Web; o preparador recusa tag com modos executáveis incorretos.
- Adicionado `scripts/release-prepare.sh` para validar a fonte, criar/assinar manifesto interno, gerar tar.gz reprodutível, assinar checksum externo e verificar o resultado antes da publicação.
- `scripts/release-sign.sh` mantido como compatibilidade, encaminhando para o novo fluxo completo.
- Rollback de atualização passa a registrar e restaurar o estado habilitado/ativo das unidades OnePlus.
- Adicionada retenção automática de rollbacks de atualização, com padrão de três snapshots após sucesso.
- Chave pública importada pelo menu passa a mostrar SHA-256 para conferência por canal independente.
- Adicionado `scripts/test-release.py` com casos válidos e maliciosos de arquivo TAR.
- Validação estática ampliada para recusar symlinks e bits setuid/setgid na árvore do projeto.
- Adicionado `docs/RELEASES.md` com a cerimônia de chave, preparação, tag e publicação dos assets.

## 0.5.0 — 2026-08-10
- Iniciada/concluída a camada principal da Fase 4 de operação e segurança do host.
- Adicionado backup obrigatório criptografado com `age`, checksum externo e manifesto SHA-256 interno.
- Backup captura apenas contas gerenciadas pelo OnePlus em vez de copiar `/etc/shadow` integralmente.
- Restauração valida caminhos e tipos TAR, recusa links/arquivos especiais e não altera contas externas preexistentes; cria rollback root-only antes de alterar o host.
- Adicionada auditoria de listeners, UFW e tabelas nftables sem alteração de regras externas.
- Adicionado serviço `oneplus-firewall.service` com tabelas exclusivas `inet oneplus_filter` e `ip oneplus_nat`.
- NAT/masquerade OpenVPN agora é opcional e restrito à rede VPN + interface de saída escolhida.
- O OnePlus nunca executa `nft flush ruleset`; ao desabilitar NAT, remove somente suas próprias tabelas.
- Forwarding IPv4 usa arquivo sysctl próprio; a desativação não força `ip_forward=0` em runtime.
- Full tunnel OpenVPN (`redirect-gateway def1`) tornou-se opcional e controlado pelo módulo de firewall; DNS não é imposto por padrão.
- Adicionados relatórios de usuários, sessões, OpenVPN, interfaces, listeners, nftables e logins recentes.
- Adicionado diagnóstico/reparo seguro de arquivos, permissões, integridade e units OnePlus.
- Adicionado atualizador estável fail-closed com `minisign` + manifesto SHA-256 + bloqueio de downgrade + rollback local.
- Adicionado `scripts/release-sign.sh`; a chave privada de release permanece obrigatoriamente fora do repositório/VPS.
- Instalador passa a instalar `nftables`, `age` e `minisign` do Ubuntu.
- Adicionados `oneplus firewall`, `oneplus backup`, `oneplus reports`, `oneplus diagnostics` e `oneplus update`.
- Adicionado `scripts/test-operations.sh` e novas validações no GitHub Actions.

## 0.4.0 — 2026-08-10
- Concluída a Fase 3 com OpenVPN opcional e multiplexação TCP via sslh.
- OpenVPN usa o pacote oficial do Ubuntu, sem binário externo ou compilação paralela.
- Adicionada CA interna e certificado do servidor gerados localmente com RSA 3072; a chave privada da CA nunca é exportada.
- Adicionado `tls-crypt`, TLS mínimo 1.2, AEAD moderno e compressão desabilitada.
- Autenticação OpenVPN integrada ao PAM e restrita ao grupo `oneplus-users`; senhas continuam fora do armazenamento OnePlus.
- Substituída a opção antiga `client-cert-not-required` pela política atual `verify-client-cert none` + `username-as-common-name`.
- Adicionada exportação de perfil `.ovpn` com CA pública e `tls-crypt`, protegido com modo 0600.
- Interface de gerenciamento OpenVPN usa somente Unix socket root-only, nunca uma porta TCP.
- Bloqueio, expiração e remoção de usuário agora tentam encerrar também sua sessão OpenVPN.
- OpenVPN não cria NAT, `redirect-gateway`, masquerade ou regras de firewall automaticamente nesta fase.
- Adicionado multiplexador `sslh-select` em `oneplus-mux.service`.
- Multiplexador reconhece SSH, TLS, OpenVPN TCP e HTTP/WebSocket em uma porta TCP compartilhada.
- Todos os backends do multiplexador são obrigatoriamente loopback.
- Modo transparente do sslh é proibido para evitar dependência de hacks/regras automáticas de firewall.
- Multiplexador roda como usuário dedicado `oneplus-mux` com somente `CAP_NET_BIND_SERVICE`.
- Configuração do multiplexador exige pelo menos dois protocolos e possui detecção de conflito/rollback.
- Timeout padrão do multiplexador ajustado para 5 segundos para melhorar detecção de OpenVPN TCP.
- Documentado explicitamente o trade-off do modo OpenVPN usuário/senha sem certificado cliente individual.
- `oneplus --check` agora confirma também a regra PAM que nega login de root no OpenVPN.
- Adicionados comandos `oneplus openvpn` e `oneplus mux`.
- `oneplus --check`, instalador, desinstalador e menu atualizados para OpenVPN/sslh.
- Adicionados testes `test-openvpn.sh`, `test-mux.sh` e validações estáticas específicas.
- GitHub Actions ampliado para testar os novos módulos e unidades systemd.

## 0.3.0 — 2026-08-10
- Adicionada Fase 3 de conectividade, mantendo administração exclusivamente pelo terminal.
- Adicionado Dropbear via `dropbear-bin` do Ubuntu, executado por unidade `oneplus-dropbear.service` própria.
- Dropbear usa chave host Ed25519 exclusiva em `/etc/oneplus/dropbear` e bloqueia login de root com `-w`.
- Encaminhamento remoto `-R` fica desabilitado por padrão e exige confirmação explícita para ser liberado.
- Adicionado proxy WebSocket em Python 3 sem dependências externas, com modos RFC6455, legacy e auto.
- WebSocket usa upstream fixo e ignora `X-Real-Host`, evitando comportamento de open proxy da base antiga.
- Adicionadas validações RFC6455 de versão/chave antes de conectar ao upstream e limites de clientes, cabeçalhos e frames.
- WebSocket roda como `oneplus-ws` e recebe somente `CAP_NET_BIND_SERVICE` para portas privilegiadas.
- Adicionado TLS via `stunnel4`, com TLS mínimo restrito a 1.2 ou 1.3.
- TLS suporta importação de certificado/chave e valida correspondência criptográfica antes de instalar.
- Adicionada geração de certificado autoassinado somente para teste/pinning explícito.
- TLS roda como `oneplus-tls`, com chave privada restrita e `CAP_NET_BIND_SERVICE`.
- Configuração de Dropbear, WebSocket e TLS possui verificação de conflito de porta e rollback quando o serviço não inicia.
- Monitor de conexões de usuários passou a reconhecer processos Dropbear além do OpenSSH.
- Instalador habilita Universe de forma controlada quando necessário e instala `dropbear-bin`, `stunnel4` e Python 3.
- `oneplus --check` e o menu principal passaram a diagnosticar os três novos serviços.
- Adicionado teste de integração do proxy WebSocket e validações estáticas específicas da Fase 3.
- Bootstrap corrige também permissões de scripts Python enviados pelo upload web do GitHub.
- BadVPN e dnstt agora registram SHA-256 do binário instalado e `oneplus --check` verifica integridade local.
- Recompilações de BadVPN/dnstt preservam o binário anterior até o novo build ser concluído e fazem rollback se um serviço ativo não reiniciar.
- BadVPN ganhou validação de bind, porta sem privilégios, limites de clientes/conexões e rollback de configuração.
- SlowDNS ganhou validação completa no wrapper, bind específico de interface como sugestão, detecção de conflito UDP e rollback sem alterar `systemd-resolved`.
- A chave privada SlowDNS foi restrita ao caminho protegido gerenciado pelo OnePlus.

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
