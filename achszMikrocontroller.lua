local component = require("component")
local computer = require("computer")

-- Proxies direkt laden (Spart RAM und ist schneller)
local modem = component.proxy(component.list("modem")())
local eeprom = component.proxy(component.list("eeprom")())

-- === KONFIGURATION ===
local PORT = 12345 -- Port für GFA Kommunikation

local MY_ID = 5

local SENSORS = {
  ["b91ba06e-fe50-4e3c-8219-ec5d6c920e40"] = { dir_in = "north", dir_out = "south" },
  ["b6395384-235f-4937-9959-e424940f8756"] = { dir_in = "north", dir_out = "south" }
}

-- STATE
local axle_count = 0
local is_occupied = false

-- === SETUP ===
if modem.isWireless() then
  modem.setStrength(400)
end
modem.open(PORT)
computer.beep(1000, 0.5) -- Startup Beep

-- === HELPER FUNCTIONS (Vom Example übernommen) ===
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

-- Funktion zum Senden des Status
local function sendUpdate(trigger_event)
  is_occupied = (axle_count > 0)
  
  modem.broadcast(PORT, serialize({
    event = trigger_event, -- Z.B. "GFA_UPDATE" oder "GFA_STATUS_REPORT"
    id = MY_ID,
    occupied = is_occupied,
    count = axle_count
  }))
end

-- === MAIN LOOP ===
while true do
  -- Wir warten max 0.05s (1 Tick). Wenn ein Signal kommt, wacht er SOFORT auf.
  -- Das ist extrem schnell und verpasst keine Züge.
  local signalType, _, sender, port, _, message = computer.pullSignal()

  -- 1. ZUG BEWEGUNG (IR Event)
  if signalType == "ir_train_overhead" then
    -- args: name, address, augmentType, stockUuid (Die Reihenfolge bei pullSignal ist anders als bei event.pull)
    -- Bei computer.pullSignal sind die args ab index 2: address, augmentType, stockUuid
    local sensor_addr = sender -- Bei ir_train_overhead ist der 2. Rückgabewert die Adresse der Komponente
    
    local sensor_config = SENSORS[sensor_addr]

    if sensor_config then
       -- Wir holen den Proxy dynamisch, um .info() zu machen
       local success, detector = pcall(component.proxy, sensor_addr)
       
       if success and detector then
          local info = detector.info()
          -- Direction prüfen (und auf lower case zwingen sicherheitshalber)
          if info and info.direction then
             local train_dir = string.lower(info.direction)

             if train_dir == sensor_config.dir_in then
                -- REIN
                axle_count = axle_count + 1
                sendUpdate("gfma_update")
                
             elseif train_dir == sensor_config.dir_out then
                -- RAUS
                axle_count = axle_count - 1
                sendUpdate("gfma_update")
             end

             -- Safety: Nicht unter 0 zählen
             if axle_count < 0 then axle_count = 0 end
          end
       end
    end

  -- 2. NETZWERK NACHRICHTEN
  elseif signalType == "modem_message" and port == PORT then
    local data = unserialize(message)
    
    if data then
      -- SERVER STARTET NEU -> Wir melden unseren Stand!
      if data.event == "initial_startup" then
         -- Hier antworten wir direkt mit dem aktuellen Status
         sendUpdate("gfma_update")
         computer.beep(2000, 0.2) -- Kleiner Bestätigungs-Beep
      
      -- RESET BEFEHL (Falls man manuell eingreifen muss)
      elseif data.event == "azgrt" and (data.id == MY_ID or data.id == "all") then
         axle_count = 0
         sendUpdate("gfma_update")
         computer.beep(500, 0.5)
      end
    end
  end
end