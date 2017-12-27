import os, ospaths, base64, json, mqtt, nuuid, docopt

import messenger

let help = """
raiwdup

Usage:
  raiwdup [-u USERNAME] [-p PASSWORD] [-s MQTTURL] [-v] SKETCHFILE
  raiwdup (-h | --help)
  raiwdup (-v | --version)

Options:
  SKETCHFILE              The Arduino sketch to verify or upload.
  -u --username USERNAME  Set MQTT username [default: test].
  -p --password PASSWORD  Set MQTT password [default: test].
  -s --server MQTTURL     Set URL for the MQTT server [default: tcp://localhost:1883]
  -v --verify             Verify only.
  -h --help               Show this screen.
  --version               Show version.
"""  
let args = docopt(help, version = "raiwd 0.1.0")

var username = $args["--username"]
var password = $args["--password"]
var serverUrl = $args["--server"]
var verifyOnly = args["--verify"]
var filePath  = $args["SKETCHFILE"]
var fileName = extractFilename(filePath)
var source: string

# Open file content
try:
  source = readFile(filePath)
except:
  echo getCurrentExceptionMsg()
  quit 1

# Start up MQTT messenger
startMessenger(serverUrl, username, password, "uploader" & generateUUID())
  
# Upload or Verify only
var command = "upload"
if verifyOnly:
  command = "verify"

# Generate an id for the response we want to get
let responseId = generateUUID()

# Subscribe in advance for that response
subscribeMQTT("response/" & command & "/" & responseId, QOS0)

# Construct a job to run
var job = %*{
  "sketch": fileName,
  "src": encode(source)
}

# Submit job
publishMQTT(command & "/" & responseId, $job)

# Make sure we got a response
var msg = popMessage()
var jobId = parseJson(msg.payload)["id"].getStr

# Make sure we got a result with exitCode 0
subscribeMQTT("result/" & jobId, QOS0)
msg = popMessage()
var result = parseJson(msg.payload)
if (result["type"].getStr == "success") and (result["exitCode"].getNum == 0):
  if verifyOnly:
    echo "Verify successful!"
  else:
    echo "Upload successful!"
else:
  if verifyOnly:
    echo "Verify failed ..."
  else:
    echo "Upload failed ..."
  