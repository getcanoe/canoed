# canoed is a service written in Nim, run as:
#
#   canoed -u myuser -p mysecretpassword -s tcp://some-mqtt-server.com:1883 -r http://localhost:7076
#
# canoed listens on port 8080 for REST calls with JSON payloads, and performs calls to rai_node RPC. 
#
# * Jester runs in the main thread, asynchronously. 
# * MQTT is handled in the messengerThread and uses one Channel to publish, and another to get messages.

import jester, posix, asyncdispatch, mqtt, MQTTClient, asyncnet, htmlgen, json, os, strutils,
  sequtils, nuuid, tables, osproc, base64, threadpool, docopt, streams, pegs, httpclient


template debug(args: varargs[string, `$`]) =
  echo "<7>" & args.join(" ")

template info(args: varargs[string, `$`]) =
  echo "<6>" & args.join(" ")

# <5>This is a NOTICE level message
# <4>This is a WARNING level message
# <3>This is an ERR level message

template critical(args: varargs[string, `$`]) =
  echo "<2>" & args.join(" ")
  
# <1>This is an ALERT level message
# <0>This is an EMERG level message

onSignal(SIGABRT):
  ## Handle SIGABRT from systemd
  # Lines printed to stdout will be received by systemd and logged
  # Start with "<severity>" from 0 to 7
  critical "Received SIGABRT"
  quit(1)


# Jester settings
settings:
  port = Port(8080)

# Various defaults
const
  canoedVersion = "canoed 0.0.1"

let help = """
  canoed
  
  Usage:
    canoed [-c CONFIGFILE] [-a PATH] [-u USERNAME] [-p PASSWORD] [-s MQTTURL] [-r RAIURL]
    canoed (-h | --help)
    canoed (-v | --version)

  Options:
    -u USERNAME       Set MQTT username [default: test].
    -p PASSWORD       Set MQTT password [default: test].
    -r RAIURL         Set URL for the rai_node [default: http://localhost:7076]
    -z PORT         
    -s MQTTURL        Set URL for the MQTT server [default: tcp://localhost:1883]
    -c CONFIGFILE     Load options from given filename if it exists [default: canoed.conf]
    -h --help         Show this screen.
    -v --version      Show version.
  """

var args = docopt(help, version = canoedVersion)

# Pool size
#setMinPoolSize(50)
#setMaxPoolSize(50)

# We need to load config file if it exists and run docopt again
let config = $args["-c"]
if existsFile(getCurrentDir() / config):
  var conf = readFile(getCurrentDir() / config).splitWhitespace()
  var params = commandLineParams().concat(conf)
  args = docopt(help, params, version = canoedVersion)

# MQTT parameters
let clientID = "canoed-" & generateUUID()
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
    info("Connecting as " & clientID & " to " & serverUrl)
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
        debug "Topic: ", topicName,  " payload: ", message.payload
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
    debug("Available supply: " & $spec)
    return availableSupply(spec)
  of "wallet_create":
    debug("Wallet create: " & $spec)
    return walletCreate(spec)
  of "wallet_change_seed":
    debug("Wallet change seed: " & $spec)
    return walletChangeSeed(spec)
  of "account_create":
    debug("Account create: " & $spec)
    return accountCreate(spec)
  of "account_key":
    debug("Account key: " & $spec)
    return accountKey(spec)
  of "account_list":
    debug("Account list: " & $spec)
    return accountList(spec)
  of "account_remove":
    debug("Account remove: " & $spec)
    return accountRemove(spec)
  of "account_history":
    debug("Account history: " & $spec)
    return accountHistory(spec)
  of "accounts_balances":
    debug("Accounts balances: " & $spec)
    return accountsBalances(spec)
  of "password_change":
    debug("Password change: " & $spec)
    return passwordChange(spec)
  of "password_enter":
    debug("Password enter: " & $spec)
    return passwordEnter(spec)
  of "password_valid":
    debug("Password valid: " & $spec)
    return passwordValid(spec)
  of "wallet_locked":
    debug("Wallet locked: " & $spec)
    return walletLocked(spec)                
  of "send":
    debug("Send: " & $spec)
    return send(spec)
  return %*{"error": "unknown action"}

# Jester routes
routes:
  get "/":
   resp p("canoed is running")

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
    debug("Result: " & $res)
    resp($res, "application/json")

# Start MQTT messenger thread
#startMessenger(serverUrl, clientID, username, password)

# Start Jester
runForever()