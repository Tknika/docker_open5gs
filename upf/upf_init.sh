#!/bin/bash

# BSD 2-Clause License

# Copyright (c) 2020-2025, Supreeth Herle
# All rights reserved.

# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:

# 1. Redistributions of source code must retain the above copyright notice, this
#    list of conditions and the following disclaimer.

# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.

# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

export LC_ALL=C.UTF-8
export LANG=C.UTF-8
export IP_ADDR=$(awk 'END{print $1}' /etc/hosts)
export IF_NAME=$(ip r | awk '/default/ { print $5 }')

trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

validate_interface_name_for_mode() {
    local if_name="$1"
    if [ "$UPF_TUNTAP_MODE" = "tap" ]; then
        if [[ "$if_name" != *"tap"* ]]; then
            echo "Error: When UPF_TUNTAP_MODE is 'tap', interface '$if_name' must contain 'tap'" >&2
            return 1
        fi
    elif [ "$UPF_TUNTAP_MODE" = "tun" ]; then
        if [[ "$if_name" == *"tap"* ]]; then
            echo "Error: When UPF_TUNTAP_MODE is 'tun', interface '$if_name' must not contain 'tap'" >&2
            return 1
        fi
    else
        echo "Error: UPF_TUNTAP_MODE must be either 'tap' or 'tun'" >&2
        return 1
    fi
}

generate_dynamic_upf_session_block() {
    local dnn_list="$1"
    local ipv6_base_prefix="${UPF_DNN_IPV6_BASE:-${SMF_DNN_IPV6_BASE:-fd00:230}}"
    local session_block=""
    local dnn_index=1
    local raw_entry entry dnn_name subnet if_name extra gateway_ip ipv6_idx ipv6_subnet ipv6_gateway

    ipv6_base_prefix="${ipv6_base_prefix%:}"

    IFS=';' read -ra dnn_entries <<< "$dnn_list"
    for raw_entry in "${dnn_entries[@]}"; do
        entry=$(trim_whitespace "$raw_entry")
        [ -z "$entry" ] && continue

        IFS=',' read -r dnn_name subnet if_name extra <<< "$entry"
        dnn_name=$(trim_whitespace "$dnn_name")
        subnet=$(trim_whitespace "$subnet")
        if_name=$(trim_whitespace "$if_name")
        extra=$(trim_whitespace "$extra")

        if [ -z "$dnn_name" ] || [ -z "$subnet" ] || [ -z "$if_name" ] || [ -n "$extra" ]; then
            echo "Error: Invalid DNN_LIST entry '$entry'. Expected format: <dnn_name>,<subnet>,<interface_name>" >&2
            return 1
        fi

        validate_interface_name_for_mode "$if_name" || return 1

        ip link delete "$if_name" 2>/dev/null

        gateway_ip=$(python3 /mnt/upf/ip_utils.py --ip_range "$subnet")
        if [ $? -ne 0 ] || [ -z "$gateway_ip" ]; then
            echo "Error: Invalid IPv4 subnet '$subnet' in DNN_LIST entry '$entry'" >&2
            return 1
        fi

        ipv6_idx=$(printf '%x' "$dnn_index")
        ipv6_subnet="${ipv6_base_prefix}:${ipv6_idx}::/48"
        ipv6_gateway="${ipv6_base_prefix}:${ipv6_idx}::1"

        if [ "$dnn_name" = "ims" ]; then
            python3 /mnt/upf/tun_if.py --tun_ifname "$if_name" --tun_ifmode "$UPF_TUNTAP_MODE" --ipv4_range "$subnet" --ipv6_range "$ipv6_subnet" --no_nat_ipv4_addr "$PCSCF_IP" --no_nat_ipv6_addr 2001:230:eafe::1 --nat_rule 'no' || return 1
        else
            python3 /mnt/upf/tun_if.py --tun_ifname "$if_name" --tun_ifmode "$UPF_TUNTAP_MODE" --ipv4_range "$subnet" --ipv6_range "$ipv6_subnet" --no_nat_ipv4_addr "$PCSCF_IP" --no_nat_ipv6_addr 2001:230:eafe::1 || return 1
        fi

        if [ -z "$session_block" ]; then
            session_block="    session:\n"
        fi

        session_block+="      - subnet: ${subnet}\\n"
        session_block+="        gateway: ${gateway_ip}\\n"
        session_block+="        dnn: ${dnn_name}\\n"
        session_block+="        dev: ${if_name}\\n"
        session_block+="      - subnet: ${ipv6_subnet}\\n"
        session_block+="        gateway: ${ipv6_gateway}\\n"
        session_block+="        dnn: ${dnn_name}\\n"
        session_block+="        dev: ${if_name}\\n"

        dnn_index=$((dnn_index + 1))
    done

    if [ -z "$session_block" ]; then
        echo "Error: DNN_LIST is set but no valid entries were found" >&2
        return 1
    fi

    printf '%b' "$session_block"
}

replace_upf_session_block() {
    local target_file="$1"
    local session_block="$2"
    local tmp_file

    tmp_file=$(mktemp)
    awk -v session_block="$session_block" '
        BEGIN { in_session = 0 }
        {
            if ($0 ~ /^    session:$/) {
                print session_block
                in_session = 1
                next
            }
            if (in_session && $0 ~ /^    metrics:$/) {
                in_session = 0
                print
                next
            }
            if (!in_session) {
                print
            }
        }
    ' "$target_file" > "$tmp_file" && mv "$tmp_file" "$target_file"
}

# use nftables instead of iptables
update-alternatives --set iptables `which iptables-nft`
update-alternatives --set ip6tables `which ip6tables-nft`

cp /mnt/upf/upf.yaml install/etc/open5gs

TRIMMED_DNN_LIST=$(trim_whitespace "${DNN_LIST}")
if [ -n "$TRIMMED_DNN_LIST" ]; then
    DYNAMIC_SESSION_BLOCK=$(generate_dynamic_upf_session_block "$TRIMMED_DNN_LIST") || exit 1
    replace_upf_session_block install/etc/open5gs/upf.yaml "$DYNAMIC_SESSION_BLOCK"
else
    # Remove UPF Interfaces if they exist
    ip link delete $UPF_INTERNET_APN_IF_NAME 2>/dev/null
    ip link delete $UPF_IMS_APN_IF_NAME 2>/dev/null

    validate_interface_name_for_mode "$UPF_INTERNET_APN_IF_NAME" || exit 1
    validate_interface_name_for_mode "$UPF_IMS_APN_IF_NAME" || exit 1

    python3 /mnt/upf/tun_if.py --tun_ifname $UPF_INTERNET_APN_IF_NAME --tun_ifmode $UPF_TUNTAP_MODE --ipv4_range $UE_IPV4_INTERNET --ipv6_range 2001:230:cafe::/48 --no_nat_ipv4_addr $PCSCF_IP --no_nat_ipv6_addr 2001:230:eafe::1
    python3 /mnt/upf/tun_if.py --tun_ifname $UPF_IMS_APN_IF_NAME --tun_ifmode $UPF_TUNTAP_MODE --ipv4_range $UE_IPV4_IMS --ipv6_range 2001:230:babe::/48 --no_nat_ipv4_addr $PCSCF_IP --no_nat_ipv6_addr 2001:230:eafe::1 --nat_rule 'no'

    UE_IPV4_INTERNET_APN_GATEWAY_IP=$(python3 /mnt/upf/ip_utils.py --ip_range $UE_IPV4_INTERNET)
    UE_IPV4_IMS_TUN_IP=$(python3 /mnt/upf/ip_utils.py --ip_range $UE_IPV4_IMS)
fi

sed -i 's|UPF_IP|'$UPF_IP'|g' install/etc/open5gs/upf.yaml
sed -i 's|SMF_IP|'$SMF_IP'|g' install/etc/open5gs/upf.yaml
sed -i 's|UE_IPV4_INTERNET_APN_GATEWAY_IP|'$UE_IPV4_INTERNET_APN_GATEWAY_IP'|g' install/etc/open5gs/upf.yaml
sed -i 's|UE_IPV4_INTERNET_APN_SUBNET|'$UE_IPV4_INTERNET'|g' install/etc/open5gs/upf.yaml
sed -i 's|UE_IPV4_IMS_TUN_IP|'$UE_IPV4_IMS_TUN_IP'|g' install/etc/open5gs/upf.yaml
sed -i 's|UE_IPV4_IMS_SUBNET|'$UE_IPV4_IMS'|g' install/etc/open5gs/upf.yaml
sed -i 's|UPF_ADVERTISE_IP|'$UPF_ADVERTISE_IP'|g' install/etc/open5gs/upf.yaml
sed -i 's|MAX_NUM_UE|'$MAX_NUM_UE'|g' install/etc/open5gs/upf.yaml
sed -i 's|UPF_INTERNET_APN_IF_NAME|'$UPF_INTERNET_APN_IF_NAME'|g' install/etc/open5gs/upf.yaml
sed -i 's|UPF_IMS_APN_IF_NAME|'$UPF_IMS_APN_IF_NAME'|g' install/etc/open5gs/upf.yaml

cd install/bin
exec ./open5gs-upfd $@

# Sync docker time
#ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone
