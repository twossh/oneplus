#!/usr/bin/env bash
set -Eeuo pipefail

ONEPLUS_HISTORY_CONFIG=/etc/oneplus/history.env
ONEPLUS_HISTORY_DIR=/var/lib/oneplus/history
ONEPLUS_HISTORY_TIMER=oneplus-history.timer
ONEPLUS_HISTORY_SERVICE=oneplus-history.service
ONEPLUS_HISTORY_DROPIN=/etc/systemd/system/oneplus-history.timer.d/override.conf

history_cfg_get() {
  local key="$1" default="$2" value
  value=$(awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$ONEPLUS_HISTORY_CONFIG" 2>/dev/null || true)
  printf '%s' "${value:-$default}"
}

history_cfg_set() {
  local key="$1" value="$2" tmp
  tmp=$(mktemp /tmp/oneplus-history-env.XXXXXX)
  awk -F= -v k="$key" -v v="$value" '
    BEGIN{done=0}
    $1==k {print k "=" v; done=1; next}
    {print}
    END{if(!done) print k "=" v}
  ' "$ONEPLUS_HISTORY_CONFIG" > "$tmp"
  install -m 0640 -o root -g root "$tmp" "$ONEPLUS_HISTORY_CONFIG"
  rm -f -- "$tmp"
}

history_valid_interval() {
  case "$1" in 1|5|15|30|60) return 0 ;; *) return 1 ;; esac
}

history_apply_interval() {
  local minutes="$1"
  history_valid_interval "$minutes" || { error "Intervalo permitido: 1, 5, 15, 30 ou 60 minutos."; return 1; }
  install -d -m 0755 -o root -g root /etc/systemd/system/oneplus-history.timer.d
  cat > "$ONEPLUS_HISTORY_DROPIN" <<EOF2
[Timer]
OnBootSec=
OnUnitActiveSec=
OnBootSec=2min
OnUnitActiveSec=${minutes}min
EOF2
  chmod 0644 "$ONEPLUS_HISTORY_DROPIN"
  systemctl daemon-reload
  if systemctl is-enabled --quiet "$ONEPLUS_HISTORY_TIMER" 2>/dev/null; then
    systemctl restart "$ONEPLUS_HISTORY_TIMER"
  fi
}

history_status() {
  local interval retention size count next
  interval=$(history_cfg_get HISTORY_INTERVAL_MINUTES 5)
  retention=$(history_cfg_get HISTORY_RETENTION_DAYS 14)
  if [[ -d "$ONEPLUS_HISTORY_DIR" ]]; then
    count=$(find "$ONEPLUS_HISTORY_DIR" -maxdepth 1 -type f -name '*.ndjson' 2>/dev/null | wc -l | tr -d ' ')
    size=$(du -sh "$ONEPLUS_HISTORY_DIR" 2>/dev/null | awk '{print $1}' || true)
  else
    count=0
    size=0
  fi
  next=$(systemctl list-timers "$ONEPLUS_HISTORY_TIMER" --no-legend --no-pager 2>/dev/null | awk '{$1=$1;print}' || true)
  if systemctl is-enabled --quiet "$ONEPLUS_HISTORY_TIMER" 2>/dev/null; then
    if systemctl is-active --quiet "$ONEPLUS_HISTORY_TIMER" 2>/dev/null; then
      printf 'Timer: HABILITADO/ATIVO\n'
    else
      printf 'Timer: HABILITADO/INATIVO\n'
    fi
  else
    printf 'Timer: DESABILITADO (opt-in)\n'
  fi
  printf 'Intervalo: %s min\n' "$interval"
  printf 'Retenção: %s dias\n' "$retention"
  printf 'Arquivos: %s\n' "${count:-0}"
  printf 'Espaço: %s\n' "${size:-0}"
  [[ -n "$next" ]] && printf 'Agendamento: %s\n' "$next"
  printf '\nPrivacidade: snapshots não persistem usernames, IPs remotos, comandos, senhas ou payloads.\n'
}

history_enable() {
  local interval
  interval=$(history_cfg_get HISTORY_INTERVAL_MINUTES 5)
  history_apply_interval "$interval"
  systemctl enable --now "$ONEPLUS_HISTORY_TIMER"
  ok "Histórico leve habilitado."
}

history_disable() {
  systemctl disable --now "$ONEPLUS_HISTORY_TIMER" 2>/dev/null || true
  ok "Coleta periódica desabilitada. Os snapshots existentes foram preservados."
}

history_snapshot_now() {
  systemctl start "$ONEPLUS_HISTORY_SERVICE"
  ok "Snapshot coletado."
}

history_summary() {
  local hours="$1"
  [[ "$hours" =~ ^[0-9]+$ ]] && (( 10#$hours >= 1 && 10#$hours <= 2160 )) || {
    error "Período deve estar entre 1 e 2160 horas."
    return 1
  }
  python3 /opt/oneplus/libexec/history_summary.py --history-dir "$ONEPLUS_HISTORY_DIR" --hours "$hours"
}

history_set_interval_menu() {
  local minutes
  printf 'Intervalo em minutos [1,5,15,30,60]: '; read -r minutes
  history_valid_interval "$minutes" || { error "Intervalo inválido."; return 1; }
  history_cfg_set HISTORY_INTERVAL_MINUTES "$minutes"
  history_apply_interval "$minutes"
  ok "Intervalo alterado para ${minutes} min."
}

history_set_retention_menu() {
  local days
  printf 'Retenção em dias [1-90]: '; read -r days
  [[ "$days" =~ ^[0-9]+$ ]] && (( 10#$days >= 1 && 10#$days <= 90 )) || { error "Retenção inválida."; return 1; }
  history_cfg_set HISTORY_RETENTION_DAYS "$days"
  python3 /opt/oneplus/libexec/history_snapshot.py --output-dir "$ONEPLUS_HISTORY_DIR" --retention-days "$days" --prune-only
  ok "Retenção alterada para ${days} dias."
}

history_clear() {
  local confirm
  warn "Isto remove somente os arquivos NDJSON em $ONEPLUS_HISTORY_DIR."
  printf 'Digite APAGAR-HISTORICO para continuar: '; read -r confirm
  [[ "$confirm" == APAGAR-HISTORICO ]] || { info "Cancelado."; return 0; }
  find "$ONEPLUS_HISTORY_DIR" -maxdepth 1 -type f -name '*.ndjson' -links 1 -delete 2>/dev/null || true
  ok "Histórico removido."
}

module_history() {
  while true; do
    clear
    printf "%bOnePlus • Histórico leve%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    history_status
    printf '\n1) Habilitar coleta periódica\n'
    printf '2) Desabilitar coleta periódica\n'
    printf '3) Coletar snapshot agora\n'
    printf '4) Resumo últimas 24 horas\n'
    printf '5) Resumo últimos 7 dias\n'
    printf '6) Resumo período personalizado\n'
    printf '7) Alterar intervalo\n'
    printf '8) Alterar retenção\n'
    printf '9) Apagar histórico armazenado\n'
    printf '0) Voltar\n\nEscolha: '
    read -r opt
    case "$opt" in
      1) history_enable; pause ;;
      2) history_disable; pause ;;
      3) history_snapshot_now; pause ;;
      4) clear; history_summary 24; pause ;;
      5) clear; history_summary 168; pause ;;
      6) printf 'Horas [1-2160]: '; read -r hours; clear; history_summary "$hours"; pause ;;
      7) history_set_interval_menu; pause ;;
      8) history_set_retention_menu; pause ;;
      9) history_clear; pause ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
}
