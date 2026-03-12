#!/bin/bash

# Цветовые коды
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Функции для цветного вывода
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

print_header() {
    echo -e "\n${BOLD}${PURPLE}=== $1 ===${NC}\n"
}

print_prompt() {
    echo -e "${CYAN}➤ $1${NC}"
}

# Функция для преобразования IP в число
ip_to_int() {
    local IFS=.
    read -r i1 i2 i3 i4 <<< "$1"
    echo $((i1 * 256 ** 3 + i2 * 256 ** 2 + i3 * 256 + i4))
}

# Функция для преобразования числа в IP
int_to_ip() {
    local ip=$1
    echo "$((ip >> 24 & 255)).$((ip >> 16 & 255)).$((ip >> 8 & 255)).$((ip & 255))"
}

# Функция для проверки корректности IP-адреса
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        for octet in ${ip//./ }; do
            if [[ $octet -gt 255 ]] || [[ $octet -lt 0 ]]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# Функция для проверки маски подсети
validate_netmask() {
    local mask=$1
    if validate_ip "$mask"; then
        # Преобразуем маску в число и проверяем, что это непрерывная последовательность битов
        mask_int=$(ip_to_int "$mask")
        # Инвертируем и проверяем, что после инверсии получается (маска+1) степень двойки
        inverted=$((~mask_int & 0xFFFFFFFF))
        if [ $inverted -eq 0 ] || { [ $((inverted + 1)) -gt 0 ] && [ $(( (inverted + 1) & inverted )) -eq 0 ]; }; then
            return 0
        fi
    fi
    return 1
}

# Функция для проверки существования интерфейса
validate_interface() {
    local iface=$1
    if ip link show "$iface" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Функция для проверки, входит ли IP в подсеть
is_ip_in_subnet() {
    local ip=$1
    local network=$2
    local mask=$3
    
    ip_int=$(ip_to_int "$ip")
    network_int=$(ip_to_int "$network")
    mask_int=$(ip_to_int "$mask")
    
    [ $((ip_int & mask_int)) -eq $network_int ]
}

# Функция для расчета broadcast адреса
calculate_broadcast() {
    local network=$1
    local netmask=$2
    
    network_int=$(ip_to_int "$network")
    netmask_int=$(ip_to_int "$netmask")
    broadcast_int=$((network_int | (~netmask_int & 0xFFFFFFFF)))
    int_to_ip $broadcast_int
}

# Функция для расчета network адреса по IP и маске
calculate_network() {
    local ip=$1
    local netmask=$2
    
    ip_int=$(ip_to_int "$ip")
    netmask_int=$(ip_to_int "$netmask")
    network_int=$((ip_int & netmask_int))
    int_to_ip $network_int
}

# Проверка, что скрипт запущен с root правами
if [[ $EUID -ne 0 ]]; then
    print_error "Этот скрипт должен быть запущен с правами root"
    exit 1
fi

clear
print_header "НАСТРОЙКА DHCP СЕРВЕРА"
print_info "Добро пожаловать в установщик DHCP сервера"
print_info "Скрипт автоматически рассчитает все необходимые параметры"

# Запрос интерфейса
print_header "ВЫБОР СЕТЕВОГО ИНТЕРФЕЙСА"
print_info "Доступные интерфейсы:"
ip -4 -o link show | awk -F': ' '{printf "  - " $2}'; echo

while true; do
    print_prompt "Введите сетевой интерфейс для DHCP (например, eth0):"
    read -p "> " laniface
    
    if validate_interface "$laniface"; then
        print_success "Интерфейс $laniface найден"
        break
    else
        print_error "Интерфейс $laniface не существует. Попробуйте снова."
    fi
done

# Получаем текущие настройки интерфейса
current_ip=$(ip -4 addr show "$laniface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
current_cidr=$(ip -4 addr show "$laniface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1 | cut -d/ -f2)

# Если есть текущие настройки, предлагаем их
if [ -n "$current_ip" ] && [ -n "$current_cidr" ]; then
    # Конвертируем CIDR в маску
    if [ ${#current_cidr} -le 2 ]; then
        # Это CIDR, конвертируем в маску
        cidr=$current_cidr
        mask_int=$((0xFFFFFFFF << (32 - cidr) & 0xFFFFFFFF))
        suggested_mask=$(int_to_ip $mask_int)
    else
        suggested_mask=$current_cidr
    fi
    
    suggested_network=$(calculate_network "$current_ip" "$suggested_mask")
    suggested_broadcast=$(calculate_broadcast "$suggested_network" "$suggested_mask")
    
    print_header "ОБНАРУЖЕНЫ ТЕКУЩИЕ НАСТРОЙКИ ИНТЕРФЕЙСА $laniface"
    echo -e "${BOLD}IP адрес:${NC}     $current_ip"
    echo -e "${BOLD}Сеть:${NC}        $suggested_network"
    echo -e "${BOLD}Маска:${NC}       $suggested_mask"
    echo -e "${BOLD}Broadcast:${NC}   $suggested_broadcast"
fi

# Запрос IP сервера
print_header "НАСТРОЙКА IP-АДРЕСА СЕРВЕРА"
while true; do
    print_prompt "Введите IP-адрес сервера (шлюз):"
    if [ -n "$current_ip" ]; then
        print_info "Нажмите Enter для использования текущего IP: $current_ip"
    fi
    read -p "> " lanip
    lanip=${lanip:-$current_ip}
    
    if validate_ip "$lanip"; then
        print_success "IP-адрес корректен"
        break
    else
        print_error "Некорректный IP-адрес"
    fi
done

# Запрос маски подсети
print_header "НАСТРОЙКА МАСКИ ПОДСЕТИ"
while true; do
    print_prompt "Введите маску подсети:"
    if [ -n "$suggested_mask" ]; then
        print_info "Нажмите Enter для использования маски: $suggested_mask"
    fi
    read -p "> " lannetmask
    lannetmask=${lannetmask:-$suggested_mask}
    
    if validate_netmask "$lannetmask"; then
        print_success "Маска подсети корректна"
        break
    else
        print_error "Некорректная маска подсети"
    fi
done

# Автоматически рассчитываем network адрес
lannet=$(calculate_network "$lanip" "$lannetmask")
broadcast=$(calculate_broadcast "$lannet" "$lannetmask")

print_header "РАССЧИТАННЫЕ ЗНАЧЕНИЯ"
echo -e "${BOLD}Сеть:${NC}       $lannet"
echo -e "${BOLD}Маска:${NC}      $lannetmask"
echo -e "${BOLD}Broadcast:${NC}  $broadcast"
echo -e "${BOLD}Шлюз:${NC}       $lanip"

# Запрос диапазона IP
print_header "НАСТРОЙКА ДИАПАЗОНА IP-АДРЕСОВ"
print_info "Диапазон должен находиться в подсети $lannet/$lannetmask"

# Функция для запроса IP с проверкой принадлежности подсети
ask_ip_in_range() {
    local prompt=$1
    local default=$2
    local ip_variable=$3
    local other_end=$4
    
    while true; do
        print_prompt "$prompt"
        [ -n "$default" ] && print_info "Нажмите Enter для использования: $default"
        read -p "> " input_ip
        input_ip=${input_ip:-$default}
        
        if ! validate_ip "$input_ip"; then
            print_error "Некорректный IP-адрес"
            continue
        fi
        
        if ! is_ip_in_subnet "$input_ip" "$lannet" "$lannetmask"; then
            print_error "IP-адрес $input_ip не находится в подсети $lannet/$lannetmask"
            continue
        fi
        
        if [ -n "$other_end" ] && [ "$input_ip" = "$other_end" ]; then
            print_error "Начальный и конечный IP не могут быть одинаковыми"
            continue
        fi
        
        eval $ip_variable="'$input_ip'"
        return 0
    done
}

# Предлагаем разумные значения по умолчанию для диапазона
# Берем первый и последний возможные адреса в подсети (исключая сеть и broadcast)
network_int=$(ip_to_int "$lannet")
mask_int=$(ip_to_int "$lannetmask")
broadcast_int=$(ip_to_int "$broadcast")

# Первый доступный адрес (сеть + 1)
first_available_int=$((network_int + 1))
first_available=$(int_to_ip $first_available_int)

# Последний доступный адрес (broadcast - 1)
last_available_int=$((broadcast_int - 1))
last_available=$(int_to_ip $last_available_int)

print_info "Доступный диапазон в подсети: $first_available - $last_available"
print_info "Рекомендуется использовать диапазон, исключая первые 10 и последние 10 адресов"

# Рекомендуемый диапазон (сеть + 10 до broadcast - 10)
suggested_start_int=$((network_int + 10))
suggested_end_int=$((broadcast_int - 10))
suggested_start=$(int_to_ip $suggested_start_int)
suggested_end=$(int_to_ip $suggested_end_int)

if [ $suggested_start_int -lt $suggested_end_int ]; then
    print_info "Рекомендуемый диапазон: $suggested_start - $suggested_end"
fi

# Запрос начального IP
ask_ip_in_range "Введите начальный IP диапазона:" "$suggested_start" "range_start"

# Запрос конечного IP
ask_ip_in_range "Введите конечный IP диапазона:" "$suggested_end" "range_end" "$range_start"

# Проверка, что начальный IP меньше конечного
start_int=$(ip_to_int "$range_start")
end_int=$(ip_to_int "$range_end")

if [ $start_int -ge $end_int ]; then
    print_error "Начальный IP должен быть меньше конечного"
    exit 1
fi

print_header "ПРОВЕРКА КОНФИГУРАЦИИ"
echo -e "${BOLD}Сеть:${NC}        $lannet"
echo -e "${BOLD}Маска:${NC}       $lannetmask"
echo -e "${BOLD}Broadcast:${NC}   $broadcast"
echo -e "${BOLD}Шлюз:${NC}        $lanip"
echo -e "${BOLD}Диапазон:${NC}    $range_start - $range_end"
echo -e "${BOLD}Интерфейс:${NC}   $laniface"

print_warning "Проверьте правильность введенных данных"
print_prompt "Продолжить установку? (y/n)"
read -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_warning "Установка отменена"
    exit 1
fi

print_header "УСТАНОВКА DHCP СЕРВЕРА"

# Установка пакета
print_info "Обновление списка пакетов..."
apt update > /dev/null 2>&1
print_success "Список пакетов обновлен"

print_info "Установка isc-dhcp-server..."
apt install isc-dhcp-server -y > /dev/null 2>&1
if [ $? -eq 0 ]; then
    print_success "Пакет установлен успешно"
else
    print_error "Ошибка при установке пакета"
    exit 1
fi

# Бэкап оригинальных конфигов
backup_date=$(date +%Y%m%d_%H%M%S)
print_info "Создание резервных копий..."

[ -f /etc/dhcp/dhcpd.conf ] && {
    mv /etc/dhcp/dhcpd.conf /etc/dhcp/dhcpd.conf_orig_$backup_date
    print_success "Создана копия /etc/dhcp/dhcpd.conf"
}

[ -f /etc/dhcp/dhcpd6.conf ] && {
    mv /etc/dhcp/dhcpd6.conf /etc/dhcp/dhcpd6.conf_orig_$backup_date
    print_success "Создана копия /etc/dhcp/dhcpd6.conf"
}

# Создание конфигурации DHCP
print_info "Создание конфигурационного файла..."

cat > /etc/dhcp/dhcpd.conf << EOF
# Глобальные настройки
option domain-name "local.lan";
option domain-name-servers $lanip;
default-lease-time 86400;
max-lease-time 86400;
authoritative;

# Логгирование
log-facility local7;

# Подсеть
subnet $lannet netmask $lannetmask {
    range $range_start $range_end;
    option routers $lanip;
    option subnet-mask $lannetmask;
    option broadcast-address $broadcast;
    option domain-name-servers $lanip;
}

# Статические IP-адреса (опционально - раскомментируйте при необходимости)
#host printer {
#    hardware ethernet 84:69:93:f3:27:db;
#    fixed-address 192.168.89.213;
#}
#
#host color-printer {
#    hardware ethernet 7C:4D:8F:84:2C:AD;
#    fixed-address 192.168.89.214;
#}
EOF

if [ $? -eq 0 ]; then
    print_success "Конфигурационный файл создан"
else
    print_error "Ошибка при создании конфигурационного файла"
    exit 1
fi

# Бэкап и настройка интерфейсов
[ -f /etc/default/isc-dhcp-server ] && {
    mv /etc/default/isc-dhcp-server /etc/default/isc-dhcp-server_orig_$backup_date
    print_success "Создана копия /etc/default/isc-dhcp-server"
}

cat > /etc/default/isc-dhcp-server << EOF
# Only listen on IPv4
INTERFACESv4="$laniface"
EOF

print_success "Настройки интерфейса сохранены"

# Включение и запуск сервера
print_info "Включение автозапуска сервера..."
systemctl enable isc-dhcp-server > /dev/null 2>&1
print_success "Автозапуск включен"

print_info "Запуск сервера..."
systemctl restart isc-dhcp-server > /dev/null 2>&1
sleep 2

# Проверка статуса
if systemctl is-active --quiet isc-dhcp-server; then
    print_success "Сервер успешно запущен"
else
    print_error "Ошибка при запуске сервера"
fi

# Проверка конфигурации
print_header "ПРОВЕРКА КОНФИГУРАЦИИ"
dhcpd -t -cf /etc/dhcp/dhcpd.conf
if [ $? -eq 0 ]; then
    print_success "Конфигурация корректна"
else
    print_error "Ошибка в конфигурации"
fi

# Финальная информация
print_header "УСТАНОВКА ЗАВЕРШЕНА"
print_success "DHCP сервер успешно настроен!"
echo
echo -e "${BOLD}Параметры конфигурации:${NC}"
echo -e "  ${CYAN}•${NC} Сеть:        $lannet"
echo -e "  ${CYAN}•${NC} Маска:       $lannetmask"
echo -e "  ${CYAN}•${NC} Broadcast:   $broadcast"
echo -e "  ${CYAN}•${NC} Шлюз:        $lanip"
echo -e "  ${CYAN}•${NC} Диапазон:    $range_start - $range_end"
echo -e "  ${CYAN}•${NC} Интерфейс:   $laniface"
echo
echo -e "${BOLD}Полезные команды:${NC}"
echo -e "  ${YELLOW}•${NC} systemctl status isc-dhcp-server  ${GREEN}# Статус сервера${NC}"
echo -e "  ${YELLOW}•${NC} journalctl -u isc-dhcp-server -f  ${GREEN}# Логи в реальном времени${NC}"
echo -e "  ${YELLOW}•${NC} dhcpd -t                          ${GREEN}# Проверка конфигурации${NC}"
echo -e "  ${YELLOW}•${NC} cat /var/lib/dhcp/dhcpd.leases    ${GREEN}# Просмотр выданных аренд${NC}"
echo
print_success "Готово!"
