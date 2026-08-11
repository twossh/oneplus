#!/usr/bin/env bash

SSH_SNIPPET=/etc/ssh/sshd_config.d/60-oneplus.conf

ssh_apply_current_config() {
  if ! openssh_config_test; then
    error "sshd -t rejeitou a configuração."
    return 1
  fi
  systemctl daemon-reload
  if systemctl reload ssh.service 2>/dev/null || systemctl restart ssh.service; then
    ok "Configuração OpenSSH validada e aplicada."
    return 0
  fi
  error "OpenSSH não aceitou reload/restart."
  return 1
}

ssh_write_snippet() {
  local password_auth="$1" root_login="$2" max_sessions="$3" max_startups="$4"
  install -d -m 0755 /etc/ssh/sshd_config.d
  local tmp previous had_previous=0
  tmp=$(mktemp)
  previous=$(mktemp)
  if [[ -e "$SSH_SNIPPET" ]]; then
    cp -a "$SSH_SNIPPET" "$previous"
    had_previous=1
  fi
  cat > "$tmp" <<EOF2
# Gerenciado pelo OnePlus.
# Personalizações isoladas para preservar o sshd_config do Ubuntu.
PasswordAuthentication ${password_auth}
PermitRootLogin ${root_login}
MaxSessions ${max_sessions}
MaxStartups ${max_startups}
ClientAliveInterval 120
ClientAliveCountMax 2
DebianBanner no
EOF2
  install -m 0644 "$tmp" "$SSH_SNIPPET"
  rm -f "$tmp"

  if ssh_apply_current_config; then
    rm -f "$previous"
    return 0
  fi

  warn "Revertendo automaticamente a alteração do OpenSSH."
  if (( had_previous )); then
    install -m 0644 "$previous" "$SSH_SNIPPET"
  else
    rm -f "$SSH_SNIPPET"
  fi
  rm -f "$previous"
  openssh_config_test || error "A configuração OpenSSH anterior também contém erro."
  return 1
}

module_ssh() {
  while true; do
    clear
    printf "%bOnePlus • OpenSSH%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    printf "Serviço: %s\n" "$(service_state ssh.service)"
    printf "Portas:  %s\n\n" "$(ss -lntp 2>/dev/null | awk '/sshd|ssh/ {print $4}' | paste -sd ', ' - || true)"
    printf "1) Ver configuração efetiva\n"
    printf "2) Aplicar perfil compatível (senha habilitada; root por senha desabilitado)\n"
    printf "3) Aplicar perfil legado controlado (senha + root habilitados)\n"
    printf "4) Remover configuração OnePlus do SSH\n"
    printf "5) Testar configuração (sshd -t)\n"
    printf "0) Voltar\n\nEscolha: "
    read -r opt
    case "$opt" in
      1) sshd -T | sort | less ;;
      2)
        ssh_write_snippet yes prohibit-password 100 "100:30:200"
        pause
        ;;
      3)
        warn "Este perfil permite login root com senha. Use apenas se seu ambiente realmente exigir."
        printf "Digite HABILITAR para confirmar: "
        read -r confirm
        if [[ "$confirm" == "HABILITAR" ]]; then
          ssh_write_snippet yes yes 200 "200:30:400"
        else
          info "Operação cancelada."
        fi
        pause
        ;;
      4)
        if [[ -e "$SSH_SNIPPET" ]]; then
          backup=$(mktemp)
          cp -a "$SSH_SNIPPET" "$backup"
          rm -f "$SSH_SNIPPET"
          if ssh_apply_current_config; then
            rm -f "$backup"
          else
            warn "Falha ao aplicar remoção; restaurando o snippet OnePlus."
            install -m 0644 "$backup" "$SSH_SNIPPET"
            rm -f "$backup"
          fi
        else
          info "Nenhuma configuração OnePlus encontrada."
        fi
        pause
        ;;
      5) openssh_config_test && ok "OpenSSH OK" || error "OpenSSH contém erro"; pause ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
}
