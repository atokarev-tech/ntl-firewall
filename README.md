> [!WARNING]  
> * tested on debian 13 only 
> * you must be root

> [!TIP]  
> If curl is not found (command not found), install it from the repository:
> ```shell
> apt install curl -y
> ```
> or y can use wget
> ```shell
> wget <link to script> && bash <script_name>
> ```

# Firewall script

```shell
curl -O https://raw.githubusercontent.com/atokarev-tech/ntl-firewall/refs/heads/main/ntl_firewall_install.sh && bash ntl_firewall_install.sh
```






# DHCP script

```shell
curl -O https://raw.githubusercontent.com/atokarev-tech/ntl-firewall/refs/heads/main/ntl_dhcp_install.sh && bash ntl_dhcp_install.sh
```
