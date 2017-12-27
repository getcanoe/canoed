# RaiWd
RaiW is a backend for the RaiW RaiBlocks wallet. It uses a rai_node and creates a middle layer for filtering out RPC calls and holding external state.

## Installing Nim
RaiWd is written in Nim, a modern high performance language that produces small and fast binaries by compiling via C. We first need to install Nim.

### Linux
For **regular Linux** you can install Nim the easiest using [choosenim](https://github.com/dom96/choosenim):

    curl https://nim-lang.org/choosenim/init.sh -sSf | sh

That will install the `nim` compiler and the `nimble` package manager.

## Building Raiwd
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
Now we are ready to build **raiwd**.

Enter the `raiwd` directory and build it using the command `nimble build` or both build and install it using `nimble install`. This will download and install Nim dependencies automatically.

### Adding service
Create `/etc/systemd/system/raiwd.service`:

    [Unit]
    Description=RaiWd
    After=network.target

    [Service]
    User=raiw
    WorkingDirectory=/home/raiw
    ExecStart=/home/raiw/.nimble/bin/raiwd
    Restart=always
    RestartSec=60
        
    [Install]
    WantedBy=multi-user.target

Then enable it:

    systemctl daemon-reload
    systemctl enable raiwd
    systemctl start raiwd

