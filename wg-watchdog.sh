#!/bin/bash

##### VARIABLE DECLARATION
WG_INTERFACE="wg1"
PING_TIMEOUT=15
STATUS_FILE="/tmp/wg_active"
LOCK_FILE="/tmp/wg-watchdog.lock"
LOG_FILE="/var/log/wg-watchdog.log"
MAX_LOG_SIZE=1000000
LOCK_TIMEOUT=60
FORCE_NEXT=0

##### SET THE VPN ORDER AND ADD PEER INFO
VPN_ORDER=("CH-SI" "IS-BE" "SE-FI")
declare -A VPN_CONFIGS=(
    ["CH-AT"]="1.1.1.1|/config/auth/wireguard/CH-SI.pub|/config/auth/wireguard/CH-SI.priv"
    ["CH-IE"]="2.2.2.2|/config/auth/wireguard/IS-BE.pub|/config/auth/wireguard/IS-BE.priv"
    ["CH-BA"]="3.3.3.3|/config/auth/wireguard/SE-FI.pub|/config/auth/wireguard/SE-FI.priv"
)

##### OPTIONAL DEBUGGING
#set -x
#exec > /var/log/wg-watchdog-debug.log 2>&1

##### TRAP AND CLEANUP
cleanup() { rm -f "$LOCK_FILE"; }
trap cleanup EXIT INT TERM

##### LOG MAINTENANCE
if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE")" -gt "$MAX_LOG_SIZE" ]; then
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] [INFO] Log file exceeded $MAX_LOG_SIZE bytes, truncating..." > "$LOG_FILE"
fi

##### LOCK FILE
if [ -f "$LOCK_FILE" ]; then
    if [[ "$1" == "--next" ]]; then
        echo "[$(date "+%Y-%m-%d %H:%M:%S")] [INFO] Lock detected. Waiting..." >> "$LOG_FILE"
        for ((i=0; i<LOCK_TIMEOUT; i++)); do
            sleep 1
            [ ! -f "$LOCK_FILE" ] && break
        done
        if [ -f "$LOCK_FILE" ]; then
            echo "[$(date "+%Y-%m-%d %H:%M:%S")] [ERROR] Lock timeout. Aborting." >> "$LOG_FILE"
            exit 1
        fi
    else
        echo "[$(date "+%Y-%m-%d %H:%M:%S")] [ERROR] Another instance is running. Exiting." >> "$LOG_FILE"
        exit 1
    fi
fi
echo $$ > "$LOCK_FILE"

##### MANUAL VPN SWITCH CONTROL
[[ "$1" == "--next" ]] && FORCE_NEXT=1

##### READ CURRENT VPN
if [ -f "$STATUS_FILE" ]; then
    CURRENT_VPN=$(<"$STATUS_FILE")
fi

##### SET CURRENT VPN IF VPN NOT ACTIVE
if [[ -z "$CURRENT_VPN" || -z "${VPN_CONFIGS[$CURRENT_VPN]}" ]]; then
    CURRENT_VPN="CH-BA"
    echo "$CURRENT_VPN" > "$STATUS_FILE"
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] [INFO] No valid VPN set, defaulting to CH-BA." >> "$LOG_FILE"
fi

##### VPN SWITCH LOGIC
if [[ "$FORCE_NEXT" -eq 0 ]]; then
    if timeout "$PING_TIMEOUT" ping -I "$WG_INTERFACE" -c 5 8.8.8.8 &>/dev/null; then
        echo "[$(date "+%Y-%m-%d %H:%M:%S")] VPN $CURRENT_VPN is working fine. No switch needed." >> "$LOG_FILE"
        exit 0
    else
        echo "[$(date "+%Y-%m-%d %H:%M:%S")] Ping failed. Initiating VPN switch..." >> "$LOG_FILE"
    fi
else
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] Manual switch requested (--next)." >> "$LOG_FILE"
fi

##### READ NEXT VPN
for ((i=0; i<${#VPN_ORDER[@]}; i++)); do
    if [[ "${VPN_ORDER[$i]}" == "$CURRENT_VPN" ]]; then
        NEXT_VPN="${VPN_ORDER[$(((i + 1) % ${#VPN_ORDER[@]}))]}"
        break
    fi
done

IFS='|' read -r ADDR PUBKEY_FILE PRIVKEY_FILE <<< "${VPN_CONFIGS[$NEXT_VPN]}"

##### SET VARIABLES FROM KEY FILES
if ! PRIVKEY=$(<"$PRIVKEY_FILE"); then
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] ERROR: Missing private key at $PRIVKEY_FILE" >> "$LOG_FILE"
    exit 1
fi
if ! PUBKEY=$(<"$PUBKEY_FILE"); then
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] ERROR: Missing public key at $PUBKEY_FILE" >> "$LOG_FILE"
    exit 1
fi

##### LOG START OF VPN SWITCH PROCESS
echo "[$(date "+%Y-%m-%d %H:%M:%S")] Switching to $NEXT_VPN" >> "$LOG_FILE"

##### DELETE WIREGUARD INTERFACE AND COMMIT
/opt/vyatta/sbin/vyatta-cfg-cmd-wrapper begin
/opt/vyatta/sbin/vyatta-cfg-cmd-wrapper delete interfaces wireguard "$WG_INTERFACE"
/opt/vyatta/sbin/vyatta-cfg-cmd-wrapper commit

##### SET WIREGUARD INTERFACE AND COMMIT
/opt/vyatta/sbin/vyatta-cfg-cmd-wrapper set interfaces wireguard "$WG_INTERFACE" description "PROTONVPN"
/opt/vyatta/sbin/vyatta-cfg-cmd-wrapper set interfaces wireguard "$WG_INTERFACE" address "10.2.0.2/32"
/opt/vyatta/sbin/vyatta-cfg-cmd-wrapper set interfaces wireguard "$WG_INTERFACE" private-key "$PRIVKEY"
/opt/vyatta/sbin/vyatta-cfg-cmd-wrapper set interfaces wireguard "$WG_INTERFACE" peer "$NEXT_VPN" address "$ADDR"
/opt/vyatta/sbin/vyatta-cfg-cmd-wrapper set interfaces wireguard "$WG_INTERFACE" peer "$NEXT_VPN" public-key "$PUBKEY"
/opt/vyatta/sbin/vyatta-cfg-cmd-wrapper set interfaces wireguard "$WG_INTERFACE" peer "$NEXT_VPN" allowed-ips "0.0.0.0/0"
/opt/vyatta/sbin/vyatta-cfg-cmd-wrapper set interfaces wireguard "$WG_INTERFACE" peer "$NEXT_VPN" persistent-keepalive "20"
/opt/vyatta/sbin/vyatta-cfg-cmd-wrapper set interfaces wireguard "$WG_INTERFACE" peer "$NEXT_VPN" port "51820"
/opt/vyatta/sbin/vyatta-cfg-cmd-wrapper commit
sudo /opt/vyatta/sbin/vyatta-cfg-cmd-wrapper save
/opt/vyatta/sbin/vyatta-cfg-cmd-wrapper end

##### LOG AND UPDATE STATUS FILE
echo "[$(date "+%Y-%m-%d %H:%M:%S")] Switched WireGuard to $NEXT_VPN" >> "$LOG_FILE"
echo "$NEXT_VPN" > "$STATUS_FILE"
exit 0
