# Rotação da infraestrutura OpenVPN — OnePlus v0.6.1

Esta função é destinada a servidores OpenVPN do OnePlus já configurados em modo `hybrid` (usuário/senha + certificado mTLS por dispositivo). A promoção de uma nova CA é uma operação de impacto e **não é automática**.

## Objetivo

A rotação completa migra, de forma assistida:

1. CA raiz OpenVPN;
2. certificado/chave do servidor;
3. banco da CA e CRL;
4. canal de controle compartilhado `tls-crypt` para `tls-crypt-v2` por perfil.

O OnePlus primeiro prepara a próxima geração sem substituir a atual. Durante essa fase, o servidor mantém a CA atual e a próxima em um bundle de confiança e aceita o canal de controle legado e o novo. A promoção final só acontece por comando explícito do administrador.

## Pré-requisitos

- OpenVPN configurado pelo OnePlus em `OPENVPN_AUTH_MODE=hybrid`;
- PKI atual válida;
- CRL atual válida;
- backup `age` recente do OnePlus;
- acesso SSH administrativo independente da VPN;
- espaço para um snapshot local em `/var/lib/oneplus/openvpn-pki-archives`.

Não inicie uma rotação completa sem um acesso administrativo alternativo ao servidor.

## Fase 1 — Preparar

Abra:

```bash
oneplus openvpn
```

Escolha **Rotação da infraestrutura PKI / tls-crypt** e depois **Preparar nova CA + servidor + tls-crypt-v2**.

O OnePlus gera em área separada:

- próxima CA RSA 3072;
- próximo certificado de servidor RSA 3072;
- próximo banco OpenSSL e CRL;
- chave de servidor `tls-crypt-v2`;
- bundles temporários contendo as duas CAs e as duas CRLs.

O arquivo `/etc/oneplus/openvpn.env` muda de `OPENVPN_TLS_CRYPT_MODE=legacy` para `dual` somente depois da validação da próxima geração. Se o OpenVPN estiver ativo, o serviço é reiniciado e a preparação é revertida se não voltar a ficar ativo.

## Fase 2 — Emitir perfis de migração

Para cada dispositivo mTLS ativo, emita um perfil da próxima geração pelo mesmo menu.

Cada novo perfil contém:

- CA atual + próxima CA no bloco `<ca>`;
- certificado do dispositivo assinado pela próxima CA;
- chave privada do dispositivo somente dentro do `.ovpn` exportado;
- uma chave `tls-crypt-v2` individual.

O servidor conserva apenas o certificado público e metadados de revogação. A chave privada do dispositivo é criada em diretório temporário e apagada após a exportação. O serial do certificado também entra no mapa root-owned de autorização `serial -> usuário`, usado como uma segunda verificação além do PAM.

Se um perfil da próxima geração for emitido para o dispositivo errado, for perdido ou precisar ser descartado antes do cutover, use **Revogar perfil da próxima geração**. O OnePlus atualiza a próxima CRL, os bundles e remove o serial do mapa de identidade; depois um novo perfil pode ser emitido para o mesmo usuário/dispositivo.

**Importante:** o painel marca o perfil como emitido, não como testado. Importe e teste manualmente o novo `.ovpn` no dispositivo antes do cutover.

## Fase 3 — Conferir progresso

Use **Listar progresso de migração**. O OnePlus compara os certificados atuais ativos por `usuário/dispositivo` com os perfis emitidos pela próxima CA.

`PENDENTE` significa que ainda não existe um perfil novo emitido para aquele par. Um perfil marcado como emitido ainda precisa ser testado pelo administrador.

## Fase 4 — Finalizar

Quando todos os dispositivos necessários estiverem testados, escolha **Finalizar/promover nova infraestrutura**.

Sem pendências, o OnePlus exige:

```text
FINALIZAR
```

Com pendências, exige explicitamente:

```text
FINALIZAR-FORCAR
```

Antes de alterar a PKI ativa é criado:

```text
/var/lib/oneplus/openvpn-pki-archives/<ROTATION_ID>/pre-finalize.tar.gz
```

A promoção substitui a CA, servidor, banco/CRL e metadados pela próxima geração e muda o canal de controle para `OPENVPN_TLS_CRYPT_MODE=v2`. O antigo `tls-crypt.key` deixa de ser usado.

Se a PKI promovida falhar na validação ou o OpenVPN não voltar a iniciar, o snapshot anterior é restaurado automaticamente.

## Cancelar antes da promoção

Enquanto o estado for `prepared`, a preparação pode ser cancelada. O OnePlus primeiro retorna o runtime para `legacy`, valida/reinicia o serviço quando necessário e só depois remove a área da próxima geração.

Perfis da próxima geração já exportados deixam de funcionar após o cancelamento.

## Rotacionar somente o certificado do servidor

Há uma operação separada para trocar apenas a chave/certificado do servidor mantendo a CA. Ela não exige reemitir os clientes porque a âncora de confiança não muda. O certificado anterior é arquivado e restaurado automaticamente se o novo não for aceito.

## Limitações deliberadas

- a promoção da CA nunca é feita pelo timer;
- o OnePlus não consegue confirmar que um perfil foi realmente instalado no dispositivo;
- após o cutover da CA, perfis antigos não migrados deixam de conectar;
- v0.6.1 implementa a migração inicial do `tls-crypt` compartilhado para `tls-crypt-v2`; uma futura rotação do próprio segredo de servidor `tls-crypt-v2` já estabelecido requer outra estratégia de migração e não é executada silenciosamente;
- a validação em VPS Ubuntu 24.04 real, com clientes reais e combinações de firewall/NAT, continua obrigatória antes de uso em produção.

## Checklist recomendado

```text
[ ] backup age criado e validado
[ ] acesso SSH administrativo fora da VPN confirmado
[ ] próxima infraestrutura preparada
[ ] novo perfil emitido para cada dispositivo necessário
[ ] cada novo perfil importado e testado
[ ] lista de pendências revisada
[ ] promoção executada
[ ] OpenVPN ativo após promoção
[ ] cliente Android/Windows/Linux/iOS validado após promoção
[ ] backup age pós-rotação criado
```
