# Canoed
Canoed is a backend for the Canoe RaiBlocks wallet. It uses a rai_node and creates a middle layer for filtering out RPC calls and holding external state.

## Installing Nim
Canoed is written in Nim, a modern high performance language that produces small and fast binaries by compiling via C. We first need to install Nim.

### Linux
For **regular Linux** you can install Nim the easiest using [choosenim](https://github.com/dom96/choosenim):

    curl https://nim-lang.org/choosenim/init.sh -sSf | sh

That will install the `nim` compiler and the `nimble` package manager.

## Building Canoed
### Prerequisites
First we need to compile the [Paho C library](https://www.eclipse.org/paho/clients/c/) for communicating with MQTT. It's not available as far as I could tell via packages. This library is the de facto standard for MQTT communication and used in tons of projects.

To compile we also need libssl-dev:

    sudo apt-get install libssl-dev

Then we can build and install Paho C:

    git clone https://github.com/eclipse/paho.mqtt.c.git
    cd paho.mqtt.c
    make
    sudo make install
    sudo ldconfig

### Building
Now we are ready to build **canoed**.

Enter the `canoed` directory and build it using the command `nimble build` or both build and install it using `nimble install`. This will download and install Nim dependencies automatically.

### Adding service
This presumes you already have a rai_node.service defined according to [the wiki page](https://github.com/clemahieu/raiblocks/wiki/Running-rai_node-as-a-service).

Create `/etc/systemd/system/canoed.service`:

    [Unit]
    Description=Canoed
    Documentation=https://github.com/gokr/canoed
    After=network.target httpd.service rai_node.service

    [Service]
    User=canoe
    WorkingDirectory=/home/canoe
    ExecStart=/home/canoe/.nimble/bin/canoed -r http://[::1]:7076
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

