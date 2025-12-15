local redstone = component.proxy(component.list("redstone")())
local modem = component.proxy(component.list("modem")())
local eeprom = component.proxy(component.list("eeprom")())

local PORT = 1234
local ID = 5 

-- SIDES
local SIDE_MAIN = 1 -- Oben (Hauptsignal)
local SIDE_DIST = 0 -- Unten (Vorsignal)

-- COLORS
local C_WHITE  = 0
local C_YELLOW = 4
local C_GREEN  = 13
local C_RED    = 14

-- TIMINGS
local PING_INTERVAL = 10 
local TIMEOUT_LIMIT = 15 
local ANIMATION_DELAY = 0.25 

-- MODEM SETUP
if modem.isWireless() then modem.setStrength(400) end
modem.open(PORT)

-- STARTUP BEEP
computer.beep(1000, 0.5)

-- STATE MEMORY
local current_state = {
    main = "hp0",
    dist = "vr0"
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
    
    -- Check if Main changed
    if new_main ~= current_state.main then
        writeToSide(SIDE_MAIN, "off")
        changed = true
    end
    
    -- Check if Distant changed
    if new_dist ~= current_state.dist then
        writeToSide(SIDE_DIST, "off")
        changed = true
    end

    -- Wait briefly if anything turned off (Animation)
    if changed then
        computer.pullSignal(ANIMATION_DELAY)
    end

    -- Set new values
    writeToSide(SIDE_MAIN, new_main)
    writeToSide(SIDE_DIST, new_dist)

    -- Update Memory
    current_state.main = new_main
    current_state.dist = new_dist
end

-- ============================================================================
-- LAMP TEST (Visual Startup)
-- ============================================================================
-- Shows White (Sh1/Zs1)
writeToSide(SIDE_MAIN, "sh1")
writeToSide(SIDE_DIST, "zs1")
computer.pullSignal(0.5)

-- Shows Red (Hp0/Vr0)
writeToSide(SIDE_MAIN, "hp0")
writeToSide(SIDE_DIST, "vr0")
computer.pullSignal(0.5)

-- Shows Off (Waiting for server)
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

    -- 2. TIMEOUT WATCHDOG (Failsafe)
    if (now - last_server_contact) > TIMEOUT_LIMIT then
        writeToSide(SIDE_MAIN, "off")
        writeToSide(SIDE_DIST, "off")
        current_state.main = "off"
        current_state.dist = "off"
    end

    -- 3. WAIT FOR SIGNAL
    local time_left = next_ping - now
    if time_left < 0.1 then time_left = 0.1 end

    local eventType, _, _, port, _, message = computer.pullSignal(time_left)

    if eventType == "modem_message" and port == PORT then
        local data = unserialize(message)
        
        if data then
            local dataID = tonumber(data.id) or data.id

            -- A. Server Restart
            if data.event == "initial_startup" then
                modem.broadcast(PORT, serialize({event = "signal_request_state", id = ID}))
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
                
                -- Execute
                updateSignalsAnimated(target_main, target_dist)

                -- Send ACK with the COMPLETE state (Combined)
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