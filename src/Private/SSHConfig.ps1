# SSHConfig.ps1

# Ruta de la clave privada
$privateKeyPath = "E:/Documents/cacsi_dev/linux/ssh_key/privatekey.key"

# Información de los servidores
$servers = @{
    "isabel" = @{
        "username" = "cacsiadmin"
        "ip" = "192.168.10.18"
        "port" = 22
    };
    "lucia" = @{
        "username" = "slnadmin"
        "ip" = "192.168.9.18"
        "port" = 22
    };
    "cisne" = @{
        "username" = "ccisnedev"
        "ip" = "192.168.10.22"
        "port" = 22
    };
    "termux" = @{
        "username" = "u0_a115"
        "ip" = "192.168.137.206"
        "port" = 8022
    };
    "10.3" = @{
        "username" = "apiController"
        "ip" = "192.168.10.3"
        "port" = 22
    }
}