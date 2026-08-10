# Releases assinadas do OnePlus

A partir da v0.5.1, o canal de atualização estável usa **GitHub Releases** com duas camadas de verificação:

1. `OnePlus-vX.Y.Z.tar.gz.sha256` é assinado com Minisign;
2. depois da verificação do pacote, a árvore extraída contém `release/SHA256SUMS` também assinado com Minisign.

A instalação só começa depois das duas assinaturas, dos checksums e da validação estática passarem.

## 1. Gerar a chave uma única vez

Faça isso em um computador administrativo confiável, fora do repositório e fora de uma VPS de produção:

```bash
sudo apt install minisign
bash scripts/release-keygen.sh "$HOME/.config/oneplus-release"
```

Serão criados:

```text
~/.config/oneplus-release/oneplus-release.key   # PRIVADA / offline
~/.config/oneplus-release/oneplus-release.pub   # pública
```

A chave privada deve permanecer fora do GitHub, backups públicos e VPS de produção.

## 2. Distribuir a chave pública

Copie somente `oneplus-release.pub` para a VPS por um canal confiável e, no OnePlus:

```bash
oneplus update
```

Escolha **Instalar/alterar chave pública confiável** e compare o SHA-256 mostrado pelo OnePlus com o SHA-256 obtido na estação administrativa.

## 3. Preparar uma release

Atualize `VERSION` e `CHANGELOG.md`. Antes do commit/tag, normalize também os bits executáveis no índice Git (isso funciona inclusive quando o projeto veio de Windows/GitHub Web):

```bash
bash scripts/git-fix-modes.sh
git add -u
git commit -m "Prepare vX.Y.Z"
```

Depois execute:

```bash
bash scripts/release-prepare.sh \
  "$HOME/.config/oneplus-release/oneplus-release.key" \
  "$HOME/.config/oneplus-release/oneplus-release.pub"
```

O processo executa validações e gera:

```text
release/SHA256SUMS
release/SHA256SUMS.minisig

dist/OnePlus-vX.Y.Z.tar.gz
dist/OnePlus-vX.Y.Z.tar.gz.sha256
dist/OnePlus-vX.Y.Z.tar.gz.sha256.minisig
```

Os dois arquivos em `release/` devem ser commitados. Os três arquivos em `dist/` são assets da GitHub Release e permanecem fora do Git.

## 4. Commit, tag e GitHub Release

Exemplo para a v0.6.1:

```bash
git add release/SHA256SUMS release/SHA256SUMS.minisig
git commit -m "Release v0.6.1"
git tag v0.6.1
git push origin main --tags
```

No GitHub, crie uma Release para a **mesma tag** e anexe exatamente:

```text
OnePlus-v0.6.1.tar.gz
OnePlus-v0.6.1.tar.gz.sha256
OnePlus-v0.6.1.tar.gz.sha256.minisig
```


### Consultar a release antes de instalar

Desde a v0.5.2, o administrador não precisa digitar uma tag apenas para descobrir a versão disponível:

```bash
oneplus update --check
```

O OnePlus consulta `releases/latest` da API oficial do GitHub. A resposta só é aceita quando representa uma release publicada, não-draft, não-prerelease, com tag `vX.Y.Z` e com os três assets OnePlus esperados. Nenhuma atualização é iniciada por esse comando.

Para instalar a release estável mais recente depois que a chave pública já foi conferida:

```bash
oneplus update --latest
```

Ou uma tag específica:

```bash
oneplus update --tag v0.6.1
```

Em ambos os casos, Minisign, SHA-256, inspeção segura do TAR, manifesto interno, validação estática e confirmação manual continuam obrigatórios.

## 5. Atualização na VPS

Na VPS que já confia na chave pública:

```bash
oneplus update
```

O fluxo estável é:

```text
GitHub Release
   ↓ HTTPS
checksum Minisign
   ↓
SHA-256 do tar.gz
   ↓
inspeção do TAR (sem symlink/hardlink/device/traversal)
   ↓
extração em diretório temporário
   ↓
manifesto interno Minisign
   ↓
SHA-256 de toda a árvore
   ↓
scripts/validate.sh
   ↓
rollback local
   ↓
install.sh
   ↓
oneplus --check
```

Se a instalação falhar, o OnePlus tenta restaurar arquivos e estados anteriores das unidades `systemd`. Após atualizações bem-sucedidas, os rollbacks antigos são reduzidos à retenção configurada (padrão: 3).

## Limite de confiança do primeiro bootstrap

O primeiro `setup.sh` baixado de `raw.githubusercontent.com` ainda depende de HTTPS/GitHub. A cadeia Minisign passa a proteger os **upgrades estáveis** depois que a chave pública é instalada e conferida por um canal independente.
