# VyOS ProtonVPN Wireguard Rotation Script

This repository contains a script that will log, monitor, and rotate a ProtonVPN WireGuard connection on a VyOS firewall.  It also has a --next flag that allows you to manually switch to the next VPN.  You will need to create multiple standard and/or secure core peer configs in the ProtonVPN portal that this script will use to rotate through.

I've run into issues where my ProtonVPN WireGuard tunnels will stop performing handshakes and passing traffic, sometimes because there is maintenance on the ProtonVPN end and sometimes for reasons unknown.  I found that I would need to delete the WireGuard interface and commit the changes, then re-add it in order to get traffic flowing again.  I decided to create multiple secure core configs, and create a script to perform tests and automate this process.

I recommend changing file ownership to vyos:vyattacfg to avoid any permissions issues with running, modifying, and saving the VyOS configuration.

You can view a full VyOS config with policy based routing and a ProtonVPN WireGuard tunnel [here](https://github.com/nicodemus84/vyos-protonvpn-wireguard-config).

ProtonVPN currently hardcodes their clients to use the same internal IP address of 10.2.0.2.  Therefore, you will need to configure your WireGuard interface with this IP as well.

https://protonvpn.com/support/wireguard-privacy

---

### Login to ProtonVPN and create your WireGuard connections.

Navigate to https://account.protonvpn.com/downloads and scroll down to the WireGuard section.

    1. Enter an appropriate name (ie. US#47 or CH-NL)
    2. Select 'Router'
    3. Select VPN Options - N/A, these settings only work with the ProtonVPN client apps 
    4. Select your standard server or secure core server
    5. Select 'Create'

A config will be generated.  Repeat that process as many times as you'd like.  I'm currently running 3 European secure core peers - using each of their 3 secure core backbone servers located in Iceland, Switzterland, and Sweden for a certain level of redundancy.

Your configs will look like this (fake/invalid keys):

```
[Interface]
# Key for CH-SI
# NetShield = 1
# Moderate NAT = off
# NAT-PMP (Port Forwarding) = off
# VPN Accelerator = on
PrivateKey = UFfupZwMuBB9B0E0BWdl0BUC/9IlLQu6ClA4qPClw=
Address = 10.2.0.2/32
DNS = 10.2.0.1

[Peer]
# CH-SI
PublicKey = OyElFys0B0k2Kx9UjgoZ1lIjpltqS135wO2UTgl0M=
AllowedIPs = 0.0.0.0/0
Endpoint = 1.1.1.1:51820
```

You will copy out the PrivateKey, PublicKey, and Endpoint for use with this script.

---

### Setup the script and key files

Create your public and private key files for each of your WireGuard peers in /config/auth/wireguard/ and then set ownership and permissions.

```
sudo touch /config/auth/wireguard/CH-SI.pub
sudo touch /config/auth/wireguard/CH-SI.priv
sudo touch /config/auth/wireguard/IS-BE.pub
sudo touch /config/auth/wireguard/IS-BE.priv
sudo touch /config/auth/wireguard/SE-FI.pub
sudo touch /config/auth/wireguard/SE-FI.priv
sudo chown vyos:vyattacfg /config/auth/wireguard/*
chmod 600 /config/auth/wireguard/*
```

You can then copy the PrivateKey string into your .priv files and the PublicKey string into your .pub files accordingly.

### Create the script file at /config/scripts/wg-watchdog.sh, the log files in /var/log/, and then set ownership and permissions.

```
sudo touch /config/scripts/wg-watchdog.sh
sudo touch /var/log/wg-watchdog.log
sudo touch /var/log/wg-watchdog.debug.log
sudo chown vyos:vyattacfg /config/scripts/wg-watchdog.sh
sudo chown vyos:vyattacfg /var/log/wg-watchdog*
chmod 755 /config/scripts/wg-watchdog.sh
chmod 644 /var/log/wg-watchdog*
```

You can then add the below script, and update it with your peer information:

```
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

### SET THE VPN ORDER AND ADD PEER INFO
VPN_ORDER=("CH-SI" "IS-BE" "SE-FI")
declare -A VPN_CONFIGS=(
    ["CH-SI"]="1.1.1.1|/config/auth/wireguard/CH-SI.pub|/config/auth/wireguard/CH-SI.priv"
    ["IS-BE"]="2.2.2.2|/config/auth/wireguard/IS-BE.pub|/config/auth/wireguard/IS-BE.priv"
    ["SE-FI"]="3.3.3.3|/config/auth/wireguard/SE-FI.pub|/config/auth/wireguard/SE-FI.priv"
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
```

The part you will need to edit is the section below.

We create a VPN order with your 3 WireGuard peers.  Update them with the same name you used when creating them to keep things simple.

We then create an array with a '|' delimiter for each of the peers.
- The first field is the peer Endpoint
- The second field is the path to the peer PublicKey file
- The third field is the path to the peer PrivateKey file

```
VPN_ORDER=("CH-SI" "IS-BE" "SE-FI")
declare -A VPN_CONFIGS=(
    ["CH-SI"]="1.1.1.1|/config/auth/wireguard/CH-SI.pub|/config/auth/wireguard/CH-SI.priv"
    ["IS-BE"]="2.2.2.2|/config/auth/wireguard/IS-BE.pub|/config/auth/wireguard/IS-BE.priv"
    ["SE-FI"]="3.3.3.3|/config/auth/wireguard/SE-FI.pub|/config/auth/wireguard/SE-FI.priv"
)
```

---

# The script has the following features:

1) The VyOS interface used is wg1
2) The active VPN is tracked in /tmp/wg_active
3) A lock file is used to prevent any race conditions when run via a cron or manually
4) A auto truncating log file at /var/log/wg-watchdog.log
5) A debug log file for troubleshooting purposes (uncomment the OPTIONAL DEBUGGING lines)
6) Can add a cron job for the vyos user to have the script run and update the log every minute (see below)
7) A --next flag to move to the next VPN manually ( /config/scripts/wg-watchdog.sh --next )
8) A ping test to 8.8.8.8 out the wg1 interface.  If it fails, the script will delete, then re-add the interface using the next peer

---

### Please note that the line in the script to save the config is run with sudo, otherwise you will get a permissions error in the log.

```
sudo /opt/vyatta/sbin/vyatta-cfg-cmd-wrapper save
```

You can view the log with:

```
tail -f /var/log/wg-watchdog.sh
```

You can view the WireGuard tunnel status with:

```
sudo wg show
```
