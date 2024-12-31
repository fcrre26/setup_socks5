#!/bin/bash

# 检测系统类型并设置相应的命令
detect_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            "ubuntu"|"debian")
                service_manager="systemctl"
                ;;
            "centos")
                if [ "$VERSION_ID" -ge 7 ]; then
                    service_manager="systemctl"
                else
                    service_manager="service"
                fi
                ;;
            *)
                echo "不支持的系统"
                exit 1
                ;;
        esac
    else
        echo "无法识别的系统"
        exit 1
    fi
}

# 检测并安装 unzip
check_and_install_unzip() {
    if ! command -v unzip &> /dev/null; then
        echo "未安装unzip，正在安装..."
        if [ "$ID" == "centos" ]; then
            sudo yum install unzip -y
        else
            sudo apt-get install unzip -y
        fi
    fi
}

# 检测并安装防火墙
check_and_install_iptables() {
    if ! command -v iptables &> /dev/null; then
        echo "未安装iptables，正在安装..."
        if [ "$ID" == "centos" ]; then
            sudo yum install iptables-services -y
            sudo systemctl enable iptables
        else
            sudo apt-get install iptables-persistent -y
        fi
    fi
}

# 环境配置
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
Description=The Xray Proxy Serve
After=network-online.target
[Service]
ExecStart=/usr/local/bin/xray -c /etc/xray/serve.toml
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
}

# 下载并设置Xray
install_xray() {
    echo "正在从GitHub下载Xray..."
    # 请确保使用正确的链接，以下链接仅为示例，您需要检查最新版本的链接
    check_and_install_unzip
    wget --no-check-certificate -O /usr/local/bin/xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
    unzip /usr/local/bin/xray.zip -d /usr/local/bin
    rm /usr/local/bin/xray.zip # 清理下载的zip文件
    chmod +x /usr/local/bin/xray
    echo "Xray已下载并设置为可执行。"
}

# SOCKS5端口设置、用户名与密码设置
set_socks5_credentials() {
    read -p "请输入SOCKS5端口: " socks_port
    read -p "请输入用户名: " socks_user
    read -p "请输入密码: " socks_pass
    configure_xray "$socks_port" "$socks_user" "$socks_pass"
    generate_proxy_list "$socks_port" "$socks_user" "$socks_pass"
    echo "SOCKS5端口、用户名和密码设置完成。"
}

# 代理列表详情
show_proxy_details() {
    echo "代理列表详情："
    cat /root/proxy_list.txt
}

# 配置Xray
configure_xray() {
    echo "配置Xray..."
    mkdir -p /etc/xray
    echo -n "" > /etc/xray/serve.toml
    local ips=($(hostname -I))
    for ((i = 0; i < ${#ips[@]}; i++)); do
        cat <<EOF >> /etc/xray/serve.toml
[[inbounds]]
listen = "${ips[i]}"
port = $1
protocol = "socks"
tag = "in$((i+1))"
settings = { auth = "password", udp = true, accounts = [{ user = "$2", pass = "$3" }] }
[[outbounds]]
protocol = "freedom"
tag = "out$((i+1))"

EOF
    done
    echo "Xray配置已完成。"
}

# 生成代理列表文件
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
}

# 清除所有代理规则
clear_proxy_rules() {
    echo "清除所有代理规则..."
    # 停止并禁用Xray服务
    $service_manager stop xray
    $service_manager disable xray
    # 删除Xray配置文件和服务文件
    rm -f /etc/xray/serve.toml
    rm -f /etc/systemd/system/xray.service
    # 清空iptables规则
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t mangle -F
    iptables-save
    # 删除代理列表文件
    rm -f /root/proxy_list.txt
    echo "已清除所有代理规则，回到未安装SOCKS5代理的状态。"
}

# 测试代理连通性
test_proxy_connectivity() {
    echo "测试代理连通性..."
    local socks_port=$1
    local socks_user=$2
    local socks_pass=$3
    local ips=($(hostname -I))
    for ip in "${ips[@]}"; do
        echo "正在测试 $ip:$socks_port..."
        # 使用 curl 测试代理连通性，这里以 httpbin.org 为例
        curl -x socks5h://$socks_user:$socks_pass@$ip:$socks_port http://httpbin.org/ip
    done
    echo "代理连通性测试完成。"
}

# 菜单函数
show_menu() {
    echo "请选择要执行的操作："
    echo "1. 环境配置"
    echo "2. SOCKS5代理设置"
    echo "3. 代理列表"
    echo "4. 清除所有代理规则"
    echo "5. 测试代理连通性"
    echo "6. 退出"
    read -p "请输入选项 [1-6]: " option
    case $option in
        1) setup_environment ;;
        2) set_socks5_credentials ;;
        3) show_proxy_details ;;
        4) clear_proxy_rules ;;
        5) test_proxy_connectivity "${socks_port}" "${socks_user}" "${socks_pass}" ;;
        6) echo "退出脚本。"; exit ;;
        *) echo "无效选项，请输入1-6之间的数字" ;;
    esac
}

# 主程序
detect_system
check_and_install_iptables
while true; do
    show_menu
done
