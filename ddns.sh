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

# 优化日志功能
log() {
    local level=$1
    local message=$2
    if [ "$level" = "debug" ] || [ "$level" = "info" ] || [ "$level" = "warn" ] || [ "$level" = "error" ] || [ "$level" = "fatal" ]; then
        echo "[$level] $message"
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
    if [ -f "$CONFIG_FILE" ]; then
        log "debug" "Configuration file exists, start running"
        config=$(jq . "$CONFIG_FILE")
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

# 获取域名数量
get_domain_size() {
    domain_size=$(echo "$config" | jq ".domains | length")
    log "debug" "in get_domain_size domain_size: $domain_size"
    echo $domain_size
}

# 优化 make_curl_request 函数
make_curl_request() {
    local method=$1
    local url=$2
    local auth_key=$3
    local data=$4

    local response
    if [ "$method" = "GET" ]; then
        response=$(curl -s -X GET "$url" \
            -H "Authorization: Bearer $auth_key" \
            -H "Content-Type: application/json")
    else
        response=$(curl -s -X "$method" "$url" \
            -H "Authorization: Bearer $auth_key" \
            -H "Content-Type: application/json" \
            --data "$data")
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
    local response=$(make_curl_request "GET" "$url" "$auth_key")
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
        response=$(make_curl_request "GET" "$url" "$auth_key")
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

# 获取cloudflare记录信息
get_record_info() {
    log "debug" "function--------- get_record_info"
    local domain_int=$1
    local record_int=$2
    local zone_id=$(echo "$config" | jq -r ".domains[$domain_int].zone_id")
    local record_type=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].type")
    local domain_name=$(echo "$config" | jq -r ".domains[$domain_int].domain_name")
    local record_name=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].name")
    local fqdn_name="$record_name.$domain_name"
    local auth_key=$(echo "$config" | jq -r ".domains[$domain_int].auth_key")
    local url="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=$record_type&name=$fqdn_name"
    response=$(make_curl_request "GET" "$url" "$auth_key")
    log "debug" "get_record_info from $url response: $response" >&2
    echo $response
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

# 获取本地IP,并过滤私有IP地址
get_local_ip() {
    local record_nic_name=$1
    local record_type=$2
    log "debug" "get_local_ip record_local: $record_local"
    log "debug" "get_local_ip record_nic_name: $record_nic_name"
    log "debug" "get_local_ip record_type: $record_type"
    if [ "$record_type" = "AAAA" ]; then
        ip_address=$(ip -6 addr show "$record_nic_name" | grep 'inet6' | awk '{print $2}' | cut -d/ -f1 | grep -vE "$(arLanIp6)" | head -n 1)
    else
        ip_address=$(ip -4 addr show "$record_nic_name" | grep 'inet' | awk '{print $2}' | cut -d/ -f1 | grep -vE "$(arLanIp4)" | head -n 1)
    fi
    log "debug" "Fetched local $record_type address for $record_nic_name: $ip_address" >&2
    echo $ip_address
}

# 获取公网IP
get_url_ip() {
    local record_type=$1
    local arIp6QueryUrl=$(echo "$config" | jq -r '.settings.arIp6QueryUrl')
    local arIp4QueryUrl=$(echo "$config" | jq -r '.settings.arIp4QueryUrl')

    if [ "$record_type" = "AAAA" ]; then
        log "debug" "get_url_ip arIp6QueryUrl: $arIp6QueryUrl"
        curl -s $arIp6QueryUrl | grep -vE "$(arLanIp6)"
    else
        log "debug" "get_url_ip arIp4QueryUrl: $arIp4QueryUrl"
        curl -s $arIp4QueryUrl | grep -vE "$(arLanIp4)"
    fi
}

# 创建cloudflare记录
create_record() {
    log "debug" "function--------- create_record"
    local domain_int=$1
    local record_int=$2
    local local_ip=$3
    local zone_id=$(echo "$config" | jq -r ".domains[$domain_int].zone_id")
    local record_name=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].name")
    local record_type=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].type")
    local record_proxy=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].proxy")
    local auth_key=$(echo "$config" | jq -r ".domains[$domain_int].auth_key")
    local url="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records"
    local current_time=$(date +"%Y-%m-%d %H:%M:%S")
    local data=$(jq -n --arg type "$record_type" --arg name "$record_name" --arg content "$local_ip" --argjson proxied "$record_proxy" --arg comment "$current_time" '{
        type: $type,
        name: $name,
        content: $content,
        proxied: $proxied,
        comment: $comment,
    }')
    log "info" "create_record $record_name.$domain_name"
    response=$(make_curl_request "POST" "$url" "$auth_key" "$data")
    log "debug" "Response from create_record: $response"

    if echo "$response" | jq -e '.success' >/dev/null; then
        log "info" "Record $record_name created successfully."
        log "debug" "response: $response"
    else
        log_and_exit "Failed to create record $record_name: $(echo "$response" | jq -r '.errors[0].message')"
    fi
}

# 更新cloudflare记录
update_record() {
    local domain_int=$1
    local record_int=$2
    local record_id=$3
    local local_ip=$4
    local zone_id=$(echo "$config" | jq -r ".domains[$domain_int].zone_id")
    local record_name=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].name")
    local record_type=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].type")
    local record_proxy=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].proxy")
    local auth_key=$(echo "$config" | jq -r ".domains[$domain_int].auth_key")
    local url="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id"
    local current_time=$(date +"%Y-%m-%d %H:%M:%S")
    local data=$(jq -n --arg type "$record_type" --arg name "$record_name" --arg content "$local_ip" --argjson proxied "$record_proxy" --arg comment "$current_time" '{
        type: $type,
        name: $name,
        content: $content,
        proxied: $proxied,
        comment: $comment
    }')
    log "info" "update_record $record_name.$domain_name"
    response=$(make_curl_request "PUT" "$url" "$auth_key" "$data")
    log "debug" "Response for $url update_record: $response"

    if echo "$response" | jq -e '.success' >/dev/null; then
        log "info" "Record $record_name updated successfully."
    else
        log_and_exit "Failed to update record $record_name: $(echo "$response" | jq -r '.errors[0].message')"
    fi

}

main() {

    check_environment

    check_config

    domain_size=$(get_domain_size)
    log "debug" "domain_size: $domain_size"

    # 遍历每个域名
    for domain_int in $(seq 0 $((domain_size - 1))); do
        # 获取域名
        domain_name=$(echo "$config" | jq -r ".domains[$domain_int].domain_name")
        echo "Domains： $((domain_int + 1))/$domain_size $domain_name"
        # 检查auth_key是否有效
        check_auth_key "$domain_int"
        # 检查zone_id是否存在
        check_zone_id "$domain_int"
        # 获取records数量
        records_size=$(echo "$config" | jq ".domains[$domain_int].records | length")
        for record_int in $(seq 0 $((records_size - 1))); do
            record_name=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].name")
            record_type=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].type")
            record_local=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].local")
            record_proxy=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].proxy")
            record_nic_name=$(echo "$config" | jq -r ".domains[$domain_int].records[$record_int].nic_name")
            log "info" "Records： $((record_int + 1))/$records_size $record_name.$domain_name"

            # 获取本地IP
            if [ "$record_local" = "true" ]; then
                local_ip=$(get_local_ip $record_nic_name $record_type)
            else
                local_ip=$(get_url_ip $record_type)
            fi

            # 获取cloudflare记录信息
            remote_info=$(get_record_info "$domain_int" "$record_int")
            remote_id=$(echo "$remote_info" | jq -r '.result[0].id')
            remote_ip=$(echo "$remote_info" | jq -r '.result[0].content')
            remote_proxy=$(echo "$remote_info" | jq -r '.result[0].proxied')

            # 若不存在，则创建记录
            if [ "$remote_id" = "null" ]; then
                log "debug" "$record_name.$domain_name not exist"
                create_record "$domain_int" "$record_int" "$local_ip"
                #跳出循环
                break
            fi

            log "debug" "remote_id: $remote_id"
            log "debug" "remote_ip: $remote_ip"
            log "debug" "remote_proxy: $remote_proxy"
            #如果local_ip和remote_ip不一致，或record_proxy和remote_proxy不一致，则更新记录
            if [ "$local_ip" != "$remote_ip" ] || [ "$record_proxy" != "$remote_proxy" ]; then
                log "debug" "local_ip: $local_ip"
                log "debug" "remote_ip: $remote_ip"
                log "debug" "record_proxy: $record_proxy"
                log "debug" "remote_proxy: $remote_proxy"
                log "debug" "<L>:$local_ip--<R>:$remote_ip"
                log "debug" "<L>:$record_proxy--<R>:$remote_proxy"
                log "info" "$remote_id:$record_name.$domain_name  ip or proxy not match, update record."
                update_record "$domain_int" "$record_int" "$remote_id" "$local_ip"
            else
                log "info" "$record_name.$domain_name match no need update"
            fi

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
#  version:250109
