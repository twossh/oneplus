#!/usr/bin/env bash
set -Eeuo pipefail

ONEPLUS_BACKUP_DEFAULT_DIR="/root/oneplus-backups"
ONEPLUS_ROLLBACK_DIR="/var/lib/oneplus/rollback"

backup_require_age() {
  command_exists age || { error "Pacote 'age' não está instalado."; return 1; }
}

backup_copy_if_exists() {
  local src="$1" root="$2" rel="${1#/}" dst="$root/payload/$rel"
  [[ -e "$src" ]] || return 0
  # Backups never follow symlinks. A link under a root-controlled OnePlus path
  # could otherwise make unrelated host files enter the encrypted archive.
  if [[ -L "$src" ]] || { [[ -d "$src" ]] && find "$src" -type l -print -quit 2>/dev/null | grep -q .; }; then
    error "Link simbólico detectado em $src; backup recusado até a árvore ser revisada."
    return 1
  fi
  install -d -m 0700 "$(dirname "$dst")"
  if [[ -d "$src" ]]; then
    install -d -m 0700 "$dst"
    rsync -a -- "$src/" "$dst/"
  else
    cp --preserve=mode,timestamps -- "$src" "$dst"
  fi
}

backup_capture_accounts() {
  local stage="$1" file user
  : > "$stage/metadata/accounts.passwd"
  : > "$stage/metadata/accounts.shadow"
  chmod 0600 "$stage/metadata/accounts.passwd" "$stage/metadata/accounts.shadow"
  shopt -s nullglob
  for file in /var/lib/oneplus/users/*.conf; do
    user=$(meta_get "$file" USERNAME)
    managed_user_identity_ok "$user" || continue
    getent passwd "$user" >> "$stage/metadata/accounts.passwd" || true
    getent shadow "$user" >> "$stage/metadata/accounts.shadow" || true
  done
  shopt -u nullglob
}

backup_manifest() {
  local stage="$1" now host os version
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  host=$(hostname -f 2>/dev/null || hostname)
  os=$(show_os_line 2>/dev/null || true)
  version=$(cat /opt/oneplus/VERSION 2>/dev/null || cat "$ROOT_DIR/VERSION" 2>/dev/null || echo unknown)
  cat > "$stage/metadata/manifest.env" <<EOF2
FORMAT=1
ONEPLUS_VERSION=${version}
CREATED_AT_UTC=${now}
HOSTNAME=${host}
OS=${os}
PASSWORD_HASHES_INCLUDED=yes
HOME_DIRECTORIES_INCLUDED=no
EOF2
  chmod 0600 "$stage/metadata/manifest.env"
  (
    cd "$stage"
    find payload metadata -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
  )
  chmod 0600 "$stage/SHA256SUMS"
}

create_oneplus_backup() {
  require_root
  backup_require_age || return 1
  local outdir name stage plain outfile tmpbase now
  printf "Diretório de backup [%s]: " "$ONEPLUS_BACKUP_DEFAULT_DIR"
  read -r outdir
  outdir=${outdir:-$ONEPLUS_BACKUP_DEFAULT_DIR}
  [[ "$outdir" == /* ]] || { error "Use um caminho absoluto."; return 1; }
  install -d -m 0700 -o root -g root "$outdir"

  now=$(date -u +%Y%m%dT%H%M%SZ)
  name="oneplus-backup-${now}.tar.gz.age"
  outfile="$outdir/$name"
  [[ ! -e "$outfile" ]] || { error "Arquivo já existe: $outfile"; return 1; }

  tmpbase=$(mktemp -d /tmp/oneplus-backup.XXXXXX)
  stage="$tmpbase/stage"
  plain="$tmpbase/backup.tar.gz"
  install -d -m 0700 "$stage/payload" "$stage/metadata"
  trap 'rm -rf -- "${tmpbase:-}" 2>/dev/null || true' RETURN

  info "Coletando somente dados gerenciados pelo OnePlus..."
  backup_copy_if_exists /etc/oneplus "$stage"
  backup_copy_if_exists /var/lib/oneplus/users "$stage"
  backup_copy_if_exists /etc/ssh/sshd_config.d/60-oneplus.conf "$stage"
  backup_copy_if_exists /etc/security/limits.d/90-oneplus.conf "$stage"
  backup_copy_if_exists /etc/pam.d/oneplus-openvpn "$stage"
  backup_copy_if_exists /etc/sysctl.d/90-oneplus-forwarding.conf "$stage"
  backup_copy_if_exists /etc/oneplus/nftables.conf "$stage"
  backup_capture_accounts "$stage"
  backup_manifest "$stage"

  tar -C "$stage" -czf "$plain" .
  chmod 0600 "$plain"
  warn "O backup contém hashes de senha e chaves privadas do OnePlus. Ele será obrigatoriamente criptografado."
  info "O age solicitará uma senha de criptografia. Não a perca: o OnePlus não a armazena."
  if ! age -p -o "$outfile" "$plain"; then
    rm -f -- "$outfile"
    error "Falha ao criptografar o backup."
    return 1
  fi
  chmod 0600 "$outfile"
  (cd "$outdir" && sha256sum "$name" > "${name}.sha256")
  chmod 0600 "${outfile}.sha256"
  rm -rf -- "$tmpbase"
  trap - RETURN
  ok "Backup criptografado criado: $outfile"
  info "Checksum: ${outfile}.sha256"
  warn "Diretórios /home não são incluídos. O backup restaura contas/configurações, não arquivos pessoais dos usuários."
}

backup_archive_safe() {
  local archive="$1" entry
  while IFS= read -r entry; do
    entry=${entry#./}
    [[ -z "$entry" ]] && continue
    [[ "$entry" != /* ]] || return 1
    [[ "$entry" != ".." && "$entry" != ../* && "$entry" != */../* && "$entry" != */.. ]] || return 1
  done < <(tar -tzf "$archive")
  # Accept only regular files and directories before extraction. This rejects
  # symlinks, hardlinks, FIFOs and device nodes from a crafted archive.
  LC_ALL=C tar -tvzf "$archive" | awk '{t=substr($1,1,1); if (t!="-" && t!="d") exit 1}' || return 1
}

create_restore_rollback() {
  local stamp file="$ONEPLUS_ROLLBACK_DIR/pre-restore-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
  install -d -m 0700 -o root -g root "$ONEPLUS_ROLLBACK_DIR"
  local -a paths=()
  [[ -e /etc/oneplus ]] && paths+=(etc/oneplus)
  [[ -e /var/lib/oneplus/users ]] && paths+=(var/lib/oneplus/users)
  [[ -e /etc/ssh/sshd_config.d/60-oneplus.conf ]] && paths+=(etc/ssh/sshd_config.d/60-oneplus.conf)
  [[ -e /etc/security/limits.d/90-oneplus.conf ]] && paths+=(etc/security/limits.d/90-oneplus.conf)
  [[ -e /etc/pam.d/oneplus-openvpn ]] && paths+=(etc/pam.d/oneplus-openvpn)
  [[ -e /etc/sysctl.d/90-oneplus-forwarding.conf ]] && paths+=(etc/sysctl.d/90-oneplus-forwarding.conf)
  if ((${#paths[@]})); then
    tar -C / -czf "$file" "${paths[@]}"
  else
    tar -C /tmp -czf "$file" --files-from /dev/null
  fi
  chmod 0600 "$file"
  printf '%s' "$file"
}

restore_account_records() {
  local stage="$1" pfile="$stage/metadata/accounts.passwd" sfile="$stage/metadata/accounts.shadow"
  local line user _ uid gid gecos home shell shadow hash current_uid file
  [[ -r "$pfile" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=: read -r user _ uid gid gecos home shell <<< "$line"
    is_valid_username "$user" || { warn "Conta ignorada no backup: nome inválido '$user'."; continue; }
    [[ "$uid" =~ ^[0-9]+$ && "$uid" -gt 0 ]] || { warn "UID inválido para $user; ignorando."; continue; }
    [[ "$home" == "/home/$user" ]] || { warn "Home inesperado para $user; ignorando conta."; continue; }
    file=$(user_meta_file "$user")
    [[ -f "$file" ]] || { warn "Metadado ausente para $user; ignorando conta."; continue; }

    if id "$user" >/dev/null 2>&1; then
      current_uid=$(id -u "$user")
      if [[ "$current_uid" != "$uid" ]]; then
        warn "Usuário $user já existe com UID $current_uid (backup: $uid); senha não será alterada."
        continue
      fi
      if ! managed_user_identity_ok "$user"; then
        warn "Usuário $user já existe, mas não é uma conta OnePlus validada; a conta existente não será alterada."
        continue
      fi
    else
      if getent passwd "$uid" >/dev/null 2>&1; then
        warn "UID $uid do backup já está ocupado; criando $user com novo UID seguro."
        [[ ! -e "$home" ]] || { warn "$home já existe; conta $user não será recriada automaticamente."; continue; }
        useradd --create-home --home-dir "$home" --shell /bin/bash --groups "$ONEPLUS_USERS_GROUP" "$user"
      else
        [[ ! -e "$home" ]] || { warn "$home já existe; conta $user não será recriada automaticamente."; continue; }
        useradd --uid "$uid" --create-home --home-dir "$home" --shell /bin/bash --groups "$ONEPLUS_USERS_GROUP" "$user"
      fi
      current_uid=$(id -u "$user")
      meta_set "$file" UID "$current_uid"
    fi

    shadow=$(awk -F: -v u="$user" '$1==u {print; exit}' "$sfile" 2>/dev/null || true)
    if [[ -n "$shadow" ]]; then
      IFS=: read -r _ hash _ <<< "$shadow"
      if [[ -n "$hash" ]]; then
        usermod -p "$hash" "$user"
      fi
    fi
    set_shadow_expiry_from_epoch "$user" "$(meta_get "$file" EXPIRES_AT)" || true
  done < "$pfile"
}

restore_oneplus_backup() {
  require_root
  backup_require_age || return 1
  local source checksum tmpbase plain stage rollback confirm
  printf "Caminho do backup .age: "
  read -r source
  [[ "$source" == /* && -f "$source" ]] || { error "Arquivo não encontrado ou caminho não absoluto."; return 1; }

  checksum="${source}.sha256"
  if [[ -f "$checksum" ]]; then
    info "Validando checksum externo..."
    (cd "$(dirname "$source")" && sha256sum -c "$(basename "$checksum")") || { error "Checksum externo inválido."; return 1; }
  else
    warn "Arquivo .sha256 não encontrado; a assinatura criptográfica do age ainda detectará corrupção na descriptografia."
  fi

  printf "Digite RESTAURAR para descriptografar e preparar a restauração: "
  read -r confirm
  [[ "$confirm" == RESTAURAR ]] || { info "Cancelado."; return 0; }

  tmpbase=$(mktemp -d /tmp/oneplus-restore.XXXXXX)
  plain="$tmpbase/backup.tar.gz"
  stage="$tmpbase/stage"
  install -d -m 0700 "$stage"
  trap 'rm -rf -- "${tmpbase:-}" 2>/dev/null || true' RETURN
  info "Informe a senha do backup quando solicitado pelo age."
  age -d -o "$plain" "$source" || { error "Não foi possível descriptografar o backup."; return 1; }
  backup_archive_safe "$plain" || { error "Arquivo contém caminhos inseguros; restauração bloqueada."; return 1; }
  tar -C "$stage" -xzf "$plain"
  if find "$stage" \( -type l -o -type b -o -type c -o -type p -o -type s \) -print -quit | grep -q .; then
    error "Links e arquivos especiais não são aceitos em backups OnePlus."
    return 1
  fi
  [[ -r "$stage/metadata/manifest.env" && -r "$stage/SHA256SUMS" ]] || { error "Manifesto do backup ausente."; return 1; }
  (cd "$stage" && sha256sum -c SHA256SUMS) || { error "Integridade interna do backup falhou."; return 1; }
  grep -Fxq 'FORMAT=1' "$stage/metadata/manifest.env" || { error "Formato de backup não suportado."; return 1; }

  printf "\nBackup validado. Esta operação substitui configurações OnePlus e pode recriar contas ausentes.\n"
  printf "Digite APLICAR para continuar: "
  read -r confirm
  [[ "$confirm" == APLICAR ]] || { info "Cancelado sem alterações."; return 0; }

  rollback=$(create_restore_rollback)
  info "Rollback local criado: $rollback"

  if [[ -d "$stage/payload/etc/oneplus" ]]; then
    install -d -m 0755 /etc/oneplus
    rsync -a --delete "$stage/payload/etc/oneplus/" /etc/oneplus/
  fi
  if [[ -d "$stage/payload/var/lib/oneplus/users" ]]; then
    install -d -m 0700 -o root -g root /var/lib/oneplus/users
    rsync -a --delete "$stage/payload/var/lib/oneplus/users/" /var/lib/oneplus/users/
  fi

  local rel dst
  for rel in \
    etc/ssh/sshd_config.d/60-oneplus.conf \
    etc/security/limits.d/90-oneplus.conf \
    etc/pam.d/oneplus-openvpn \
    etc/sysctl.d/90-oneplus-forwarding.conf; do
    if [[ -f "$stage/payload/$rel" ]]; then
      dst="/$rel"
      install -d -m 0755 "$(dirname "$dst")"
      install -m 0644 -o root -g root "$stage/payload/$rel" "$dst"
    fi
  done

  ensure_users_group
  restore_account_records "$stage"
  regenerate_login_limits
  if declare -F ensure_openvpn_pam >/dev/null 2>&1; then ensure_openvpn_pam; fi

  if ! sshd -t; then
    error "Configuração SSH restaurada é inválida. O rollback local foi preservado em: $rollback"
    return 1
  fi
  systemctl daemon-reload
  /opt/oneplus/modules/diagnostics.sh repair-permissions >/dev/null 2>&1 || true
  rm -rf -- "$tmpbase"
  trap - RETURN
  ok "Restauração concluída."
  warn "Serviços de rede não foram reiniciados automaticamente. Revise 'oneplus diagnostics' e reinicie apenas o necessário."
  warn "Rollback pré-restauração preservado em: $rollback"
}

list_oneplus_backups() {
  local dir="$ONEPLUS_BACKUP_DEFAULT_DIR"
  printf "Diretório [%s]: " "$dir"; read -r input
  dir=${input:-$dir}
  [[ -d "$dir" ]] || { warn "Diretório inexistente."; return 0; }
  find "$dir" -maxdepth 1 -type f -name 'oneplus-backup-*.tar.gz.age' -printf '%TY-%Tm-%Td %TH:%TM  %10s  %p\n' | sort -r || true
}

module_backup() {
  while true; do
    clear
    printf "%bOnePlus • Backup e restauração%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    printf "1) Criar backup criptografado\n"
    printf "2) Restaurar backup\n"
    printf "3) Listar backups\n"
    printf "0) Voltar\n\nEscolha: "
    read -r opt
    case "$opt" in
      1) create_oneplus_backup; pause ;;
      2) restore_oneplus_backup; pause ;;
      3) list_oneplus_backups; pause ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
}
