# Package
version       = "0.0.1"
author        = "Göran Krampe"
description   = "Headless REST backend for RaiW wallet."
license       = "MIT"
srcDir        = "src"
binDir        = "bin"
bin           = @["canoed"]
skipExt       = @["nim"]

# Dependencies
requires "nim >= 0.17.2"
requires "jester"
requires "nuuid"
requires "docopt >= 0.6.5"
requires "tempdir >= 1.0.0"
requires "https://github.com/barnybug/nim-mqtt.git"

# Tasks
task test, "Runs the test suite":
  exec "cd tests && nim c -r all"
