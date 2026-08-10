# OnePlus signed releases

A partir da v0.5.0, o atualizador estável aceita apenas tags com `release/SHA256SUMS` e `release/SHA256SUMS.minisig` válidos para a chave pública confiável instalada em `/etc/oneplus/update.pub`.

A chave privada de assinatura nunca deve entrar neste repositório ou em uma VPS de produção. Gere e mantenha a chave em uma estação administrativa separada e protegida.
