#!/bin/bash

# debug set  you can set on or any else to turn off.
_DEBUG="on"
# debug use Example Need to be placed after the debug function to run
# debug "debug test"

arIp6QueryUrl="https://6.ipw.cn"
arIp4QueryUrl="https://4.ipw.cn"

# log set header
export log_header_name="jaDDNS"
# log use Example
# jaLog "this is log test"

export config_domain
export zone_id
export auth_key
export config_name
export config_type
export config_proxy
export config_static
export config_nic_name
export FQDN_name

export record_info
export record_id
export record_ip
export record_proxy

export host_ip

#debug function
function debug() {
    [ "$_DEBUG" == "on" ] && echo $@
}

# log function
function jaLog() {
    echo "$@"
    logger $log_header_name:"$@"
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

    echo $lanIps

}

# try install pkgs
function abort_due_to_setup_problem {
    debug 'try install pkgs'
}

# check env function
function check_env() {
    if command -v $@ >/dev/null 2>&1; then
        debug "$@ is available. Good."
    else
        debug "This script uses $@, but it does not seem to be installed"
        abort_due_to_setup_problem
    fi

}

# check config
function check_config() {
    if [ -f "cfconf.json" ]; then
        debug "Configuration file exists, start running"
    else
        config={\"config\":[{\"domain_name\":\"domain_name1\",\"zone_id\":\"\",\"auth_type\":\"key\",\"auth_key\":\"****************************************\",\"records\":[{\"name\":\"host_name1\",\"type\":\"AAAA\",\"proxy\":false,\"static\":true,\"nic_name\":\"eth0\"},{\"name\":\"host_name2\",\"type\":\"A\",\"proxy\":true,\"static\":false,\"nic_name\":\"\"}]},{\"domain_name\":\"domain_name2\",\"zone_id\":\"\",\"auth_type\":\"key\",\"auth_key\":\"****************************************\",\"records\":[{\"name\":\"host_name3\",\"type\":\"AAAA\",\"proxy\":false,\"static\":true,\"nic_name\":\"eth0\"},{\"name\":\"host_name4\",\"type\":\"AAAA\",\"proxy\":false,\"static\":true,\"nic_name\":\"eth0\"}]}]}
        echo $config | jq . >test.json
        jaLog "The configuration file does not exist. A template has been created, please modify it before executing."
        exit 1
    fi
}

# get cf zone_id
function get_zone_id() {
    domain_int=$1
    domain_name=$2
    auth_key=$3
    url="https://api.cloudflare.com/client/v4/zones?name=$domain_name"

    zone_id=$(curl -s -X GET $url \
        -H "Authorization: Bearer $auth_key" \
        -H "Content-Type: application/json" | jq -r '.result[0].id')

    echo $zone_id
    # Write zone_id into the JSON configuration file
    echo $config | jq --arg d_int $((domain_int)) --arg id ${zone_id} '.config[$d_int|tonumber].zone_id=$id' | jq >cfconf.json
}

# get records info
function get_record_info() {
    zone_id=$1
    FQDN_name=$2
    config_type=$3
    auth_key=$4

    url="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=$config_type&name=$FQDN_name"
    record_info=$(curl -s -X GET $url \
        -H "Authorization: Bearer $auth_key" \
        -H "Content-Type: application/json")
}

# get nic ip
function get_nic_ip() {
    debug "this is get nic $config_nic_name $config_type ip"

    if [ "$config_nic_name" = "remote" ]; then
        debug "get remote ip"
        if [ "$config_type" = "A" ]; then
            eval ${config_nic_name}_${config_type}=$(curl -s $arIp4QueryUrl)
        elif [ "$config_type" = "AAAA" ]; then
            eval ${config_nic_name}_${config_type}=$(curl -s $arIp6QueryUrl)
        fi

    elif command -v ip >/dev/null 2>&1; then
        if [ "$config_type" = "A" ]; then
            debug "ip command get $config_nic_name $config_type ip addr"
            eval ${config_nic_name}_${config_type}=$(ip addr show $config_nic_name | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        elif [ "$config_type" = "AAAA" ]; then
            debug "ip command get  $config_nic_name $config_type ip addr"
            ipv6_info=$(ip addr show $config_nic_name)

            # 提取出地址和有效时间
            max_valid=0
            eval ${config_nic_name}_${config_type}=""
            # 逐行读取ipv6_info
            while read -r line; do
                # echo "line::$line"
                # 如果含inet6，则提取地址
                if echo "$line" | grep -q 'inet6'; then
                    # echo "addr::$line"
                    addr=$(echo "$line" | awk '{print $2}' | cut -d' ' -f2 | cut -d "/" -f1)
                    # echo $addr
                    # 如果含有valid_lft，则提取有效时间
                elif echo "$line" | grep -q -e 'valid_lft'; then
                    # echo "valid::$line"
                    valid=$(echo "$line" | awk '{print $2}' | cut -d "s" -f 1)
                    # echo $valid
                    # 如果有效时间大于最大有效时间，则更新最大有效时间和最大地址
                    if [ "$valid" != "forever" ] && [ "$valid" -gt "$max_valid" ]; then
                        max_valid=$valid
                        eval ${config_nic_name}_${config_type}="$addr"
                    fi
                fi
                # 逐行读取ipv6_info
            done < <(echo "$ipv6_info")

        fi

    elif command -v ifconfig >/dev/null 2>&1; then
        debug 'command ifconfig is ok'
        if [ "$config_type" = "A" ]; then
            debug "ifconfig command get  $config_nic_name $config_type ip addr"
            eval ${config_nic_name}_${config_type}=$(ifconfig $config_nic_name | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1')
        elif [ "$config_type" = "AAAA" ]; then
            debug "ifconfig command get  $config_nic_name $config_type ip addr"
            ipv6_info=$(ifconfig $config_nic_name | grep 'inet6')
            lanIps=$(arLanIp6)

            while read -r line; do
                addr=$(echo "$line" | awk '{print $2}' | cut -d' ' -f2 | cut -d/ -f1)
                addr=$(echo "$addr" | grep -Ev "$lanIps")
                if [ "$addr" != "" ]; then
                    eval ${config_nic_name}_${config_type}=$addr
                fi
            done < <(echo "$ipv6_info")
        fi

    fi

}

# update
function update() {

    res=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
        -H "Authorization: Bearer $auth_key" \
        -H "Content-Type: application/json" \
        --data "{\"content\":\"$host_ip\",\"name\":\"$config_name\",\"proxied\":$config_proxy,\"type\":\"$config_type\"}")
    result=$(echo $res | jq -r '.success')
    if [ "$result" == true ]; then
        jaLog "update success:$record_name:$host_ip"
    else
        jaLog "update fail:$record_name:$host_ip"
        jaLog $update
    fi
}

# compare
function compare() {
    debug 'Compare records'
    host_ip=$(eval echo '$'${config_nic_name}_${config_type})
    if [[ $config_proxy != $record_proxy || $record_ip != $host_ip ]]; then
        jaLog "record porxy set:$record_proxy "
        jaLog "config porxy set:$config_proxy "
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
    domain_int=$@
    config_size=$(echo $config | jq .config[$domain_int].records | jq length)
    config_int=0
    while [ $config_int -lt $config_size ]; do
        config_name=$(echo $config | jq -r .config[$domain_int].records[$config_int].name)
        config_type=$(echo $config | jq -r .config[$domain_int].records[$config_int].type)
        config_proxy=$(echo $config | jq -r .config[$domain_int].records[$config_int].proxy)
        config_static=$(echo $config | jq -r .config[$domain_int].records[$config_int].static)
        config_nic_name=$(echo $config | jq -r .config[$domain_int].records[$config_int].nic_name)
        FQDN_name=$config_name.$domain_name
        debug "---------------------------------"
        debug "check $FQDN_name"
        # get record info
        get_record_info $zone_id $FQDN_name $config_type $auth_key

        # debug record_info: $record_info
        record_id=$(echo $record_info | jq -r '.result[0].id')
        record_ip=$(echo $record_info | jq -r '.result[0].content')
        record_proxy=$(echo $record_info | jq -r '.result[0].proxied')

        get_host_ip

        config_int=$(expr $config_int + 1)
    done

}

# check domain
function check_domain() {

    domain_size=$(echo $config | jq .config | jq length)
    domain_int=0
    while [ $domain_int -lt $domain_size ]; do

        # read config
        domain_name=$(echo $config | jq -r .config[$domain_int].domain_name)
        zone_id=$(echo $config | jq -r .config[$domain_int].zone_id)
        login_email=$(echo $config | jq -r .config[$domain_int].login_email)
        auth_type=$(echo $config | jq -r .config[$domain_int].auth_type)
        auth_key=$(echo $config | jq -r .config[$domain_int].auth_key)

        debug "check domain: $domain_name"
        # check zone_id
        if [ -z $zone_id ]; then
            zone_id=$(get_zone_id $domain_int $domain_name $auth_key)
            debug "$domain_name zone_id:$zone_id"
        fi

        # check records
        check_records $domain_int

        domain_int=$(expr $domain_int + 1)
    done

}

# main function
function main() {

    # test debug log
    # debug 'this is main funciont'
    # jaLog 'this is log test'

    # Check the environment
    check_env 'jq'
    check_env 'curl'
    debug 'check all over'
    # Check the config
    check_config

    # read config
    config=$(cat cfconf.json | jq)

    # Check the Domain
    check_domain
}

main

#  read logs command

#   journalctl --no-pager --since today -g 'jaDDNS'
#   logread -e jaDDNS
