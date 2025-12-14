local redstone, modem, eeprom = component.proxy(component.list("redstone")()), component.proxy(component.list("modem")()),component.proxy(component.list("eeprom")())
local PORT = 1234
local colorMap = {} -- id (as string) -> color index (1-based for colorBits)
local colorBits = { "white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink", "gray", "lightGray", "cyan", "purple", "blue", "brown", "green", "red", "black" }
local REDSTONE_SIDE = 0

local ID = 2

modem.open(PORT)

local function serialize(tbl)
  local function ser(val)
    if type(val) == "number" then return tostring(val)
    elseif type(val) == "boolean" then return val and "true" or "false"
    elseif type(val) == "string" then 
      return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
    elseif type(val) == "table" then
      local items = {}
      for k, v in pairs(val) do
        items[#items + 1] = "[" .. ser(k) .. "]=" .. ser(v)
      end
      return "{" .. table.concat(items, ",") .. "}"
    else return "nil" end
  end
  return ser(tbl)
end

local function unserialize(str)
  local f = load("return " .. str)
  if not f then return nil end
  return f()
end

local function setRedstone(stellung)
    if stellung == "hp0" then 
        redstone.setBundledOutput(REDSTONE_SIDE, {[14] = 255})
    elseif stellung == "sh1" then
        redstone.setBundledOutput(REDSTONE_SIDE, {[0] = 255})
    else
        redstone.setBundledOutput(REDSTONE_SIDE, {[15] = 255})
    end
end

while true do
    local eventType, _, from, port, _, message = computer.pullSignal()

    if eventType ~= "modem_message" then goto continue end
    if port ~= PORT then goto continue end

    local data = unserialize(message)
    if not data then goto continue end

    if data.event == "signal_update" and data.id == ID then
        setRedstone(data.state)

        modem.broadcast(9999, "Set signal " .. data.id .. " to state " .. data.state)

        modem.broadcast(PORT, serialize({
            event = "signal_update_ack",
            id = data.id,
            state = data.state
        }))
    end

    ::continue::
end
