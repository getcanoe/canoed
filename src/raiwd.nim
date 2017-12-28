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

proc callRai(spec: JsonNode): httpclient.Response =
  let client = newHttpClient()
  client.headers = newHttpHeaders({ "Content-Type": "application/json" })
  return client.request(raiUrl, httpMethod = HttpPost, body = $spec)

proc availableSupply(spec: JsonNode): JsonNode =
  var response = callRai(spec)
  var spec = parseJson(response.body)
  return %*{"available": spec["available"]}

proc walletCreate(spec: JsonNode): JsonNode =
  var response = callRai(spec)
  var spec = parseJson(response.body)
  return %*{"wallet": spec["wallet"]}

proc walletChangeSeed(spec: JsonNode): JsonNode =
  var response = callRai(spec)
  var spec = parseJson(response.body)
  return %*{"success": spec["success"]}
  
proc accountCreate(spec: JsonNode): JsonNode =
  var response = callRai(spec)
  var spec = parseJson(response.body)
  return %*{"account": spec["account"]}

proc accountKey(spec: JsonNode): JsonNode =
  var response = callRai(spec)
  var spec = parseJson(response.body)
  return %*{"key": spec["key"]}

proc accountList(spec: JsonNode): JsonNode =
  var response = callRai(spec)
  var spec = parseJson(response.body)
  return %*{"accounts": spec["accounts"]}

proc accountRemove(spec: JsonNode): JsonNode =
  var response = callRai(spec)
  var spec = parseJson(response.body)
  return %*{"removed": spec["removed"]}    

proc accountHistory(spec: JsonNode): JsonNode =
  var response = callRai(spec)
  var spec = parseJson(response.body)
  return %*{"history": spec["history"]}    

proc accountsBalances(spec: JsonNode): JsonNode =
  var response = callRai(spec)
  var spec = parseJson(response.body)
  return %*{"balances": spec["balances"]}    

proc passwordChange(spec: JsonNode): JsonNode =
  var response = callRai(spec)
  var spec = parseJson(response.body)
  return %*{"changed": spec["changed"]}    

proc passwordEnter(spec: JsonNode): JsonNode =
  var response = callRai(spec)
  var spec = parseJson(response.body)
  return %*{"valid": spec["valid"]}    

proc passwordValid(spec: JsonNode): JsonNode =
  var response = callRai(spec)
  var spec = parseJson(response.body)
  return %*{"valid": spec["valid"]}    

proc walletLocked(spec: JsonNode): JsonNode =
  var response = callRai(spec)
  var spec = parseJson(response.body)
  return %*{"locked": spec["locked"]}    
        
proc send(spec: JsonNode): JsonNode =
  var response = callRai(spec)
  var spec = parseJson(response.body)
  return %*{"block": spec["block"]}    
  
proc performRaiRPC(spec: JsonNode): JsonNode =
  # Switch on action
  var action = spec["action"].str
  case action
  of "available_supply":
    echo "Available supply: " & $spec
    return availableSupply(spec)
  of "wallet_create":
    echo "Wallet create: " & $spec
    return walletCreate(spec)
  of "wallet_change_seed":
    echo "Wallet change seed: " & $spec
    return walletChangeSeed(spec)
  of "account_create":
    echo "Account create: " & $spec
    return accountCreate(spec)
  of "account_key":
    echo "Account key: " & $spec
    return accountKey(spec)
  of "account_list":
    echo "Account list: " & $spec
    return accountList(spec)
  of "account_remove":
    echo "Account remove: " & $spec
    return accountRemove(spec)
  of "account_history":
    echo "Account history: " & $spec
    return accountHistory(spec)
  of "accounts_balances":
    echo "Accounts balances: " & $spec
    return accountsBalances(spec)
  of "password_change":
    echo "Password change: " & $spec
    return passwordChange(spec)
  of "password_enter":
    echo "Password enter: " & $spec
    return passwordEnter(spec)
  of "password_valid":
    echo "Password valid: " & $spec
    return passwordValid(spec)
  of "wallet_locked":
    echo "Wallet locked: " & $spec
    return walletLocked(spec)                
  of "send":
    echo "Send: " & $spec
    return send(spec)
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
#startMessenger(serverUrl, clientID, username, password)

# Start Jester
runForever()