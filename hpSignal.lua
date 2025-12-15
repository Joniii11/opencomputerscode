local redstone = component.proxy(component.list("redstone")())
local modem = component.proxy(component.list("modem")())
local eeprom = component.proxy(component.list("eeprom")())

local PORT = 1234
local ID = 2 -- ID des Signals anpassen!

-- SIDES
local SIDE_MAIN = 1 -- Oben (Hauptsignal)
local SIDE_DIST = 0 -- Unten (Vorsignal)

-- COLORS (OpenComputers Color Indices)
local C_WHITE  = 0
local C_YELLOW = 4
local C_GREEN  = 13
local C_RED    = 14

-- TIMINGS
local PING_INTERVAL = 10 
local TIMEOUT_LIMIT = 15 
local ANIMATION_DELAY = 0.25 -- Zeit, die das Signal "dunkel" ist beim Umschalten

-- MODEM SETUP
if modem.isWireless() then modem.setStrength(400) end
modem.open(PORT)

-- STARTUP
computer.beep(1000, 0.5)

-- Speichert den aktuellen Ziel-Zustand
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

-- HELPER: Output setzen (ohne Animation)
-- Schreibt die Farbwerte direkt auf die Leitung
local function writeToSide(side, stellung)
    local outputs = {}
    for i=0,15 do outputs[i] = 0 end

    -- Mapping Logic
    -- side 1 (Main): hp0(red), hp1(green), hp2(yellow), sh1(white)
    -- side 0 (Dist): vr0(red), vr1(green), vr2(yellow), zs1(white)

    if stellung == "off" then
        -- alles aus
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

-- ANIMATION FUNCTION
-- Schaltet erst aus, wartet kurz, schaltet dann an
local function updateSignalsAnimated(new_main, new_dist)
    -- 1. Alles, was sich ändert, dunkel schalten
    local changed = false
    
    if new_main ~= current_state.main then
        writeToSide(SIDE_MAIN, "off")
        changed = true
    end
    
    if new_dist ~= current_state.dist then
        writeToSide(SIDE_DIST, "off")
        changed = true
    end

    -- 2. Kurze Dunkelphase (nur warten, wenn sich was geändert hat)
    if changed then
        computer.pullSignal(ANIMATION_DELAY)
    end

    -- 3. Neue Werte setzen
    writeToSide(SIDE_MAIN, new_main)
    writeToSide(SIDE_DIST, new_dist)

    -- Status merken
    current_state.main = new_main
    current_state.dist = new_dist
end

-- Initiale Abfrage
writeToSide(SIDE_MAIN, "hp0") -- Sicherer Startzustand
writeToSide(SIDE_MAIN, "hp1")
writeToSide(SIDE_MAIN, "hp2")
modem.broadcast(PORT, serialize({event = "signal_request_state", id = ID}))
writeToSide(SIDE_MAIN, "sh1")
writeToSide(SIDE_DIST, "vr0")
writeToSide(SIDE_DIST, "vr1")
writeToSide(SIDE_DIST, "vr2")
writeToSide(SIDE_DIST, "zs1")

writeToSide(SIDE_MAIN, "hp0")
writeToSide(SIDE_DIST, "off")

local last_server_contact = computer.uptime()
local next_ping = 0

-- MAIN LOOP
while true do
    local now = computer.uptime()
    
    -- PING
    if now >= next_ping then
        modem.broadcast(PORT, serialize({event = "ping", id = ID}))
        next_ping = now + PING_INTERVAL
    end

    -- TIMEOUT CHECK (Failsafe -> Dunkel)
    if (now - last_server_contact) > TIMEOUT_LIMIT then
        writeToSide(SIDE_MAIN, "off")
        writeToSide(SIDE_DIST, "off")
        -- Status zurücksetzen, damit beim Wiederverbinden das Licht wieder angeht
        current_state.main = "off"
        current_state.dist = "off"
    end

    -- SLEEP TIME
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

            -- B. Pong (Keep-Alive)
            if data.event == "pong" and (dataID == ID) then
                last_server_contact = now
            end

            -- C. Signal Update
            if data.event == "signal_update" and (dataID == ID) then
                last_server_contact = now 
                
                -- Neue Werte auslesen (Fallback auf aktuelle Werte, falls nil)
                local target_main = data.main or current_state.main
                local target_dist = data.dist or current_state.dist
                
                -- Animation ausführen
                updateSignalsAnimated(target_main, target_dist)

                -- Bestätigung senden (ACK)
                modem.broadcast(PORT, serialize({
                    event = "signal_update_ack",
                    id = ID,
                    main = target_main,
                    dist = target_dist
                }))
            end
        end
    end
end