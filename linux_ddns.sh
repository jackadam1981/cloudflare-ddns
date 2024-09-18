#!/bin/bash
CONFIG_FILE="cfconf.json"
# Exported variables
export config_domain zone_id auth_key config_name config_type config_proxy config_static config_nic_name FQDN_name
export record_info record_id record_ip record_proxy host_ip

# debug function
function debug() {
    [ "$_DEBUG" == "on" ] && echo "$@"
}

# log function
function jaLog() {
    echo "$@"
    logger "$log_header_name:$@"
}

# Define Excluded Local IPV6 Address Definition
arLanIp6() {
    local lanIps="(^$)"
    lanIps="$lanIps|(^::1$)"                            # RFC4291
    lanIps="$lanIps|(^64:[fF][fF]9[bB]:)"               # RFC6052, RFC8215
    lanIps="$lanIps|(^100::)"                           # RFC6666
    lanIps="$lanIps|(^2001:2:0?:)"                      # RFC5180
    lanIps="$lanIps|(^2001:[dD][bB]8:)"                 # RFC3849
    lanIps="$lanIps|(^[fF][cdCD][0-9a-fA-F]{2}:)"       # RFC4193 Unique local addresses
    lanIps="$lanIps|(^[fF][eE][8-9a-bA-B][0-9a-fA-F]:)" # RFC4291 Link-local addresses
    echo "$lanIps"
}

# try install pkgs
function abort_due_to_setup_problem {
    debug 'try install pkgs'
}

# check env function
function check_env() {
    if command -v "$@" >/dev/null 2>&1; then
        debug "$@ is available. Good."
    else
        debug "This script uses $@, but it does not seem to be installed"
        abort_due_to_setup_problem
        exit 1 # Add exit on failure
    fi
}

# check config
# ... existing code ...
function check_config() {
    if [ -f "$CONFIG_FILE" ]; then
        debug "Configuration file exists, start running"
        config=$(jq . <"$CONFIG_FILE")
        _DEBUG=$(echo "$config" | jq -r '.settings.debug')
        arIp6QueryUrl=$(echo "$config" | jq -r '.settings.arIp6QueryUrl')
        arIp4QueryUrl=$(echo "$config" | jq -r '.settings.arIp4QueryUrl')
        log_header_name=$(echo "$config" | jq -r '.settings.log_header_name')
        export log_header_name
    else
        config='{
    "settings": {
        "debug": "on",
        "arIp6QueryUrl": "https://6.ipw.cn",
        "arIp4QueryUrl": "https://4.ipw.cn",
        "log_header_name": "jaDDNS"
    },
    "config": [
        {
            "domain_name": "domain_name1",
            "zone_id": "",
            "auth_type": "key",
            "auth_key": "****************************************",
            "records": [
                {
                    "name": "host_name1",
                    "type": "AAAA",
                    "proxy": false,
                    "static": true,
                    "nic_name": "eth0"
                },
                {
                    "name": "host_name2",
                    "type": "A",
                    "proxy": true,
                    "static": false,
                    "nic_name": ""
                }
            ]
        },
        {
            "domain_name": "domain_name2",
            "zone_id": "",
            "auth_type": "key",
            "auth_key": "****************************************",
            "records": [
                {
                    "name": "host_name3",
                    "type": "AAAA",
                    "proxy": false,
                    "static": true,
                    "nic_name": "eth0"
                },
                {
                    "name": "host_name4",
                    "type": "AAAA",
                    "proxy": false,
                    "static": true,
                    "nic_name": "eth0"
                }
            ]
        }
    ]
}'
        echo "$config" | jq . >"$CONFIG_FILE"
        log_and_exit "The configuration file does not exist. A template has been created, please modify it before executing."
    fi
}
# ... existing code ...

# get cf zone_id
function get_zone_id() {
    local domain_int=$1 domain_name=$2 auth_key=$3
    local url="https://api.cloudflare.com/client/v4/zones?name=$domain_name"

    zone_id=$(curl -s -X GET "$url" \
        -H "Authorization: Bearer $auth_key" \
        -H "Content-Type: application/json" | jq -r '.result[0].id')

    if [ -z "$zone_id" ]; then
        log_and_exit "Failed to retrieve zone_id for domain: $domain_name"
    fi

    echo "$zone_id"
    # Write zone_id into the JSON configuration file
    jq --arg d_int "$domain_int" --arg id "$zone_id" '.config[$d_int|tonumber].zone_id=$id' "$CONFIG_FILE" >tmp.$$.json && mv tmp.$$.json "$CONFIG_FILE"
}
# get records info
function get_record_info() {
    local zone_id=$1 FQDN_name=$2 config_type=$3 auth_key=$4
    local url="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=$config_type&name=$FQDN_name"
    record_info=$(curl -s -X GET "$url" \
        -H "Authorization: Bearer $auth_key" \
        -H "Content-Type: application/json")
}

# get nic ip
function get_nic_ip() {
    debug "this is get nic $config_nic_name $config_type ip"

    if [ "$config_nic_name" = "remote" ]; then
        debug "get remote ip"
        if [ "$config_type" = "A" ]; then
            eval "${config_nic_name}_${config_type}=$(curl -s $arIp4QueryUrl)"
        elif [ "$config_type" = "AAAA" ]; then
            eval "${config_nic_name}_${config_type}=$(curl -s $arIp6QueryUrl)"
        fi
    elif command -v ip >/dev/null 2>&1; then
        if [ "$config_type" = "A" ]; then
            debug "ip command get $config_nic_name $config_type ip addr"
            eval "${config_nic_name}_${config_type}=$(ip addr show $config_nic_name | grep -oP '(?<=inet\s)\d+(\.\d+){3}')"
        elif [ "$config_type" = "AAAA" ]; then
            debug "ip command get $config_nic_name $config_type ip addr"
            ipv6_info=$(ip addr show $config_nic_name)

            # 提取出地址和有效时间
            max_valid=0
            eval "${config_nic_name}_${config_type}=''"
            # 逐行读取ipv6_info
            while read -r line; do
                # 如果含inet6，则提取地址
                if echo "$line" | grep -q 'inet6'; then
                    addr=$(echo "$line" | awk '{print $2}' | cut -d' ' -f2 | cut -d "/" -f1)
                elif echo "$line" | grep -q -e 'valid_lft'; then
                    valid=$(echo "$line" | awk '{print $2}' | cut -d "s" -f 1)
                    if [ "$valid" != "forever" ] && [ "$valid" -gt "$max_valid" ]; then
                        max_valid=$valid
                        eval "${config_nic_name}_${config_type}='$addr'"
                    fi
                fi
            done < <(echo "$ipv6_info")

            # 排除特定的 IPv6 地址范围
            lanIps=$(arLanIp6)
            eval "${config_nic_name}_${config_type}=$(echo "${!config_nic_name}_${config_type}" | grep -Ev "$lanIps")"
        fi
    elif command -v ifconfig >/dev/null 2>&1; then
        debug 'command ifconfig is ok'
        if [ "$config_type" = "A" ]; then
            debug "ifconfig command get $config_nic_name $config_type ip addr"
            eval "${config_nic_name}_${config_type}=$(ifconfig $config_nic_name | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1')"
        elif [ "$config_type" = "AAAA" ]; then
            debug "ifconfig command get $config_nic_name $config_type ip addr"
            ipv6_info=$(ifconfig $config_nic_name | grep 'inet6')
            lanIps=$(arLanIp6)

            while read -r line; do
                addr=$(echo "$line" | awk '{print $2}' | cut -d' ' -f2 | cut -d/ -f1)
                addr=$(echo "$addr" | grep -Ev "$lanIps")
                if [ "$addr" != "" ]; then
                    eval "${config_nic_name}_${config_type}=$addr"
                fi
            done < <(echo "$ipv6_info")
        fi
    fi
}

function get_host_ip() {
    debug 'this is get host ip'
    if [ "$config_static" = "false" ]; then
        config_nic_name="remote"
    fi

    tag=$(eval echo '$'${config_nic_name}_${config_type})

    if [ -z "$tag" ]; then
        get_nic_ip
    fi

    compare
}
# update
function update() {
    local res result
    res=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
        -H "Authorization: Bearer $auth_key" \
        -H "Content-Type: application/json" \
        --data "{\"content\":\"$host_ip\",\"name\":\"$config_name\",\"proxied\":$config_proxy,\"type\":\"$config_type\"}")
    result=$(echo "$res" | jq -r '.success')
    if [ "$result" == true ]; then
        jaLog "update success:$record_name:$host_ip"
    else
        jaLog "update fail:$record_name:$host_ip"
        jaLog "$update"
    fi
}

# compare
function compare() {
    debug 'Compare records'
    host_ip=$(eval echo '$'${config_nic_name}_${config_type})
    if [[ $config_proxy != $record_proxy || $record_ip != $host_ip ]]; then
        jaLog "record proxy set:$record_proxy "
        jaLog "config proxy set:$config_proxy "
        jaLog "host_ip:$host_ip "
        jaLog "record_ip:$record_ip "

        update
    else
        jaLog "No upgrade $FQDN_name"
    fi
}

# get host ip
function get_host_ip() {
    debug 'this is get host ip'
    if [ "$config_static" = "false" ]; then
        config_nic_name="remote"
    fi

    tag=$(eval echo '$'${config_nic_name}_${config_type})

    if [ -z "$tag" ]; then
        get_nic_ip
    fi

    compare
}

# check records
function check_records() {
    local domain_int=$1 config_size config_int=0
    config_size=$(echo "$config" | jq .config["$domain_int"].records | jq length)
    while [ $config_int -lt $config_size ]; do
        config_name=$(echo "$config" | jq -r .config["$domain_int"].records["$config_int"].name)
        config_type=$(echo "$config" | jq -r .config["$domain_int"].records["$config_int"].type)
        config_proxy=$(echo "$config" | jq -r .config["$domain_int"].records["$config_int"].proxy)
        config_static=$(echo "$config" | jq -r .config["$domain_int"].records["$config_int"].static)
        config_nic_name=$(echo "$config" | jq -r .config["$domain_int"].records["$config_int"].nic_name)
        FQDN_name=$config_name.$domain_name
        debug "---------------------------------"
        debug "check $FQDN_name"
        # get record info
        get_record_info "$zone_id" "$FQDN_name" "$config_type" "$auth_key"

        # debug record_info: $record_info
        record_id=$(echo "$record_info" | jq -r '.result[0].id')
        record_ip=$(echo "$record_info" | jq -r '.result[0].content')
        record_proxy=$(echo "$record_info" | jq -r '.result[0].proxied')

        if [ "$record_id" != "null" ]; then
            get_host_ip
        else
            debug "Record $FQDN_name does not exist, creating..."
            if [ "$config_static" = "true" ]; then
                if [ "$config_type" = "AAAA" ]; then
                    host_ip=$(ip -6 addr show "$config_nic_name" | grep 'inet6' | awk '{print $2}' | cut -d/ -f1 | head -n 1)
                else
                    host_ip=$(ip -4 addr show "$config_nic_name" | grep 'inet' | awk '{print $2}' | cut -d/ -f1 | head -n 1)
                fi
            else
                if [ "$config_type" = "AAAA" ]; then
                    host_ip=$(curl -s "$arIp6QueryUrl")
                else
                    host_ip=$(curl -s "$arIp4QueryUrl")
                fi
            fi
            create_record "$domain_int" "$domain_name" "$auth_key" "$config_name" "$config_type" "$host_ip" "$config_proxy"
        fi

        config_int=$((config_int + 1))
    done
}


# check domain
function check_domain() {
    # read config
    config=$(jq <cfconf.json)

    local domain_size domain_int=0
    domain_size=$(echo "$config" | jq .config | jq length)
    while [ $domain_int -lt $domain_size ]; do
        # read config
        domain_name=$(echo "$config" | jq -r .config["$domain_int"].domain_name)
        zone_id=$(echo "$config" | jq -r .config["$domain_int"].zone_id)
        login_email=$(echo "$config" | jq -r .config["$domain_int"].login_email)
        auth_type=$(echo "$config" | jq -r .config["$domain_int"].auth_type)
        auth_key=$(echo "$config" | jq -r .config["$domain_int"].auth_key)

        debug "check domain: $domain_name"
        # check zone_id
        if [ -z "$zone_id" ]; then
            zone_id=$(get_zone_id "$domain_int" "$domain_name" "$auth_key")
            debug "$domain_name zone_id:$zone_id"
        fi

        # check records
        check_records "$domain_int"

        domain_int=$((domain_int + 1))
    done
}

function create_record() {
    local domain_int=$1 domain_name=$2 auth_key=$3 record_name=$4 record_type=$5 record_content=$6 record_proxy=$7

    local url="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records"
    local data=$(jq -n --arg type "$record_type" --arg name "$record_name" --arg content "$record_content" --argjson proxied "$record_proxy" '{
        type: $type,
        name: $name,
        content: $content,
        proxied: $proxied
    }')

    response=$(curl -s -X POST "$url" \
        -H "Authorization: Bearer $auth_key" \
        -H "Content-Type: application/json" \
        --data "$data")

    if echo "$response" | jq -e '.success' >/dev/null; then
        debug "Record $record_name.$domain_name created successfully."
    else
        log_and_exit "Failed to create record $record_name.$domain_name: $(echo "$response" | jq -r '.errors[0].message')"
    fi
}

function update_or_create_record() {
    local domain_int=$1 domain_name=$2 auth_key=$3 record_name=$4 record_type=$5 record_content=$6 record_proxy=$7

    local url="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=$record_type&name=$record_name.$domain_name"
    response=$(curl -s -X GET "$url" \
        -H "Authorization: Bearer $auth_key" \
        -H "Content-Type: application/json")

    record_id=$(echo "$response" | jq -r '.result[0].id')

    if [ "$record_id" != "null" ]; then
        debug "Record $record_name.$domain_name exists, updating..."
        update_record "$domain_int" "$domain_name" "$auth_key" "$record_id" "$record_name" "$record_type" "$record_content" "$record_proxy"
    else
        debug "Record $record_name.$domain_name does not exist, creating..."
        create_record "$domain_int" "$domain_name" "$auth_key" "$record_name" "$record_type" "$record_content" "$record_proxy"
    fi
}

function update_record() {
    local domain_int=$1 domain_name=$2 auth_key=$3 record_id=$4 record_name=$5 record_type=$6 record_content=$7 record_proxy=$8

    local url="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id"
    local data=$(jq -n --arg type "$record_type" --arg name "$record_name" --arg content "$record_content" --argjson proxied "$record_proxy" '{
        type: $type,
        name: $name,
        content: $content,
        proxied: $proxied
    }')

    response=$(curl -s -X PUT "$url" \
        -H "Authorization: Bearer $auth_key" \
        -H "Content-Type: application/json" \
        --data "$data")

    if echo "$response" | jq -e '.success' >/dev/null; then
        debug "Record $record_name.$domain_name updated successfully."
    else
        log_and_exit "Failed to update record $record_name.$domain_name: $(echo "$response" | jq -r '.errors[0].message')"
    fi
}

function process_records() {
    local domain_int=$1 domain_name=$2 auth_key=$3 records=$4

    for record in $(echo "$records" | jq -c '.[]'); do
        record_name=$(echo "$record" | jq -r '.name')
        record_type=$(echo "$record" | jq -r '.type')
        record_proxy=$(echo "$record" | jq -r '.proxy')
        record_static=$(echo "$record" | jq -r '.static')
        nic_name=$(echo "$record" | jq -r '.nic_name')

        if [ "$record_static" = "true" ]; then
            if [ "$record_type" = "AAAA" ]; then
                record_content=$(ip -6 addr show "$nic_name" | grep 'inet6' | awk '{print $2}' | cut -d/ -f1 | head -n 1)
            else
                record_content=$(ip -4 addr show "$nic_name" | grep 'inet' | awk '{print $2}' | cut -d/ -f1 | head -n 1)
            fi
        else
            if [ "$record_type" = "AAAA" ]; then
                record_content=$(curl -s "$arIp6QueryUrl")
            else
                record_content=$(curl -s "$arIp4QueryUrl")
            fi
        fi

        update_or_create_record "$domain_int" "$domain_name" "$auth_key" "$record_name" "$record_type" "$record_content" "$record_proxy"
    done
}
# main function·
function main() {
    # test debug log
    # debug 'this is main function'
    jaLog 'this is cloudflare ddns script'

    # Check the environment
    check_env 'jq'
    check_env 'curl'
    debug 'check all over'
    # Check the config
    check_config

    # Check the Domain
    check_domain
}

main

# read logs command
# journalctl --no-pager --since today -g 'jaDDNS'
# logread -e jaDDNS
