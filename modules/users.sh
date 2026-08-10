#!/usr/bin/env bash
set -Eeuo pipefail

ONEPLUS_USERS_GROUP="oneplus-users"
ONEPLUS_USERS_DIR="/var/lib/oneplus/users"
ONEPLUS_USERS_CONF="/etc/oneplus/users.conf"
ONEPLUS_LIMITS_FILE="/etc/security/limits.d/90-oneplus.conf"

users_conf_get() {
  local key="$1" default="${2:-}" value
  value=$(awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$ONEPLUS_USERS_CONF" 2>/dev/null || true)
  printf '%s' "${value:-$default}"
}

is_valid_username() {
  local user="$1"
  [[ "$user" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || return 1
  case "$user" in
    root|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|_apt|nobody|systemd-*|oneplus-*) return 1 ;;
  esac
}

user_meta_file() { printf '%s/%s.conf' "$ONEPLUS_USERS_DIR" "$1"; }

meta_get() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$file" 2>/dev/null || true
}

meta_set() {
  local file="$1" key="$2" value="$3" tmp
  [[ -f "$file" ]] || return 1
  [[ "$key" =~ ^[A-Z0-9_]+$ ]] || return 1
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  awk -F= -v k="$key" -v v="$value" '
    BEGIN {done=0}
    $1==k {print k "=" v; done=1; next}
    {print}
    END {if (!done) print k "=" v}
  ' "$file" > "$tmp"
  install -m 0600 -o root -g root "$tmp" "$file"
  rm -f "$tmp"
}

write_user_meta() {
  local user="$1" uid="$2" home="$3" kind="$4" created="$5" expires="$6" limit="$7" action="$8"
  local file tmp
  file=$(user_meta_file "$user")
  install -d -m 0700 -o root -g root "$ONEPLUS_USERS_DIR"
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  cat > "$tmp" <<EOF2
FORMAT=1
USERNAME=${user}
UID=${uid}
HOME=${home}
KIND=${kind}
CREATED_AT=${created}
EXPIRES_AT=${expires}
CONNECTION_LIMIT=${limit}
EXPIRE_ACTION=${action}
EXPIRED_HANDLED=0
EOF2
  install -m 0600 -o root -g root "$tmp" "$file"
  rm -f "$tmp"
}

managed_user_identity_ok() {
  local user="$1" file uid meta_uid
  is_valid_username "$user" || return 1
  file=$(user_meta_file "$user")
  [[ -f "$file" ]] || return 1
  uid=$(id -u "$user" 2>/dev/null) || return 1
  (( uid > 0 )) || return 1
  meta_uid=$(meta_get "$file" UID)
  [[ "$meta_uid" =~ ^[0-9]+$ && "$uid" == "$meta_uid" ]] || return 1
  id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -Fxq "$ONEPLUS_USERS_GROUP"
}

require_managed_user() {
  local user="$1"
  if ! managed_user_identity_ok "$user"; then
    error "Usuário '$user' não é uma conta gerenciada válida do OnePlus."
    return 1
  fi
}

ensure_users_group() {
  getent group "$ONEPLUS_USERS_GROUP" >/dev/null 2>&1 || groupadd --system "$ONEPLUS_USERS_GROUP"
  install -d -m 0700 -o root -g root "$ONEPLUS_USERS_DIR"
}

pam_limits_available_for_sshd() {
  grep -Eq '^[[:space:]]*session[[:space:]]+(required|requisite|sufficient|optional)[[:space:]]+pam_limits\.so([[:space:]]|$)' /etc/pam.d/sshd 2>/dev/null
}

regenerate_login_limits() {
  local tmp file user limit
  install -d -m 0755 /etc/security/limits.d
  tmp=$(mktemp /tmp/oneplus-limits.XXXXXX)
  {
    printf '# Gerado pelo OnePlus. Não edite manualmente.\n'
    printf '# O monitor OnePlus também aplica o limite a conexões SSH sem TTY.\n'
    shopt -s nullglob
    for file in "$ONEPLUS_USERS_DIR"/*.conf; do
      user=$(meta_get "$file" USERNAME)
      limit=$(meta_get "$file" CONNECTION_LIMIT)
      managed_user_identity_ok "$user" || continue
      [[ "$limit" =~ ^[0-9]+$ ]] || continue
      (( 10#$limit > 0 )) || continue
      printf '%s hard maxlogins %s\n' "$user" "$limit"
    done
    shopt -u nullglob
  } > "$tmp"
  install -m 0644 -o root -g root "$tmp" "$ONEPLUS_LIMITS_FILE"
  rm -f "$tmp"
}

user_ssh_processes() {
  local user="$1"
  if [[ -n "${ONEPLUS_PS_SNAPSHOT:-}" && -r "${ONEPLUS_PS_SNAPSHOT}" ]]; then
    awk -v u="$user" '$1==u && ($4=="sshd" || $4=="sshd-session") {print $2, $3}' "$ONEPLUS_PS_SNAPSHOT"
  else
    ps -eo user=,pid=,etimes=,comm= 2>/dev/null | awk -v u="$user" '
      $1==u && ($4=="sshd" || $4=="sshd-session") {print $2, $3}
    '
  fi
}

create_ps_snapshot() {
  ONEPLUS_PS_SNAPSHOT=$(mktemp /tmp/oneplus-ps.XXXXXX)
  ps -eo user=,pid=,etimes=,comm= > "$ONEPLUS_PS_SNAPSHOT"
}

remove_ps_snapshot() {
  if [[ -n "${ONEPLUS_PS_SNAPSHOT:-}" ]]; then
    rm -f -- "$ONEPLUS_PS_SNAPSHOT"
    unset ONEPLUS_PS_SNAPSHOT
  fi
}

user_connection_count() {
  local user="$1"
  user_ssh_processes "$user" | awk 'END {print NR+0}'
}

pid_is_user_ssh() {
  local user="$1" pid="$2" puser comm
  puser=$(ps -o user= -p "$pid" 2>/dev/null | awk '{$1=$1; print}')
  comm=$(ps -o comm= -p "$pid" 2>/dev/null | awk '{$1=$1; print}')
  [[ "$puser" == "$user" && ( "$comm" == "sshd" || "$comm" == "sshd-session" ) ]]
}

terminate_user_sessions() {
  local user="$1" uid
  require_managed_user "$user" || return 1
  uid=$(id -u "$user")
  loginctl terminate-user "$user" >/dev/null 2>&1 || true
  sleep 1
  if pgrep -u "$uid" >/dev/null 2>&1; then
    pkill -TERM -u "$uid" 2>/dev/null || true
    sleep 1
  fi
  if pgrep -u "$uid" >/dev/null 2>&1; then
    pkill -KILL -u "$uid" 2>/dev/null || true
  fi
}

apply_connection_limit() {
  local user="$1" limit="$2" count i pid line
  [[ "$limit" =~ ^[0-9]+$ ]] || return 0
  (( 10#$limit > 0 )) || return 0
  mapfile -t sessions < <(user_ssh_processes "$user" | sort -k2,2nr)
  count=${#sessions[@]}
  (( count > limit )) || return 0

  # Mantém as conexões mais antigas e encerra somente o excedente mais recente.
  for ((i=limit; i<count; i++)); do
    line=${sessions[$i]}
    pid=${line%% *}
    if [[ "$pid" =~ ^[0-9]+$ ]] && pid_is_user_ssh "$user" "$pid"; then
      printf '[LIMITE] %s excedeu %s conexão(ões); encerrando PID %s.\n' "$user" "$limit" "$pid"
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
}

expiry_fallback_date() {
  local expires="$1"
  if [[ "$expires" =~ ^[0-9]+$ ]] && (( expires > 0 )); then
    date -d "@$((expires + 86400))" +%F
  else
    printf '%s' '-1'
  fi
}

set_shadow_expiry_from_epoch() {
  local user="$1" expires="$2" exact_date="${3:-}"
  if [[ "$expires" == "0" ]]; then
    chage -E -1 "$user"
  elif [[ -n "$exact_date" ]]; then
    chage -E "$exact_date" "$user"
  else
    chage -E "$(expiry_fallback_date "$expires")" "$user"
  fi
}

lock_managed_user() {
  local user="$1"
  require_managed_user "$user" || return 1
  usermod -L "$user" || { error "Falha ao bloquear a senha de $user."; return 1; }
  chage -E 1 "$user" || { error "Falha ao expirar a conta $user."; return 1; }
  terminate_user_sessions "$user" || return 1
}

unlock_managed_user() {
  local user="$1" file expires
  require_managed_user "$user" || return 1
  file=$(user_meta_file "$user")
  expires=$(meta_get "$file" EXPIRES_AT)
  if [[ "$expires" =~ ^[0-9]+$ ]] && (( expires > 0 && $(date +%s) >= expires )); then
    error "A validade desta conta já terminou. Altere a expiração antes de desbloquear."
    return 1
  fi
  usermod -U "$user" || { error "Falha ao desbloquear a senha de $user."; return 1; }
  set_shadow_expiry_from_epoch "$user" "${expires:-0}" || { error "Falha ao restaurar a validade de $user."; return 1; }
}

generate_test_username() {
  local candidate
  while true; do
    candidate="test$(date +%H%M%S)$(printf '%04x' "$RANDOM")"
    candidate=${candidate:0:24}
    if ! getent passwd "$candidate" >/dev/null 2>&1 && [[ ! -e "$(user_meta_file "$candidate")" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
}

create_linux_managed_user() {
  local user="$1" kind="$2" expires="$3" limit="$4" action="$5" set_password_mode="$6" generated_password="${7:-}"
  local home uid created home_uid
  ensure_users_group
  home="/home/$user"
  created=$(date +%s)
  if [[ -e "$home" || -L "$home" ]]; then
    error "O caminho $home já existe. Renomeie/remova esse diretório antes de reutilizar o usuário."
    return 1
  fi

  if ! useradd --create-home --home-dir "$home" --shell /bin/bash --groups "$ONEPLUS_USERS_GROUP" \
    --comment "OnePlus managed ${kind} user" "$user"; then
    error "Falha ao criar a conta Linux '$user'."
    return 1
  fi
  uid=$(id -u "$user") || { userdel -r "$user" 2>/dev/null || true; return 1; }
  home_uid=$(stat -c %u "$home" 2>/dev/null || true)
  if [[ "$home_uid" != "$uid" ]]; then
    error "O home criado não pertence ao UID esperado; removendo somente a conta e preservando o caminho para inspeção."
    userdel "$user" 2>/dev/null || true
    return 1
  fi

  if [[ "$set_password_mode" == "interactive" ]]; then
    printf '\nDefina a senha de %s. A senha não será armazenada pelo OnePlus.\n' "$user"
    if ! passwd "$user"; then
      warn "Falha ao definir senha; revertendo criação da conta."
      userdel -r "$user" 2>/dev/null || userdel "$user" 2>/dev/null || true
      return 1
    fi
  else
    if [[ -z "$generated_password" || "$generated_password" == *:* ]]; then
      userdel -r "$user" 2>/dev/null || true
      error "Senha temporária inválida."
      return 1
    fi
    if ! printf '%s:%s\n' "$user" "$generated_password" | chpasswd; then
      userdel -r "$user" 2>/dev/null || userdel "$user" 2>/dev/null || true
      error "Falha ao definir senha temporária."
      return 1
    fi
  fi

  if ! set_shadow_expiry_from_epoch "$user" "$expires"; then
    userdel -r "$user" 2>/dev/null || userdel "$user" 2>/dev/null || true
    error "Falha ao aplicar validade; criação revertida."
    return 1
  fi
  if ! write_user_meta "$user" "$uid" "$home" "$kind" "$created" "$expires" "$limit" "$action"; then
    userdel -r "$user" 2>/dev/null || userdel "$user" 2>/dev/null || true
    error "Falha ao registrar metadados; criação revertida."
    return 1
  fi
  if ! regenerate_login_limits; then
    error "Conta criada, mas houve falha ao atualizar limites PAM. Execute 'oneplus users' e processe a manutenção."
    return 1
  fi
  return 0
}

prompt_connection_limit() {
  local default_limit v
  default_limit=$(users_conf_get DEFAULT_CONNECTION_LIMIT 1)
  printf 'Limite de conexões simultâneas [%s] (0 = ilimitado): ' "$default_limit" >&2
  read -r v
  v=${v:-$default_limit}
  [[ "$v" =~ ^[0-9]+$ ]] && (( 10#$v <= 1000 )) || { error "Limite inválido (0-1000)."; return 1; }
  printf '%s' "$v"
}

prompt_regular_expiry() {
  local default_days opt v normalized epoch
  default_days=$(users_conf_get DEFAULT_VALIDITY_DAYS 30)
  printf 'Validade:\n' >&2
  printf '  1) Quantidade de dias\n' >&2
  printf '  2) Data exata de bloqueio (AAAA-MM-DD)\n' >&2
  printf '  3) Sem expiração\n' >&2
  printf 'Escolha [1]: ' >&2
  read -r opt
  opt=${opt:-1}
  case "$opt" in
    1)
      printf 'Dias de validade [%s]: ' "$default_days" >&2
      read -r v
      v=${v:-$default_days}
      [[ "$v" =~ ^[0-9]+$ ]] && (( 10#$v >= 1 && 10#$v <= 3650 )) || { error "Dias inválidos (1-3650)."; return 1; }
      printf '%s' "$(( $(date +%s) + 10#$v * 86400 ))"
      ;;
    2)
      printf 'A conta ficará inacessível a partir de (AAAA-MM-DD): ' >&2
      read -r v
      [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { error "Formato de data inválido."; return 1; }
      normalized=$(date -d "$v 00:00:00" +%F 2>/dev/null || true)
      [[ "$normalized" == "$v" ]] || { error "Data inexistente."; return 1; }
      epoch=$(date -d "$v 00:00:00" +%s)
      (( epoch > $(date +%s) )) || { error "A data precisa estar no futuro."; return 1; }
      printf '%s' "$epoch"
      ;;
    3) printf '0' ;;
    *) error "Opção inválida."; return 1 ;;
  esac
}

create_regular_user() {
  local user expires limit action
  printf 'Nome do novo usuário: '
  read -r user
  is_valid_username "$user" || { error "Use 1-32 caracteres: letra minúscula inicial, depois letras, números, _ ou -."; return 1; }
  if getent passwd "$user" >/dev/null 2>&1; then
    error "O usuário '$user' já existe no sistema."
    return 1
  fi
  expires=$(prompt_regular_expiry) || return 1
  limit=$(prompt_connection_limit) || return 1
  action=$(users_conf_get DEFAULT_EXPIRE_ACTION lock)
  case "$action" in lock|delete|delete-home) ;; *) action=lock ;; esac
  if create_linux_managed_user "$user" regular "$expires" "$limit" "$action" interactive; then
    ok "Usuário '$user' criado."
    printf 'Validade: %s\n' "$(format_expiry "$expires")"
    printf 'Conexões: %s\n' "$([[ "$limit" == 0 ]] && echo ilimitadas || echo "$limit")"
    warn "A senha foi definida diretamente pelo comando passwd e não foi salva pelo OnePlus."
  fi
}

create_test_user() {
  local hours default_hours user password expires limit action
  default_hours=$(users_conf_get DEFAULT_TEST_HOURS 1)
  printf 'Duração do teste em horas [%s]: ' "$default_hours"
  read -r hours
  hours=${hours:-$default_hours}
  [[ "$hours" =~ ^[0-9]+$ ]] && (( 10#$hours >= 1 && 10#$hours <= 168 )) || { error "Duração inválida (1-168 horas)."; return 1; }
  limit=$(prompt_connection_limit) || return 1
  user=$(generate_test_username)
  password=$(openssl rand -hex 8)
  expires=$(( $(date +%s) + 10#$hours * 3600 ))
  action=$(users_conf_get DEFAULT_TEST_EXPIRE_ACTION delete-home)
  case "$action" in lock|delete|delete-home) ;; *) action=delete-home ;; esac

  if create_linux_managed_user "$user" test "$expires" "$limit" "$action" generated "$password"; then
    clear
    printf '%bConta de teste criada%b\n\n' "$C_BOLD$C_GREEN" "$C_RESET"
    printf 'Usuário:   %s\n' "$user"
    printf 'Senha:     %s\n' "$password"
    printf 'Expira em: %s\n' "$(format_expiry "$expires")"
    printf 'Conexões:  %s\n' "$([[ "$limit" == 0 ]] && echo ilimitadas || echo "$limit")"
    printf '\n%bA senha é exibida somente agora e não é gravada pelo OnePlus.%b\n' "$C_YELLOW" "$C_RESET"
  fi
  unset password
}

format_expiry() {
  local epoch="$1"
  if [[ ! "$epoch" =~ ^[0-9]+$ || "$epoch" == 0 ]]; then
    printf 'Nunca'
  else
    date -d "@$epoch" '+%Y-%m-%d %H:%M:%S %Z'
  fi
}

account_lock_state() {
  local user="$1" state
  state=$(passwd -S "$user" 2>/dev/null | awk '{print $2}')
  case "$state" in
    L|LK) printf 'BLOQUEADO' ;;
    P|PS) printf 'ATIVO' ;;
    NP) printf 'SEM-SENHA' ;;
    *) printf 'N/D' ;;
  esac
}

list_managed_users() {
  local file user expires limit kind state conn now count=0
  now=$(date +%s)
  create_ps_snapshot
  printf '%-20s %-10s %-9s %-7s %-8s %s\n' 'USUÁRIO' 'TIPO' 'STATUS' 'CONEX.' 'LIMITE' 'EXPIRAÇÃO'
  printf '%-20s %-10s %-9s %-7s %-8s %s\n' '--------------------' '----------' '---------' '-------' '--------' '-------------------------'
  shopt -s nullglob
  for file in "$ONEPLUS_USERS_DIR"/*.conf; do
    user=$(meta_get "$file" USERNAME)
    if ! managed_user_identity_ok "$user"; then
      printf '%-20s %-10s %-9s %-7s %-8s %s\n' "${user:-?}" '?' 'INVÁLIDO' '-' '-' 'metadados/UID divergentes'
      continue
    fi
    expires=$(meta_get "$file" EXPIRES_AT)
    limit=$(meta_get "$file" CONNECTION_LIMIT)
    kind=$(meta_get "$file" KIND)
    state=$(account_lock_state "$user")
    if [[ "$expires" =~ ^[0-9]+$ ]] && (( expires > 0 && now >= expires )); then
      state='EXPIRADO'
    fi
    conn=$(user_connection_count "$user")
    [[ "$limit" == 0 ]] && limit='∞'
    printf '%-20s %-10s %-9s %-7s %-8s %s\n' "$user" "$kind" "$state" "$conn" "$limit" "$(format_expiry "$expires")"
    ((count+=1))
  done
  shopt -u nullglob
  remove_ps_snapshot
  (( count > 0 )) || printf '\nNenhuma conta gerenciada pelo OnePlus.\n'
}

prompt_managed_username() {
  local user
  printf 'Usuário: ' >&2
  read -r user
  require_managed_user "$user" || return 1
  printf '%s' "$user"
}

change_user_password() {
  local user
  user=$(prompt_managed_username) || return 1
  printf 'Alterando senha de %s. O OnePlus não armazenará a nova senha.\n' "$user"
  passwd "$user"
}

change_user_expiry() {
  local user file expires state
  user=$(prompt_managed_username) || return 1
  file=$(user_meta_file "$user")
  expires=$(prompt_regular_expiry) || return 1
  if ! set_shadow_expiry_from_epoch "$user" "$expires"; then
    error "Falha ao aplicar a nova validade no sistema."
    return 1
  fi
  meta_set "$file" EXPIRES_AT "$expires" || return 1
  meta_set "$file" EXPIRED_HANDLED 0 || return 1
  state=$(account_lock_state "$user")
  if [[ "$state" == 'BLOQUEADO' ]] && { [[ "$expires" == 0 ]] || (( expires > $(date +%s) )); }; then
    printf 'A conta está bloqueada. Desbloquear agora? [s/N]: '
    read -r answer
    if [[ "$answer" =~ ^[sS]$ ]]; then
      unlock_managed_user "$user"
    fi
  fi
  ok "Validade atualizada: $(format_expiry "$expires")"
}

change_user_limit() {
  local user file limit
  user=$(prompt_managed_username) || return 1
  file=$(user_meta_file "$user")
  limit=$(prompt_connection_limit) || return 1
  meta_set "$file" CONNECTION_LIMIT "$limit"
  regenerate_login_limits
  apply_connection_limit "$user" "$limit"
  ok "Limite atualizado."
}

change_user_expire_action() {
  local user file opt action
  user=$(prompt_managed_username) || return 1
  file=$(user_meta_file "$user")
  printf 'Ação quando a validade terminar:\n'
  printf '1) Bloquear conta e encerrar sessões (recomendado)\n'
  printf '2) Remover conta e preservar home\n'
  printf '3) Remover conta e home, somente se /home/<usuario> for validado\n'
  printf 'Escolha: '
  read -r opt
  case "$opt" in
    1) action=lock ;;
    2) action=delete ;;
    3) action=delete-home ;;
    *) error 'Opção inválida.'; return 1 ;;
  esac
  meta_set "$file" EXPIRE_ACTION "$action" || return 1
  ok "Ação de expiração atualizada para: $action"
}

toggle_user_lock() {
  local user state
  user=$(prompt_managed_username) || return 1
  state=$(account_lock_state "$user")
  if [[ "$state" == 'BLOQUEADO' || "$state" == 'EXPIRADO' ]]; then
    unlock_managed_user "$user" && ok "Usuário desbloqueado."
  else
    printf "Bloquear '%s' e encerrar suas sessões agora? [s/N]: " "$user"
    read -r answer
    if [[ "$answer" =~ ^[sS]$ ]]; then
      if lock_managed_user "$user"; then
        ok "Usuário bloqueado."
      fi
    fi
  fi
}

safe_remove_managed_user() {
  local user="$1" remove_home="$2" file home current_home
  require_managed_user "$user" || return 1
  file=$(user_meta_file "$user")
  home=$(meta_get "$file" HOME)
  current_home=$(getent passwd "$user" | cut -d: -f6)
  terminate_user_sessions "$user" || return 1

  if [[ "$remove_home" == 1 ]]; then
    if [[ "$home" == "/home/$user" && "$current_home" == "$home" ]]; then
      if ! userdel -r "$user" 2>/dev/null; then
        if getent passwd "$user" >/dev/null 2>&1; then
          warn "Não foi possível remover o home com segurança; tentando remover somente a conta."
          userdel "$user" || return 1
        fi
      fi
    else
      warn "Home divergente do padrão seguro; removendo conta sem apagar arquivos."
      userdel "$user" || return 1
    fi
  else
    userdel "$user" || return 1
  fi
  if getent passwd "$user" >/dev/null 2>&1; then
    error "A conta '$user' ainda existe após a tentativa de remoção."
    return 1
  fi
  if [[ "$remove_home" == 1 && ( -e "$home" || -L "$home" ) ]]; then
    warn "A conta foi removida, mas o caminho $home permaneceu e não será apagado à força."
  fi
  rm -f -- "$file"
  regenerate_login_limits
}

remove_user_interactive() {
  local user opt
  user=$(prompt_managed_username) || return 1
  printf "\nRemover '%s':\n" "$user"
  printf '1) Remover conta e preservar /home\n'
  printf '2) Remover conta e /home/%s\n' "$user"
  printf '0) Cancelar\nEscolha: '
  read -r opt
  case "$opt" in
    1)
      printf 'Digite REMOVER para confirmar: '; read -r confirm
      [[ "$confirm" == 'REMOVER' ]] || { info 'Cancelado.'; return 0; }
      safe_remove_managed_user "$user" 0
      ok 'Conta removida; diretório home preservado.'
      ;;
    2)
      warn 'Esta opção remove também os arquivos do diretório home da conta.'
      printf 'Digite REMOVER-TUDO para confirmar: '; read -r confirm
      [[ "$confirm" == 'REMOVER-TUDO' ]] || { info 'Cancelado.'; return 0; }
      safe_remove_managed_user "$user" 1
      ok 'Conta e home removidos.'
      ;;
    0) info 'Cancelado.' ;;
    *) error 'Opção inválida.'; return 1 ;;
  esac
}

monitor_connections() {
  local file user pid elapsed count=0
  clear
  create_ps_snapshot
  printf '%bOnePlus • Conexões SSH de usuários gerenciados%b\n\n' "$C_BOLD$C_CYAN" "$C_RESET"
  printf '%-20s %-9s %-12s %s\n' 'USUÁRIO' 'PID' 'DURAÇÃO(s)' 'PROCESSO'
  shopt -s nullglob
  for file in "$ONEPLUS_USERS_DIR"/*.conf; do
    user=$(meta_get "$file" USERNAME)
    managed_user_identity_ok "$user" || continue
    while read -r pid elapsed; do
      [[ -n "$pid" ]] || continue
      printf '%-20s %-9s %-12s sshd\n' "$user" "$pid" "$elapsed"
      ((count+=1))
    done < <(user_ssh_processes "$user")
  done
  shopt -u nullglob
  remove_ps_snapshot
  (( count > 0 )) || printf 'Nenhuma conexão SSH ativa de contas OnePlus.\n'
}

handle_expired_user() {
  local user="$1" file="$2" action handled
  action=$(meta_get "$file" EXPIRE_ACTION)
  handled=$(meta_get "$file" EXPIRED_HANDLED)
  [[ "$handled" == 1 ]] && return 0

  case "$action" in
    delete)
      printf '[EXPIRAÇÃO] Removendo conta expirada %s e preservando home.\n' "$user"
      safe_remove_managed_user "$user" 0
      ;;
    delete-home)
      printf '[EXPIRAÇÃO] Removendo conta temporária expirada %s e seu home seguro.\n' "$user"
      safe_remove_managed_user "$user" 1
      ;;
    *)
      printf '[EXPIRAÇÃO] Bloqueando conta expirada %s.\n' "$user"
      usermod -L "$user" || return 1
      chage -E 1 "$user" || return 1
      terminate_user_sessions "$user" || return 1
      meta_set "$file" EXPIRED_HANDLED 1 || return 1
      ;;
  esac
}

maintain_users() {
  require_root
  ensure_users_group
  local now file user expires limit changed=0
  now=$(date +%s)
  create_ps_snapshot
  trap 'remove_ps_snapshot' RETURN
  shopt -s nullglob
  for file in "$ONEPLUS_USERS_DIR"/*.conf; do
    user=$(meta_get "$file" USERNAME)
    if ! is_valid_username "$user"; then
      continue
    fi
    if ! getent passwd "$user" >/dev/null 2>&1; then
      rm -f -- "$file"
      changed=1
      continue
    fi
    if ! managed_user_identity_ok "$user"; then
      continue
    fi
    expires=$(meta_get "$file" EXPIRES_AT)
    limit=$(meta_get "$file" CONNECTION_LIMIT)
    if [[ "$expires" =~ ^[0-9]+$ ]] && (( expires > 0 && now >= expires )); then
      handle_expired_user "$user" "$file"
      changed=1
      continue
    fi
    apply_connection_limit "$user" "${limit:-0}"
  done
  shopt -u nullglob
  (( changed == 0 )) || regenerate_login_limits
  remove_ps_snapshot
  trap - RETURN
}

show_user_maintenance_status() {
  printf 'Timer: %s\n' "$(service_state oneplus-user-maintenance.timer)"
  printf 'PAM pam_limits no SSH: '
  if pam_limits_available_for_sshd; then
    printf '%bSIM%b\n' "$C_GREEN" "$C_RESET"
  else
    printf '%bNÃO (o monitor OnePlus continua aplicando os limites)%b\n' "$C_YELLOW" "$C_RESET"
  fi
  printf '\nÚltimos eventos:\n'
  journalctl -u oneplus-user-maintenance.service -n 40 --no-pager 2>/dev/null || true
}

initialize_users_module() {
  require_root
  ensure_users_group
  regenerate_login_limits
}

module_users() {
  ensure_users_group
  while true; do
    clear
    printf '%bOnePlus • Usuários SSH%b\n\n' "$C_BOLD$C_CYAN" "$C_RESET"
    printf 'Contas OnePlus: %s  |  Manutenção: %b\n\n' \
      "$(find "$ONEPLUS_USERS_DIR" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | wc -l | tr -d ' ')" \
      "$(service_state oneplus-user-maintenance.timer)"
    printf '1) Listar usuários\n'
    printf '2) Criar usuário\n'
    printf '3) Criar usuário de teste\n'
    printf '4) Alterar senha\n'
    printf '5) Alterar validade\n'
    printf '6) Alterar limite de conexões\n'
    printf '7) Alterar ação ao expirar\n'
    printf '8) Bloquear / desbloquear usuário\n'
    printf '9) Remover usuário\n'
    printf '10) Monitorar conexões ativas\n'
    printf '11) Processar expirações/limites agora\n'
    printf '12) Status e logs da manutenção\n'
    printf '0) Voltar\n\nEscolha: '
    read -r opt
    case "$opt" in
      1) clear; list_managed_users; pause ;;
      2) create_regular_user; pause ;;
      3) create_test_user; pause ;;
      4) change_user_password; pause ;;
      5) change_user_expiry; pause ;;
      6) change_user_limit; pause ;;
      7) change_user_expire_action; pause ;;
      8) toggle_user_lock; pause ;;
      9) remove_user_interactive; pause ;;
      10) monitor_connections; pause ;;
      11) maintain_users; ok 'Manutenção executada.'; pause ;;
      12) clear; show_user_maintenance_status; pause ;;
      0) return 0 ;;
      *) warn 'Opção inválida'; sleep 1 ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
  # shellcheck source=../lib/common.sh
  source "$ROOT_DIR/lib/common.sh"
  case "${1:-}" in
    init) initialize_users_module ;;
    maintain) maintain_users ;;
    list) list_managed_users ;;
    *) echo "Uso: $0 {init|maintain|list}"; exit 2 ;;
  esac
fi
