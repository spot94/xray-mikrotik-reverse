#!/bin/sh
set -e

CONFIG_FILE="/etc/xray/config.json"
LOG_FILE="/var/log/xray/access.log"
ERROR_FILE="/var/log/xray/error.log"

# =============================================================================
# Helper functions
# =============================================================================

url_decode() {
    local input="$1"
    local output=""
    local i=0
    local len=${#input}

    while [ $i -lt $len ]; do
        local char="${input:$i:1}"
        if [ "$char" = "%" ]; then
            local hex="${input:$((i+1)):2}"
            # Only decode a well-formed %HH; otherwise keep '%' literally.
            # The hex guard also removes any printf format-string risk.
            case "$hex" in
                [0-9A-Fa-f][0-9A-Fa-f])
                    output="${output}$(printf "\\x$hex")"
                    i=$((i+3))
                    ;;
                *)
                    output="${output}%"
                    i=$((i+1))
                    ;;
            esac
        elif [ "$char" = "+" ]; then
            output="${output} "
            i=$((i+1))
        else
            output="${output}${char}"
            i=$((i+1))
        fi
    done
    printf '%s' "$output"
}

log_info() {
    echo "[INFO] $1" >&2
}

log_error() {
    echo "[ERROR] $1" >&2
}

die() {
    log_error "$1"
    exit 1
}

# Parse vless:// URL and output JSON outbound settings
# Args: $1=url $2=tag $3=reverse_tag (optional)
parse_vless_url() {
    local url="$1"
    local tag="$2"
    local reverse_tag="${3:-}"

    local raw="${url#vless://}"
    local uuid="${raw%%@*}"
    local rest="${raw#*@}"

    # Split off query (?) and fragment (#) BEFORE parsing host:port. Otherwise a
    # portless URL (no ":port") leaks the whole query string into the address.
    local query=""
    if [ "$rest" != "${rest#*\?}" ]; then
        local q="${rest#*\?}"
        query="${q%%\#*}"
    fi

    local remark=""
    if [ "$rest" != "${rest#*\#}" ]; then
        remark="${rest##*\#}"
    fi

    # Authority = host[:port], with query/fragment already stripped.
    local authority="${rest%%\?*}"
    authority="${authority%%\#*}"

    local host="${authority%%:*}"
    local port="443"
    if [ "$authority" != "${authority#*:}" ]; then
        port="${authority#*:}"
    fi
    # Fallback to 443 if port is missing/non-numeric (prevents jq --argjson failure)
    case "$port" in
        ''|*[!0-9]*) port=443 ;;
    esac

    # Parse query params
    local type_="tcp"
    local security="none"
    local sni=""
    local pbk=""
    local sid=""
    local fp="chrome"
    local path=""
    local host_header=""
    local flow=""
    local mode=""
    local spider_x=""
    local extra=""
    local finalmask=""

    local old_ifs="$IFS"
    IFS='&'
    for param in $query; do
        local key="${param%%=*}"
        local val="${param#*=}"
        val=$(url_decode "$val")
        case "$key" in
            type) type_="$val" ;;
            security) security="$val" ;;
            sni|serverName) sni="$val" ;;
            pbk|publicKey) pbk="$val" ;;
            sid|shortId) sid="$val" ;;
            fp|fingerprint) fp="$val" ;;
            path) path="$val" ;;
            host) host_header="$val" ;;
            flow) flow="$val" ;;
            mode) mode="$val" ;;
            spx|spiderX) spider_x="$val" ;;
            extra) extra="$val" ;;
            fm|finalmask) finalmask="$val" ;;
        esac
    done
    IFS="$old_ifs"

    # Build streamSettings with jq to avoid JSON escaping issues
    local stream_json
    stream_json=$(jq -n '{network: "tcp"}')

    # Transport settings
    case "$type_" in
        xhttp|splithttp)
            local xhttp_mode="${mode:-auto}"
            local xhttp_path="${path:-/}"
            local xhttp_json

            # Parse extra if present (query value already URL-decoded above)
            local extra_obj="null"
            if [ -n "$extra" ]; then
                if echo "$extra" | jq -e . >/dev/null 2>&1; then
                    extra_obj="$extra"
                fi
            fi

            if [ "$extra_obj" != "null" ]; then
                xhttp_json=$(jq -n \
                    --arg path "$xhttp_path" \
                    --arg host "$host_header" \
                    --arg mode "$xhttp_mode" \
                    --argjson extra "$extra_obj" \
                    '{
                        path: $path,
                        host: "",
                        mode: $mode,
                        scMaxConcurrentPosts: 10,
                        scMaxEachPostBytes: 1000000,
                        scMinPostsIntervalMs: 30,
                        extra: $extra
                    } | if $host != "" then .host = $host else . end')
            else
                xhttp_json=$(jq -n \
                    --arg path "$xhttp_path" \
                    --arg host "$host_header" \
                    --arg mode "$xhttp_mode" \
                    '{
                        path: $path,
                        host: "",
                        mode: $mode,
                        scMaxConcurrentPosts: 10,
                        scMaxEachPostBytes: 1000000,
                        scMinPostsIntervalMs: 30,
                        extra: {
                            scMaxEachPostBytes: "1000000",
                            scMinPostsIntervalMs: "30",
                            xPaddingBytes: "100-1000"
                        }
                    } | if $host != "" then .host = $host else . end')
            fi
            stream_json=$(echo "$stream_json" | jq --argjson x "$xhttp_json" '. + {network: "xhttp", xhttpSettings: $x}')
            ;;
        ws|websocket)
            local ws_json
            if [ -n "$host_header" ]; then
                ws_json=$(jq -n --arg path "$path" --arg host "$host_header" \
                    '{path: $path, headers: {Host: $host}}')
            else
                ws_json=$(jq -n --arg path "$path" '{path: $path}')
            fi
            stream_json=$(echo "$stream_json" | jq --argjson w "$ws_json" '. + {network: "ws", wsSettings: $w}')
            ;;
        grpc)
            local service_name="${path##*/}"
            local grpc_json
            grpc_json=$(jq -n --arg sn "$service_name" '{serviceName: $sn}')
            stream_json=$(echo "$stream_json" | jq --argjson g "$grpc_json" '. + {network: "grpc", grpcSettings: $g}')
            ;;
    esac

    # Security settings
    case "$security" in
        reality)
            local reality_json
            reality_json=$(jq -n \
                --arg serverName "$sni" \
                --arg publicKey "$pbk" \
                --arg fingerprint "$fp" \
                --arg shortId "$sid" \
                --arg spiderX "$spider_x" \
                '{
                    serverName: $serverName,
                    publicKey: $publicKey,
                    fingerprint: $fingerprint,
                    shortId: $shortId,
                    spiderX: $spiderX,
                    allowInsecure: false,
                    show: false
                }')
            stream_json=$(echo "$stream_json" | jq --argjson r "$reality_json" '. + {security: "reality", realitySettings: $r}')
            ;;
        tls)
            local tls_json
            tls_json=$(jq -n --arg serverName "$sni" --arg fingerprint "$fp" \
                '{serverName: $serverName, fingerprint: $fingerprint}')
            stream_json=$(echo "$stream_json" | jq --argjson t "$tls_json" '. + {security: "tls", tlsSettings: $t}')
            ;;
        *)
            stream_json=$(echo "$stream_json" | jq '. + {security: "none"}')
            ;;
    esac

    # Add finalmask if present (URL-encoded JSON)
    case "$security" in
        reality|tls)
            if [ -n "$finalmask" ]; then
                if echo "$finalmask" | jq -e . >/dev/null 2>&1; then
                    stream_json=$(echo "$stream_json" | jq --argjson f "$finalmask" '. + {finalmask: $f}')
                fi
            fi
            ;;
    esac

    # =========================================================================
    # Reverse bridge outbound and normal forward-proxy outbound differ in shape.
    #
    #  * VLESS Reverse Proxy (reverse_tag set): the bridge outbound MUST use the
    #    FLAT settings format (address/port/id directly in settings + reverse),
    #    NOT vnext/users — with vnext xray treats it as a plain forward proxy and
    #    never activates the reverse tunnel. Reverse also runs Mux internally, so
    #    NO "mux" block may be added here: a second mux corrupts the tunnel frames
    #    and the bridge fails with "common/mux: ... invalid domain name".
    #    Ref: https://xtls.github.io/en/document/level-2/vless_reverse.html
    #
    #  * Normal proxy outbound: classic vnext/users + Mux.
    # =========================================================================
    local settings_json user_json
    if [ -n "$reverse_tag" ]; then
        if [ -n "$flow" ]; then
            settings_json=$(jq -n --arg address "$host" --argjson port "$port" --arg id "$uuid" --arg flow "$flow" --arg tag "$reverse_tag" \
                '{address: $address, port: $port, id: $id, encryption: "none", flow: $flow, reverse: {tag: $tag}}')
        else
            settings_json=$(jq -n --arg address "$host" --argjson port "$port" --arg id "$uuid" --arg tag "$reverse_tag" \
                '{address: $address, port: $port, id: $id, encryption: "none", reverse: {tag: $tag}}')
        fi
        jq -n --arg tag "$tag" --argjson settings "$settings_json" --argjson stream "$stream_json" \
            '{
                tag: $tag,
                protocol: "vless",
                settings: $settings,
                streamSettings: $stream
            }'
    else
        if [ -n "$flow" ]; then
            user_json=$(jq -n --arg id "$uuid" --arg flow "$flow" '{id: $id, encryption: "none", security: "auto", flow: $flow, level: 8}')
        else
            user_json=$(jq -n --arg id "$uuid" '{id: $id, encryption: "none", security: "auto", level: 8}')
        fi
        settings_json=$(jq -n --arg address "$host" --argjson port "$port" --argjson user "$user_json" \
            '{vnext: [{address: $address, port: $port, users: [$user]}]}')
        jq -n --arg tag "$tag" --argjson settings "$settings_json" --argjson stream "$stream_json" \
            '{
                tag: $tag,
                protocol: "vless",
                settings: $settings,
                streamSettings: $stream,
                mux: { enabled: false, concurrency: -1, xudpConcurrency: 8, xudpProxyUDP443: "" }
            }'
    fi
}

# Download subscription and extract server URL by index
# Args: $1=sub_url $2=index
get_server_from_sub() {
    local sub_url="$1"
    local idx="${2:-0}"

    log_info "Downloading subscription from ${sub_url%%\?*} ..."

    local tmp_file="/tmp/subscription.txt"
    local http_code
    http_code=$(curl -sL --max-time 60 --retry 3 --retry-delay 2 \
        -w "%{http_code}" \
        -o "$tmp_file" \
        "$sub_url")

    if [ "$http_code" != "200" ]; then
        log_error "Failed to download subscription, HTTP code: $http_code"
        [ -f "$tmp_file" ] && log_error "Response preview: $(head -c 200 "$tmp_file")"
        die "Failed to download subscription"
    fi

    local sub_data
    sub_data=$(cat "$tmp_file")
    rm -f "$tmp_file"

    [ -z "$sub_data" ] && die "Subscription is empty"

    # Try base64 decode
    local decoded
    decoded=$(printf '%s' "$sub_data" | base64 -d 2>/dev/null | tr -d '\r')

    # If decoded doesn't look like a proxy URL, use raw response
    case "$decoded" in
        vless://*|vmess://*|trojan://*|ss://*|socks://*) ;;
        *) decoded="$sub_data" ;;
    esac

    # Get line by index, clean whitespace and newlines
    local line
    line=$(printf '%s' "$decoded" | sed -n "$((idx + 1))p" | tr -d ' \n\r\t')

    [ -z "$line" ] && die "No server found at index $idx in subscription"
    printf '%s' "$line"
}

# Parse one REVERSE_SERVICES entry into rsvc_* globals. Supported forms:
#   name:destPort:ip:port  -> mode "port"   : port-routed redirect (multi-service)
#   name:ip:port           -> mode "single" : catch-all redirect (single service)
#   name:cidr[:ports]      -> mode "cidr"   : catch-all, NO redirect — freedom just
#                             forwards to whatever dest the portal set, finalRules
#                             restrict it to the allowed CIDR (+ optional ports).
# A "/" in the first field after the name selects CIDR mode.
parse_reverse_svc() {
    local svc="$1"
    rsvc_mode=""; rsvc_name=""; rsvc_ip=""; rsvc_port=""; rsvc_destport=""; rsvc_cidr=""; rsvc_ports=""
    rsvc_name="${svc%%:*}"
    [ -z "$rsvc_name" ] && die "REVERSE_SERVICES entry '$svc': empty name"
    local r="${svc#*:}"
    [ "$r" = "$svc" ] && die "REVERSE_SERVICES entry '$svc': expected name:ip:port, name:destPort:ip:port, or name:cidr[:ports]"
    local f1="${r%%:*}"
    case "$f1" in
        */*)  # CIDR mode: name:cidr[:ports]. Ports list uses ';' (the ',' is the
              # entry separator), e.g. name:10.0.0.0/24:80;443;8000-9000
            rsvc_mode="cidr"
            rsvc_cidr="$f1"
            case "$r" in
                *:*) rsvc_ports=$(printf '%s' "${r#*:}" | tr ';' ',') ;;
                *)   rsvc_ports="" ;;
            esac
            case "$rsvc_ports" in *:*) die "REVERSE_SERVICES entry '$svc': too many fields (expected name:cidr[:ports])" ;; esac
            ;;
        *)    # redirect mode
            case "$r" in
                *:*:*)  # name:destPort:ip:port
                    rsvc_mode="port"
                    rsvc_destport="$f1"
                    local rr="${r#*:}"
                    rsvc_ip="${rr%%:*}"
                    rsvc_port="${rr#*:}"
                    case "$rsvc_port"     in *:*)         die "REVERSE_SERVICES entry '$svc': too many fields (expected name:destPort:ip:port)" ;; esac
                    case "$rsvc_destport" in ''|*[!0-9]*) die "REVERSE_SERVICES entry '$svc': destPort must be numeric" ;; esac
                    ;;
                *:*)    # name:ip:port
                    rsvc_mode="single"
                    rsvc_ip="$f1"
                    rsvc_port="${r#*:}"
                    ;;
                *)  die "REVERSE_SERVICES entry '$svc': expected name:ip:port, name:destPort:ip:port, or name:cidr[:ports]" ;;
            esac
            [ -z "$rsvc_ip" ] && die "REVERSE_SERVICES entry '$svc': empty ip"
            case "$rsvc_port" in ''|*[!0-9]*) die "REVERSE_SERVICES entry '$svc': port must be numeric" ;; esac
            ;;
    esac
}

# =============================================================================
# Validate environment
# =============================================================================

[ -z "$SUB" ] && [ -z "$SRV" ] && die "Either SUB or SRV must be set"

SERVER_INDEX="${SERVER_INDEX:-0}"
LOG_LEVEL="${LOG_LEVEL:-warning}"
DNS_SERVERS="${DNS_SERVERS:-}"

# =============================================================================
# Resolve VPN server URL
# =============================================================================

VPN_URL=""
if [ -n "$SRV" ]; then
    VPN_URL=$(printf '%s' "$SRV" | tr -d ' \n\r\t')
else
    VPN_URL=$(get_server_from_sub "$SUB" "$SERVER_INDEX")
fi

log_info "VPN server: ${VPN_URL%%\?*}"

# =============================================================================
# Resolve reverse server URL (optional)
# =============================================================================

REVERSE_URL=""
if [ -n "$RSRV" ]; then
    REVERSE_URL=$(printf '%s' "$RSRV" | tr -d ' \n\r\t')
elif [ -n "$RSUB" ]; then
    REVERSE_URL=$(get_server_from_sub "$RSUB" "0")
fi

if [ -n "$REVERSE_URL" ]; then
    log_info "Reverse portal: ${REVERSE_URL%%\?*}"
    [ -z "$REVERSE_SERVICES" ] && die "REVERSE_SERVICES must be set when reverse is enabled"

    # Validate every entry up front (parse_reverse_svc dies on malformed specs).
    # Catch-all forms (single redirect / CIDR) can't be combined with others,
    # since a catch-all rule would swallow the traffic of any sibling.
    old_ifs="$IFS"
    IFS=','
    _rsvc_count=0
    for svc in $REVERSE_SERVICES; do _rsvc_count=$((_rsvc_count + 1)); done
    for svc in $REVERSE_SERVICES; do
        parse_reverse_svc "$svc"
        if [ "$_rsvc_count" -gt 1 ] && [ "$rsvc_mode" != "port" ]; then
            die "REVERSE_SERVICES: '$svc' is a catch-all ($rsvc_mode) entry; with multiple services every entry must use name:destPort:ip:port"
        fi
    done
    IFS="$old_ifs"
fi

# =============================================================================
# Build outbounds
# =============================================================================

OUTBOUNDS="[]"

# VPN outbound
VPN_OUT=$(parse_vless_url "$VPN_URL" "proxy")
OUTBOUNDS=$(echo "$OUTBOUNDS" | jq --argjson o "$VPN_OUT" '. + [$o]')

# Reverse outbound (if enabled)
if [ -n "$REVERSE_URL" ]; then
    REV_OUT=$(parse_vless_url "$REVERSE_URL" "portal-reverse" "from-portal")
    OUTBOUNDS=$(echo "$OUTBOUNDS" | jq --argjson o "$REV_OUT" '. + [$o]')
fi

# Direct outbound
OUTBOUNDS=$(echo "$OUTBOUNDS" | jq '. + [{tag:"direct",protocol:"freedom"}]')

# Local service outbounds from REVERSE_SERVICES (forms: see parse_reverse_svc)
if [ -n "$REVERSE_URL" ] && [ -n "$REVERSE_SERVICES" ]; then
    old_ifs="$IFS"
    IFS=','
    for svc in $REVERSE_SERVICES; do
        parse_reverse_svc "$svc"
        if [ "$rsvc_mode" = "cidr" ]; then
            # CIDR: no redirect — forward to the dest the portal set; finalRules
            # restrict egress to the allowed subnet (and ports, if given).
            if [ -n "$rsvc_ports" ]; then
                local_out=$(jq -n --arg tag "to-${rsvc_name}" --arg ip "$rsvc_cidr" --arg port "$rsvc_ports" \
                    '{tag:$tag, protocol:"freedom", settings:{ finalRules:[ {action:"allow", network:"tcp", ip:[$ip], port:$port}, {action:"block"} ] }}')
            else
                local_out=$(jq -n --arg tag "to-${rsvc_name}" --arg ip "$rsvc_cidr" \
                    '{tag:$tag, protocol:"freedom", settings:{ finalRules:[ {action:"allow", network:"tcp", ip:[$ip]}, {action:"block"} ] }}')
            fi
        else
            # single | port: redirect to the fixed local ip:port
            local_out=$(jq -n --arg tag "to-${rsvc_name}" --arg redirect "${rsvc_ip}:${rsvc_port}" --arg ip "${rsvc_ip}/32" --arg port "$rsvc_port" \
                '{tag:$tag, protocol:"freedom", settings:{ redirect:$redirect, finalRules:[ {action:"allow", network:"tcp", ip:[$ip], port:$port}, {action:"block"} ] }}')
        fi
        OUTBOUNDS=$(echo "$OUTBOUNDS" | jq --argjson o "$local_out" '. + [$o]')
    done
    IFS="$old_ifs"
fi

# =============================================================================
# Build inbounds
# =============================================================================

INBOUNDS="[]"

# TUN inbound (always enabled)
TUN_IN=$(jq -n '{
    tag: "tun-in",
    protocol: "tun",
    settings: {
        name: "tun0",
        mtu: 9000,
        gateway: ["172.19.0.1/30"]
    }
}')
INBOUNDS=$(echo "$INBOUNDS" | jq --argjson i "$TUN_IN" '. + [$i]')

# SOCKS inbound (optional)
SOCKS_PORT="${SOCKS_PORT:-}"
if [ -n "$SOCKS_PORT" ]; then
    # Validate before jq --argjson, which would otherwise crash cryptically.
    case "$SOCKS_PORT" in
        ''|*[!0-9]*) die "SOCKS_PORT must be numeric (1-65535), got: $SOCKS_PORT" ;;
    esac
    if [ "$SOCKS_PORT" -lt 1 ] || [ "$SOCKS_PORT" -gt 65535 ]; then
        die "SOCKS_PORT out of range (1-65535): $SOCKS_PORT"
    fi
    if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASSWORD" ]; then
        SOCKS_IN=$(jq -n \
            --argjson port "$SOCKS_PORT" \
            --arg user "$SOCKS_USER" \
            --arg pass "$SOCKS_PASSWORD" \
            '{
                tag: "socks-in",
                port: $port,
                protocol: "socks",
                settings: {
                    auth: "password",
                    accounts: [{user: $user, pass: $pass}],
                    udp: true,
                    userLevel: 8
                },
                sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
            }')
    else
        SOCKS_IN=$(jq -n --argjson port "$SOCKS_PORT" '{
            tag: "socks-in",
            port: $port,
            protocol: "socks",
            settings: { auth: "noauth", udp: true, userLevel: 8 },
            sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
        }')
    fi
    INBOUNDS=$(echo "$INBOUNDS" | jq --argjson i "$SOCKS_IN" '. + [$i]')
fi

# =============================================================================
# Build routing
# =============================================================================

ROUTING_RULES="[]"

# Reverse traffic -> local services. "port" entries match by destPort (so several
# services share one tunnel); "single"/"cidr" entries are catch-all (no port match).
if [ -n "$REVERSE_URL" ] && [ -n "$REVERSE_SERVICES" ]; then
    old_ifs="$IFS"
    IFS=','
    for svc in $REVERSE_SERVICES; do
        parse_reverse_svc "$svc"
        if [ "$rsvc_mode" = "port" ]; then
            rule=$(jq -n --arg port "$rsvc_destport" --arg out "to-${rsvc_name}" \
                '{type:"field", inboundTag:["from-portal"], port:$port, outboundTag:$out}')
        else
            rule=$(jq -n --arg out "to-${rsvc_name}" \
                '{type:"field", inboundTag:["from-portal"], outboundTag:$out}')
        fi
        ROUTING_RULES=$(echo "$ROUTING_RULES" | jq --argjson r "$rule" '. + [$r]')
    done
    IFS="$old_ifs"
fi

# DNS bypass rule — plain-IP DNS servers resolve directly, not through the tunnel.
# Derived from DNS_SERVERS (no hardcoded resolver). Must precede the proxy
# catch-all below, otherwise the tun-in/socks-in rule matches first.
# Default (no DNS_SERVERS) uses the container's own DNS via Xray "localhost",
# which bypasses routing entirely and needs no rule here.
if [ -n "$DNS_SERVERS" ]; then
    DNS_DIRECT_IPS="[]"
    old_ifs="$IFS"
    IFS=','
    for dns_srv in $DNS_SERVERS; do
        dns_srv=$(printf '%s' "$dns_srv" | tr -d ' ')
        case "$dns_srv" in
            *://*) continue ;;           # DoH/DoT/tcp — leave to routing/tunnel
        esac
        dns_ip="${dns_srv%%:*}"          # strip optional :port
        case "$dns_ip" in
            *[!0-9.]*) : ;;              # not a bare IPv4 -> skip
            *.*.*.*) DNS_DIRECT_IPS=$(echo "$DNS_DIRECT_IPS" | jq --arg ip "$dns_ip" '. + [$ip]') ;;
        esac
    done
    IFS="$old_ifs"

    if [ "$(echo "$DNS_DIRECT_IPS" | jq 'length')" -gt 0 ]; then
        DNS_DIRECT_RULE=$(jq -n --argjson ips "$DNS_DIRECT_IPS" '{
            type: "field",
            ip: $ips,
            port: "53",
            outboundTag: "direct"
        }')
        ROUTING_RULES=$(echo "$ROUTING_RULES" | jq --argjson r "$DNS_DIRECT_RULE" '. + [$r]')
    fi
fi

# Local inbounds -> proxy
LOCAL_TAGS='["tun-in"]'
[ -n "$SOCKS_PORT" ] && LOCAL_TAGS=$(echo "$LOCAL_TAGS" | jq '. + ["socks-in"]')

PROXY_RULE=$(jq -n --argjson tags "$LOCAL_TAGS" '{
    type: "field",
    inboundTag: $tags,
    outboundTag: "proxy"
}')
ROUTING_RULES=$(echo "$ROUTING_RULES" | jq --argjson r "$PROXY_RULE" '. + [$r]')

# =============================================================================
# Assemble final config
# =============================================================================

CONFIG=$(jq -n \
    --arg loglevel "$LOG_LEVEL" \
    --argjson inbounds "$INBOUNDS" \
    --argjson outbounds "$OUTBOUNDS" \
    --argjson rules "$ROUTING_RULES" \
    '{
        log: { loglevel: $loglevel, access: "/var/log/xray/access.log", error: "/var/log/xray/error.log" },
        inbounds: $inbounds,
        outbounds: $outbounds,
        routing: { domainStrategy: "IPIfNonMatch", rules: $rules },
        policy: {
            levels: {
                "0": { statsUserDownlink: true, statsUserUplink: true },
                "8": { connIdle: 300, downlinkOnly: 1, handshake: 4, uplinkOnly: 1 }
            },
            system: {
                statsInboundDownlink: true,
                statsInboundUplink: true,
                statsOutboundDownlink: true,
                statsOutboundUplink: true
            }
        }
    }'
)

# DNS: explicit DNS_SERVERS override, otherwise defer to the container's own
# DNS configuration (/etc/resolv.conf, set by the container runtime).
# Xray "localhost" resolves via the system resolver.
if [ -n "$DNS_SERVERS" ]; then
    CONFIG=$(echo "$CONFIG" | jq --arg servers "$DNS_SERVERS" '
        .dns = {
            queryStrategy: "UseIPv4",
            servers: ($servers | split(","))
        }'
    )
else
    CONFIG=$(echo "$CONFIG" | jq '
        .dns = {
            queryStrategy: "UseIPv4",
            servers: ["localhost"]
        }'
    )
fi

echo "$CONFIG" > "$CONFIG_FILE"

log_info "Config written to $CONFIG_FILE"

# =============================================================================
# Start Xray
# =============================================================================

log_info "Starting Xray-Core..."
/usr/local/bin/xray run -c "$CONFIG_FILE"
