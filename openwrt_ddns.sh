#!/bin/sh

# Debug function
debug() {
    if [ "$_DEBUG" = "on" ]; then
        echo "DEBUG: $1"
    fi
}

# Log and exit function
log_and_exit() {
    echo "$1"
    exit 1
}

# Create record function
create_record() {
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

# Update or create record function
update_or_create_record() {
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

# Update record function
update_record() {
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

# Get host IP function
get_host_ip() {
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

# Check records function
check_records() {
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

# Main function to check configuration and process records
check_config() {
    if [ -f "cfconf.json" ]; then
        debug "Configuration file exists, start running"
        config=$(jq . <cfconf.json)
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
        echo "$config" | jq . >cfconf.json
        log_and_exit "The configuration file does not exist. A template has been created, please modify it before executing."
    fi
}

# Main script execution
main() {
    check_config

    config_size=$(echo "$config" | jq .config | jq length)
    domain_int=0
    while [ $domain_int -lt $config_size ]; do
        domain_name=$(echo "$config" | jq -r .config["$domain_int"].domain_name)
        zone_id=$(echo "$config" | jq -r .config["$domain_int"].zone_id)
        auth_key=$(echo "$config" | jq -r .config["$domain_int"].auth_key)

        if [ "$zone_id" = "null" ] || [ -z "$zone_id" ]; then
            zone_id=$(get_zone_id "$domain_int" "$domain_name" "$auth_key")
        fi

        check_records "$domain_int"

        domain_int=$((domain_int + 1))
    done
}

main
