# canoed is a service written in Nim, run as:
#
#   canoed -u myuser -p mysecretpassword -s tcp://some-mqtt-server.com:1883 -r http://localhost:7076
#
# canoed listens on port 8080 for REST calls with JSON payloads, and performs calls to rai_node RPC. 
#
# * Jester runs in the main thread, asynchronously. 
# * MQTT is handled in the messengerThread and uses one Channel to publish, and another to get messages.

import jester, posix, net, asyncdispatch, threadpool, mqtt, MQTTClient, asyncnet, htmlgen, json, os, strutils,
  sequtils, nuuid, tables, osproc, base64, docopt, streams, pegs, httpclient


template debug(args: varargs[string, `$`]) =
  echo "<7>" & args.join(" ")

template info(args: varargs[string, `$`]) =
  echo "<6>" & args.join(" ")

# <5>This is a NOTICE level message
# <4>This is a WARNING level message
# <3>This is an ERR level message

template error(args: varargs[string, `$`]) =
  echo "<3>" & args.join(" ")


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
  bindAddr = "127.0.0.1"

# Various defaults
const
  canoedVersion = "canoed 0.0.1"

let help = """
  canoed
  
  Usage:
    canoed [-c CONFIGFILE] [-a PATH] [-u USERNAME] [-p PASSWORD] [-s MQTTURL] [-r RAIURL] [-l LIMIT]
    canoed (-h | --help)
    canoed (-v | --version)

  Options:
    -u USERNAME       Set MQTT username [default: test].
    -p PASSWORD       Set MQTT password [default: test].
    -r RAIURL         Set URL for the rai_node [default: http://localhost:7076]
    -l LIMIT          Set LIMIT of wallets to allow [default: 1000]
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
let limit = parseInt($args["-l"])
var raiUrl {.threadvar.}: string
raiUrl = $args["-r"]
var wallets = 0

wallets = parseInt(readFile("wallets"))

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

proc callRai(spec: JsonNode): JsonNode =
  let client = newHttpClient(timeout = 10000)
  client.headers = newHttpHeaders({ "Content-Type": "application/json" })
  var response: httpclient.Response
  try:
    response = client.request(raiUrl, httpMethod = HttpPost, body = $spec)
    result = parseJson(response.body)
  except TimeoutError:
    let msg = getCurrentExceptionMsg()
    result = %*{"failure": "timeout", "message": msg}
    error("Timeout: " & $result)
  except:
    let
      # e = getCurrentException()
      msg = getCurrentExceptionMsg()
    result = %*{"failure": "error", "message": msg, "body": response.body}
    error("Falure: " & $result)

proc canoeServerStatus(spec: JsonNode): JsonNode =
  # Called if calls fail to get a message to show
  if (fileExists("canoeServerStatus.json")):
    return parseJSON(readFile("canoeServerStatus.json"))
  return %*{"status": "ok"}

proc quotaFull(spec: JsonNode): JsonNode =
  # Called to check available quota
  if (wallets >= limit):
    return %*{"full": true}
  return %*{"full": false}

proc availableSupply(spec: JsonNode): JsonNode =
  return callRai(spec)

proc walletCreate(spec: JsonNode): Future[JsonNode] {.async.} =
  if (wallets < limit):
    debug("Wallets " & $wallets & " < " & $limit)
    result = callRai(spec)
  else:
    debug("Wallets limit reached")
    return %*{"failure": "error", "message": "Not allowing new wallets"}
  if (result.hasKey("wallet")):
    inc wallets
    writeFile("wallets", $wallets)
  await sleepAsync(2000) # Helps?
  return result

proc walletChangeSeed(spec: JsonNode): JsonNode =
  callRai(spec)
  
proc accountCreate(spec: JsonNode): JsonNode =
  callRai(spec)

proc accountKey(spec: JsonNode): JsonNode =
  callRai(spec)

proc accountList(spec: JsonNode): JsonNode =
  callRai(spec)

proc accountRemove(spec: JsonNode): JsonNode =
  callRai(spec)

proc accountHistory(spec: JsonNode): JsonNode =
  callRai(spec)

proc accountsBalances(spec: JsonNode): JsonNode =
  callRai(spec)

proc passwordChange(spec: JsonNode): JsonNode =
  callRai(spec)

proc passwordEnter(spec: JsonNode): JsonNode =
  callRai(spec)

proc passwordValid(spec: JsonNode): JsonNode =
  callRai(spec)

proc walletLocked(spec: JsonNode): JsonNode =
  callRai(spec)
        
proc send(spec: JsonNode): JsonNode =
  callRai(spec)
  
proc performRaiRPC(spec: JsonNode): Future[JsonNode] {.async.} =
  # Switch on action
  var action = spec["action"].str
  case action
  of "quota_full":
    debug("Quota full:" & $spec)
    return quotaFull(spec)
  of "canoe_server_status":
    debug("Canoe server status:" & $spec)
    return canoeServerStatus(spec)
  of "available_supply":
    debug("Available supply: " & $spec)
    return availableSupply(spec)
  of "wallet_create":
    return await walletCreate(spec)
  of "wallet_change_seed":
    debug("Wallet change seed")
    return walletChangeSeed(spec)
  of "account_create":
    debug("Account create")
    return accountCreate(spec)
  of "account_key":
    debug("Account key")
    return accountKey(spec)
  of "account_list":
    debug("Account list")
    let res = accountList(spec)
    debug("Account list: " & $res)
    return res
  of "account_remove":
    debug("Account remove")
    return accountRemove(spec)
  of "account_history":
    debug("Account history")
    return accountHistory(spec)
  of "accounts_balances":
    debug("Accounts balances")
    return accountsBalances(spec)
  of "password_change":
    debug("Password change")
    return passwordChange(spec)
  of "password_enter":
    debug("Password enter")
    return passwordEnter(spec)
  of "password_valid":
    debug("Password valid")
    return passwordValid(spec)
  of "wallet_locked":
    debug("Wallet locked")
    return walletLocked(spec)                
  of "send":
    debug("Send")
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
    var res = await performRaiRPC(spec)
    debug("Result: " & $res)
    resp($res, "application/json")

# Start MQTT messenger thread
#startMessenger(serverUrl, clientID, username, password)

# Start Jester
runForever()
