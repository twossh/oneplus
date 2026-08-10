# OnePlus signed releases

A partir da v0.5.1, o canal estável usa assets de GitHub Release:

- `OnePlus-vX.Y.Z.tar.gz`
- `OnePlus-vX.Y.Z.tar.gz.sha256`
- `OnePlus-vX.Y.Z.tar.gz.sha256.minisig`

A árvore do pacote também contém `release/SHA256SUMS` e `release/SHA256SUMS.minisig`.

A chave privada Minisign nunca deve entrar neste repositório nem em uma VPS de produção. Use `scripts/release-keygen.sh` para gerá-la fora do projeto e `scripts/release-prepare.sh` para montar/verificar os artefatos antes da publicação.

Veja `docs/RELEASES.md`.
