# Raiwd is a service written in Nim, run as:
#
#   raiwd -u myuser -p mysecretpassword -s tcp://some-mqtt-server.com:1883 -r http://localhost:7076
#
# Raiwd listens on port 8080 for REST calls with JSON payloads, and performs calls to rai_node RPC. 
#
# * Jester runs in the main thread, asynchronously. 
# * MQTT is handled in the messengerThread and uses one Channel to publish, and another to get messages.

import jester, asyncdispatch, mqtt, MQTTClient, asyncnet, htmlgen, json, logging, os, strutils,
  sequtils, nuuid, tables, osproc, base64, threadpool, docopt, streams, pegs, httpclient

# Jester settings
settings:
  port = Port(8080)

# Various defaults
const
  raiwdVersion = "raiwd 0.0.1"

let help = """
  raiwd
  
  Usage:
    raiwd [-c CONFIGFILE] [-a PATH] [-u USERNAME] [-p PASSWORD] [-s MQTTURL] [-r RAIURL]
    raiwd (-h | --help)
    raiwd (-v | --version)

  Options:
    -u USERNAME       Set MQTT username [default: test].
    -p PASSWORD       Set MQTT password [default: test].
    -r RAIURL         Set URL for the rai_node [default: http://localhost:7076]
    -z PORT         
    -s MQTTURL        Set URL for the MQTT server [default: tcp://localhost:1883]
    -c CONFIGFILE     Load options from given filename if it exists [default: raiwd.conf]
    -h --help         Show this screen.
    -v --version      Show version.
  """

var args = docopt(help, version = raiwdVersion)

# Pool size
#setMinPoolSize(50)
#setMaxPoolSize(50)

# We need to load config file if it exists and run docopt again
let config = $args["-c"]
if existsFile(getCurrentDir() / config):
  var conf = readFile(getCurrentDir() / config).splitWhitespace()
  var params = commandLineParams().concat(conf)
  args = docopt(help, params, version = raiwdVersion)

# MQTT parameters
let clientID = "raiwd-" & generateUUID()
let username = $args["-u"]
let password = $args["-p"]
let serverUrl = $args["-s"]
var raiUrl {.threadvar.}: string
raiUrl = $args["-r"]

type
  MessageKind = enum connect, publish, stop
  Message = object
    case kind: MessageKind
    of connect:
      serverUrl, clientID, username, password: string
    of publish:
      topic, payload: string
    of stop:
      nil

var
  messengerThread: Thread[void]
  channel: Channel[Message]

proc publishMQTT*(topic, payload: string) =
  channel.send(Message(kind: publish, topic: topic, payload: payload))

proc connectMQTT*(s, c, u, p: string) =
  channel.send(Message(kind: connect, serverUrl: s, clientID: c, username: u, password: p))
   
proc stopMessenger() {.noconv.} =
  channel.send(Message(kind: stop))
  joinThread(messengerThread)
  close(channel)
  
proc connectToServer(serverUrl, clientID, username, password: string): MQTTClient =
  try:
    echo "Connecting as " & clientID & " to " & serverUrl
    result = newClient(serverUrl, clientID, MQTTPersistenceType.None)
    var connectOptions = newConnectOptions()
    connectOptions.username = username
    connectOptions.password = password
    result.connect(connectOptions)
    #result.subscribe("config", QOS0)
    #result.subscribe("verify/+", QOS0)
    #result.subscribe("upload/+", QOS0)
  except MQTTError:
    quit "MQTT exception: " & getCurrentExceptionMsg()

proc messengerLoop() {.thread.} =
  var client: MQTTClient
  while true:
    if client.isConnected:
      var topicName: string
      var message: MQTTMessage
      # Wait upto 100 ms to receive an MQTT message
      let timeout = client.receive(topicName, message, 100)
      if not timeout:
        echo "Topic: " & topicName & " payload: " & message.payload
        #handleMessage(topicName, message)
    # If we have something in the channel, handle it
    var (gotit, msg) = tryRecv(channel)
    if gotit:
      case msg.kind
      of connect:
        client = connectToServer(msg.serverUrl, msg.clientID, msg.username, msg.password)
      of publish:
        #echo "Publishing " & msg.topic & " " & msg.payload
        discard client.publish(msg.topic, msg.payload, QOS0, false)
      of stop:
        client.disconnect(1000)
        client.destroy()      
        break

proc startMessenger(serverUrl, clientID, username, password: string) =
  open(channel)
  messengerThread.createThread(messengerLoop)
  addQuitProc(stopMessenger)
  connectMQTT(serverUrl, clientID, username, password)

proc walletCreate(spec: JsonNode): JsonNode =
  let client = newHttpClient()
  client.headers = newHttpHeaders({ "Content-Type": "application/json" })
  #let body = %*{
  #  "data": "some text"
  #}
  let response = client.request(raiUrl, httpMethod = HttpPost, body = $spec)
  echo "Status from wallet create: " & response.status
  var spec = parseJson(response.body)
  return %*{"wallet": spec["wallet"]}

proc performRaiRPC(spec: JsonNode): JsonNode =
  # Switch on action
  var action = spec["action"].str
  case action
  of "wallet_create":
    echo "Wallet create: " & $spec
    return walletCreate(spec)
  return %*{"error": "unknown action"}

# Jester routes
routes:
  get "/":
   resp p("Raiwd is running")

  post "/callback":
    var spec: JsonNode
    try:
      spec = parseJson(request.body)
      echo "Callback: " & $spec
    except:
      stderr.writeLine "Unable to parse JSON body: " & request.body      
      resp Http400, "Unable to parse JSON body"
    resp Http200, "Got it"

  post "/rpc":
    var spec: JsonNode
    try:
      spec = parseJson(request.body)
    except:
      stderr.writeLine "Unable to parse JSON body: " & request.body      
      resp Http400, "Unable to parse JSON body"
    var res = performRaiRPC(spec)
    resp($res, "application/json")

# Start MQTT messenger thread
startMessenger(serverUrl, clientID, username, password)

# Start Jester
runForever()