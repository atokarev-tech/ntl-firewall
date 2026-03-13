[![en](https://img.shields.io/badge/lang-en-red.svg)](https://github.com/atokarev-tech/ntl-firewall/blob/main/README-en.md)

> [!WARNING]  
> * тестировалось только на debian 13
> * нужен рут

> [!TIP]  
> если ошибка, что curl не установлен, то:
> ```shell
> apt install curl -y
> ```
> или можно использовать wget
> ```shell
> wget <ссылка_на_скрипт> && bash <имя_скрипта>
> ```

# Firewall

```shell
curl -O https://raw.githubusercontent.com/atokarev-tech/ntl-firewall/refs/heads/main/ntl_firewall_install.sh && bash ntl_firewall_install.sh
```

# DHCP

```shell
curl -O https://raw.githubusercontent.com/atokarev-tech/ntl-firewall/refs/heads/main/ntl_dhcp_install.sh && bash ntl_dhcp_install.sh
```

# DNS

```shell
curl -O https://raw.githubusercontent.com/atokarev-tech/ntl-firewall/refs/heads/main/ntl_dns_install.sh && bash ntl_dns_install.sh
```
