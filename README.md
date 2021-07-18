# NOT MAINTAINED ANYMORE
Canoe is not maintained, the Canoe website with the binary downloads **is not live anymore** and this wallet backend is not running. The domain "getcanoe.io" will not be renewed at end of 2021.
This means Canoe **can no longer be used** but if you used Canoe earlier you can easily import your seed to another wallet, no funds are lost. Canoe is fully Open Source and anyone could revive it, rebrand and start their own server. If anyone is interested in doing that, feel free to contact me.

regards, Göran and the rest of the developers of Canoe
_____
# Canoed
Canoed is a backend for the Canoe Nano wallet. It uses a rai_node and creates a middle layer for mediating RPC calls, holding external state, forwarding blocks over MQTT and various other things Canoe needs to be done on the server. It uses a runing rai_node, Redis, PostgreSQL and VerneMQ.

## Nodejs
Canoed was first written in Nim, a modern high performance language that produces small and fast binaries by compiling via C. I love Nim, but we switched to Nodejs because there is no properly working MQTT library in Nim. The code style is fairly plain vanilla.

## Running Canoed
It's the standard:

```
npm install
./canoed
```

See source code to find the default `canoed.conf` JSON configuration.

### Adding a systemd service
This presumes you already have a rai_node.service defined according to [the wiki page](https://github.com/clemahieu/raiblocks/wiki/Running-rai_node-as-a-service).

Create `/etc/systemd/system/canoed.service`:

    [Unit]
    Description=Canoed
    Documentation=https://github.com/gokr/canoed
    After=network.target httpd.service rai_node.service

    [Service]
    User=canoed
    WorkingDirectory=/home/canoed
    ExecStart=/home/canoed/canoed/canoed
    KillMode=mixed
    KillSignal=SIGTERM
    Restart=always
    RestartSec=2s
    NoNewPrivileges=yes
    StandardOutput=syslog+console
    StandardError=syslog+console

    [Install]
    WantedBy=multi-user.target


Then enable it:

    systemctl daemon-reload
    systemctl enable canoed
    systemctl start canoed

