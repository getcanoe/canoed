import mqtt, MQTTClient, json, strutils

type
  MessageKind = enum connect, publish, subscribe, stop
  MessageIn = object
    case kind: MessageKind
    of connect:
      serverUrl, clientID, username, password: string
    of subscribe:
      topicPattern: string
      qos: QOS
    of publish:
      topic, payload: string
    of stop:
      nil
  MessageOut = object
    topic*, payload*: string

var
  messengerThread: Thread[void]
  channelIn: Channel[MessageIn]
  channelOut: Channel[MessageOut]

proc publishMQTT*(topic, payload: string) =
  channelIn.send(MessageIn(kind: publish, topic: topic, payload: payload)) 

proc subscribeMQTT*(topicPattern: string, qos: QOS) =
  channelIn.send(MessageIn(kind: subscribe, topicPattern: topicPattern, qos: qos))
  
proc connectMQTT*(s, c, u, p: string) =
  channelIn.send(MessageIn(kind: connect, serverUrl: s, clientID: c, username: u, password: p))

proc popMessage*(): MessageOut =
  recv(channelOut)
    
proc tryPopMessage*(): tuple[gotit: bool, topic: string, payload: string] =
  var (gotit, msg) = tryRecv(channelOut)
  if gotit:
    return (true, msg.topic, msg.payload)
  else:
    return (false, nil, nil)

proc stopMessenger*() {.noconv.} =
  channelIn.send(MessageIn(kind: stop))
  joinThread(messengerThread)
  close(channelIn)
  close(channelOut)
  
proc connectToServer(serverUrl, clientID, username, password: string): MQTTClient =
  try:
    echo "Connecting as " & clientID & " to " & serverUrl
    result = newClient(serverUrl, clientID, MQTTPersistenceType.None)
    var connectOptions = newConnectOptions()
    connectOptions.username = username
    connectOptions.password = password
    result.connect(connectOptions)
  except MQTTError:
    quit "MQTT exception: " & getCurrentExceptionMsg()

proc handleMessage(topic: string, message: MQTTMessage) =
  channelOut.send(MessageOut(topic: topic, payload: message.payload))

proc messengerLoop() {.thread.} =
  var client: MQTTClient
  while true:
    if client.isConnected:
      var topicName: string
      var message: MQTTMessage
      # Wait upto 100 ms to receive an MQTT message
      let timeout = client.receive(topicName, message, 100)
      if not timeout:
        #echo "Topic: " & topicName & " payload: " & message.payload
        handleMessage(topicName, message)
    # If we have something in the channel, handle it
    var (gotit, msg) = tryRecv(channelIn)
    if gotit:
      case msg.kind
      of connect:
        client = connectToServer(msg.serverUrl, msg.clientID, msg.username, msg.password)
      of publish:
        #echo "Publishing " & msg.topic & " " & msg.payload
        discard client.publish(msg.topic, msg.payload, QOS0, false)
      of subscribe:
        client.subscribe(msg.topicPattern, msg.qos)
      of stop:
        client.disconnect(1000)
        client.destroy()      
        break

proc startMessenger*(serverUrl, clientID, username, password: string) =
  open(channelIn)
  open(channelOut)
  messengerThread.createThread(messengerLoop)
  addQuitProc(stopMessenger)
  connectMQTT(serverUrl, clientID, username, password)
