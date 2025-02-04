#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 使用说明
show_usage() {
    echo -e "${YELLOW}=== 代理服务器配置流程 ===${NC}"
    echo -e "推荐配置顺序："
    echo -e "1. 环境配置 - 安装必要的软件包和服务"
    echo -e "2. BBR加速 - 优化网络性能"
    echo -e "3. IPv6管理 - 配置IPv6地址（可选）"
    echo -e "4. 带宽控制 - 设置流量限制"
    echo -e "5. SOCKS5设置 - 配置代理服务"
    echo -e "6. IP策略 - 设置进出流量规则"
    echo -e "7. 连通性测试 - 验证代理是否正常工作"
    echo -e "${GREEN}提示：首次使用请按照顺序依次配置${NC}"
    echo -e "${RED}注意：清除规则(选项9)会重置所有设置${NC}\n"
}

# 系统检测模块
detect_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            "ubuntu"|"debian")
                service_manager="systemctl"
                ;;
            "centos")
                if (( $(echo "$VERSION_ID >= 7" | bc -l) )); then
                    service_manager="systemctl"
                else
                    service_manager="service"
                fi
                ;;
            *)
                echo -e "${RED}不支持的系统${NC}"
                return 1
                ;;
        esac
    else
        echo -e "${RED}无法识别的系统${NC}"
        return 1
    fi
}

# 软件安装模块
check_and_install_unzip() {
    if ! command -v unzip &> /dev/null; then
        echo "未安装unzip，正在安装..."
        if [ "$ID" == "centos" ]; then
            yum install unzip -y
        else
            apt-get update && apt-get install unzip -y
        fi
    fi
    return 0
}

check_and_install_iptables() {
    if ! command -v iptables &> /dev/null; then
        echo "未安装iptables，正在安装..."
        if [ "$ID" == "centos" ]; then
            yum install iptables-services -y
            systemctl enable iptables
        else
            apt-get update && apt-get install iptables-persistent -y
        fi
    fi
    return 0
}

# 系统检查模块
check_ipv6() {
    if ! sysctl -a 2>/dev/null | grep -q "net.ipv6.conf.all.disable_ipv6 = 0"; then
        echo "启用IPv6支持..."
        sysctl -w net.ipv6.conf.all.disable_ipv6=0
        sysctl -w net.ipv6.conf.default.disable_ipv6=0
        echo "net.ipv6.conf.all.disable_ipv6 = 0" >> /etc/sysctl.conf
        echo "net.ipv6.conf.default.disable_ipv6 = 0" >> /etc/sysctl.conf
        sysctl -p
    fi
    return 0
}

# Xray安装模块
install_xray() {
    echo "正在从GitHub下载Xray..."
    check_and_install_unzip
    wget --no-check-certificate -O /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
    unzip /tmp/xray.zip -d /usr/local/bin
    rm -f /tmp/xray.zip
    chmod +x /usr/local/bin/xray
    echo "Xray已下载并设置为可执行。"
    return 0
}

# 环境配置模块
setup_environment() {
    echo "设置防火墙规则..."
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -t nat -F
    iptables -t mangle -F
    iptables -F
    iptables -X
    iptables-save

    install_xray
    echo "创建Xray服务文件..."
    cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=The Xray Proxy Server
After=network-online.target

[Service]
ExecStart=/usr/local/bin/xray -c /etc/xray/serve.json
ExecStop=/bin/kill -s QUIT \$MAINPID
Restart=always
RestartSec=15s

[Install]
WantedBy=multi-user.target
EOF

    echo "启动Xray服务..."
    $service_manager daemon-reload
    $service_manager enable xray
    $service_manager start xray
    echo "环境配置完成。"
    return 0
}

# IPv6相关函数
generate_random_hex() {
    local length=$1
    head -c $((length/2)) /dev/urandom | hexdump -ve '1/1 "%.2x"'
}

get_main_interface() {
    MAIN_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [ -z "$MAIN_INTERFACE" ]; then
        echo -e "${RED}错误: 无法检测到主网卡${NC}"
        return 1
    fi
    echo $MAIN_INTERFACE
}

get_ipv6_prefix() {
    local interface=$1

    # 获取非本地IPv6地址
    local current_ipv6=$(ip -6 addr show dev $interface | grep "scope global" | grep -v "temporary" | head -n1 | awk '{print $2}')

    if [ -z "$current_ipv6" ]; then
        echo -e "${RED}错误: 未检测到IPv6地址${NC}" >&2
        return 1
    fi

    # 从CIDR格式中提取地址部分
    local ipv6_addr=$(echo "$current_ipv6" | cut -d'/' -f1)

    # 提取前缀（前64位）
    local prefix=$(echo "$ipv6_addr" | sed -E 's/:[^:]+:[^:]+:[^:]+:[^:]+$/::/')

    if [ -z "$prefix" ]; then
        echo -e "${RED}错误: 无法提取IPv6前缀${NC}" >&2
        return 1
    fi

    echo "$prefix"
}

add_ipv6_addresses() {
    local interface=$1
    local prefix=$2
    local num=$3

    echo -e "${YELLOW}准备添加IPv6地址:${NC}"
    echo "使用网络接口: $interface"
    echo "使用IPv6前缀: $prefix"
    echo "计划添加数量: $num"

    # 获取现有地址列表
    declare -A existing_addresses
    while read -r addr; do
        existing_addresses["$addr"]=1
    done < <(ip -6 addr show dev $interface | grep "inet6" | grep -v "fe80" | awk '{print $2}' | cut -d'/' -f1)

    # 显示当前地址
    echo -e "\n${YELLOW}当前IPv6地址:${NC}"
    ip -6 addr show dev $interface

    count=0
    attempts=0
    max_attempts=$((num * 3))  # 设置最大尝试次数

    while [ $count -lt $num ] && [ $attempts -lt $max_attempts ]; do
        ((attempts++))

        # 生成后四组十六进制数
        suffix=$(printf "%04x:%04x:%04x:%04x" \
            $((RANDOM % 65536)) \
            $((RANDOM % 65536)) \
            $((RANDOM % 65536)) \
            $((RANDOM % 65536)))

        # 构建完整的IPv6地址
        NEW_IPV6="${prefix%::}:${suffix}"

        # 检查是否已存在
        if [ "${existing_addresses[$NEW_IPV6]}" == "1" ]; then
            echo -e "${YELLOW}地址已存在，重新生成: $NEW_IPV6${NC}"
            continue
        fi

        echo -e "\n${YELLOW}尝试添加新地址: $NEW_IPV6${NC}"
        if ip -6 addr add "$NEW_IPV6/64" dev "$interface" 2>/dev/null; then
            echo -e "${GREEN}成功添加IPv6地址: $NEW_IPV6${NC}"
            existing_addresses["$NEW_IPV6"]=1
            ((count++))

            # 创建持久化配置
            mkdir -p /etc/network/interfaces.d
            echo "iface $interface inet6 static" >> /etc/network/interfaces.d/60-ipv6-addresses
            echo "    address $NEW_IPV6/64" >> /etc/network/interfaces.d/60-ipv6-addresses
            echo "" >> /etc/network/interfaces.d/60-ipv6-addresses
        else
            echo -e "${RED}添加地址失败: $NEW_IPV6${NC}"
        fi
    done

    if [ $count -lt $num ]; then
        echo -e "${RED}警告: 只成功添加了 $count 个地址（目标: $num）${NC}"
    fi

    # 显示最终结果
    echo -e "\n${YELLOW}更新后的IPv6地址:${NC}"
    ip -6 addr show dev $interface

    # 确保配置文件存在
    if [ ! -f "/etc/network/interfaces" ]; then
        echo "auto lo" > /etc/network/interfaces
        echo "iface lo inet loopback" >> /etc/network/interfaces
        echo "" >> /etc/network/interfaces
    fi

    # 添加 source 指令（如果不存在）
    if ! grep -q "source /etc/network/interfaces.d/*" /etc/network/interfaces; then
        echo "source /etc/network/interfaces.d/*" >> /etc/network/interfaces
    fi
}

delete_all_ipv6() {
    local interface=$1

    CONFIG_FILE="/etc/network/interfaces.d/60-ipv6-addresses"
    if [ -f "$CONFIG_FILE" ]; then
        rm -f "$CONFIG_FILE"
        echo -e "${GREEN}已删除配置文件${NC}"
    fi

    for addr in $(ip -6 addr show dev $interface | grep "inet6" | grep -v "fe80" | awk '{print $2}'); do
        ip -6 addr del $addr dev $interface
        echo -e "${YELLOW}已删除IPv6地址: $addr${NC}"
    done

    echo -e "${GREEN}所有配置的IPv6地址已删除${NC}"
}

show_current_ipv6() {
    local interface=$1
    echo -e "${YELLOW}当前IPv6地址列表：${NC}"
    local ipv6_list=$(ip -6 addr show dev $interface | grep "inet6" | grep -v "fe80")
    if [ -z "$ipv6_list" ]; then
        echo -e "${RED}未检测到任何IPv6地址${NC}"
        return 1
    fi
    echo "$ipv6_list"
}

# IP策略配置模块
configure_ip_strategy() {
    local strategy=$1
    local -n port_map # 修改声明方式
    if [ "$2" ]; then
        port_map=$2
    fi
    
    mkdir -p /etc/xray
    echo -n "" > /etc/xray/serve.json

    case $strategy in
        1)  # 同IP进同IP出
            for ipv4 in "${ipv4_addrs[@]}"; do
                cat <<EOF >> /etc/xray/serve.json
[[inbounds]]
listen = "$ipv4"
port = $socks_port
protocol = "socks"
tag = "in_$ipv4"
[inbounds.settings]
auth = "password"
udp = true
ip = "$ipv4"
[[inbounds.settings.accounts]]
user = "$socks_user"
pass = "$socks_pass"

[[outbounds]]
protocol = "freedom"
tag = "out_$ipv4"
settings = { domainStrategy = "UseIPv4" }
streamSettings = { sockopt = { mark = 255 } }
sendThrough = "$ipv4"

[[routing.rules]]
type = "field"
inboundTag = ["in_$ipv4"]
outboundTag = "out_$ipv4"

EOF
            done
            ;;
        
        2)  # IPv4进随机IPv4出
            # 首先写入所有入站配置
            for ipv4 in "${ipv4_addrs[@]}"; do
                cat <<EOF >> /etc/xray/serve.json
[[inbounds]]
listen = "$ipv4"
port = $socks_port
protocol = "socks"
tag = "in_$ipv4"
[inbounds.settings]
auth = "password"
udp = true
ip = "$ipv4"
[[inbounds.settings.accounts]]
user = "$socks_user"
pass = "$socks_pass"

EOF
            done

            # 然后写入所有出站配置
            for ipv4 in "${ipv4_addrs[@]}"; do
                cat <<EOF >> /etc/xray/serve.json
[[outbounds]]
protocol = "freedom"
tag = "out_$ipv4"
settings = { domainStrategy = "UseIPv4" }
streamSettings = { sockopt = { mark = 255 } }
sendThrough = "$ipv4"

EOF
            done

            # 添加负载均衡器配置
            cat <<EOF >> /etc/xray/serve.json
[[balancers]]
tag = "ipv4_balancer"
selector = [$(printf '"out_%s", ' "${ipv4_addrs[@]}" | sed 's/, $//')]
strategy = "random"

EOF

            # 为每个入站添加到负载均衡器的路由规则
            for ipv4 in "${ipv4_addrs[@]}"; do
                cat <<EOF >> /etc/xray/serve.json
[[routing.rules]]
type = "field"
inboundTag = ["in_$ipv4"]
balancerTag = "ipv4_balancer"

EOF
            done
            ;;

3)  # IPv4进随机IPv6出（不重复直到耗尽）
    # 首先生成所有 outbound tags
    ipv6_shuffled=($(printf "%s\n" "${ipv6_addrs[@]}" | shuf))
    outbound_tags=()
    for ipv6 in "${ipv6_shuffled[@]}"; do
        outbound_tags+=("outbound_$(echo $ipv6 | tr ':.' '_')")
    done

    # 检查是否有可用的 IPv6 地址
    if [ ${#outbound_tags[@]} -eq 0 ]; then
        echo -e "${RED}错误：没有可用的IPv6地址${NC}"
        return 1
    fi

    # 生成配置文件
    cat <<EOF > /etc/xray/serve.json
{
    "inbounds": [{
        "listen": "${ipv4_addrs[0]}",
        "port": $socks_port,
        "protocol": "socks",
        "tag": "inbound-ipv4",
        "settings": {
            "auth": "password",
            "udp": true,
            "accounts": [{"user": "$socks_user", "pass": "$socks_pass"}]
        }
    }],
    "outbounds": [
EOF

    # 写入出站配置
    first=true
    for i in "${!ipv6_shuffled[@]}"; do
        ipv6=${ipv6_shuffled[$i]}
        tag=${outbound_tags[$i]}
        
        if [ "$first" = true ]; then
            first=false
        else
            echo "        ," >> /etc/xray/serve.json
        fi
        
        cat <<EOF >> /etc/xray/serve.json
        {
            "protocol": "freedom",
            "tag": "$tag",
            "settings": {"domainStrategy": "UseIPv6"},
            "streamSettings": {"sockopt": {"mark": 255}},
            "sendThrough": "$ipv6"
        }
EOF
    done

# 完成配置文件
cat <<EOF >> /etc/xray/serve.json
    ],
    "routing": {
        "balancers": [{
            "tag": "ipv6_balancer",
            "selector": [$(printf '"%s",' "${outbound_tags[@]}" | sed 's/,$//')],
            "strategy": {
                "type": "random"
            }
        }],
        "rules": [{
            "type": "field",
            "inboundTag": ["inbound-ipv4"],
            "balancerTag": "ipv6_balancer"
        }]
    }
}
EOF

    # 验证配置
    echo -e "${YELLOW}验证配置文件...${NC}"
    if ! /usr/local/bin/xray -test -config /etc/xray/serve.json; then
        echo -e "${RED}配置验证失败，配置文件内容：${NC}"
        cat /etc/xray/serve.json
        return 1
    fi

    # 重启 Xray 服务
    systemctl restart xray
    sleep 2

    if ! systemctl is-active --quiet xray; then
        echo -e "${RED}Xray 服务启动失败${NC}"
        systemctl status xray
        return 1
    fi

    echo -e "${GREEN}IP策略设置完成并成功启动服务${NC}"
    ;;
 4)  # IPv4进，不同端口对应固定IPv6出
    cat <<EOF > /etc/xray/serve.json
{
    "inbounds": [
EOF

    # 为每个端口配置入站
    first_inbound=true
    for port in "${!port_map[@]}"; do
        ipv6=${port_map[$port]}
        for ipv4 in "${ipv4_addrs[@]}"; do
            if [ "$first_inbound" = true ]; then
                first_inbound=false
            else
                echo "," >> /etc/xray/serve.json
            fi
            
            cat <<EOF >> /etc/xray/serve.json
        {
            "listen": "$ipv4",
            "port": $port,
            "protocol": "socks",
            "tag": "in_${port}_${ipv4}",
            "settings": {
                "auth": "password",
                "udp": true,
                "ip": "$ipv4",
                "accounts": [{
                    "user": "$socks_user",
                    "pass": "$socks_pass"
                }]
            }
        }
EOF
        done
    done

    # 添加出站配置
    cat <<EOF >> /etc/xray/serve.json
    ],
    "outbounds": [
EOF

    # 为每个端口配置出站
    first_outbound=true
    for port in "${!port_map[@]}"; do
        ipv6=${port_map[$port]}
        if [ "$first_outbound" = true ]; then
            first_outbound=false
        else
            echo "," >> /etc/xray/serve.json
        fi
        
        cat <<EOF >> /etc/xray/serve.json
        {
            "protocol": "freedom",
            "tag": "out_${port}",
            "settings": { "domainStrategy": "UseIPv6" },
            "streamSettings": { "sockopt": { "mark": 255 } },
            "sendThrough": "$ipv6"
        }
EOF
    done

    # 添加路由规则
    cat <<EOF >> /etc/xray/serve.json
    ],
    "routing": {
        "rules": [
EOF

    # 为每个入站配置路由规则
    first_rule=true
    for port in "${!port_map[@]}"; do
        for ipv4 in "${ipv4_addrs[@]}"; do
            if [ "$first_rule" = true ]; then
                first_rule=false
            else
                echo "," >> /etc/xray/serve.json
            fi
            
            cat <<EOF >> /etc/xray/serve.json
            {
                "type": "field",
                "inboundTag": ["in_${port}_${ipv4}"],
                "outboundTag": "out_${port}"
            }
EOF
        done
    done

    # 完成配置文件
    cat <<EOF >> /etc/xray/serve.json
        ]
    }
}
EOF

    # 检查配置文件
    if ! /usr/local/bin/xray -test -config /etc/xray/serve.json; then
        echo -e "${RED}Xray 配置验证失败${NC}"
        return 1
    fi

    # 重启 Xray 服务
    systemctl restart xray
    sleep 2

    if ! systemctl is-active --quiet xray; then
        echo -e "${RED}Xray 服务启动失败${NC}"
        systemctl status xray
        return 1
    fi

    echo -e "${GREEN}IP策略设置完成并成功启动服务${NC}"
    ;;   
    esac
}

#配置IP进出策略
set_ip_strategy() {
    echo "配置IP进出策略..."

    # 如果没有之前设置的信息，先获取
    if [ -z "$socks_port" ] || [ -z "$socks_user" ] || [ -z "$socks_pass" ]; then
        read -p "请输入SOCKS5起始端口: " socks_port
        read -p "请输入用户名: " socks_user
        read -p "请输入密码: " socks_pass
    fi

    # 获取IPv4和IPv6地址列表 
    ipv4_addrs=($(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.'))
    ipv6_addrs=($(ip -6 addr show | grep "inet6" | grep -v "fe80" | grep -v "::1" | awk '{print $2}' | cut -d'/' -f1))

    echo "当前IPv4地址: ${ipv4_addrs[@]}"
    echo "当前IPv6地址: ${ipv6_addrs[@]}"

    echo "请选择IP进出策略："
    echo "1. 同IP进同IP出（默认）"
    echo "2. IPv4进随机IPv4出（不重复直到耗尽）"
    echo "3. IPv4进随机IPv6出（不重复直到耗尽）"
    echo "4. IPv4进，不同端口对应固定IPv6出（自动分配）"
    read -p "请输入选项 [1-4]: " strategy

    case $strategy in
        4)
            # 获取当前可用的IPv6地址数量
            ipv6_count=${#ipv6_addrs[@]}
            echo -e "${YELLOW}当前可用的IPv6地址数量: $ipv6_count${NC}"

            while true; do
                read -p "请输入要配置的端口数量 (最大 $ipv6_count): " port_count
                if ! [[ "$port_count" =~ ^[0-9]+$ ]]; then
                    echo -e "${RED}请输入有效的数字${NC}"
                    continue
                fi

                if [ "$port_count" -gt "$ipv6_count" ]; then
                    echo -e "${RED}错误: 端口数量($port_count)不能超过可用的IPv6地址数量($ipv6_count)${NC}"
                    continue
                fi

                if [ "$port_count" -lt 1 ]; then
                    echo -e "${RED}错误: 端口数量必须大于0${NC}"
                    continue
                fi

                break
            done

            declare -A port_ipv6_map

            # 自动分配IPv6地址给端口
            echo -e "\n${YELLOW}端口与IPv6地址的对应关系：${NC}"
            for ((i=0; i<port_count; i++)); do
                current_port=$((socks_port + i))
                ipv6_index=$((i % ipv6_count))
                port_ipv6_map[$current_port]=${ipv6_addrs[$ipv6_index]}
                echo -e "${GREEN}端口 $current_port -> IPv6: ${ipv6_addrs[$ipv6_index]}${NC}"
            done

            read -p "确认使用以上配置？[y/N] " confirm
            if [[ ! $confirm =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}已取消配置${NC}"
                return 1
            fi

            configure_ip_strategy $strategy port_ipv6_map
            ;;
        1|2|3)
            configure_ip_strategy $strategy
            ;;
        *)
            echo -e "${RED}无效的策略选择${NC}"
            return 1
            ;;
    esac
}

# 代理管理模块
generate_proxy_list() {
    local socks_port=$1
    local socks_user=$2
    local socks_pass=$3
    local ips=($(hostname -I))
    echo "生成代理列表文件..."
    echo -n "" > /root/proxy_list.txt
    for ip in "${ips[@]}"; do
        echo "$ip:$socks_port:$socks_user:$socks_pass" >> /root/proxy_list.txt
    done
    echo "代理列表文件已生成：/root/proxy_list.txt"
    return 0
}

# 代理设置模块
set_socks5_credentials() {
    read -p "请输入SOCKS5起始端口: " socks_port
    read -p "请输入用户名: " socks_user
    read -p "请输入密码: " socks_pass
    set_ip_strategy
    generate_proxy_list "$socks_port" "$socks_user" "$socks_pass"
    echo "SOCKS5端口、用户名和密码设置完成。"
    return 0
}

# 工具函数
get_active_interfaces() {
    interfaces=$(ip -o link show | awk -F': ' '$2 != "lo" {print $2}')
    echo "检测到的活动网络接口: $interfaces"
    return 0
}

get_active_ip_count() {
    active_ip_count=$(hostname -I | wc -w)
    echo "当前活动的IP数量: $active_ip_count"
    return 0
}

# 带宽控制和BBR相关函数
setup_bandwidth_control() {
    get_active_interfaces
    get_active_ip_count

    read -p "请输入VPS的总带宽（例如50M）: " total_bandwidth

    if [[ ! $total_bandwidth =~ ^[0-9]+M$ ]]; then
        echo -e "${RED}ERROR: 输入格式错误，请输入类似'50M'的格式。${NC}"
        return 1
    fi

    if [ "$active_ip_count" -eq 0 ]; then
        echo "INFO: 没有活动的IP，跳过带宽设置。"
        return 0
    fi

    local rate=$(echo "${total_bandwidth%M} / $active_ip_count" | bc)Mbit

    echo "INFO: 设置带宽控制..."
    for interface in $interfaces; do
        tc qdisc del dev $interface root 2>/dev/null
        tc qdisc add dev $interface root handle 1: htb default 30
        tc class add dev $interface parent 1: classid 1:1 htb rate $total_bandwidth

        for ip in $(hostname -I); do
            tc class add dev $interface parent 1:1 classid 1:10 htb rate ${rate} ceil ${rate}
            tc filter add dev $interface protocol ip parent 1:0 prio 1 u32 match ip dst $ip flowid 1:10
        done
    done

    echo "INFO: 带宽控制设置完成。"
    return 0
}

enable_bbr() {
    echo "启用BBR..."

    if ! sysctl net.ipv4.tcp_available_congestion_control | grep -q "bbr"; then
        echo -e "${RED}当前内核不支持BBR，请升级内核。${NC}"
        return 1
    fi

    echo "net.core.default_qdisc=fq" | tee -a /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" | tee -a /etc/sysctl.conf

    sysctl -p

    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo -e "${GREEN}BBR已成功启用。${NC}"
    else
        echo -e "${RED}BBR启用失败，请检查配置。${NC}"
    fi
    return 0
}

# 测试代理连通性
test_proxy_connectivity() {
    echo "测试代理连通性..."

    if [ ! -f /root/proxy_list.txt ]; then
        echo -e "${RED}/root/proxy_list.txt 文件不存在。${NC}"
        return 1
    fi

    while IFS= read -r line; do
        if [[ $line =~ ^(.+):([0-9]+):(.+):(.+)$ ]]; then
            ip="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
            user="${BASH_REMATCH[3]}"
            pass="${BASH_REMATCH[4]}"

            echo "正在测试 $ip:$port..."

            if [[ $ip == *:* ]]; then
                ip="[$ip]"
            fi

            if curl -s --proxy socks5h://$user:$pass@$ip:$port http://httpbin.org/ip -o /dev/null; then
                echo -e "${GREEN}$ip:$port 代理连接成功${NC}"
            else
                echo -e "${RED}$ip:$port 代理连接失败${NC}"
            fi
        else
            echo -e "${RED}行格式不正确: $line${NC}"
        fi
    done < /root/proxy_list.txt

    echo "代理连通性测试完成。"
    return 0
}

# 清理函数
clear_proxy_rules() {
    echo "清除所有代理规则..."
    $service_manager stop xray
    $service_manager disable xray
    rm -f /etc/xray/serve.json
    rm -f /etc/systemd/system/xray.service
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t mangle -F
    ip6tables -F
    ip6tables -X
    ip6tables -t nat -F
    ip6tables -t mangle -F
    iptables-save
    ip6tables-save
    rm -f /root/proxy_list.txt
    echo "已清除所有代理规则，回到未安装SOCKS5代理的状态。"
    return 0
}

# IPv6管理菜单
ipv6_manager_menu() {
    while true; do
        echo -e "\n${YELLOW}IPv6地址管理工具${NC}"
        echo "1. 添加随机IPv6地址"
        echo "2. 删除所有IPv6地址"
        echo "3. 显示当前IPv6地址"
        echo "4. 测试IPv6连通性"
        echo "0. 返回主菜单"

        read -p "请选择操作 [0-4]: " ipv6_option

        case $ipv6_option in
            1)
                INTERFACE=$(get_main_interface)
                if [ $? -ne 0 ]; then
                    echo -e "${RED}获取网络接口失败${NC}"
                    continue
                fi

                # 先显示当前IPv6信息
                echo -e "${YELLOW}当前IPv6配置：${NC}"
                ip -6 addr show dev $INTERFACE

                # 获取IPv6前缀
                PREFIX=$(ip -6 addr show dev $INTERFACE | grep "scope global" | grep -v "temporary" | head -n1 | awk '{print $2}' | cut -d'/' -f1 | sed -E 's/:[^:]+:[^:]+:[^:]+:[^:]+$/::/')

                if [ -z "$PREFIX" ]; then
                    echo -e "${RED}无法获取IPv6前缀${NC}"
                    continue
                fi

                echo -e "${GREEN}使用IPv6前缀: $PREFIX${NC}"

                read -p "请输入要添加的IPv6地址数量: " num_addresses
                if [[ ! "$num_addresses" =~ ^[0-9]+$ ]]; then
                    echo -e "${RED}请输入有效的数字${NC}"
                    continue
                fi

                add_ipv6_addresses "$INTERFACE" "$PREFIX" "$num_addresses"
                ;;
            2)
                INTERFACE=$(get_main_interface)
                if [ $? -eq 0 ]; then
                    delete_all_ipv6 $INTERFACE
                fi
                ;;
            3)
                INTERFACE=$(get_main_interface)
                if [ $? -eq 0 ]; then
                    show_current_ipv6 $INTERFACE
                fi
                ;;
            4)
                test_proxy_connectivity
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效的选择${NC}"
                ;;
        esac

        echo -e "\n按回车键继续..."
        read
    done
}

# 主菜单
show_menu() {
    echo -e "\n${YELLOW}=== 代理服务器管理工具 ===${NC}"
    echo "1. 环境配置（安装必要组件）"
    echo "2. 启用BBR加速"
    echo "3. IPv6地址管理"
    echo "4. 设置带宽控制"
    echo "5. SOCKS5代理设置"
    echo "6. 设置IP进出策略"
    echo "7. 测试代理连通性"
    echo "8. 显示代理列表"
    echo "9. 清除所有代理规则"
    echo "10. 退出"

    read -p "请输入选项 [1-10]: " option
    case $option in
        1) setup_environment ;;
        2) enable_bbr ;;
        3) ipv6_manager_menu ;;
        4) setup_bandwidth_control ;;
        5) set_socks5_credentials ;;
        6) set_ip_strategy ;;
        7) test_proxy_connectivity ;;
        8) 
            if [ -f /root/proxy_list.txt ]; then
                cat /root/proxy_list.txt
            else
                echo -e "${RED}/root/proxy_list.txt 文件不存在。${NC}"
            fi
            ;;
        9) clear_proxy_rules ;;
        10) echo "退出脚本。"; exit ;;
        *) echo -e "${RED}无效选项，请输入1-10之间的数字${NC}" ;;
    esac
}

# 主程序
main() {
    # 检查root权限
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}请使用root权限运行此脚本${NC}"
        exit 1
    fi

    # 初始化
    detect_system
    if [ $? -ne 0 ]; then
        echo -e "${RED}系统检测失败，请检查您的操作系统是否受支持。${NC}"
        exit 1
    fi

    check_and_install_iptables
    check_ipv6

    # 显示使用说明
    show_usage

    # 主循环
    while true; do
        show_menu
        sleep 1
    done
}

# 运行主程序
main
