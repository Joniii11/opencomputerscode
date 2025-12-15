local redstone = component.proxy(component.list("redstone")())
local modem = component.proxy(component.list("modem")())
local eeprom = component.proxy(component.list("eeprom")())

local PORT = 1234
local ID = 5 

-- SIDES
local SIDE_MAIN = 1 
local SIDE_DIST = 0 

-- COLORS
local C_WHITE  = 0
local C_YELLOW = 4
local C_GREEN  = 13
local C_RED    = 14

-- TIMINGS
local PING_INTERVAL = 10 
local TIMEOUT_LIMIT = 15 
local ANIMATION_DELAY = 0.25 

-- EVENT BUFFER (To fix lost packets during animation)
local event_queue = {}

-- MODEM SETUP
if modem.isWireless() then modem.setStrength(400) end
modem.open(PORT)

-- STARTUP BEEP
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

-- HELPER: Smart Sleep (Prevents ignoring messages during animation)
local function smart_sleep(duration)
    local deadline = computer.uptime() + duration
    while true do
        local now = computer.uptime()
        if now >= deadline then break end
        
        local time_left = deadline - now
        -- Pull signal with remaining time
        local signal = table.pack(computer.pullSignal(time_left))
        
        -- If we caught a signal (not nil), save it for later!
        if signal.n > 0 and signal[1] ~= nil then
            table.insert(event_queue, signal)
        end
    end
end

-- HELPER: Get Next Event (Checks queue first, then pulls new)
local function get_next_event(timeout)
    if #event_queue > 0 then
        -- Return the oldest saved event
        return table.unpack(table.remove(event_queue, 1))
    end
    -- If empty, wait for new one
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

    -- Use smart_sleep so we don't lose messages during the blackout
    if changed then
        smart_sleep(ANIMATION_DELAY)
    end

    writeToSide(SIDE_MAIN, new_main)
    writeToSide(SIDE_DIST, new_dist)

    current_state.main = new_main
    current_state.dist = new_dist
end

-- ============================================================================
-- LAMP TEST (Visual Startup)
-- ============================================================================
writeToSide(SIDE_MAIN, "sh1")
writeToSide(SIDE_DIST, "zs1")
computer.pullSignal(0.5)

writeToSide(SIDE_MAIN, "hp0")
writeToSide(SIDE_DIST, "vr0")
computer.pullSignal(0.5)

writeToSide(SIDE_MAIN, "off")
writeToSide(SIDE_DIST, "off")

-- Request actual state from server
modem.broadcast(PORT, serialize({event = "signal_request_state", id = ID}))

-- ============================================================================
-- MAIN LOOP
-- ============================================================================
local last_server_contact = computer.uptime()
local next_ping = 0

while true do
    local now = computer.uptime()
    
    -- 1. PING SERVER
    if now >= next_ping then
        modem.broadcast(PORT, serialize({event = "ping", id = ID}))
        next_ping = now + PING_INTERVAL
    end

    -- 2. TIMEOUT WATCHDOG
    if (now - last_server_contact) > TIMEOUT_LIMIT then
        writeToSide(SIDE_MAIN, "off")
        writeToSide(SIDE_DIST, "off")
        current_state.main = "off"
        current_state.dist = "off"
    end

    -- 3. WAIT FOR SIGNAL (Using queue-aware function)
    local time_left = next_ping - now
    if time_left < 0.1 then time_left = 0.1 end

    -- REPLACED computer.pullSignal with get_next_event
    local eventType, _, _, port, _, message = get_next_event(time_left)

    if eventType == "modem_message" and port == PORT then
        local data = unserialize(message)
        
        if data then
            local dataID = tonumber(data.id) or data.id

            -- A. Server Restart -> REBOOT MICROCONTROLLER
            if data.event == "initial_startup" then
                -- true = reboot
                computer.shutdown(true) 
            end

            -- B. Pong
            if data.event == "pong" and (dataID == ID) then
                last_server_contact = now
            end

            -- C. Signal Update
            if data.event == "signal_update" and (dataID == ID) then
                last_server_contact = now 
                
                local target_main = data.state or current_state.main
                local target_dist = data.dist or current_state.dist
                
                -- Safety Logic: Hp0 forces Vr-Off
                if target_main == "hp0" then
                    target_dist = "off"
                end

                -- Execute (captures incoming messages during sleep)
                updateSignalsAnimated(target_main, target_dist)

                -- Send ACK
                modem.broadcast(PORT, serialize({
                    event = "signal_update_ack",
                    id = ID,
                    state = target_main,
                    dist = target_dist
                }))
            end
        end
    end
end