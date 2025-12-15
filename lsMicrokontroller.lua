local redstone = component.proxy(component.list("redstone")())
local modem = component.proxy(component.list("modem")())
local eeprom = component.proxy(component.list("eeprom")())

local PORT = 1234
local REDSTONE_SIDE = 0 
local ID = 2 

local PING_INTERVAL = 10 
local TIMEOUT_LIMIT = 15 

-- 1. SET MODEM STRENGTH (Critical Fix)
if modem.isWireless() then
    modem.setStrength(400) -- Set wireless range
end
modem.open(PORT)

-- 2. STARTUP INDICATOR (Beep + Flash)
computer.beep(1000, 0.5) 

-- Helper Functions
local function serialize(tbl)
  local function ser(val)
    if type(val) == "number" then return tostring(val)
    elseif type(val) == "boolean" then return val and "true" or "false"
    elseif type(val) == "string" then return string.format("%q", val)
    elseif type(val) == "table" then
      local items = {}
      for k, v in pairs(val) do items[#items + 1] = "[" .. ser(k) .. "]=" .. ser(v) end
      return "{" .. table.concat(items, ",") .. "}"
    else return "nil" end
  end
  return ser(tbl)
end

local function unserialize(str)
  local f = load("return " .. str)
  if f then return f() end
  return nil
end

local function setRedstone(stellung)
    local outputs = {}
    for i=0,15 do outputs[i] = 0 end

    if stellung == "hp0" then outputs[14] = 255
    elseif stellung == "sh1" then outputs[0] = 255
    elseif stellung == "kenn" then outputs[15] = 255
    end
    
    redstone.setBundledOutput(REDSTONE_SIDE, outputs)
end

-- Visual flash on startup to prove code is running
setRedstone("sh1")
setRedstone("off")

-- Initial Request
modem.broadcast(PORT, serialize({event = "signal_request_state", id = ID}))

local last_server_contact = computer.uptime()
local next_ping = 0

while true do
    local now = computer.uptime()
    
    -- SEND PING
    if now >= next_ping then
        modem.broadcast(PORT, serialize({event = "ping", id = ID}))
        next_ping = now + PING_INTERVAL
    end

    -- TIMEOUT CHECK (Turn off if no PONG for too long)
    if (now - last_server_contact) > TIMEOUT_LIMIT then
        setRedstone("off")
    end

    -- Calculate Sleep
    local time_left = next_ping - now
    if time_left < 0.1 then time_left = 0.1 end

    local eventType, _, _, port, _, message = computer.pullSignal(time_left)

    if eventType == "modem_message" and port == PORT then
        local data = unserialize(message)
        
        if data then
            local dataID = tonumber(data.id) or data.id

            -- 1. Server Restart -> Request State
            if data.event == "initial_startup" then
                modem.broadcast(PORT, serialize({event = "signal_request_state", id = ID}))
            end

            -- 2. Pong Received -> Update Watchdog
            if data.event == "pong" and (dataID == ID) then
                last_server_contact = now
            end

            -- 3. Signal Update -> Set State & Update Watchdog
            if data.event == "signal_update" and (dataID == ID) then
                setRedstone(data.state)
                last_server_contact = now 

                modem.broadcast(PORT, serialize({
                    event = "signal_update_ack",
                    id = ID,
                    state = data.state
                }))
            end
        end
    end
end