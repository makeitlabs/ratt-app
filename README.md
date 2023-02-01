# RATT Application

The core RATT application that controls access to the equipment as well as provides the GUI that the end user sees is written in Python3 and PyQt5/QML.  This runs on the target hardware, and can also be run on a desktop host for more rapid debug and feature development.

## Run on Development Host

### Install prerequisites

These instructions are meant for Ubuntu 20.04 (LTS), typically run in a virtual machine.  They may work on future versions of Ubuntu, but this is not guaranteed.

Start by installing the following packages:

    sudo apt install python3-pyqt5 python3-pyqt5.qtmultimedia python3-pyqt5.qtserialport python3-pyqt5.qtquick qml-module-qtquick-controls qml-module-qtmultimedia python3-paho-mqtt mosquitto

These packages are needed to run the application (Python3 + PyQt5 + QML), as well as the optional backend services such as the Mosquitto MQTT broker.

### Set up Certificates

#### Local Self-Signed Certs

For running completely contained on a development host, you will need to create your own CA, server and client certificates.  The certificates are used for the MQTT client in RATT to connect to the MQTT broker (aka server).

You can create development certs as follows:

    cd ~/ratt/deployment/certs/mqtt

    ./gen_ca_and_server_certs.sh
    ./gen_client_cert.sh ubuntu
    ./deploy_mosquitto_certs.sh

#### Production Certs

It is also possible to use real MQTT certificates from a production server.  In this case, the CA and server certs will have already been created.  A script is usually used to create new certificates, similar to above.

  * Create a client cert on the production server
  * Copy CA cert and private certs and keys to your development server
  * Edit the RATT config file and set the SSL certificate options to point to your certs

### Add host alias in `/etc/hosts`

Note that the localhost alias hostname 'ubuntu' must match the name used when the client cert was generated in the previous step, otherwise the CN will not match and there will be an SSL error.

    127.0.1.1	ubuntu devel

### MQTT Broker

#### Local MQTT

To run a development MQTT broker locally, if a `systemd` service was not installed.

    sudo mosquito &

#### Remote/Production MQTT via SSH Tunnel

It is also possible to use the production MQTT server with SSH tunneling.  This is especially useful when developing features which interact with backend automation.  The RATT config must be edited to point to a localhost tunneled port for the MQTT broker, and the SSH tunnel must be established.

### Authentication Backend

#### Local Auth Backend

Running the auth backend locally requires a clone of the `authbackend` repository and proper configuration.  See `README.md` in the repo for more information about configuration of databases and ini files.

    cd ~/authbackend
    python authserver.py

#### Remote/Production Auth Backend

It is also possible to use a remote auth backend, either directly accessible via a public address or through an SSH tunnel.  The RATT config file must be edited to use the correct server address, port, API path, and API credentials.

### Run the RATT Application

The `conf/ratt-devhost.ini-example` example config file contains appropriate settings to allow the app to run on the development host with simulated I/O, RFID, and diagnostics display output.  The example should be copied to `ratt-devhost.ini` and modified to suit your specific environment.

    python3 ./ratt.py --ini ./conf/ratt-devhost.ini
    
# Deployment Notes
When deploying this application - to get it to run smoothly, you must...

1. Add MakeIt devel auth server into `/etc/hosts` like `10.25.0.10 auth`
2. Add MakeIt mqtt server into `/etc/hosts` like `10.25.0.8 mqtt`
3. Add your own ssh key into `/home/root/.ssh/authorized_keys`
4. Configure `/data/ratt/ratt.ini` as required, like:
  1. `ToolDesc=` with friendly tool name
  2. `Class=` with a class from the `/usr/ratt/personalities` directory
  3. `ResourceId=` to match appropriate Resource name in AuthIt
  4. `NodeName=` to match approprate Node Name in AuthIt
  5. `BrokerHost=mqtt` to match server previously in `/etc/hosts`
  6. `BrokerPort=8883` for standard internal MakeIt MQTTS

