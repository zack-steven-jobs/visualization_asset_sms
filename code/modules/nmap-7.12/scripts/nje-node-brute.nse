local io = require "io"
local string = require "string"
local table = require "table"
local nmap = require "nmap"
local stdnse = require "stdnse"
local shortport = require "shortport"
local brute = require "brute"
local creds = require "creds"
local unpwdb = require "unpwdb"
local drda = require "drda"
local comm = require "comm"

description = [[
z/OS JES Network Job Entry (NJE) target node name brute force.

NJE node communication is made up of an OHOST and an RHOST. Both fields
must be present when conducting the handshake. This script attemtps to
determine the target systems NJE node name.

To initiate NJE the client sends a 33 byte record containing the type of
record, the hostname (RHOST), IP address (RIP), target (OHOST),
target IP (OIP) and a 1 byte response value (R) as outlined below:

<code>
0 1 2 3 4 5 6 7 8 9 A B C D E F
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  TYPE       |     RHOST     |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  RIP  |  OHOST      | OIP   |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| R |
+-+-+
</code>

* TYPE: Can either be 'OPEN', 'ACK', or 'NAK', in EBCDIC, padded by spaces to make 8 bytes. This script always send 'OPEN' type.
* RHOST: Name of the local machine initiating the connection. Set to 'FAKE'
* RIP: Hex value of the local systems IP address. Set to '0.0.0.0'
* OHOST: The value being enumerated to determine the target system name.
* OIP: IP address, in hex, of the target system. Set to '0.0.0.0'.
* R: The response. NJE will send an 'R' of 0x01 if the OHOST is wrong or 0x04/0x00 if the OHOST is correct.

Since most systems will only have one node name, it is recommended to use the
<code>brute.firstonly</code> script argument.
]]


---
-- @usage
-- nmap -sV --script=nje-node-brute <target>
-- nmap --script=nje-node-brute --script-args=hostlist=nje_names.txt -p 175 <target>
--
-- @args nje-node-brute.hostlist The filename of a list of node names to try.
--                               Defaults to "nselib/data/vhosts-default.lst"
--
-- @output
-- PORT    STATE SERVICE REASON
-- 175/tcp open  nje     syn-ack
-- | nje-node-brute:
-- |   Node Name:
-- |     Node Name:WASHDC - Valid credentials
-- |_  Statistics: Performed 6 guesses in 14 seconds, average tps: 0
--
-- @changelog
-- 2015-06-15 - v0.1 - created by Soldier of Fortran

author = "Soldier of Fortran"
license = "Same as Nmap--See http://nmap.org/book/man-legal.html"
categories = {"intrusive", "brute"}

portrule = shortport.port_or_service({175,2252}, "nje")

local openNJEfmt = "\xd6\xd7\xc5\xd5@@@@\xc6\xc1\xd2\xc5@@@@\0\0\0\0%s\0\0\0\0\0"

Driver = {
  new = function(self, host, port, options)
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o.host = host
    o.port = port
    o.options = options
    return o
  end,

  connect = function( self )
    -- the high timeout should take delays into consideration
    local s, r, opts, _ = comm.tryssl(self.host, self.port, '', { timeout = 50000 } )
    if ( not(s) ) then
      return false, "Failed to connect to server"
    end
    self.socket = s
    return true
  end,

  disconnect = function( self )
    return self.socket:close()
  end,

  login = function( self, username, password ) -- Technically we're not 'logging in' we're just using password
    -- Generates an NJE 'OPEN' packet with the node name
    password = string.upper(password)
    stdnse.verbose(2,"Trying... %s", password)
    local openNJE = openNJEfmt:format( drda.StringUtil.toEBCDIC(("%-8s"):format(password)) )
    local status, err = self.socket:send( openNJE )
    if not status then return false, "Failed to send" end
    local status, data = self.socket:receive_bytes(33)
    if not status then return false, "Failed to receive" end
    if ( data:sub(-1) == "\0" ) or
      ( data:sub(-1) == "\x04" ) then
      stdnse.verbose("Valid Node Name Found: %s", password)
      return true, creds.Account:new("Node Name", password, creds.State.VALID)
    end
    return false, brute.Error:new( "Invalid Node Name" )
  end,
}

-- Checks string to see if it follows node naming limitations
local valid_name = function(x)
  local patt = "[%w@#%$]"
  return (string.len(x) <= 8 and string.match(x,patt))
end

function iter(t)
  local i, val
  return function()
    i, val = next(t, i)
    return val
  end
end

action = function( host, port )
  -- Oftentimes the LPAR will be one of the subdomain of a system.
  local names = host.name and stdnse.strsplit("%.", host.name) or {}
  if host.targetname then
    host.targetname:gsub("[^.]+", function(n) table.insert(names, n) end)
  end
  local filename = stdnse.get_script_args('nje-node-brute.hostlist')
  filename = (filename and nmap.fetchfile(filename) or filename) or
    nmap.fetchfile("nselib/data/vhosts-default.lst")
  for l in io.lines(filename) do
    if not l:match("#!comment:") then
      table.insert(names, l)
    end
  end
  local engine = brute.Engine:new(Driver, host, port)
  local users = unpwdb.filter_iterator(iter(names), valid_name)
  engine.options:setOption("passonly", true )
  engine:setPasswordIterator(users)
  engine.options.script_name = SCRIPT_NAME
  engine.options:setTitle("Node Name")
  local status, result = engine:start()
  return result
end
