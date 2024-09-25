#!/bin/sh

# 配置文件名，默认值为 "cfconf.json"
CONFIG_FILE="cfconf.json"


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


# Log function
log() {
    local level=$1
    local message=$2
    case $log_level in
    "debug")
        echo "[$level] $message"
        logger -t "$log_header_name" "[$level] $message"
        ;;
    "info")
        if [ "$level" != "debug" ]; then
            echo "[$level] $message"
            logger -t "$log_header_name" "[$level] $message"
        fi
        ;;
    "warn")
        if [ "$level" = "warn" ] || [ "$level" = "error" ] || [ "$level" = "fatal" ]; then
            echo "[$level] $message"
            logger -t "$log_header_name" "[$level] $message"
        fi
        ;;
    "error")
        if [ "$level" = "error" ] || [ "$level" = "fatal" ]; then
            echo "[$level] $message"
            logger -t "$log_header_name" "[$level] $message"
        fi
        ;;
    "fatal")
        if [ "$level" = "fatal" ]; then
            echo "[$level] $message"
            logger -t "$log_header_name" "[$level] $message"
        fi
        ;;
    esac
}

# Log and exit function
log_and_exit() {
    log "ERROR" "$1"
    exit 1
}

# 检查环境
check_environment() {
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

# 获取 zone_id 的函数
get_zone_id() {
    local domain_name=$1
    local auth_key=$2

    local url="https://api.cloudflare.com/client/v4/zones?name=$domain_name"
    response=$(curl -s -X GET "$url" \
        -H "Authorization: Bearer $auth_key" \
        -H "Content-Type: application/json")

    log "debug" "Response from zone_id request: $response"

    zone_id=$(echo "$response" | jq -r '.result[0].id')

    if [ "$zone_id" = "null" ] || [ -z "$zone_id" ]; then
        log_and_exit "Failed to get zone_id for domain $domain_name: $(echo "$response" | jq -r '.errors[0].message')"
    fi

    echo "$zone_id"
}

# 检查 auth_key 的函数
check_auth_key() {
    local auth_key=$1
    local domain_int=$2

    # 检查 auth_key 是否已经标记为有效
    auth_key_valid=$(echo "$config" | jq -r ".domains[$domain_int].auth_key_valid")

    if [ "$auth_key_valid" = "true" ]; then
        log "debug" "auth_key for domain $((domain_int + 1)) is already valid, skipping verification."
        return
    fi

    local url="https://api.cloudflare.com/client/v4/user/tokens/verify"
    response=$(curl -s -X GET "$url" \
        -H "Authorization: Bearer $auth_key" \
        -H "Content-Type: application/json")

    log "debug" "Response from token verification: $response"

    success=$(echo "$response" | jq -r '.success')

    if [ "$success" != "true" ]; then
        log_and_exit "Invalid auth_key: $(echo "$response" | jq -r '.errors[0].message')"
    fi

    log "debug" "auth_key is valid."

    # 在 JSON 配置文件中标记 auth_key 为有效
    config=$(echo "$config" | jq ".domains[$domain_int] |= . + {auth_key_valid: true}")
    echo "$config" | jq . >"$CONFIG_FILE"
}

# ... existing code ...

# 检查是否支持 declare 命令
if command -v declare >/dev/null 2>&1; then
    declare -A ip_cache
    use_cache=true
else
    use_cache=false
fi

get_host_ip() {
    local config_type=$1
    local config_nic_name=$2
    local arIp6QueryUrl=$3
    local arIp4QueryUrl=$4
    local config_local=$5

    local cache_key="${config_type}_${config_nic_name}_${config_local}"
    local ip_address

    if [ "$use_cache" = true ] && [ -n "${ip_cache[$cache_key]}" ]; then
        log "debug" "Using cached IP for $cache_key" >&2
        echo "${ip_cache[$cache_key]}"
        return
    fi

    log "debug" "function get_host_ip" >&2
    if [ "$config_local" = "true" ]; then
        if [ "$config_type" = "AAAA" ]; then
            ip_address=$(ip -6 addr show "$config_nic_name" | grep 'inet6' | awk '{print $2}' | cut -d/ -f1 | grep -vE "$(arLanIp6)" | head -n 1)
        else
            ip_address=$(ip -4 addr show "$config_nic_name" | grep 'inet' | awk '{print $2}' | cut -d/ -f1 | grep -vE "$(arLanIp4)" | head -n 1)
        fi
    else
        if [ "$config_type" = "AAAA" ]; then
            ip_address=$(curl -s "$arIp6QueryUrl" | grep -vE "$(arLanIp6)")
        else
            ip_address=$(curl -s "$arIp4QueryUrl" | grep -vE "$(arLanIp4)")
        fi
    fi

    log "debug" "Fetched $config_local $config_type address for $config_nic_name: $ip_address" >&2

    if [ "$use_cache" = true ]; then
        ip_cache[$cache_key]=$ip_address
    fi

    echo "$ip_address"
}

# 检查配置的函数
check_config() {
    if [ -f "$CONFIG_FILE" ]; then
        log "debug" "Configuration file exists, start running"
        config=$(jq . <"$CONFIG_FILE")
        log_level=$(echo "$config" | jq -r '.settings.log_level')
        arIp6QueryUrl=$(echo "$config" | jq -r '.settings.arIp6QueryUrl')
        arIp4QueryUrl=$(echo "$config" | jq -r '.settings.arIp4QueryUrl')
        log_header_name=$(echo "$config" | jq -r '.settings.log_header_name')
        export log_header_name
    else
        config='{
    "settings": {
        "log_level": "debug,info",
        "arIp6QueryUrl": "https://6.ipw.cn",
        "arIp4QueryUrl": "https://4.ipw.cn",
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

# 获取 DNS 记录信息的函数
get_record_info() {
    local zone_id=$1
    local fqdn_name=$2
    local record_type=$3
    local auth_email=$4
    local auth_key=$5

    # 获取所有 DNS 记录
    local url="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=$record_type&name=$fqdn_name"
    response=$(curl -s -X GET "$url" \
        -H "Authorization: Bearer $auth_key" \
        -H "Content-Type: application/json")

    if echo "$response" | jq -e '.success' >/dev/null; then
        record_info=$(echo "$response" | jq -r '.result[0]')
        if [ "$record_info" = "null" ] || [ -z "$record_info" ]; then

            record_info=""

        fi
    else
        log_and_exit "Failed to get record info: $(echo "$response" | jq -r '.errors[0].message')"
    fi

    echo "$record_info"
}

# 创建记录的函数
create_record() {
    local zone_id=$1 auth_email=$2 auth_key=$3 record_name=$4 record_type=$5 record_content=$6 record_proxy=$7

    local url="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records"
    local data=$(jq -n --arg type "$record_type" --arg name "$record_name" --arg content "$record_content" --argjson proxied "$record_proxy" '{
        type: $type,
        name: $name,
        content: $content,
        proxied: $proxied,
        ttl: 300,
        comment: "Domain verification record",
        settings: {},
        tags: []
    }')

    response=$(curl -s -X POST "$url" \
        -H "Authorization: Bearer $auth_key" \
        -H "Content-Type: application/json" \
        --data "$data")
    log "debug" "Response from create_record: $response"

    if echo "$response" | jq -e '.success' >/dev/null; then
        log "debug" "Record $record_name created successfully."
    else
        log_and_exit "Failed to create record $record_name: $(echo "$response" | jq -r '.errors[0].message')"
    fi
}

# 更新记录的函数
update_record() {
    local zone_id=$1 auth_key=$2 record_id=$3 record_name=$4 record_type=$5 record_content=$6 record_proxy=$7

    local url="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id"
    local data=$(jq -n --arg type "$record_type" --arg name "$record_name" --arg content "$record_content" --argjson proxied "$record_proxy" '{
        type: $type,
        name: $name,
        content: $content,
        proxied: $proxied
    }')

    response=$(curl -s -X PATCH "$url" \
        -H "Authorization: Bearer $auth_key" \
        -H "Content-Type: application/json" \
        --data "$data")
    log "debug" "Response from update_record: $response"

    if echo "$response" | jq -e '.success' >/dev/null; then
        log "debug" "Record $record_name updated successfully."
    else
        log_and_exit "Failed to update record $record_name: $(echo "$response" | jq -r '.errors[0].message')"
    fi
}

# 检查记录的函数
check_records() {
    local domain_int=$1
    local domain_name=$2
    local zone_id=$3
    local auth_key=$4
    local arIp6QueryUrl=$5
    local arIp4QueryUrl=$6

    config_size=$(echo "$config" | jq ".domains[$domain_int].records | length")

    if [ -z "$config_size" ] || [ "$config_size" -eq 0 ]; then
        log_and_exit "No records found for domain $domain_int."
    fi

    for config_int in $(seq 0 $((config_size - 1))); do
        log "info" "records: $((config_int + 1))/$config_size"
        config_name=$(echo "$config" | jq -r ".domains[$domain_int].records[$config_int].name")
        config_type=$(echo "$config" | jq -r ".domains[$domain_int].records[$config_int].type")
        config_proxy=$(echo "$config" | jq -r ".domains[$domain_int].records[$config_int].proxy")
        config_local=$(echo "$config" | jq -r ".domains[$domain_int].records[$config_int].local")
        config_nic_name=$(echo "$config" | jq -r ".domains[$domain_int].records[$config_int].nic_name")
        FQDN_name="$config_name.$domain_name"

        log "debug" "config_name: $config_name"
        log "debug" "config_type: $config_type"
        log "debug" "config_proxy: $config_proxy"
        log "debug" "config_local: $config_local"
        log "debug" "config_nic_name: $config_nic_name"
        log "debug" "FQDN_name: $FQDN_name"
        # 获取记录信息
        record_info=$(get_record_info "$zone_id" "$FQDN_name" "$config_type" "$auth_email" "$auth_key")

        log "debug" "record_info:$record_info"
        if [ -z "$record_info" ]; then
            log "warn" "Record $FQDN_name does not exist, creating..."
            host_ip=$(get_host_ip "$config_type" "$config_nic_name" "$arIp6QueryUrl" "$arIp4QueryUrl" "$config_local")
            create_record "$zone_id" "$auth_email" "$auth_key" "$FQDN_name" "$config_type" "$host_ip" "$config_proxy"
        else

            record_id=$(echo "$record_info" | jq -r '.id')
            record_ip=$(echo "$record_info" | jq -r '.content')
            record_proxy=$(echo "$record_info" | jq -r '.proxied')

            host_ip=$(get_host_ip "$config_type" "$config_nic_name" "$arIp6QueryUrl" "$arIp4QueryUrl" "$config_local")

            if [ "$host_ip" != "$record_ip" ] || [ "$config_proxy" != "$record_proxy" ]; then
                log "info" "IP $host_ip or proxy setting has changed for $FQDN_name, updating record..."
                update_record "$zone_id" "$auth_key" "$record_id" "$config_name" "$config_type" "$host_ip" "$config_proxy"
            else
                log "info" "IP $host_ip and proxy setting have not changed for $FQDN_name type $config_type, no update needed."
            fi
        fi
    done
}

main() {
    check_environment
    check_config

    config_size=$(echo "$config" | jq ".domains | length")
    domain_int=0

    log "debug" "config_size: $config_size"
    log "debug" "domain_int: $domain_int"

    if [ -z "$config_size" ] || [ "$config_size" -eq 0 ]; then
        log_and_exit "No configuration found."
    fi

    for domain_int in $(seq 0 $((config_size - 1))); do
        log "info" "domains:$((domain_int + 1))/$config_size"
        domain_name=$(echo "$config" | jq -r ".domains[$domain_int].domain_name")
        zone_id=$(echo "$config" | jq -r ".domains[$domain_int].zone_id")
        auth_key=$(echo "$config" | jq -r ".domains[$domain_int].auth_key")

        log "debug" "domain_name: $domain_name"
        log "debug" "zone_id: $zone_id"
        log "debug" "auth_key: $auth_key"

        check_auth_key "$auth_key" "$domain_int"

        if [ "$zone_id" = "null" ] || [ -z "$zone_id" ]; then
            zone_id=$(get_zone_id "$domain_name" "$auth_key")
            log "debug" "Fetched zone_id: $zone_id"
            config=$(echo "$config" | jq ".domains[$domain_int] |= . + {zone_id: \"$zone_id\"}")
            echo "$config" | jq . >"$CONFIG_FILE"
        fi

        check_records "$domain_int" "$domain_name" "$zone_id" "$auth_key" "$arIp6QueryUrl" "$arIp4QueryUrl"
    done
}

main

# 查看日志
#  journalctl --no-pager --since today -g 'jaDDNS'
#  logread -e jaDDNS
