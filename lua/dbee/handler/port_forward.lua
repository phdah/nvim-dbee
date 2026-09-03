local utils = require("dbee.utils")

-- how long to wait for more current_connection_changed events before actually
-- switching - collapses bursts of events (e.g. all connections becoming
-- "current" one after another while a source loads at startup) into a single
-- switch to whatever the last event in the burst asked for.
local DEBOUNCE_MS = 300

-- PortForward manages a single background shell job used to keep a
-- connection's port-forward (e.g. "kubectl port-forward ...") running while
-- that connection is the active one. Only one job ever runs at a time, which
-- is what allows multiple connections to reuse the same local port.
---@class PortForward
---@field private job vim.SystemObj?
---@field private active_id connection_id?
---@field private cmd string?
---@field private debounce_timer uv.uv_timer_t?
local PortForward = {}

---@return PortForward
function PortForward:new()
  local o = {
    job = nil,
    active_id = nil,
    cmd = nil,
    debounce_timer = nil,
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Stop the currently running job, if any.
function PortForward:stop()
  local job = self.job
  local conn_id = self.active_id
  self.job = nil
  self.active_id = nil
  self.cmd = nil

  if not job then
    return
  end

  utils.log("info", string.format("stopping port-forward for connection %q", conn_id), "port_forward")

  -- the job is spawned detached (its own process group, pgid == pid), so
  -- kill the whole group with a negative pid - a plain job:kill() only
  -- signals the top-level "sh -c ..." wrapper and can leave e.g. a spawned
  -- "kubectl" child process running and still holding the forwarded port.
  pcall(vim.uv.kill, -job.pid, 15) -- SIGTERM
  pcall(job.wait, job, 1000)
  pcall(vim.uv.kill, -job.pid, 9) -- SIGKILL, in case anything is still around
end

---@param conn_id connection_id
---@param cmd string shell command to run in the background
local function run(self, conn_id, cmd)
  self.active_id = conn_id
  self.cmd = cmd

  utils.log("info", string.format("starting port-forward for connection %q: %s", conn_id, cmd), "port_forward")

  self.job = vim.system({ "sh", "-c", cmd }, {
    detach = true, -- own process group, so it can be killed as a whole (see stop())
    text = true,
    stderr = function(_, data)
      if not data then
        return
      end
      vim.schedule(function()
        utils.log("error", vim.trim(data), "port_forward")
      end)
    end,
  }, function(obj)
    -- only report exits of the job that is still supposed to be active -
    -- an expected stop() already cleared active_id/job before killing it.
    if self.active_id ~= conn_id then
      return
    end
    self.job = nil
    self.active_id = nil
    self.cmd = nil
    vim.schedule(function()
      utils.log("warn", string.format("port-forward exited unexpectedly (code %d)", obj.code), "port_forward")
    end)
  end)
end

-- Stop whatever is currently running (if anything) and start the port-forward
-- for the given connection, unless it's already the active one or it has no
-- port_forward command configured.
---@param conn_id connection_id
---@param cmd string? shell command to run in the background
function PortForward:switch(conn_id, cmd)
  if self.debounce_timer then
    self.debounce_timer:stop()
    self.debounce_timer = nil
  end

  if self.active_id == conn_id then
    return
  end

  self:stop()

  if not cmd or cmd == "" then
    return
  end

  run(self, conn_id, cmd)
end

-- Same as switch(), but debounced by DEBOUNCE_MS: rapid-fire calls (e.g. a
-- source creating many connections at startup, each briefly becoming
-- "current") collapse into a single switch to whatever the last call within
-- the debounce window asked for.
---@param conn_id connection_id
---@param cmd string?
function PortForward:switch_debounced(conn_id, cmd)
  if self.debounce_timer then
    self.debounce_timer:stop()
  end

  self.debounce_timer = vim.defer_fn(function()
    self.debounce_timer = nil
    self:switch(conn_id, cmd)
  end, DEBOUNCE_MS)
end

-- Current status, or nil if nothing is running.
---@return { conn_id: connection_id, cmd: string, pid: integer }?
function PortForward:status()
  if not self.job or not self.active_id then
    return nil
  end

  return {
    conn_id = self.active_id,
    cmd = self.cmd,
    pid = self.job.pid,
  }
end

return PortForward
