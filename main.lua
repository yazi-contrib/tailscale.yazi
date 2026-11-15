--- Taildrop in Yazi: send the selected files, or the hovered one, to a device of your tailnet, and take
--- the files that other devices sent.
---
--- Keys, in keymap.toml:
---
---   { on = ["T", "s"], run = "plugin tailscale send",    desc = "Send with Taildrop" }
---   { on = ["T", "r"], run = "plugin tailscale receive", desc = "Receive with Taildrop" }
---
--- Optional setup, in init.lua:
---
---   require("tailscale"):setup {
---     receive_dir = "~/Downloads",   -- where `receive` puts the files, the folder of Yazi when it is not set
---     zip_folders = true,            -- a folder is sent as a zip, the only way Taildrop takes one
---   }

local M = {}

-- the options of setup, for the code that runs async (see get_options): async code has a Lua state of
-- its own, where `setup` has not run
local get_options = ya.sync(function(state)
	return state.options or {}
end)

-- the selected files, or the hovered one when none is selected, and the folder that Yazi shows
local get_selection = ya.sync(function()
	local urls = {}
	-- an entry is a file in the latest Yazi, which has the url, and was a url before
	for _, item in pairs(cx.active.selected) do
		urls[#urls + 1] = tostring(item.url or item)
	end
	if #urls == 0 then
		local hovered = cx.active.current.hovered
		if hovered then
			urls[1] = tostring(hovered.url)
		end
	end
	return urls
end)

local get_cwd = ya.sync(function()
	return tostring(cx.active.current.cwd)
end)

function M:setup(opts)
	self.options = opts or {}
end

local notify = function(level, content)
	ya.notify { title = "tailscale.yazi", content = content, timeout = 6, level = level }
end

local expand_home = function(path)
	local home = os.getenv("HOME") or ""
	return (path:gsub("^~", home))
end

local output_of = function(command)
	local output = command:stdout(Command.PIPED):stderr(Command.PIPED):output()
	return output
end

-- the devices that are online, the others cannot take a file: a name, a system and an address
local PEERS = '.Peer[]? | select(.Online) | "\\(.DNSName | split(".")[0])\\t\\(.OS)\\t\\(.TailscaleIPs[0])"'

local peers = function()
	local output = output_of(Command("sh"):arg { "-c", 'tailscale status --json | jq -r "$1"', "sh", PEERS })
	if not output or not output.status.success then
		return nil, output and output.stderr or "`tailscale` or `jq` was not found"
	end
	local list = {}
	for line in output.stdout:gmatch("[^\n]+") do
		local name, os_name, address = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)$")
		if name and address and address ~= "" and address ~= "null" then
			list[#list + 1] = { name = name, os = os_name, address = address }
		end
	end
	return list
end

-- one device, chosen in the menu of Yazi: a key for each, 1 to 9 and a to z
local KEYS = "123456789abcdefghijklmnopqrstuvwxyz"

local choose = function(list)
	local cands = {}
	for i, peer in ipairs(list) do
		if i > #KEYS then
			break
		end
		cands[#cands + 1] = { on = KEYS:sub(i, i), desc = string.format("%s (%s)", peer.name, peer.os) }
	end
	local index = ya.which { cands = cands }
	return index and list[index] or nil
end

local is_dir = function(path)
	local cha = fs.cha(Url(path))
	return cha and cha.is_dir
end

local send = function(options)
	local files = get_selection()
	if #files == 0 then
		return notify("warn", "Nothing is selected or hovered")
	end

	local list, err = peers()
	if not list then
		return notify("error", "Cannot list the devices: " .. tostring(err))
	end
	if #list == 0 then
		return notify("warn", "No device is online: the devices of the tailnet that are on can take a file")
	end

	local peer = choose(list)
	if not peer then
		return -- cancelled
	end

	local tmp
	local sent, failed = 0, {}
	for _, file in ipairs(files) do
		local target = file
		local base = file:match("([^/]+)/*$") or file
		if is_dir(file) then
			if options.zip_folders == false then
				failed[#failed + 1] = base .. ": a folder"
				goto continue
			end
			if not tmp then
				local made = output_of(Command("mktemp"):arg("-d"))
				tmp = made and made.stdout:gsub("%s+$", "")
			end
			target = (tmp or "/tmp") .. "/" .. base .. ".zip"
			local parent = file:gsub("/+$", ""):match("^(.*)/[^/]*$") or "."
			local zipped = output_of(Command("zip"):cwd(parent == "" and "/" or parent):arg { "-qr", target, base })
			if not zipped or not zipped.status.success then
				failed[#failed + 1] = base .. ": the folder could not be zipped, is `zip` installed?"
				goto continue
			end
		end
		do
			local result = output_of(Command("tailscale"):arg { "file", "cp", target, peer.address .. ":" })
			if result and result.status.success then
				sent = sent + 1
			else
				failed[#failed + 1] = base .. ": " .. (result and result.stderr:gsub("%s+", " ") or "`tailscale` was not found")
			end
		end
		::continue::
	end
	if tmp then
		output_of(Command("rm"):arg { "-rf", tmp })
	end

	if sent > 0 then
		notify("info", string.format("Sent %d file%s to %s", sent, sent == 1 and "" or "s", peer.name))
	end
	if #failed > 0 then
		notify("error", "Not sent to " .. peer.name .. ": " .. table.concat(failed, "; "))
	end
end

-- the number of entries of a folder, to tell how many files came
local count_entries = function(dir)
	local listing = output_of(Command("ls"):arg { "-1A", dir })
	if not listing then
		return 0
	end
	local count = 0
	for _ in listing.stdout:gmatch("[^\n]+") do
		count = count + 1
	end
	return count
end

local receive = function(options)
	local dir = options.receive_dir and expand_home(options.receive_dir) or get_cwd()
	local before = count_entries(dir)
	local result = output_of(Command("tailscale"):arg { "file", "get", "--conflict=rename", dir })
	if not result then
		return notify("error", "`tailscale` was not found")
	elseif not result.status.success then
		return notify("error", "Taildrop: " .. result.stderr:gsub("%s+", " "))
	end
	local came = count_entries(dir) - before
	if came > 0 then
		notify("info", string.format("Received %d file%s into %s", came, came == 1 and "" or "s", dir))
	else
		notify("info", "No file is waiting in the Taildrop inbox")
	end
end

function M:entry(job)
	local action = job.args[1]
	local options = get_options()
	if action == "send" then
		return send(options)
	elseif action == "receive" then
		return receive(options)
	end
	notify("error", "Use `plugin tailscale send` or `plugin tailscale receive`")
end

return M
