#!/bin/sh

set -e # 在遇到错误时退出脚本

# 获取当前脚本的目录路径 / Get the directory path of the current script
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

# 配置文件路径，默认值为 "cfconf.json" / Configuration file path, default is "cfconf.json"
CONFIG_FILE="$SCRIPT_DIR/cfconf.json"

# 解析命令行参数
while getopts "c:" opt; do
    case $opt in
    c)
        CONFIG_FILE=$OPTARG
        ;;
    *)
        echo "Usage: $0 [-c config_file]"
        exit 1
        ;;
    esac
done

# 公网探测 URL（写死在脚本内，不由 cfconf 覆盖）
DEFAULT_IPV4_QUERY_URLS='https://ddns.oray.com/checkip
https://ip.3322.net
https://4.ipw.cn
https://v4.yinghualuo.cn/bejson
https://myip.ipip.net'

DEFAULT_IPV6_QUERY_URLS='https://speed.neu6.edu.cn/getIP.php
https://v6.ident.me
https://6.ipw.cn
https://v6.yinghualuo.cn/bejson'

# 私网/特殊网段正则（供 grep -vE；无外部依赖，与常量区放一起）
# Get regular expression for IPv4 LAN addresses
arLanIp4() {
    local lanIps="^$"
    lanIps="$lanIps|(^10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$)"              # RFC1918
    lanIps="$lanIps|(^100\.(6[4-9]|[7-9][0-9])\.[0-9]{1,3}\.[0-9]{1,3}$)"    # RFC6598 100.64.x.x - 100.99.x.x
    lanIps="$lanIps|(^100\.1([0-1][0-9]|2[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$)"   # RFC6598 100.100.x.x - 100.127.x.x
    lanIps="$lanIps|(^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$)"             # RFC1122
    lanIps="$lanIps|(^169\.254\.[0-9]{1,3}\.[0-9]{1,3}$)"                    # RFC3927
    lanIps="$lanIps|(^172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]{1,3}\.[0-9]{1,3}$)" # RFC1918
    lanIps="$lanIps|(^192\.0\.2\.[0-9]{1,3}$)"                               # RFC5737
    lanIps="$lanIps|(^192\.168\.[0-9]{1,3}\.[0-9]{1,3}$)"                    # RFC1918
    lanIps="$lanIps|(^198\.1[8-9]\.[0-9]{1,3}\.[0-9]{1,3}$)"                 # RFC2544
    lanIps="$lanIps|(^198\.51\.100\.[0-9]{1,3}$)"                            # RFC5737
    lanIps="$lanIps|(^203\.0\.113\.[0-9]{1,3}$)"                             # RFC5737
    lanIps="$lanIps|(^2[4-5][0-9]\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$)"     # RFC1112
    echo $lanIps
}

# Get regular expression for IPv6 LAN addresses
arLanIp6() {
    local lanIps="(^$)"
    lanIps="$lanIps|(^::1$)"                            # RFC4291
    lanIps="$lanIps|(^64:[fF][fF]9[bB]:)"               # RFC6052, RFC8215
    lanIps="$lanIps|(^100::)"                           # RFC6666
    lanIps="$lanIps|(^2001:2:0?:)"                      # RFC5180
    lanIps="$lanIps|(^2001:[dD][bB]8:)"                 # RFC3849
    lanIps="$lanIps|(^[fF][cdCD][0-9a-fA-F]{2}:)"       # RFC4193 Unique local addresses
    lanIps="$lanIps|(^[fF][eE][8-9a-bA-B][0-9a-fA-F]:)" # RFC4291 Link-local addresses
    echo $lanIps
}

# 优化日志功能
log() {
    local level=$1
    local message=$2
    local current_log_level="info" # 默认日志级别为 info

    # 从配置中获取日志级别
    if [ -n "$log_level" ]; then
        current_log_level="$log_level"
    fi

    # 定义日志级别的优先级
    case $current_log_level in
    debug) current_log_level_num=1 ;;
    info) current_log_level_num=2 ;;
    warn) current_log_level_num=3 ;;
    error) current_log_level_num=4 ;;
    fatal) current_log_level_num=5 ;;
    *) current_log_level_num=2 ;; # 默认 info
    esac

    case $level in
    debug) level_num=1 ;;
    info) level_num=2 ;;
    warn) level_num=3 ;;
    error) level_num=4 ;;
    fatal) level_num=5 ;;
    *) level_num=2 ;; # 默认 info
    esac

    # 只有当当前日志级别允许时才输出日志信息
    if [ "$level_num" -ge "$current_log_level_num" ]; then
        echo "[$level] $message" >&2
        logger -t "$log_header_name" "[$level] $message"
    fi
}

# Log and exit function
log_and_exit() {
    echo "$1"
    log "ERROR" "$1"
    journalctl --no-pager --since "1 minute ago" | grep 'DDNS'
    exit 1
}
# 检查环境
check_environment() {
    log "debug" "function--------- check_environment"
    log "debug" "CONFIG_FILE: $CONFIG_FILE"
    for cmd in jq curl; do
        if ! command -v $cmd >/dev/null 2>&1; then
            case $cmd in
            jq)
                log_and_exit "jq is not installed. Please install jq. For example:
                    - openwrt: opkg update && opkg install jq
                    - Debian/Ubuntu: sudo apt-get install jq
                    - CentOS/RHEL: sudo yum install jq
                    - Fedora: sudo dnf install jq
                    - macOS: brew install jq"
                ;;
            curl)
                log_and_exit "curl is not installed. Please install curl. For example:
                    - openwrt: opkg update && opkg install curl
                    - Debian/Ubuntu: sudo apt-get install curl
                    - CentOS/RHEL: sudo yum install curl
                    - Fedora: sudo dnf install curl
                    - macOS: brew install curl"
                ;;
            esac
        fi
    done
}

# 检查配置的函数
check_config() {
    log "debug" "function--------- check_config"
    if [ -f "$CONFIG_FILE" ]; then
        log "debug" "Configuration file exists, start running"
        config=$(jq . "$CONFIG_FILE")
        log_level=$(echo "$config" | jq -r '.settings.log_level')
        log_header_name=$(echo "$config" | jq -r '.settings.log_header_name')
        export log_header_name
    else
        config='{
    "settings": {
        "log_level": "debug,info",
        "log_header_name": "DDNS"
    },
    "domains": [
        {
            "domain_name": "example1.com",
            "zone_id": "",
            "auth_email": "your_email@example.com",
            "auth_key": "your_auth_key1",
            "auth_key_valid": false,
            "records": [
                {
                    "name": "subdomain1",
                    "type": "A",
                    "proxy": false,
                    "local": true,
                    "nic_name": "eth0"
                },
                {
                    "name": "subdomain2",
                    "type": "AAAA",
                    "proxy": true,
                    "local": false,
                    "nic_name": "eth0"
                }
            ]
        },
        {
            "domain_name": "example2.com",
            "zone_id": "",
            "auth_email": "your_email@example.com",
            "auth_key": "your_auth_key2",
            "auth_key_valid": false,
            "records": [
                {
                    "name": "subdomain3",
                    "type": "A",
                    "proxy": false,
                    "local": true,
                    "nic_name": "eth1"
                }
            ]
        }
    ]
}'
        echo "$config" | jq . >"$CONFIG_FILE"
        log_and_exit "The configuration file does not exist. A template has been created, please modify it before executing."
    fi
}

# 获取域名数量
get_domain_size() {
    log "debug" "function--------- get_domain_size"
    domain_size=$(echo "$config" | jq ".domains | length")
    log "debug" "in get_domain_size domain_size: $domain_size"
    echo $domain_size
}

# 优化 make_url_request 函数
make_url_request() {
    log "debug" "function--------- make_url_request"
    local method=$1
    local url=$2
    local auth_key=$3
    local data=$4

    local response

    # 检查是否安装了 curl 或 wget
    if command -v curl >/dev/null 2>&1; then
        if [ "$method" = "GET" ]; then
            response=$(curl -s -X GET "$url" \
                -H "Authorization: Bearer $auth_key" \
                -H "Content-Type: application/json")
        else
            # JSON 经 stdin 发送，避免 --data "$data" 在特殊字符/长度下导致 curl 非零退出
            response=$(printf '%s' "$data" | curl -sS -X "$method" "$url" \
                -H "Authorization: Bearer $auth_key" \
                -H "Content-Type: application/json" \
                --data-binary @-)
        fi
    elif command -v wget >/dev/null 2>&1; then
        if [ "$method" = "GET" ]; then
            response=$(wget -qO- --method=GET "$url" \
                --header="Authorization: Bearer $auth_key" \
                --header="Content-Type: application/json")
        else
            response=$(wget -qO- --method="$method" "$url" \
                --header="Authorization: Bearer $auth_key" \
                --header="Content-Type: application/json" \
                --body-data="$data")
        fi
    else
        log "error" "Neither curl nor wget is installed."
        exit 1
    fi

    if [ $? -ne 0 ]; then
        log "error" "Failed to make $method request to $url"
        exit 1
    fi

    echo "$response"
}

# 优化 check_auth_key 函数
check_auth_key() {
    log "debug" "function--------- check_auth_key"
    local domain_int=$1
    local domain_name=$(echo "$config" | jq -r ".domains[$domain_int].domain_name")
    local auth_key=$(echo "$config" | jq -r ".domains[$domain_int].auth_key")
    local auth_key_valid=$(echo "$config" | jq -r ".domains[$domain_int].auth_key_valid")

    if [ "$auth_key_valid" = "true" ]; then
        log "info" "auth_key for $domain_name is valid"
        return
    fi

    log "info" "auth_key for $domain_name needs to be validated"
    local url="https://api.cloudflare.com/client/v4/user/tokens/verify"
    local response=$(make_url_request "GET" "$url" "$auth_key")
    local status=$(echo "$response" | jq -r '.result.status')

    if [ "$status" = "active" ]; then
        log "info" "auth_key for $domain_name is valid"
        config=$(echo "$config" | jq ".domains[$domain_int].auth_key_valid = true")
        echo "$config" | jq . >"$CONFIG_FILE"
    else
        log_and_exit "The auth_key is invalid"
    fi
}

# 检查zone_id是否存在
check_zone_id() {
    log "debug" "function--------- check_zone_id"
    local domain_int=$1
    local domain_name=$(echo "$config" | jq -r ".domains[$domain_int].domain_name")
    local auth_key=$(echo "$config" | jq -r ".domains[$domain_int].auth_key")

    local zone_id=$(echo "$config" | jq -r ".domains[$domain_int].zone_id")
    log "debug" "in check_zone_id zone_id: $zone_id"

    # 检查 zone_id 是否为 null 或空字符串
    if [ "$zone_id" = "null" ] || [ -z "$zone_id" ]; then
        log "info" "zone_id for $domain_name is not exist"
        # 获取 zone_id
        local url="https://api.cloudflare.com/client/v4/zones?name=$domain_name"
        response=$(make_url_request "GET" "$url" "$auth_key")
        zone_id=$(echo "$response" | jq -r '.result[0].id')
        log "info" "in response zone_id: $zone_id"
        if [ "$zone_id" = "null" ] || [ -z "$zone_id" ]; then
            log_and_exit "The zone_id is not exist"
        fi
        # 更新 zone_id
        config=$(echo "$config" | jq ".domains[$domain_int].zone_id = \"$zone_id\"")
        # 更新配置文件
        echo "$config" | jq . >"$CONFIG_FILE"
    fi
}

# Cloudflare List DNS Records：用扁平 name=<完整 DNS 名> + type（与旧版 ddns 一致；name=exact: 在部分环境下会空结果误判「无记录」）。
cf_dns_records_list_get() {
    log "debug" "function--------- cf_dns_records_list_get"
    local zid=$1 ty=$2 qn=$3 ak=$4
    curl -sS -G "https://api.cloudflare.com/client/v4/zones/${zid}/dns_records" \
        -H "Authorization: Bearer ${ak}" \
        -H "Content-Type: application/json" \
        --data-urlencode "type=${ty}" \
        --data-urlencode "name=${qn}"
}

# 获取cloudflare记录信息（type + 扁平 name=全名，@ 为 apex）
get_record_info() {
    log "debug" "function--------- get_record_info"
    local domain_int=$1
    local record_int=$2
    local zone_id=$(echo "$config" | jq -r ".domains[$domain_int].zone_id")
    local record_type=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].type")
    local domain_name=$(echo "$config" | jq -r ".domains[$domain_int].domain_name")
    local record_name=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].name")
    local auth_key=$(echo "$config" | jq -r ".domains[$domain_int].auth_key")

    local full_q response
    if [ "$record_name" = "@" ]; then
        full_q="$domain_name"
    else
        full_q="${record_name}.${domain_name}"
    fi

    response=$(cf_dns_records_list_get "$zone_id" "$record_type" "$full_q" "$auth_key") || response=""
    log "debug" "get_record_info name=$full_q type=$record_type response: $response"
    if [ -z "$response" ]; then
        log "warn" "get_record_info empty response for name=$full_q type=$record_type (often curl/TLS); do not treat as absent record"
    elif ! echo "$response" | jq -e '.success == true' >/dev/null 2>&1; then
        log "warn" "get_record_info list API not success for name=$full_q type=$record_type errors=$(echo "$response" | jq -c '.errors // empty' 2>/dev/null || echo "(non-json)")"
    fi
    log "debug" "get_record_info name=$full_q count=$(echo "$response" | jq '.result | length // 0')"
    printf '%s\n' "$response"
}

# 获取本地IP,并过滤私有IP地址
get_local_ip() {
    log "debug" "function--------- get_local_ip"
    local record_nic_name=$1
    local record_type=$2
    log "debug" "get_local_ip record_local: $record_local"
    log "debug" "get_local_ip record_nic_name: $record_nic_name"
    log "debug" "get_local_ip record_type: $record_type"
    if [ "$record_type" = "AAAA" ]; then
        ip_address=$(ip -6 addr show "$record_nic_name" | grep 'inet6' | grep -v 'deprecated' | awk '{print $2}' | cut -d/ -f1 | grep -vE "$(arLanIp6)" | head -n 1)
    else
        ip_address=$(ip -4 addr show "$record_nic_name" | grep 'inet' | awk '{print $2}' | cut -d/ -f1 | grep -vE "$(arLanIp4)" | head -n 1)
    fi
    log "debug" "Fetched local $record_type address for $record_nic_name: $ip_address"
    if [ -n "$ip_address" ]; then
        log "info" "resolved | type=$record_type | ip=$ip_address | via=nic:$record_nic_name"
    else
        log "warn" "resolved | type=$record_type | ip=(empty) | via=nic:$record_nic_name"
    fi
    echo $ip_address
}

# 从 HTTP 响应体提取公网 IP（$1=AAAA|其它，$2=body；JSON 或纯文本）
extract_public_ip() {
    log "debug" "function--------- extract_public_ip"
    local rt=$1 body=$2 out="" pub
    if printf '%s' "$body" | jq -e 'type == "object"' >/dev/null 2>&1; then
        if [ "$rt" = "AAAA" ]; then
            out=$(printf '%s' "$body" | jq -r '.ip // .ipv6 // (if (.data | type) == "string" then .data else empty end) // empty' 2>/dev/null)
        else
            out=$(printf '%s' "$body" | jq -r '.ip // .data.ip // (if (.data | type) == "string" then .data else empty end) // empty' 2>/dev/null)
        fi
        [ "$out" = "null" ] && out=""
    fi
    if [ -z "$out" ]; then
        if [ "$rt" = "AAAA" ]; then
            out=$(printf '%s' "$body" | grep -oE '([0-9a-fA-F]{0,4}:){2,}[0-9a-fA-F:.]+' | head -n1)
            out=$(printf '%s' "$out" | cut -d% -f1 | cut -d/ -f1)
        else
            out=$(printf '%s' "$body" | sed 's/<[^>]*>/ /g' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
        fi
    fi
    [ -z "$out" ] && return 1
    if [ "$rt" = "AAAA" ]; then
        pub=$(printf '%s' "$out" | grep -vE "$(arLanIp6)" || true)
    else
        pub=$(printf '%s' "$out" | grep -vE "$(arLanIp4)" || true)
    fi
    [ -z "$pub" ] && return 1
    printf '%s\n' "$out"
    return 0
}

# 依次遍历探测 URL，直到得到可用公网 IP（IPv4 用 curl -4，IPv6 用 curl -6）
get_url_ip() {
    log "debug" "function--------- get_url_ip"
    record_type=$1
    if [ "$record_type" = "AAAA" ]; then
        urls=$DEFAULT_IPV6_QUERY_URLS
        curl_family=-6
    else
        urls=$DEFAULT_IPV4_QUERY_URLS
        curl_family=-4
    fi

    tmpf="${TMPDIR:-/tmp}/ddns_ip.$$"
    printf '%s\n' "$urls" >"$tmpf"
    found=""
    while IFS= read -r url || [ -n "$url" ]; do
        [ -z "$url" ] && continue
        log "debug" "get_url_ip try $url"
        body=$(curl $curl_family -sS --connect-timeout 5 --max-time 20 -L "$url" 2>/dev/null) || {
            log "warn" "curl failed: $url"
            continue
        }
        cand=$(extract_public_ip "$record_type" "$body") || cand=""
        if [ -n "$cand" ]; then
            found=$cand
            log "info" "resolved | type=$record_type | ip=$cand | via=url:$url"
            break
        fi
        log "warn" "no usable IP in response from $url"
    done <"$tmpf"
    rm -f "$tmpf"

    if [ -z "$found" ]; then
        log_and_exit "All public IP query URLs failed for $record_type"
    fi
    printf '%s\n' "$found"
}

# POST 新建一条 DNS（仅写 Cloudflare；不做 list、不处理 duplicate——由 sync_one_record 统一决策）
# 成功 return 0；Cloudflare「已存在」类错误 return 2；其它错误 log_and_exit
create_record() {
    log "debug" "function--------- create_record"
    local domain_int=$1
    local record_int=$2
    local local_ip=$3
    local zone_id=$(echo "$config" | jq -r ".domains[$domain_int].zone_id")
    local domain_name=$(echo "$config" | jq -r ".domains[$domain_int].domain_name")
    local record_name=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].name")
    local record_type=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].type")
    local record_proxy=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].proxy")
    local auth_key=$(echo "$config" | jq -r ".domains[$domain_int].auth_key")
    local fqdn_name="$record_name.$domain_name"
    local url="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records"
    local current_time=$(date +"%Y-%m-%d %H:%M:%S")
    local data=$(jq -n --arg type "$record_type" --arg name "$record_name" --arg content "$local_ip" --argjson proxied "$record_proxy" --arg comment "$current_time" '{
        type: $type,
        name: $name,
        content: $content,
        proxied: $proxied,
        comment: $comment,
    }')
    log "info" "create_record $fqdn_name ($record_type)"
    response=$(make_url_request "POST" "$url" "$auth_key" "$data")
    log "debug" "Response from create_record: $response"

    if echo "$response" | jq -e '.success' >/dev/null; then
        log "info" "Record $record_name created successfully."
        log "debug" "response: $response"
        return 0
    fi
    local err_msg err_code
    err_msg=$(echo "$response" | jq -r '.errors[0].message // empty')
    err_code=$(echo "$response" | jq -r '.errors[0].code // empty')
    if echo "$err_msg" | grep -qi 'identical record already exists' || [ "$err_code" = "81053" ]; then
        log "warn" "create_record: POST duplicate for $fqdn_name ($err_msg) — 交由上层 refetch 后 update/skip"
        return 2
    fi
    log_and_exit "Failed to create record $record_name: $err_msg"
}

# 更新cloudflare记录
update_record() {
    log "debug" "function--------- update_record"
    local domain_int=$1
    local record_int=$2
    local record_id=$3
    local local_ip=$4
	if [ -z "$record_id" ]; then
        log "error" "update_record called with empty record_id"
        return 1   # 返回错误，但注意 set -e 会使脚本退出，可考虑用 || true 处理
    fi
    local zone_id=$(echo "$config" | jq -r ".domains[$domain_int].zone_id")
    local domain_name=$(echo "$config" | jq -r ".domains[$domain_int].domain_name")
    local record_name=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].name")
    local record_type=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].type")
    local record_proxy=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].proxy")
    local auth_key=$(echo "$config" | jq -r ".domains[$domain_int].auth_key")
    local fqdn_name="$record_name.$domain_name"
    local url="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id"
    local current_time=$(date +"%Y-%m-%d %H:%M:%S")
    # PUT 的 name 同样用相对 zone 名称，与 Create 一致
    local data=$(jq -n --arg type "$record_type" --arg name "$record_name" --arg content "$local_ip" --argjson proxied "$record_proxy" --arg comment "$current_time" '{
        type: $type,
        name: $name,
        content: $content,
        proxied: $proxied,
        comment: $comment
    }')
    log "info" "update_record $fqdn_name"
    response=$(make_url_request "PUT" "$url" "$auth_key" "$data")
    log "debug" "Response for $url update_record: $response"

    if echo "$response" | jq -e '.success' >/dev/null; then
        log "info" "Record $record_name updated successfully."
    else
        log_and_exit "Failed to update record $record_name: $(echo "$response" | jq -r '.errors[0].message')"
    fi
}

# 检查crontab
check_crontab() {
    log "debug" "function--------- check_crontab"
    crontab_output=$(crontab -l 2>/dev/null || echo "")
    log "debug" "Crontab content: $crontab_output"
    if ! echo "$crontab_output" | grep -q "DDNS"; then
        log "info" "crontab not exist, add crontab"
        # 添加crontab,10分钟执行一次
        (
            crontab -l 2>/dev/null
            echo "*/10 * * * * /bin/sh $SCRIPT_DIR/ddns.sh # DDNS"
        ) | crontab -
    else
        log "info" "crontab entry for DDNS already exists"
    fi
}

# 单条：本地 IP → List（非 success 不 POST）→ 有则比对 update/skip；list 空才 POST，duplicate 再 list 一次后比对
sync_one_record() {
    log "debug" "function--------- sync_one_record"
    local domain_int=$1 record_int=$2 domain_name=$3 records_size=$4
    local record_name record_type record_local record_proxy record_nic_name fqdn
    local local_ip remote_info result_len remote_id remote_ip remote_proxy cr do_apply

    record_name=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].name")
    record_type=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].type")
    record_local=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].local")
    record_proxy=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].proxy")
    record_nic_name=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].nic_name")
    fqdn="$record_name.$domain_name"
    log "info" "Records： $((record_int + 1))/$records_size $record_type $fqdn"

    if [ "$record_local" = "true" ]; then
        local_ip=$(get_local_ip $record_nic_name $record_type)
    else
        local_ip=$(get_url_ip $record_type)
    fi

    remote_info=$(get_record_info "$domain_int" "$record_int")
    if ! echo "$remote_info" | jq -e '.success == true' >/dev/null 2>&1; then
        log "warn" "sync | type=$record_type | name=$fqdn | list API not confirmed — skip (no POST)"
        return 0
    fi

    result_len=$(echo "$remote_info" | jq '(.result // []) | length') || result_len=-1
    remote_id=$(echo "$remote_info" | jq -r '.result[0].id // empty')
    remote_ip=$(echo "$remote_info" | jq -r '.result[0].content // empty')
    remote_proxy=$(echo "$remote_info" | jq -r '.result[0].proxied // empty')
    do_apply=0

    if [ "$result_len" -gt 0 ] && [ -n "$remote_id" ] && [ "$remote_id" != "null" ]; then
        do_apply=1
    elif [ "$result_len" -eq 0 ]; then
        log "info" "sync | type=$record_type | name=$fqdn | list count=0 | action=create"
        if create_record "$domain_int" "$record_int" "$local_ip"; then
            return 0
        else
            cr=$?
            [ "$cr" -eq 2 ] || log_and_exit "sync | name=$fqdn | create_record unexpected exit $cr"
        fi
        log "warn" "sync | type=$record_type | name=$fqdn | POST duplicate — refetch list once"
        remote_info=$(get_record_info "$domain_int" "$record_int")
        echo "$remote_info" | jq -e '.success == true' >/dev/null 2>&1 || log_and_exit "sync | name=$fqdn | duplicate POST but list still unavailable"
        result_len=$(echo "$remote_info" | jq '(.result // []) | length') || result_len=-1
        remote_id=$(echo "$remote_info" | jq -r '.result[0].id // empty')
        remote_ip=$(echo "$remote_info" | jq -r '.result[0].content // empty')
        remote_proxy=$(echo "$remote_info" | jq -r '.result[0].proxied // empty')
        [ "$result_len" -gt 0 ] && [ -n "$remote_id" ] && [ "$remote_id" != "null" ] || log_and_exit "sync | name=$fqdn | duplicate POST but list still empty — 核对 Cloudflare 与 cfconf"
        do_apply=1
    else
        log "warn" "sync | type=$record_type | name=$fqdn | list unexpected (len=$result_len, id=$remote_id) — skip"
        return 0
    fi

    if [ "$do_apply" -eq 1 ]; then
        if [ "$local_ip" != "$remote_ip" ] || [ "$record_proxy" != "$remote_proxy" ]; then
            log "info" "sync | type=$record_type | name=$fqdn | local=$local_ip | remote=$remote_ip | proxy L=$record_proxy R=$remote_proxy | action=update"
            update_record "$domain_int" "$record_int" "$remote_id" "$local_ip"
        else
            log "info" "sync | type=$record_type | name=$fqdn | local=$local_ip | remote=$remote_ip | proxy L=$record_proxy R=$remote_proxy | action=skip"
        fi
    fi
}

main() {
    check_crontab
    check_environment
    check_config

    local domain_size domain_int domain_name records_size record_int
    domain_size=$(get_domain_size)
    log "debug" "domain_size: $domain_size"
    for domain_int in $(seq 0 $((domain_size - 1))); do
        domain_name=$(echo "$config" | jq -r ".domains[$domain_int].domain_name")
        log "info" "Domains： $((domain_int + 1))/$domain_size $domain_name"
        check_auth_key "$domain_int"
        check_zone_id "$domain_int"
        records_size=$(echo "$config" | jq ".domains[$domain_int].records | length")
        for record_int in $(seq 0 $((records_size - 1))); do
            sync_one_record "$domain_int" "$record_int" "$domain_name" "$records_size"
        done
    done
}

main

# 查看日志
#  journalctl --no-pager --since today -g 'DDNS'
#  journalctl --no-pager --since today |grep 'DDNS'
#  journalctl --no-pager --since "1 minute ago" | grep 'DDNS'
#  journalctl --no-pager | grep 'DDNS' | tail -n 10
#  logread -e DDNS
#  version:260502
