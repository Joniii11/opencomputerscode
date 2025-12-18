local modem = component.proxy(component.list("modem")())

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

for uuid, data in pairs(SENSORS) do
    local proxy = component.proxy(uuid)
    if proxy then
        data.proxy = proxy -- Wir speichern den Proxy direkt in der Tabelle!
        computer.beep(2000, 0.5)
    end
end

computer.beep(1000, 0.5)

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
  }))
end

-- === MAIN LOOP ===
while true do
  -- Wir warten max 0.05s (1 Tick). Wenn ein Signal kommt, wacht er SOFORT auf.
  -- Das ist extrem schnell und verpasst keine Züge.
  local signalType, _, sender, port, _, message = computer.pullSignal()

  -- 1. ZUG BEWEGUNG (IR Event)
    if signalType == "ir_train_overhead" then
        -- sender ist die UUID des Sensors
        local sensor_data = SENSORS[sender]

        if sensor_data and sensor_data.proxy then
           local success, info = pcall(sensor_data.proxy.info)
        
           if success and info and info.direction then
               local train_dir = string.lower(info.direction)

               if train_dir == sensor_data.dir_in then
                  axle_count = axle_count + 1
                  sendUpdate("gfma_update")

               elseif train_dir == sensor_data.dir_out then
                  axle_count = axle_count - 1
                  sendUpdate("gfma_update")
               end

               if axle_count < 0 then axle_count = 0 end
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