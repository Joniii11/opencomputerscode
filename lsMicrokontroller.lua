local redstone = component.proxy(component.list("redstone")())
local modem = component.proxy(component.list("modem")())
local eeprom = component.proxy(component.list("eeprom")())

local PORT = 1234
local REDSTONE_SIDE = 0 
local ID = 2 

local PING_INTERVAL = 10 -- Alle 10 Sekunden Ping senden
local TIMEOUT_LIMIT = 15 -- Nach 15 Sekunden ohne Pong dunkel schalten

local last_server_contact = computer.uptime()
local next_ping = 0

modem.open(PORT)

-- HELPER FUNCTIONS (Unchanged)
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

-- Sofortige Statusabfrage beim Start
modem.broadcast(PORT, serialize({event = "signal_request_state", id = ID}))

while true do
    local now = computer.uptime()
    
    -- PING SENDEN
    if now >= next_ping then
        modem.broadcast(PORT, serialize({event = "ping", id = ID}))
        next_ping = now + PING_INTERVAL
    end

    -- TIMEOUT CHECK
    if (now - last_server_contact) > TIMEOUT_LIMIT then
        setRedstone("off")
    end

    -- Sleep Berechnung
    local time_left = next_ping - now
    if time_left < 0.1 then time_left = 0.1 end

    local eventType, _, _, port, _, message = computer.pullSignal(time_left)

    if eventType == "modem_message" and port == PORT then
        local data = unserialize(message)
        
        if data then
            local dataID = tonumber(data.id) or data.id

            -- Event 1: Server startet neu -> Status abfragen (kein Ping/Pong)
            if data.event == "initial_startup" then
                modem.broadcast(PORT, serialize({event = "signal_request_state", id = ID}))
            end
            
            -- Event 2: PONG erhalten -> Verbindung ist aktiv!
            if data.event == "pong" and (dataID == ID) then
                last_server_contact = now
            end

            -- Event 3: Signal Update (Stellungsbefehl oder Antwort auf Request)
            if data.event == "signal_update" and (dataID == ID) then
                setRedstone(data.state)
                -- Auch ein Signal Update beweist eine aktive Verbindung
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