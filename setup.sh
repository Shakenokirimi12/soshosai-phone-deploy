#!/usr/bin/env bash
#
# Soshosai Phone — Production Server Setup
# =========================================
# FreePBX(Asterisk) + Flexisip + Redis を構成し、
# iOS アプリへの VoIP プッシュ着信を実現する。
#
# 前提: Debian 12, FreePBX 17 + Asterisk, Redis, root 実行
#
# 使い方:
#   wget -qO- https://raw.githubusercontent.com/Shakenokirimi12/soshosai-phone-deploy/main/setup.sh | bash
#   または:
#   wget https://raw.githubusercontent.com/Shakenokirimi12/soshosai-phone-deploy/main/setup.sh
#   bash setup.sh
#
# IP は自動検出。上書きしたい場合は環境変数で:
#   EXTERNAL_IP=203.0.113.1 BIND_IP=10.0.0.5 bash setup.sh

set -euo pipefail

# ─────────────────────────────────────────────
# IP 自動検出（環境変数で上書き可能）
# ─────────────────────────────────────────────
detect_external_ip() {
    curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
        || curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -s --max-time 5 https://checkip.amazonaws.com 2>/dev/null \
        || { echo ""; return 1; }
}

detect_bind_ip() {
    ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' \
        || hostname -I 2>/dev/null | awk '{print $1}' \
        || { echo ""; return 1; }
}

EXTERNAL_IP="${EXTERNAL_IP:-$(detect_external_ip)}"
BIND_IP="${BIND_IP:-$(detect_bind_ip)}"

if [ -z "${EXTERNAL_IP}" ]; then
    echo "ERROR: グローバル IP を検出できません"
    echo "  EXTERNAL_IP=x.x.x.x bash $0"
    exit 1
fi
if [ -z "${BIND_IP}" ]; then
    echo "ERROR: LAN IP を検出できません"
    echo "  BIND_IP=x.x.x.x bash $0"
    exit 1
fi

# デフォルト値（通常変更不要）
SIP_DOMAIN="${SIP_DOMAIN:-sip.soshosai.com}"
FLEXISIP_PORT="${FLEXISIP_PORT:-5070}"
ASTERISK_PORT="${ASTERISK_PORT:-5060}"
WORKER_URL="${WORKER_URL:-https://soshosai-phone-provision.shakenokirimi12.workers.dev}"
REDIS_HOST="${REDIS_HOST:-localhost}"
REDIS_PORT="${REDIS_PORT:-6379}"
REG_EXPIRES="${REG_EXPIRES:-2592000}"

# ─────────────────────────────────────────────
# 確認
# ─────────────────────────────────────────────
echo "=== Soshosai Phone Setup ==="
echo ""
echo "  External IP : ${EXTERNAL_IP}  (自動検出)"
echo "  Bind IP     : ${BIND_IP}  (自動検出)"
echo "  SIP Domain  : ${SIP_DOMAIN}"
echo "  Flexisip    : :${FLEXISIP_PORT}"
echo "  Asterisk    : :${ASTERISK_PORT}"
echo "  Redis       : ${REDIS_HOST}:${REDIS_PORT}"
echo "  登録有効期限 : $(( REG_EXPIRES / 86400 ))日"
echo ""
echo "  ※ 上書き: EXTERNAL_IP=x.x.x.x BIND_IP=y.y.y.y bash $0"
echo ""
read -rp "この設定で続行しますか？ [y/N] " yn
[[ "${yn}" =~ ^[Yy]$ ]] || { echo "中止"; exit 1; }

# ─────────────────────────────────────────────
# 1. Redis 確認
# ─────────────────────────────────────────────
echo ""
echo "[1/5] Redis 確認..."
if ! redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" ping 2>/dev/null | grep -q PONG; then
    echo "  Redis が動いていません。インストールします..."
    apt-get update -qq && apt-get install -y -qq redis-server
    systemctl enable --now redis-server
fi
echo "  OK"

# RDB 永続化チェック
RDB_CONF=$(redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" config get save 2>/dev/null | tail -1)
if [ -z "${RDB_CONF}" ]; then
    redis-cli config set save "3600 1 300 100 60 10000" >/dev/null
    redis-cli config rewrite >/dev/null 2>&1 || true
    echo "  RDB 永続化を有効化しました"
fi

# ─────────────────────────────────────────────
# 2. Flexisip インストール
# ─────────────────────────────────────────────
echo ""
echo "[2/5] Flexisip..."
if dpkg -l 2>/dev/null | grep -q bc-flexisip; then
    echo "  既にインストール済み ($(dpkg -l | grep bc-flexisip | awk '{print $3}'))"
else
    echo "  インストール中..."
    if [ ! -f /usr/share/keyrings/belledonne-archive-keyring.gpg ]; then
        curl -fsSL https://download.linphone.org/snapshots/debian/pubkey.gpg \
            | gpg --dearmor -o /usr/share/keyrings/belledonne-archive-keyring.gpg
    fi
    echo "deb [arch=amd64, signed-by=/usr/share/keyrings/belledonne-archive-keyring.gpg] https://download.linphone.org/snapshots/debian bookworm stable" \
        > /etc/apt/sources.list.d/belledonne.list
    apt-get update -qq && apt-get install -y -qq bc-flexisip
    echo "  完了"
fi

# ─────────────────────────────────────────────
# 3. Flexisip 設定
# ─────────────────────────────────────────────
echo ""
echo "[3/5] Flexisip 設定..."

FLEXISIP_CONF="/etc/flexisip/flexisip.conf"
ROUTES_CONF="/etc/flexisip/routes.conf"

[ -f "${FLEXISIP_CONF}" ] && cp -n "${FLEXISIP_CONF}" "${FLEXISIP_CONF}.bak.$(date +%s)" 2>/dev/null || true
[ -f "${ROUTES_CONF}" ] && cp -n "${ROUTES_CONF}" "${ROUTES_CONF}.bak.$(date +%s)" 2>/dev/null || true

mkdir -p /etc/flexisip

cat > "${FLEXISIP_CONF}" << FLEXISIP_EOF
[global]
transports=sip:${EXTERNAL_IP}:${FLEXISIP_PORT};maddr=${BIND_IP};transport=udp sip:${EXTERNAL_IP}:${FLEXISIP_PORT};maddr=${BIND_IP};transport=tcp
aliases=${EXTERNAL_IP}:${FLEXISIP_PORT} ${SIP_DOMAIN}
default-servers=proxy
log-level=warning

[module::Registrar]
enabled=true
reg-domains=${SIP_DOMAIN}
max-contacts-by-aor=5
max-expires=${REG_EXPIRES}
db-implementation=redis
redis-server-domain=${REDIS_HOST}
redis-server-port=${REDIS_PORT}

[module::PushNotification]
enabled=true
external-push-uri=${WORKER_URL}/sip-push?type=\$type&token=\$token&app-id=\$app-id&event=\$event&call-id=\$call-id&from-name=\$from-name&from-uri=\$from-uri
external-push-method=GET
external-push-protocol=http2

[module::Router]
enabled=true
fork-late=true
fallback-route=sip:${BIND_IP}:${ASTERISK_PORT};transport=udp
fallback-route-filter=from.uri.domain != 'pbx.internal'

[module::Forward]
enabled=true
routes-config-path=${ROUTES_CONF}

[module::MediaRelay]
enabled=false

[module::Authentication]
enabled=false

[module::NatHelper]
enabled=true
fix-record-routes=false
fix-record-routes-policy=always
FLEXISIP_EOF

cat > "${ROUTES_CONF}" << ROUTES_EOF
<sip:${BIND_IP}:${ASTERISK_PORT};transport=udp>   request.uri.domain == '${SIP_DOMAIN}' && from.uri.domain != 'pbx.internal'
ROUTES_EOF

systemctl enable flexisip-proxy 2>/dev/null
systemctl restart flexisip-proxy
sleep 1
if systemctl is-active --quiet flexisip-proxy; then
    echo "  OK"
else
    echo "  ERROR: 起動失敗"; journalctl -u flexisip-proxy --no-pager -n 10; exit 1
fi

# ─────────────────────────────────────────────
# 4. Asterisk — Flexisip トランク
# ─────────────────────────────────────────────
echo ""
echo "[4/5] Asterisk..."

PJSIP_CUSTOM="/etc/asterisk/pjsip_custom_post.conf"
EXT_CUSTOM="/etc/asterisk/extensions_custom.conf"

if [ -f "${PJSIP_CUSTOM}" ] && grep -q "flexisip-trunk" "${PJSIP_CUSTOM}"; then
    echo "  flexisip-trunk 既存 — スキップ"
else
    [ -f "${PJSIP_CUSTOM}" ] && cp "${PJSIP_CUSTOM}" "${PJSIP_CUSTOM}.bak.$(date +%s)"
    cat >> "${PJSIP_CUSTOM}" << PJSIP_EOF

; === Soshosai Phone: Flexisip trunk ===
[flexisip-trunk]
type=endpoint
context=from-internal
allow=!all,ulaw,alaw,g722
trust_id_inbound=yes
rewrite_contact=yes
media_address=${EXTERNAL_IP}
rtp_symmetric=yes
force_rport=yes
direct_media=no
from_domain=pbx.internal
aors=flexisip-trunk-aor
outbound_proxy=sip:${BIND_IP}:${FLEXISIP_PORT}\;lr\;transport=udp

[flexisip-trunk-aor]
type=aor
contact=sip:${BIND_IP}:${FLEXISIP_PORT}

[flexisip-trunk-identify]
type=identify
endpoint=flexisip-trunk
match=${BIND_IP}
PJSIP_EOF
    echo "  flexisip-trunk 追加完了"
fi

if [ -f "${EXT_CUSTOM}" ] && grep -q "from-internal-custom" "${EXT_CUSTOM}"; then
    echo "  from-internal-custom 既存 — スキップ"
else
    [ -f "${EXT_CUSTOM}" ] && cp "${EXT_CUSTOM}" "${EXT_CUSTOM}.bak.$(date +%s)"
    cat >> "${EXT_CUSTOM}" << EXT_EOF

; === Soshosai Phone: モバイル内線ルール(1000-1999 ワイルドカード) ===
[from-internal-custom]
exten => _1XXX,1,Dial(PJSIP/flexisip-trunk/sip:\${EXTEN}@${SIP_DOMAIN},60)
 same => n,Hangup()
EXT_EOF
    echo "  ワイルドカードルール追加完了"
fi

if command -v fwconsole &>/dev/null; then
    fwconsole reload 2>/dev/null || true
else
    asterisk -rx "core reload" 2>/dev/null || true
fi
echo "  リロード完了"

# ─────────────────────────────────────────────
# 5. ポート
# ─────────────────────────────────────────────
echo ""
echo "[5/5] ルーターで以下を NAT 転送してください:"
echo ""
echo "  ${EXTERNAL_IP}:${FLEXISIP_PORT}/udp,tcp → ${BIND_IP}:${FLEXISIP_PORT}  (SIP)"
echo "  ${EXTERNAL_IP}:10000-20000/udp          → ${BIND_IP}:10000-20000       (RTP)"
echo ""
echo "  DNS: ${SIP_DOMAIN} → ${EXTERNAL_IP}"

# ─────────────────────────────────────────────
echo ""
echo "==========================================="
echo " 完了"
echo "==========================================="
echo ""
echo "内線: 1000-1999 はワイルドカードで自動ルーティング済み"
echo "管理画面: https://soshosai-phone-provision.shakenokirimi12.workers.dev/admin"
echo ""
echo "確認:"
echo "  redis-cli keys 'fs:*'                    # 登録データ"
echo "  asterisk -rx 'pjsip show endpoints'      # Asterisk"
echo "  tail -f /var/opt/belledonne-communications/log/flexisip/flexisip-proxy.log"
echo ""
