@reboot /usr/bin/screen -dmS xray /root/xray.sh

* * * * * /root/ddns.sh

0 8 * * * /sbin/reboot


HWGLL:/ $ pm disable-user com.android.packageinstaller Package com.android.packageinstaller new state: disabled-user HWGLL:/ $

{
  "log": {
    "loglevel": "none"
  },
  "inbounds": [
    {
      "port": 1234,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": {
        "udp": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "23.249.25.132",
            "port": 443,
            "users": [
              {
                "id": "7b39ada7-1fb2-4faa-8707-8342c86c1ebe",
                "encryption": "none",
                "flow": ""
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "path": "/haibara"
        },
        "realitySettings": {
          "serverName": "waseda.jp",
          "publicKey": "9SfWDSYQ4x9ou5N9a31EPg4RnUumHFwIrjGPA-QBkl8",
          "shortId": "e3",
          "fingerprint": "chrome"
        }
      }
    }
  ]
}

source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto ens3  
iface ens3 inet static
        address 160.16.73.96
        netmask 255.255.254.0
        gateway 160.16.72.1
        # dns-* options are implemented by the resolvconf package, if installed
        dns-nameservers 210.188.224.10 210.188.224.11

#iface ens3 inet6 static
#        address 2001:e42:102:1512:160:16:73:96
#        netmask 64
#        gateway fe80::1

auto eth0
iface ens18 inet static
    address 62.3.15.197/32
    gateway 62.3.15.1

iface ens18 inet6 static
    address 2604:a840:2::4c6/128
    gateway 2604:a840:2::1

net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
vm.swappiness=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 212992 16777216
net.ipv4.tcp_wmem=4096 212992 16777216


bash reinstall.sh windows \
     --image-name "Windows Server 2008 R2" \
     --iso "https://download.microsoft.com/download/d/7/e/d7e49421-6d66-4656-9d16-1de8fe8acc7b/7601.17514.101119-1850_ia64fre_serverenterpriseia64_eval_en-us-GRMSIAiEVAL_EN_DVD.iso" \
     --password 96744484982624Hy@ \

bash reinstall.sh windows \
     --image-name "Windows 10 Enterprise LTSC 2021" \
     --password 96744484982624Hy@ \

kD5KVwMV9uoZW1buiM0o

rQvVz5yYiXNN2q0h61Da

***** WHILE INSTALL (VIEW LOGS) *****
Username: administrator
Password: 96744484982624Hy@
SSH Port: 22
WEB Port: 80
***** AFTER INSTALL *****
Username: administrator (Depends on Windows iso's language)
Password: 96744484982624Hy@
RDP Port: 3389

  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "email": "7rqgv20kzxde",
            "id": "d2b38195-703b-4637-aa64-fe6a976b530c"
          }
        ],
        "decryption": "none"
      },
      "sniffing": {
        "destOverride": [
          "http",
          "tls",
          "quic",
          "fakedns"
        ],
        "enabled": true
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "alpn": [
            "h2",
            "http/1.1"
          ],
          "certificates": [
            {
              "buildChain": false,
              "certificateFile": "/root/cert.crt",
              "keyFile": "/root/private.key",
              "ocspStapling": 0,
              "oneTimeLoading": false,
              "usage": "encipherment"
            }
          ],
          "cipherSuites": "",
          "disableSystemRoot": false,
          "echServerKeys": "",
          "enableSessionResumption": false,
          "maxVersion": "1.3",
          "minVersion": "1.2",
          "rejectUnknownSni": false,
          "serverName": "haibara.us"
        },
        "xhttpSettings": {
          "host": "",
          "mode": "auto",
          "path": "/huifujin",
          "scMaxBufferedPosts": 30,
          "scStreamUpServerSecs": "20-80",
          "xPaddingBytes": "100-1000"
        }
      },
      "tag": "in-443-tcp"
    }
  ],

