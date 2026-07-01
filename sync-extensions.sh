#!/usr/bin/env bash
#
# Soshosai Phone — FreePBX Extension Sync
# ========================================
# Worker D1 のユーザー一覧を FreePBX に同期する。
# テストサーバーと本番サーバーの両方に対応。
#
# 使い方:
#   bash sync-extensions.sh                    # 両方のサーバーに同期
#   bash sync-extensions.sh --test             # テストサーバーのみ
#   bash sync-extensions.sh --prod             # 本番サーバーのみ
#   bash sync-extensions.sh --dry-run          # 変更せずプレビュー
#
# 環境変数で上書き可能:
#   ADMIN_TOKEN=xxx bash sync-extensions.sh

set -euo pipefail

# ─── 設定 ───
WORKER_URL="${WORKER_URL:-https://soshosai-phone-provision.shakenokirimi12.workers.dev}"
ADMIN_TOKEN="${ADMIN_TOKEN:-soshosai-phone-admin-2026}"

TEST_HOST="192.168.100.18"
TEST_PORT="22"
TEST_USER="root"

PROD_HOST="162.43.76.36"
PROD_PORT="6364"
PROD_USER="soshosai"

DRY_RUN=false
SYNC_TEST=true
SYNC_PROD=true

# ─── 引数解析 ───
for arg in "$@"; do
    case "$arg" in
        --test)     SYNC_PROD=false ;;
        --prod)     SYNC_TEST=false ;;
        --dry-run)  DRY_RUN=true ;;
        --help|-h)
            echo "Usage: $0 [--test|--prod] [--dry-run]"
            exit 0 ;;
    esac
done

echo "=== Soshosai Phone Extension Sync ==="
echo ""
echo "  Worker : ${WORKER_URL}"
echo "  Test   : ${SYNC_TEST} (${TEST_USER}@${TEST_HOST}:${TEST_PORT})"
echo "  Prod   : ${SYNC_PROD} (${PROD_USER}@${PROD_HOST}:${PROD_PORT})"
echo "  Dry-run: ${DRY_RUN}"
echo ""

# ─── Worker から内線一覧取得 ───
echo "[1] Worker から内線情報を取得..."
CSV=$(curl -sf -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${WORKER_URL}/admin/export-extensions")

if [ -z "$CSV" ]; then
    echo "ERROR: 内線情報の取得に失敗しました"
    exit 1
fi

# CSV をパース (header をスキップ)
EXTENSIONS=()
NAMES=()
SECRETS=()
while IFS=, read -r ext name tech secret context rest; do
    [ "$ext" = "extension" ] && continue  # header
    EXTENSIONS+=("$ext")
    # CSV quoted name handling
    name="${name#\"}"
    name="${name%\"}"
    NAMES+=("$name")
    SECRETS+=("$secret")
done <<< "$CSV"

echo "  ${#EXTENSIONS[@]} 件の内線を取得"
echo ""

# ─── FreePBX 同期関数 ───
sync_to_server() {
    local label="$1"
    local host="$2"
    local port="$3"
    local user="$4"
    local use_sudo="$5"

    echo "[${label}] ${host}:${port} に同期中..."

    local sudo_prefix=""
    if [ "$use_sudo" = "true" ]; then
        sudo_prefix="sudo"
    fi

    # 既存の内線を取得
    local existing
    existing=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p "$port" "${user}@${host}" \
        "${sudo_prefix} asterisk -rx 'pjsip show endpoints'" 2>/dev/null \
        | grep -oE 'Endpoint: +[0-9]{4}/' | grep -oE '[0-9]{4}' || echo "")

    local created=0
    local skipped=0
    local failed=0

    for i in "${!EXTENSIONS[@]}"; do
        local ext="${EXTENSIONS[$i]}"
        local name="${NAMES[$i]}"
        local secret="${SECRETS[$i]}"

        if echo "$existing" | grep -qx "$ext"; then
            ((skipped++))
            continue
        fi

        echo "  + ${ext} (${name})"

        if [ "$DRY_RUN" = "true" ]; then
            ((created++))
            continue
        fi

        # FreePBX PHP API で内線作成
        local php_cmd="<?php
\\\$bootstrap = '/etc/freepbx.conf';
if (!file_exists(\\\$bootstrap)) \\\$bootstrap = '/etc/asterisk/freepbx.conf';
include \\\$bootstrap;
\\\$r = FreePBX::Core()->processQuickCreate('pjsip', '${ext}', [
    'name' => '${name}',
    'secret' => '${secret}',
    'tech' => 'pjsip',
    'vm' => 'disabled',
]);
echo json_encode(\\\$r);
?>"

        local result
        result=$(ssh -o StrictHostKeyChecking=no -p "$port" "${user}@${host}" \
            "${sudo_prefix} php -r \"${php_cmd}\"" 2>&1) || true

        if echo "$result" | grep -q '"status":true\|"status":"true"'; then
            ((created++))
        elif echo "$result" | grep -qi 'error\|fatal\|exception'; then
            echo "    WARN: ${result}"
            ((failed++))
        else
            ((created++))
        fi
    done

    if [ "$created" -gt 0 ] && [ "$DRY_RUN" = "false" ]; then
        echo "  リロード中..."
        ssh -o StrictHostKeyChecking=no -p "$port" "${user}@${host}" \
            "${sudo_prefix} fwconsole reload 2>/dev/null || ${sudo_prefix} asterisk -rx 'core reload'" 2>/dev/null || true
    fi

    echo "  完了: 作成=${created} スキップ=${skipped} 失敗=${failed}"
    echo ""
}

# ─── 実行 ───
if [ "$SYNC_TEST" = "true" ]; then
    sync_to_server "TEST" "$TEST_HOST" "$TEST_PORT" "$TEST_USER" "false"
fi

if [ "$SYNC_PROD" = "true" ]; then
    sync_to_server "PROD" "$PROD_HOST" "$PROD_PORT" "$PROD_USER" "true"
fi

echo "=== 同期完了 ==="
