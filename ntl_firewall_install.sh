#!/bin/bash
set -euo pipefail  # Добавляем строгий режим выполнения

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функции для логирования
log_info() {
    echo -e "ℹ️${BLUE} $1${NC}"
}

log_success() {
    echo -e "✅${GREEN} $1${NC}"
}

log_warning() {
    echo -e "⚠️${YELLOW} $1${NC}"
}

log_error() {
    echo -e "❌${RED} $1${NC}"
}

log_input() {
    echo -e "${NC}$1${NC}"
}

log_comment() {
    echo -e "${BLUE}$1${NC}"
}

# Функция проверки прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен запускаться от root"
        exit 1
    fi
}

# Функция проверки и установки пакета
check_and_install_package() {
    local package=$1
    if dpkg -s "$package" >/dev/null 2>&1; then
        log_success "Пакет $package уже установлен"
        return 0
    fi
    
    log_warning "Пакет $package не установлен. Устанавливаем..."
    if apt update -qq && apt install -y -qq "$package"; then
        log_success "Пакет $package успешно установлен"
        return 0
    else
        log_error "Не удалось установить пакет $package"
        exit 1
    fi
}

# Функция валидации IP-адреса
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Функция валидации интерфейса
validate_interface() {
    local iface=$1
    if ip link show "$iface" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Главная функция
main() {
    check_root
    
    log_info "Установка ntl-firewall ..."
    
    # Проверка и установка iptables
    check_and_install_package "iptables"
    
    # Запрос параметров с валидацией
    while true; do
        read -p "Введите WAN IP: " wanip
        if validate_ip "$wanip"; then
            break
        else
            log_error "Неверный формат IP-адреса"
        fi
    done
    
    while true; do
        read -p "Введите название WAN-интерфейса (прим. eth0): " waniface
        if validate_interface "$waniface"; then
            break
        else
            log_error "Интерфейс $waniface не найден"
        fi
    done
    
    read -p "Введите WAN Broadcast: " wanbrd
    
    while true; do
        read -p "Введите LAN IP: " lanip
        if validate_ip "$lanip"; then
            break
        else
            log_error "Неверный формат IP-адреса"
        fi
    done
    
    while true; do
        read -p "Введите название LAN-интерфейса (прим. eth1): " laniface
        if validate_interface "$laniface"; then
            break
        else
            log_error "Интерфейс $laniface не найден"
        fi
    done
    
    read -p "Введите подсеть LAN (прим. 192.168.1.0/24): " lanrange
    
    # Создание директории, если её нет
    mkdir -p /usr/local/bin
    
    # Использование heredoc для создания файлов с правами
    cat > /usr/local/bin/rc.flush-iptables <<'EOF'
#!/bin/sh
IPTABLES="/sbin/iptables"

# Сброс политик
$IPTABLES -P INPUT ACCEPT
$IPTABLES -P FORWARD ACCEPT
$IPTABLES -P OUTPUT ACCEPT
$IPTABLES -t nat -P PREROUTING ACCEPT
$IPTABLES -t nat -P POSTROUTING ACCEPT
$IPTABLES -t nat -P OUTPUT ACCEPT
$IPTABLES -t mangle -P PREROUTING ACCEPT
$IPTABLES -t mangle -P POSTROUTING ACCEPT
$IPTABLES -t mangle -P INPUT ACCEPT
$IPTABLES -t mangle -P OUTPUT ACCEPT
$IPTABLES -t mangle -P FORWARD ACCEPT

# Очистка правил и цепочек
$IPTABLES -F
$IPTABLES -t nat -F
$IPTABLES -t mangle -F
$IPTABLES -X
$IPTABLES -t nat -X
$IPTABLES -t mangle -X
EOF

    # Создание основного файла правил с подстановкой переменных
    cat > /usr/local/bin/rc.firewall <<EOF
#!/bin/sh

# Конфигурация
INET_PROVIDER_IP="$wanip"
INET_PROVIDER_IFACE="$waniface"
INET_PROVIDER_BROADCAST="$wanbrd"
LAN_ORG_IP="$lanip"
LAN_ORG_IP_RANGE="$lanrange"
LAN_ORG_IFACE="$laniface"
LO_IFACE="lo"
LO_IP="127.0.0.1"
IPTABLES="/sbin/iptables"
OPENVPN_IFACE="tun+"
OPENVPN_PORT="1194:1199"

# Включение форвардинга
echo "1" > /proc/sys/net/ipv4/ip_forward

# Сброс правил
\$IPTABLES -F
\$IPTABLES -X
\$IPTABLES -F -t nat
\$IPTABLES -X -t nat
\$IPTABLES -F -t mangle
\$IPTABLES -X -t mangle

# Политики по умолчанию
\$IPTABLES -P INPUT DROP
\$IPTABLES -P OUTPUT DROP
\$IPTABLES -P FORWARD DROP

# Создание пользовательских цепочек
\$IPTABLES -N bad_tcp_packets
\$IPTABLES -N allowed
\$IPTABLES -N tcp_packets
\$IPTABLES -N udp_packets
\$IPTABLES -N icmp_packets

# Правила для bad_tcp_packets
\$IPTABLES -A bad_tcp_packets -p tcp --tcp-flags SYN,ACK SYN,ACK \\
    -m state --state NEW -j REJECT --reject-with tcp-reset
\$IPTABLES -A bad_tcp_packets -p tcp ! --syn -m state --state NEW -j DROP

# Правила для allowed
\$IPTABLES -A allowed -p TCP --syn -j ACCEPT
\$IPTABLES -A allowed -p TCP -m state --state ESTABLISHED,RELATED -j ACCEPT

# TCP правила
\$IPTABLES -A tcp_packets -p TCP -s 0/0 --dport 22 -j allowed

# UDP правила
\$IPTABLES -A udp_packets -p UDP -s 0/0 --destination-port \$OPENVPN_PORT -j ACCEPT

# ICMP правила
\$IPTABLES -A icmp_packets -p ICMP -s 0/0 --icmp-type 8 -j ACCEPT
\$IPTABLES -A icmp_packets -p ICMP -s 0/0 --icmp-type 11 -j ACCEPT

# INPUT chain
\$IPTABLES -A INPUT -p tcp -j bad_tcp_packets
\$IPTABLES -A INPUT -p ALL -i \$LAN_ORG_IFACE -s \$LAN_ORG_IP_RANGE -j ACCEPT
\$IPTABLES -A INPUT -p ALL -i \$LO_IFACE -s \$LO_IP -j ACCEPT
\$IPTABLES -A INPUT -p ALL -i \$LO_IFACE -s \$LAN_ORG_IP -j ACCEPT
\$IPTABLES -A INPUT -p ALL -i \$LO_IFACE -s \$INET_PROVIDER_IP -j ACCEPT
\$IPTABLES -A INPUT -p udp --dport 500 -j ACCEPT
\$IPTABLES -A INPUT -p udp --dport 4500 -j ACCEPT
\$IPTABLES -A INPUT -p udp --dport 1701 -j ACCEPT
\$IPTABLES -A INPUT -p 50 -j ACCEPT
\$IPTABLES -A INPUT -p 51 -j ACCEPT
\$IPTABLES -A INPUT -p ALL -i \$OPENVPN_IFACE -j ACCEPT
\$IPTABLES -A INPUT -p ALL -d \$INET_PROVIDER_IP -m state --state ESTABLISHED,RELATED -j ACCEPT
\$IPTABLES -A INPUT -p TCP -i \$INET_PROVIDER_IFACE -j tcp_packets
\$IPTABLES -A INPUT -p UDP -i \$INET_PROVIDER_IFACE -j udp_packets
\$IPTABLES -A INPUT -p ICMP -i \$INET_PROVIDER_IFACE -j icmp_packets

# FORWARD chain
\$IPTABLES -A FORWARD -p tcp -j bad_tcp_packets
\$IPTABLES -A FORWARD -i \$LAN_ORG_IFACE -j ACCEPT
\$IPTABLES -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
\$IPTABLES -A FORWARD -i \$OPENVPN_IFACE -j ACCEPT
\$IPTABLES -A FORWARD -o \$OPENVPN_IFACE -j ACCEPT

# OUTPUT chain
\$IPTABLES -A OUTPUT -p tcp -j bad_tcp_packets
\$IPTABLES -A OUTPUT -p ALL -s \$LO_IP -j ACCEPT
\$IPTABLES -A OUTPUT -p ALL -s \$LAN_ORG_IP -j ACCEPT
\$IPTABLES -A OUTPUT -p ALL -s \$INET_PROVIDER_IP -j ACCEPT
\$IPTABLES -A OUTPUT -p udp --sport 500 --dport 500 -j ACCEPT
\$IPTABLES -A OUTPUT -p 50 -j ACCEPT
\$IPTABLES -A OUTPUT -p 51 -j ACCEPT
\$IPTABLES -A OUTPUT -o \$OPENVPN_IFACE -j ACCEPT

# NAT таблица
\$IPTABLES -t nat -A POSTROUTING -o \$INET_PROVIDER_IFACE -j SNAT --to-source \$INET_PROVIDER_IP
EOF

    # Установка прав на выполнение
    chmod +x /usr/local/bin/rc.flush-iptables /usr/local/bin/rc.firewall
    
    # Создание systemd сервиса
    cat > /etc/systemd/system/ntl-firewall.service <<EOF
[Unit]
Description=NTL Firewall (IPTables rules)
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/rc.firewall
ExecStop=/usr/local/bin/rc.flush-iptables
RemainAfterExit=yes
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF

    # Перезагрузка systemd и включение сервиса
    systemctl daemon-reload
    systemctl enable ntl-firewall.service && log_success "Автозапуск ntl-firewall включен"
    systemctl start ntl-firewall.service && log_success "Служба ntl-firewall запущена"
    systemctl restart ntl-firewall.service
    
    # Настройка сетевого интерфейса
    log_info "Настройка сетевого адаптера ..."
    
    if grep -q "^iface[[:space:]]*$laniface" /etc/network/interfaces; then
        log_warning "Интерфейс $laniface уже настроен в /etc/network/interfaces"
        log_warning "Проверьте правильность настройки вручную"
    else
        # Создание резервной копии
        cp /etc/network/interfaces /etc/network/interfaces.backup
        
        cat >> /etc/network/interfaces <<EOF

# LAN interface configuration
allow-hotplug $laniface
iface $laniface inet static
    address $lanip
    netmask 255.255.255.0
EOF
        
        # Перезапуск сети с проверкой ошибок
        if systemctl restart networking.service; then
            ifdown "$waniface" 2>/dev/null || true
            ifup "$waniface" 2>/dev/null || true
            ifdown "$laniface" 2>/dev/null || true
            ifup "$laniface" 2>/dev/null || true
            log_success "Интерфейс $laniface настроен"
        else
            log_error "Ошибка при перезапуске networking.service"
            # Восстановление из бэкапа
            cp /etc/network/interfaces.backup /etc/network/interfaces
            exit 1
        fi
    fi
    
    log_info "Настройка ntl-firewall завершена."
#    log_info "Текущие правила iptables:"
#    iptables -L -n -v
    log_info "Использование ntl-firewall"
    log_comment "Запуск:"
    log_input "systemctl ntl-firewall start"
    log_comment "\nОстановка:"
    log_input "systemctl ntl-firewall stop"
    log_comment "\nПерезапуск:"
    log_input "systemctl ntl-firewall restart"
}

# Запуск главной функции
main "$@"
