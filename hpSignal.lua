local redstone = component.proxy(component.list("redstone")())
local modem = component.proxy(component.list("modem")())
local eeprom = component.proxy(component.list("eeprom")())

local PORT = 1234
local ID = 5 
local CODE_VERSION = "v5" -- This MUST appear in your logs

-- SIDES
local SIDE_MAIN = 1 -- Oben
local SIDE_DIST = 0 -- Unten

-- COLORS
local C_WHITE  = 0
local C_YELLOW = 4
local C_GREEN  = 13
local C_RED    = 14

-- TIMINGS
local PING_INTERVAL = 10 
local TIMEOUT_LIMIT = 15 
local ANIMATION_DELAY = 0.25 

local event_queue = {}

if modem.isWireless() then modem.setStrength(400) end
modem.open(PORT)

computer.beep(1000, 0.5)

-- STATE MEMORY
local current_state = {
    main = "hp0",
    dist = "off"
}

-- HELPER: Serialization
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

-- HELPER: Smart Sleep (Captures messages during animation)
local function smart_sleep(duration)
    local deadline = computer.uptime() + duration
    while true do
        local now = computer.uptime()
        if now >= deadline then break end
        
        local time_left = deadline - now
        local signal = table.pack(computer.pullSignal(time_left))
        
        if signal.n > 0 and signal[1] ~= nil then
            table.insert(event_queue, signal)
        end
    end
end

-- HELPER: Get Next Event (Queue Aware)
local function get_next_event(timeout)
    if #event_queue > 0 then
        return table.unpack(table.remove(event_queue, 1))
    end
    return computer.pullSignal(timeout)
end

-- HELPER: Write Output
local function writeToSide(side, stellung)
    local outputs = {}
    for i=0,15 do outputs[i] = 0 end

    if stellung == "off" then
        -- all 0
    elseif stellung == "hp0" or stellung == "vr0" then
        outputs[C_RED] = 255
    elseif stellung == "hp1" or stellung == "vr1" then
        outputs[C_GREEN] = 255
    elseif stellung == "hp2" or stellung == "vr2" then
        outputs[C_YELLOW] = 255
    elseif stellung == "sh1" or stellung == "zs1" or stellung == "zs7" or stellung == "zs8" then
        outputs[C_WHITE] = 255
    end

    redstone.setBundledOutput(side, outputs)
end

-- ANIMATION LOGIC
local function updateSignalsAnimated(new_main, new_dist)
    local changed = false
    
    if new_main ~= current_state.main then
        writeToSide(SIDE_MAIN, "off")
        changed = true
    end
    
    if new_dist ~= current_state.dist then
        writeToSide(SIDE_DIST, "off")
        changed = true
    end

    if changed then
        smart_sleep(ANIMATION_DELAY)
    end

    writeToSide(SIDE_MAIN, new_main)
    writeToSide(SIDE_DIST, new_dist)

    current_state.main = new_main
    current_state.dist = new_dist
end

-- VISUAL TEST (Reboot confirmation)
writeToSide(SIDE_MAIN, "sh1")
writeToSide(SIDE_DIST, "zs1")
computer.pullSignal(0.5)
writeToSide(SIDE_MAIN, "hp0")
writeToSide(SIDE_DIST, "vr0")
computer.pullSignal(0.5)
writeToSide(SIDE_MAIN, "off")
writeToSide(SIDE_DIST, "off")

modem.broadcast(PORT, serialize({event = "signal_request_state", id = ID}))

-- MAIN LOOP
local last_server_contact = computer.uptime()
local next_ping = 0

while true do
    local now = computer.uptime()
    
    -- PING
    if now >= next_ping then
        modem.broadcast(PORT, serialize({event = "ping", id = ID}))
        next_ping = now + PING_INTERVAL
    end

    -- WATCHDOG
    if (now - last_server_contact) > TIMEOUT_LIMIT then
        writeToSide(SIDE_MAIN, "off")
        writeToSide(SIDE_DIST, "off")
        current_state.main = "off"
        current_state.dist = "off"
    end

    -- WAIT FOR SIGNAL
    local time_left = next_ping - now
    if time_left < 0.1 then time_left = 0.1 end

    local eventType, _, _, port, _, message = get_next_event(time_left)

    if eventType == "modem_message" and port == PORT then
        local data = unserialize(message)
        
        if data then
            local dataID = tonumber(data.id) or data.id

            -- REBOOT COMMAND
            if data.event == "initial_startup" then
                computer.shutdown(true) 
            end

            -- PONG
            if data.event == "pong" and (dataID == ID) then
                last_server_contact = now
            end

            -- SIGNAL UPDATE
            if data.event == "signal_update" and (dataID == ID) then
                last_server_contact = now 
                
                local target_main = data.state or current_state.main
                local target_dist = data.dist or current_state.dist
                
                -- Force vr0 if main is hp0
                if target_main == "hp0" then target_dist = "off" end

                -- Safety check for nil
                target_dist = target_dist or "off"

                updateSignalsAnimated(target_main, target_dist)

                modem.broadcast(PORT, serialize({
                    event = "signal_update_ack",
                    id = ID,
                    ver = CODE_VERSION, -- VERSION CHECK
                    state = target_main,
                    dist = target_dist
                }))
            end
        end
    end
end