#!/bin/bash

set -e

CONFIG_FILE=/etc/sing-box/config.json
CLIENT_INFO_FILE=/etc/sing-box/reality-client.txt
QR_PNG_FILE=/etc/sing-box/reality-client.png
DEFAULT_CAMOUFLAGE=www.microsoft.com
DEFAULT_PORT=10443

ensure_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 运行此脚本"
    exit 1
  fi
}

install_deps() {
  echo "安装环境依赖"
  apt update
  apt install -y jq uuid-runtime vim curl gawk openssl qrencode
}

install_sing_box() {
  echo "开始安装 sing-box 核心"
  bash <(curl -fsSL https://sing-box.app/deb-install.sh)
  systemctl enable sing-box
  echo "sing-box 安装完成"
}

gen_reality_keys() {
  local key_output
  key_output=$(sing-box generate reality-keypair)
  PRIVATE_KEY=$(printf "%s\n" "$key_output" | awk -F': ' '/PrivateKey/{print $2}')
  PUBLIC_KEY=$(printf "%s\n" "$key_output" | awk -F': ' '/PublicKey/{print $2}')
  if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo "生成 Reality 密钥失败"
    exit 1
  fi
}

write_config() {
  cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "name": "default",
          "uuid": "${UUID}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${CAMOUFLAGE_DOMAIN}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${CAMOUFLAGE_DOMAIN}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "auto_detect_interface": true
  }
}
EOF
}

write_client_info() {
  mkdir -p /etc/sing-box
  cat > "$CLIENT_INFO_FILE" <<EOF
SERVER=${SERVER_HOST}
PORT=${PORT}
UUID=${UUID}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
SNI=${CAMOUFLAGE_DOMAIN}
SHADOWROCKET_URI=vless://${UUID}@${SERVER_HOST}:${PORT}?encryption=none&security=reality&sni=${CAMOUFLAGE_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#reality-${SERVER_HOST}
EOF
}

show_client_info() {
  if [ ! -f "$CLIENT_INFO_FILE" ]; then
    echo "未找到客户端配置，请先安装/生成配置"
    return 1
  fi
  cat "$CLIENT_INFO_FILE"
}

gen_shadowrocket_uri() {
  if [ ! -f "$CLIENT_INFO_FILE" ]; then
    echo "未找到客户端配置，请先安装/生成配置"
    return 1
  fi
  grep '^SHADOWROCKET_URI=' "$CLIENT_INFO_FILE" | cut -d= -f2-
}

gen_qrcode() {
  if [ ! -f "$CLIENT_INFO_FILE" ]; then
    echo "未找到客户端配置，请先安装/生成配置"
    return 1
  fi

  local uri
  uri=$(gen_shadowrocket_uri)

  if ! command -v qrencode >/dev/null 2>&1; then
    echo "未安装 qrencode，请先执行安装流程或手动安装 qrencode"
    return 1
  fi

  echo "终端二维码如下(可直接扫码):"
  qrencode -t ANSIUTF8 "$uri"

  qrencode -o "$QR_PNG_FILE" -s 8 -m 2 "$uri"
  echo "二维码 PNG 已生成: $QR_PNG_FILE"
}

install_and_run() {
  install_sing_box
  install_deps

  read -p "请输入客户端连接服务器地址(域名或IP): " SERVER_HOST
  if [ -z "$SERVER_HOST" ]; then
    echo "服务器地址不能为空"
    exit 1
  fi

  read -p "请输入 Reality 监听端口 [默认 ${DEFAULT_PORT}]: " PORT
  PORT=${PORT:-$DEFAULT_PORT}

  read -p "请输入 Reality 伪装域名/SNI [默认 ${DEFAULT_CAMOUFLAGE}]: " CAMOUFLAGE_DOMAIN
  CAMOUFLAGE_DOMAIN=${CAMOUFLAGE_DOMAIN:-$DEFAULT_CAMOUFLAGE}

  UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
  SHORT_ID=$(openssl rand -hex 8)

  gen_reality_keys

  if [ -f "$CONFIG_FILE" ]; then
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak-$(date +%Y%m%d-%H%M%S)"
    echo "已备份旧配置"
  fi

  write_config
  write_client_info

  echo "检查 sing-box 配置"
  sing-box check -c "$CONFIG_FILE"

  echo "重启 sing-box"
  systemctl restart sing-box
  sleep 2

  echo "安装完成，当前客户端参数如下："
  show_client_info
  echo
  gen_qrcode || true
}

uninstall() {
  echo "开始卸载 sing-box"
  rm -rf /usr/bin/sing-box
  rm -rf /etc/sing-box
  rm -rf /etc/systemd/system/sing-box.service
  systemctl daemon-reload || true
  echo "卸载完成"
}

start_sing_box() {
  systemctl start sing-box
}

stop_sing_box() {
  systemctl stop sing-box
}

restart_sing_box() {
  systemctl restart sing-box
}

status_sing_box() {
  systemctl status sing-box --no-pager
}

log_sing_box() {
  journalctl -u sing-box --output cat -e -n 200
}

edit_config() {
  vim "$CONFIG_FILE"
}

show_config_summary() {
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "未找到配置文件: $CONFIG_FILE"
    return 1
  fi
  jq '{
    listen_port: .inbounds[0].listen_port,
    uuid: .inbounds[0].users[0].uuid,
    server_name: .inbounds[0].tls.server_name,
    short_id: .inbounds[0].tls.reality.short_id[0]
  }' "$CONFIG_FILE"
}

init_menu() {
  echo "欢迎使用本脚本"
  echo "--- auto-reality ---
  0. 安装 sing-box 和 Reality(VLESS)
  1. 卸载 sing-box 和 Reality
————————————————
  2. 启动 sing-box
  3. 停止 sing-box
  4. 重启 sing-box
  5. 查看 sing-box 状态
————————————————
  6. 查看 sing-box 日志
  7. 编辑 sing-box 配置文件
  8. 查看客户端配置参数
  9. 生成 Shadowrocket 导入 URI
 10. 查看当前服务端配置摘要
 11. 生成二维码(终端+PNG)
"

  read -p "请输入选择[0-11]: " choice
  if grep '^[[:digit:]]*$' <<< "${choice}"; then
    if ((choice >= 0 && choice <= 11)); then
      case $choice in
        0) install_and_run ;;
        1) uninstall ;;
        2) start_sing_box ;;
        3) stop_sing_box ;;
        4) restart_sing_box ;;
        5) status_sing_box ;;
        6) log_sing_box ;;
        7) edit_config ;;
        8) show_client_info ;;
        9) gen_shadowrocket_uri ;;
        10) show_config_summary ;;
        11) gen_qrcode ;;
        *) echo "Invalid input. Please enter a number between 0 and 11." ;;
      esac
    else
      echo "错误，请输入正确的数字"
    fi
  else
    echo "错误，请输入正确的数字"
  fi
}

ensure_root
init_menu
