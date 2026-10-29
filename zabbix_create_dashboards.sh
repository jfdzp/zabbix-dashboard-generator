#!/bin/bash

# Zabbix per-site dashboard creator / updater
# Creates or updates a complete dashboard for each site.

ZABBIX_URL="https://localhost/api_jsonrpc.php"
ZABBIX_USER="zabbix-api"
ZABBIX_PASS=$(cat /etc/zabbix/.api_credentials)

echo "Authentication bei Zabbix API..."
AUTH_TOKEN=$(curl -k -s -X POST "$ZABBIX_URL" \
  -H "Content-Type: application/json" \
  -H "Host: zabbix.example.com" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.login\",\"params\":{\"username\":\"$ZABBIX_USER\",\"password\":\"$ZABBIX_PASS\"},\"id\":1}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['result'])")

if [ -z "$AUTH_TOKEN" ]; then
    echo "ERROR: Authentication failed."
    exit 1
fi
echo "Authentication successful."

# ============================================================
# Sites: code -> host group name
# ============================================================
declare -A SITES=(
    ["AA"]="Site A" ["BB"]="Site B" ["CC"]="Site C"
)

# ============================================================
# API Hilfsfunktionen
# ============================================================
api_call() {
    local METHOD="$1"
    local PARAMS="$2"
    curl -k -s -X POST "$ZABBIX_URL" \
      -H "Content-Type: application/json" \
      -H "Host: zabbix.example.com" \
      -H "Authorization: Bearer $AUTH_TOKEN" \
      -d "{\"jsonrpc\":\"2.0\",\"method\":\"$METHOD\",\"params\":$PARAMS,\"id\":1}"
}

get_group_id() {
    local GROUP_NAME="$1"
    api_call "hostgroup.get" "{\"filter\":{\"name\":[\"$GROUP_NAME\"]},\"output\":[\"groupid\"]}" \
      | python3 -c "import sys,json; r=json.load(sys.stdin)['result']; print(r[0]['groupid'] if r else '')"
}

get_host_id() {
    local HOSTNAME="$1"
    api_call "host.get" "{\"filter\":{\"host\":[\"$HOSTNAME\"]},\"output\":[\"hostid\"]}" \
      | python3 -c "import sys,json; r=json.load(sys.stdin)['result']; print(r[0]['hostid'] if r else '')"
}

# Finds a host by name prefix (z.B. PALNFW -> findet PALNFW02)
find_host_by_prefix() {
    local PREFIX="$1"
    local SUFFIX="$2"
    local RESULT=$(api_call "host.get" "{\"search\":{\"host\":\"${PREFIX}${SUFFIX}\"},\"startSearch\":1,\"output\":[\"hostid\",\"host\"]}" \
      | python3 -c "import sys,json; r=json.load(sys.stdin)['result']; print(r[0]['hostid']+'|'+r[0]['host'] if r else '|')")
    echo "$RESULT"
}

get_item_id() {
    local HOST_ID="$1"
    local ITEM_NAME_PATTERN="$2"
    api_call "item.get" "{\"hostids\":[\"$HOST_ID\"],\"search\":{\"name\":\"$ITEM_NAME_PATTERN\"},\"output\":[\"itemid\",\"name\"]}" \
      | python3 -c "import sys,json; r=json.load(sys.stdin)['result']; print(r[0]['itemid'] if r else '')"
}

get_dashboard_id() {
    local DASH_NAME="$1"
    api_call "dashboard.get" "{\"filter\":{\"name\":[\"$DASH_NAME\"]},\"output\":[\"dashboardid\"]}" \
      | python3 -c "import sys,json; r=json.load(sys.stdin)['result']; print(r[0]['dashboardid'] if r else '')"
}

gen_ref() {
    cat /dev/urandom | tr -dc 'A-Z' | head -c 5
}

# ============================================================
# Main function: create or update the dashboard for one site
# ============================================================
process_site() {
    local CODE="$1"
    local SITE_NAME="${SITES[$CODE]}"

    echo ""
    echo "=== Site: $SITE_NAME ($CODE) ==="

    local GROUP_ID=$(get_group_id "$SITE_NAME")
    if [ -z "$GROUP_ID" ]; then
        echo "  WARNING: group not found - skipped"
        return
    fi

    # Firewall prefix (a site may use a special-case code)
    local FW_PREFIX="$CODE"
    if [ "$CODE" == "AA" ]; then
        FW_PREFIX="PAL"
    fi

    # Hosts suchen
    IFS='|' read -r FW_ID FW_NAME <<< "$(find_host_by_prefix "$FW_PREFIX" "NFW")"
    IFS='|' read -r CS_ID CS_NAME <<< "$(find_host_by_prefix "$CODE" "NCS")"
    IFS='|' read -r AS_ID AS_NAME <<< "$(find_host_by_prefix "$CODE" "NAS")"
    IFS='|' read -r SENS_ID SENS_NAME <<< "$(find_host_by_prefix "$CODE" "NSENS")"

    echo "  Firewall: $FW_NAME | Core Switch: $CS_NAME | Access Switch: $AS_NAME | Room sensor: $SENS_NAME"

    # Look up item ids for the gauges (only if the host exists)
    FW_CPU_ITEMID=""
    if [ -n "$FW_ID" ]; then
        FW_CPU_ITEMID=$(get_item_id "$FW_ID" "CPU - Management CPU Usage")
        FW_VPN_ITEMID=$(get_item_id "$FW_ID" "VPN - SSL Active Users")
    fi

    CS_TEMP_ITEMID=""
    if [ -n "$CS_ID" ]; then
        CS_TEMP_ITEMID=$(get_item_id "$CS_ID" "Temperature")
    fi

    AS_TEMP_ITEMID=""
    if [ -n "$AS_ID" ]; then
        AS_TEMP_ITEMID=$(get_item_id "$AS_ID" "Temperature")
    fi

    SENS_TEMP_ITEMID=""
    SENS_HUM_ITEMID=""
    if [ -n "$SENS_ID" ]; then
        SENS_TEMP_ITEMID=$(get_item_id "$SENS_ID" "AKCP Temperature")
        SENS_HUM_ITEMID=$(get_item_id "$SENS_ID" "AKCP Humidity")
    fi

    # WAN Traffic Item-Namen suchen (Interface Name kann variieren)
    FW_WAN_IN=""
    FW_WAN_OUT=""
    if [ -n "$FW_ID" ]; then
        WAN_ITEM=$(api_call "item.get" "{\"hostids\":[\"$FW_ID\"],\"search\":{\"name\":\"WAN Interface\"},\"output\":[\"name\"]}" \
          | python3 -c "import sys,json; r=json.load(sys.stdin)['result']; print(r[0]['name'] if r else '')")
        if [ -n "$WAN_ITEM" ]; then
            FW_WAN_IN="$WAN_ITEM"
            FW_WAN_OUT="${WAN_ITEM/Traffic In/Traffic Out}"
        fi
    fi

    # Referenzen generieren
    local R=()
    for i in $(seq 1 16); do R+=("$(gen_ref)"); done

    # Build the dashboard JSON with Python
    DASHBOARD_JSON=$(python3 - << PYEOF
import json

group_id = "$GROUP_ID"
name = "$SITE_NAME"
fw_id = "$FW_ID"
fw_name = "$FW_NAME"
fw_cpu_itemid = "$FW_CPU_ITEMID"
fw_vpn_itemid = "$FW_VPN_ITEMID"
fw_wan_in = """$FW_WAN_IN"""
fw_wan_out = """$FW_WAN_OUT"""
cs_temp_itemid = "$CS_TEMP_ITEMID"
as_temp_itemid = "$AS_TEMP_ITEMID"
sens_temp_itemid = "$SENS_TEMP_ITEMID"
sens_hum_itemid = "$SENS_HUM_ITEMID"

r = [$( IFS=,; for ref in "${R[@]}"; do printf '"%s",' "$ref"; done )]

widgets = []

# Honeycomb: NTDS
widgets.append({
    "type": "honeycomb", "name": "Domain Controller",
    "x": 13, "y": 0, "width": 15, "height": 3, "view_mode": 1,
    "fields": [
        {"type": "2", "name": "groupids.0", "value": group_id},
        {"type": "1", "name": "items.0", "value": "Service: Active Directory Domain Services (NTDS)"},
        {"type": "1", "name": "primary_label", "value": "{HOST.NAME} AD Service"},
        {"type": "1", "name": "thresholds.0.color", "value": "43A047"},
        {"type": "1", "name": "thresholds.0.threshold", "value": "0"},
        {"type": "1", "name": "thresholds.1.color", "value": "F44336"},
        {"type": "1", "name": "thresholds.1.threshold", "value": "6"},
        {"type": "1", "name": "reference", "value": r[0]}
    ]
})

# Honeycomb: Firewall Ping
widgets.append({
    "type": "honeycomb", "name": "Firewall",
    "x": 34, "y": 3, "width": 9, "height": 3, "view_mode": 1,
    "fields": [
        {"type": "2", "name": "groupids.0", "value": group_id},
        {"type": "1", "name": "items.0", "value": "ICMP Ping - Availability"},
        {"type": "1", "name": "thresholds.0.color", "value": "F44336"},
        {"type": "1", "name": "thresholds.0.threshold", "value": "0"},
        {"type": "1", "name": "thresholds.1.color", "value": "43A047"},
        {"type": "1", "name": "thresholds.1.threshold", "value": "1"},
        {"type": "1", "name": "host_tags.0.tag", "value": "type"},
        {"type": "0", "name": "host_tags.0.operator", "value": "1"},
        {"type": "1", "name": "host_tags.0.value", "value": "fw"},
        {"type": "0", "name": "show.0", "value": "1"},
        {"type": "0", "name": "primary_label_bold", "value": "1"},
        {"type": "1", "name": "reference", "value": r[1]}
    ]
})

# Honeycomb: Access Switch Ping
widgets.append({
    "type": "honeycomb", "name": "Access Switch",
    "x": 46, "y": 0, "width": 9, "height": 3, "view_mode": 1,
    "fields": [
        {"type": "2", "name": "groupids.0", "value": group_id},
        {"type": "1", "name": "host_tags.0.tag", "value": "type"},
        {"type": "0", "name": "host_tags.0.operator", "value": "1"},
        {"type": "1", "name": "host_tags.0.value", "value": "as"},
        {"type": "1", "name": "items.0", "value": "ICMP Ping - Availability"},
        {"type": "0", "name": "show.0", "value": "1"},
        {"type": "0", "name": "primary_label_bold", "value": "1"},
        {"type": "1", "name": "thresholds.0.color", "value": "F44336"},
        {"type": "1", "name": "thresholds.0.threshold", "value": "0"},
        {"type": "1", "name": "thresholds.1.color", "value": "43A047"},
        {"type": "1", "name": "thresholds.1.threshold", "value": "1"},
        {"type": "1", "name": "reference", "value": r[2]}
    ]
})

# Honeycomb: Core Switch Ping
widgets.append({
    "type": "honeycomb", "name": "Core Switch",
    "x": 37, "y": 0, "width": 9, "height": 3, "view_mode": 1,
    "fields": [
        {"type": "2", "name": "groupids.0", "value": group_id},
        {"type": "1", "name": "host_tags.0.tag", "value": "type"},
        {"type": "0", "name": "host_tags.0.operator", "value": "1"},
        {"type": "1", "name": "host_tags.0.value", "value": "cs"},
        {"type": "1", "name": "items.0", "value": "ICMP Ping - Availability"},
        {"type": "0", "name": "show.0", "value": "1"},
        {"type": "0", "name": "primary_label_bold", "value": "1"},
        {"type": "1", "name": "thresholds.0.color", "value": "F44336"},
        {"type": "1", "name": "thresholds.0.threshold", "value": "0"},
        {"type": "1", "name": "thresholds.1.color", "value": "43A047"},
        {"type": "1", "name": "thresholds.1.threshold", "value": "1"},
        {"type": "1", "name": "reference", "value": r[3]}
    ]
})

# Honeycomb: Application Server
widgets.append({
    "type": "honeycomb", "name": "Application Server",
    "x": 28, "y": 0, "width": 9, "height": 3, "view_mode": 1,
    "fields": [
        {"type": "2", "name": "groupids.0", "value": group_id},
        {"type": "1", "name": "host_tags.0.tag", "value": "type"},
        {"type": "0", "name": "host_tags.0.operator", "value": "1"},
        {"type": "1", "name": "host_tags.0.value", "value": "ap"},
        {"type": "1", "name": "items.0", "value": "System - Uptime"},
        {"type": "0", "name": "show.0", "value": "1"},
        {"type": "0", "name": "primary_label_bold", "value": "1"},
        {"type": "1", "name": "thresholds.0.color", "value": "F44336"},
        {"type": "1", "name": "thresholds.0.threshold", "value": "0"},
        {"type": "1", "name": "thresholds.1.color", "value": "43A047"},
        {"type": "1", "name": "thresholds.1.threshold", "value": "1"},
        {"type": "1", "name": "reference", "value": r[4]}
    ]
})

# Honeycomb: File Server
widgets.append({
    "type": "honeycomb", "name": "File Server",
    "x": 25, "y": 3, "width": 9, "height": 3, "view_mode": 1,
    "fields": [
        {"type": "2", "name": "groupids.0", "value": group_id},
        {"type": "1", "name": "host_tags.0.tag", "value": "type"},
        {"type": "0", "name": "host_tags.0.operator", "value": "1"},
        {"type": "1", "name": "host_tags.0.value", "value": "fs"},
        {"type": "1", "name": "items.0", "value": "System - Uptime"},
        {"type": "0", "name": "show.0", "value": "1"},
        {"type": "0", "name": "primary_label_bold", "value": "1"},
        {"type": "1", "name": "thresholds.0.color", "value": "F44336"},
        {"type": "1", "name": "thresholds.0.threshold", "value": "0"},
        {"type": "1", "name": "thresholds.1.color", "value": "43A047"},
        {"type": "1", "name": "thresholds.1.threshold", "value": "1"},
        {"type": "1", "name": "reference", "value": r[5]}
    ]
})

# Honeycomb: Domain Controller Ping
widgets.append({
    "type": "honeycomb", "name": "Domain Controller Ping",
    "x": 13, "y": 3, "width": 12, "height": 3, "view_mode": 1,
    "fields": [
        {"type": "2", "name": "groupids.0", "value": group_id},
        {"type": "1", "name": "host_tags.0.tag", "value": "type"},
        {"type": "0", "name": "host_tags.0.operator", "value": "1"},
        {"type": "1", "name": "host_tags.0.value", "value": "dc"},
        {"type": "1", "name": "items.0", "value": "System - Uptime"},
        {"type": "0", "name": "show.0", "value": "1"},
        {"type": "1", "name": "primary_label", "value": "{HOST.NAME} Ping"},
        {"type": "0", "name": "primary_label_bold", "value": "1"},
        {"type": "1", "name": "thresholds.0.color", "value": "F44336"},
        {"type": "1", "name": "thresholds.0.threshold", "value": "0"},
        {"type": "1", "name": "thresholds.1.color", "value": "43A047"},
        {"type": "1", "name": "thresholds.1.threshold", "value": "1"},
        {"type": "1", "name": "reference", "value": r[6]}
    ]
})

# Problems by severity
widgets.append({
    "type": "problemsbysv", "name": "",
    "x": 0, "y": 0, "width": 13, "height": 6, "view_mode": 0,
    "fields": [
        {"type": "2", "name": "groupids.0", "value": group_id},
        {"type": "0", "name": "show_type", "value": "1"},
        {"type": "0", "name": "layout", "value": "1"},
        {"type": "1", "name": "reference", "value": r[7]}
    ]
})

# Firewall WAN Traffic (nur wenn Item gefunden)
if fw_name and fw_wan_in:
    widgets.append({
        "type": "svggraph", "name": "Firewall WAN Traffic",
        "x": 13, "y": 6, "width": 18, "height": 5, "view_mode": 0,
        "fields": [
            {"type": "1", "name": "ds.0.hosts.0", "value": fw_name},
            {"type": "1", "name": "ds.0.items.0", "value": fw_wan_in},
            {"type": "1", "name": "ds.0.items.1", "value": fw_wan_out},
            {"type": "0", "name": "ds.0.color_palette", "value": "0"},
            {"type": "0", "name": "ds.0.transparency", "value": "7"},
            {"type": "0", "name": "ds.0.fill", "value": "5"},
            {"type": "0", "name": "righty", "value": "0"},
            {"type": "0", "name": "legend", "value": "0"},
            {"type": "1", "name": "reference", "value": r[8]}
        ]
    })

# Gauge: CPU Firewall (nur wenn Itemid gefunden)
if fw_cpu_itemid:
    widgets.append({
        "type": "gauge", "name": "CPU - " + fw_name,
        "x": 0, "y": 6, "width": 13, "height": 5, "view_mode": 0,
        "fields": [
            {"type": "4", "name": "itemid.0", "value": fw_cpu_itemid},
            {"type": "0", "name": "angle", "value": "270"},
            {"type": "1", "name": "min", "value": "0"},
            {"type": "1", "name": "max", "value": "100"},
            {"type": "0", "name": "show.0", "value": "1"},
            {"type": "0", "name": "show.1", "value": "2"},
            {"type": "0", "name": "show.2", "value": "3"},
            {"type": "0", "name": "show.3", "value": "4"},
            {"type": "0", "name": "show.4", "value": "5"},
            {"type": "1", "name": "description", "value": "Firewall Utilization"},
            {"type": "1", "name": "thresholds.0.color", "value": "3BC97D"},
            {"type": "1", "name": "thresholds.0.threshold", "value": "0"},
            {"type": "1", "name": "thresholds.1.color", "value": "FCCB1D"},
            {"type": "1", "name": "thresholds.1.threshold", "value": "60"},
            {"type": "1", "name": "thresholds.2.color", "value": "E65660"},
            {"type": "1", "name": "thresholds.2.threshold", "value": "80"},
            {"type": "0", "name": "th_show_labels", "value": "1"},
            {"type": "0", "name": "th_show_arc", "value": "1"},
            {"type": "1", "name": "reference", "value": r[9]}
        ]
    })

# Gauge: Access switch temperature
if as_temp_itemid:
    widgets.append({
        "type": "gauge", "name": "Temperature - Access Switch",
        "x": 56, "y": 3, "width": 13, "height": 3, "view_mode": 0,
        "fields": [
            {"type": "4", "name": "itemid.0", "value": as_temp_itemid},
            {"type": "1", "name": "min", "value": "0"},
            {"type": "1", "name": "max", "value": "100"},
            {"type": "0", "name": "show.0", "value": "2"},
            {"type": "0", "name": "show.1", "value": "4"},
            {"type": "0", "name": "show.2", "value": "5"},
            {"type": "1", "name": "thresholds.0.color", "value": "3BC97D"},
            {"type": "1", "name": "thresholds.0.threshold", "value": "0"},
            {"type": "1", "name": "thresholds.1.color", "value": "FCCB1D"},
            {"type": "1", "name": "thresholds.1.threshold", "value": "50"},
            {"type": "1", "name": "thresholds.2.color", "value": "E65660"},
            {"type": "1", "name": "thresholds.2.threshold", "value": "65"},
            {"type": "0", "name": "th_show_labels", "value": "1"},
            {"type": "0", "name": "th_show_arc", "value": "1"},
            {"type": "1", "name": "reference", "value": r[10]}
        ]
    })

# Gauge: Core switch temperature
if cs_temp_itemid:
    widgets.append({
        "type": "gauge", "name": "Temperature - Core Switch",
        "x": 43, "y": 3, "width": 13, "height": 3, "view_mode": 0,
        "fields": [
            {"type": "4", "name": "itemid.0", "value": cs_temp_itemid},
            {"type": "1", "name": "min", "value": "0"},
            {"type": "1", "name": "max", "value": "100"},
            {"type": "0", "name": "show.0", "value": "2"},
            {"type": "0", "name": "show.1", "value": "4"},
            {"type": "0", "name": "show.2", "value": "5"},
            {"type": "1", "name": "thresholds.0.color", "value": "3BC97D"},
            {"type": "1", "name": "thresholds.0.threshold", "value": "0"},
            {"type": "1", "name": "thresholds.1.color", "value": "FCCB1D"},
            {"type": "1", "name": "thresholds.1.threshold", "value": "50"},
            {"type": "1", "name": "thresholds.2.color", "value": "E65660"},
            {"type": "1", "name": "thresholds.2.threshold", "value": "65"},
            {"type": "0", "name": "th_show_labels", "value": "1"},
            {"type": "0", "name": "th_show_arc", "value": "1"},
            {"type": "1", "name": "reference", "value": r[11]}
        ]
    })

# Gauge: Server-room temperature (only if a sensor exists)
if sens_temp_itemid:
    widgets.append({
        "type": "gauge", "name": "Server Room Temperature",
        "x": 31, "y": 6, "width": 19, "height": 5, "view_mode": 0,
        "fields": [
            {"type": "4", "name": "itemid.0", "value": sens_temp_itemid},
            {"type": "1", "name": "min", "value": "0"},
            {"type": "1", "name": "max", "value": "100"},
            {"type": "0", "name": "show.0", "value": "2"},
            {"type": "0", "name": "show.1", "value": "4"},
            {"type": "0", "name": "show.2", "value": "5"},
            {"type": "0", "name": "scale_show_units", "value": "0"},
            {"type": "1", "name": "thresholds.0.color", "value": "3BC97D"},
            {"type": "1", "name": "thresholds.0.threshold", "value": "0"},
            {"type": "1", "name": "thresholds.1.color", "value": "FCCB1D"},
            {"type": "1", "name": "thresholds.1.threshold", "value": "27"},
            {"type": "1", "name": "thresholds.2.color", "value": "E65660"},
            {"type": "1", "name": "thresholds.2.threshold", "value": "35"},
            {"type": "0", "name": "th_show_labels", "value": "1"},
            {"type": "0", "name": "th_show_arc", "value": "1"},
            {"type": "1", "name": "reference", "value": r[12]}
        ]
    })

# Gauge: Server-room humidity (only if a sensor exists)
if sens_hum_itemid:
    widgets.append({
        "type": "gauge", "name": "Server Room Humidity",
        "x": 50, "y": 6, "width": 19, "height": 5, "view_mode": 0,
        "fields": [
            {"type": "4", "name": "itemid.0", "value": sens_hum_itemid},
            {"type": "1", "name": "min", "value": "0"},
            {"type": "1", "name": "max", "value": "100"},
            {"type": "0", "name": "show.0", "value": "2"},
            {"type": "0", "name": "show.1", "value": "4"},
            {"type": "0", "name": "show.2", "value": "5"},
            {"type": "1", "name": "value_arc_color", "value": "81D4FA"},
            {"type": "1", "name": "empty_color", "value": "0040FF"},
            {"type": "1", "name": "thresholds.0.color", "value": "81D4FA"},
            {"type": "1", "name": "thresholds.0.threshold", "value": "0"},
            {"type": "1", "name": "thresholds.1.color", "value": "FCCB1D"},
            {"type": "1", "name": "thresholds.1.threshold", "value": "54"},
            {"type": "1", "name": "thresholds.2.color", "value": "E65660"},
            {"type": "1", "name": "thresholds.2.threshold", "value": "69"},
            {"type": "0", "name": "th_show_labels", "value": "1"},
            {"type": "0", "name": "th_show_arc", "value": "1"},
            {"type": "1", "name": "reference", "value": r[13]}
        ]
    })

# TOP Hosts by CPU Utilization
widgets.append({
    "type": "tophosts", "name": "TOP Hosts By CPU Utilization",
    "x": 0, "y": 11, "width": 31, "height": 4, "view_mode": 0,
    "fields": [
        {"type": "2", "name": "groupids.0", "value": group_id},
        {"type": "1", "name": "columns.0.name", "value": "Host name"},
        {"type": "0", "name": "columns.0.data", "value": "2"},
        {"type": "1", "name": "columns.1.name", "value": "Utilization"},
        {"type": "0", "name": "columns.1.data", "value": "1"},
        {"type": "1", "name": "columns.1.item", "value": "CPU - Total Utilization"},
        {"type": "1", "name": "columns.1.base_color", "value": "4CAF50"},
        {"type": "0", "name": "columns.1.display", "value": "3"},
        {"type": "1", "name": "columns.1.min", "value": "0"},
        {"type": "1", "name": "columns.1.max", "value": "100"},
        {"type": "1", "name": "columnsthresholds.1.color.0", "value": "FFFF00"},
        {"type": "1", "name": "columnsthresholds.1.threshold.0", "value": "50"},
        {"type": "1", "name": "columnsthresholds.1.color.1", "value": "FF8000"},
        {"type": "1", "name": "columnsthresholds.1.threshold.1", "value": "80"},
        {"type": "1", "name": "columnsthresholds.1.color.2", "value": "FF4000"},
        {"type": "1", "name": "columnsthresholds.1.threshold.2", "value": "90"},
        {"type": "0", "name": "column", "value": "1"},
        {"type": "1", "name": "reference", "value": r[14]}
    ]
})

# Item: SSL-VPN Active Users
if fw_vpn_itemid:
    widgets.append({
        "type": "item", "name": "SSL-VPN Active Users",
        "x": 55, "y": 0, "width": 14, "height": 3, "view_mode": 1,
        "fields": [
            {"type": "4", "name": "itemid.0", "value": fw_vpn_itemid},
            {"type": "0", "name": "show.0", "value": "1"},
            {"type": "0", "name": "show.1", "value": "2"},
            {"type": "0", "name": "show.2", "value": "4"},
            {"type": "0", "name": "decimal_places", "value": "0"},
            {"type": "1", "name": "bg_color", "value": "CE93D8"},
            {"type": "1", "name": "reference", "value": r[15]}
        ]
    })

payload = {
    "name": "Site: " + name,
    "display_period": 30,
    "auto_start": 1,
    "pages": [{"name": name, "widgets": widgets}]
}
print(json.dumps(payload))
PYEOF
)

    # Check whether the dashboard already exists
    EXISTING_ID=$(get_dashboard_id "Site: $SITE_NAME")

    if [ -n "$EXISTING_ID" ]; then
        echo "  Dashboard already exists (ID: $EXISTING_ID) - updating"
        UPDATE_JSON=$(python3 -c "import json; d=json.loads('''$DASHBOARD_JSON'''); d['dashboardid']='$EXISTING_ID'; print(json.dumps(d))")
        RESULT=$(api_call "dashboard.update" "$UPDATE_JSON")
        SUCCESS=$(echo "$RESULT" | python3 -c "import sys,json; r=json.load(sys.stdin); print('ok' if 'result' in r else '')" 2>/dev/null)
        if [ "$SUCCESS" == "ok" ]; then
            echo "  Dashboard updated."
        else
            ERROR=$(echo "$RESULT" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('error',{}).get('data','unknown error'))" 2>/dev/null)
            echo "  ERROR beim Update: $ERROR"
        fi
    else
        echo "  Dashboard being created"
        RESULT=$(api_call "dashboard.create" "$DASHBOARD_JSON")
        DASHBOARD_ID=$(echo "$RESULT" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['result']['dashboardids'][0] if 'result' in r else '')" 2>/dev/null)
        if [ -n "$DASHBOARD_ID" ]; then
            echo "  Dashboard created mit ID: $DASHBOARD_ID"
        else
            ERROR=$(echo "$RESULT" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('error',{}).get('data','unknown error'))" 2>/dev/null)
            echo "  ERROR while creating: $ERROR"
        fi
    fi
}

# ============================================================
# Process all sites
# ============================================================
for CODE in "${!SITES[@]}"; do
    process_site "$CODE"
done

# ============================================================
# Abmelden
# ============================================================
curl -k -s -X POST "$ZABBIX_URL" \
  -H "Content-Type: application/json" \
  -H "Host: zabbix.example.com" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.logout\",\"params\":[],\"id\":1}" > /dev/null

echo ""
echo "Done."
