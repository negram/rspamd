--[[
Copyright (c) 2016, Andrew Lewis <nerf@judo.za.org>
Copyright (c) 2016, Vsevolod Stakhov <vsevolod@highsecure.ru>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
]]--

-- A plugin that pushes metadata (or whole messages) to external services

local redis_params
local rspamd_http = require "rspamd_http"
local rspamd_tcp = require "rspamd_tcp"
local rspamd_util = require "rspamd_util"
local rspamd_logger = require "rspamd_logger"
local ucl = require "ucl"
local E = {}
local N = 'metadata_exporter'

local settings = {
  pusher_enabled = {},
  pusher_format = {},
  pusher_select = {},
  mime_type = 'text/plain',
  defer = false,
  mail_from = '',
  mail_to = 'postmaster@localhost',
  helo = 'rspamd',
  email_template = [[From: "Rspamd" <$mail_from>
To: <$mail_to>
Subject: Spam alert
Date: $date
MIME-Version: 1.0
Message-ID: <$our_message_id>
Content-type: text/plain; charset=utf-8
Content-Transfer-Encoding: 8bit

Authenticated username: $user
IP: $ip
Queue ID: $qid
SMTP FROM: $from
SMTP RCPT: $rcpt
MIME From: $header_from
MIME To: $header_to
MIME Date: $header_date
Subject: $header_subject
Message-ID: $message_id
Action: $action
Symbols: $symbols]],
}

local function get_general_metadata(task, flatten, no_content)
  local r = {}
  r.ip = tostring(task:get_from_ip()) or 'unknown'
  r.user = task:get_user() or 'unknown'
  r.qid = task:get_queue_id() or 'unknown'
  r.action = task:get_metric_action('default')
  r.score = task:get_metric_score('default')[1]
  local rcpt = task:get_recipients('smtp')
  if rcpt then
    local l = {}
    for _, a in ipairs(rcpt) do
      table.insert(l, a['addr'])
    end
    if not flatten then
      r.rcpt = l
    else
      r.rcpt = table.concat(l, ', ')
    end
  else
    r.rcpt = 'unknown'
  end
  local from = task:get_from('smtp')
  if ((from or E)[1] or E).addr then
    r.from = from[1].addr
  else
    r.from = 'unknown'
  end
  local syminf = task:get_symbols_all()
  if flatten then
    local l = {}
    for _, sym in ipairs(syminf) do
      local txt
      if sym.options then
        local topt = table.concat(sym.options, ', ')
        txt = sym.name .. '(' .. sym.score .. ')' .. ' [' .. topt .. ']'
      else
        txt = sym.name .. '(' .. sym.score .. ')'
      end
      table.insert(l, txt)
    end
    r.symbols = table.concat(l, '\n\t')
  else
    r.symbols = syminf
  end
  local function process_header(name)
    local hdr = task:get_header_full(name)
    if hdr then
      local l = {}
      for _, h in ipairs(hdr) do
        table.insert(l, h.decoded)
      end
      if not flatten then
        return l
      else
        return table.concat(l, '\n')
      end
    else
      return 'unknown'
    end
  end
  if not no_content then
    r.header_from = process_header('from')
    r.header_to = process_header('to')
    r.header_subject = process_header('subject')
    r.header_date = process_header('date')
    r.message_id = task:get_message_id()
  end
  return r
end

local template_grammar
local function simple_template(tmpl, keys)
  local lpeg = require "lpeg"

  if not template_grammar then
    local var_lit = lpeg.P { lpeg.R("az") + lpeg.R("AZ") + lpeg.R("09") + "_" }
    local var = lpeg.P { (lpeg.P("$") / "") * ((var_lit^1) / keys) }
    local var_braced = lpeg.P { (lpeg.P("${") / "") * ((var_lit^1) / keys) * (lpeg.P("}") / "") }

    template_grammar = lpeg.Cs((var + var_braced + 1)^0)
  end

  return lpeg.match(template_grammar, tmpl)
end

local formatters = {
  default = function(task)
    return task:get_content()
  end,
  email_alert = function(task, rule)
    local meta = get_general_metadata(task, true)
    meta.mail_from = rule.mail_from or settings.mail_from
    meta.mail_to = rule.mail_to or settings.mail_to
    meta.our_message_id = rspamd_util.random_hex(12) .. '@rspamd'
    meta.date = rspamd_util.time_to_string(rspamd_util.get_time())
    return simple_template(rule.email_template or settings.email_template, meta)
  end,
  json = function(task)
    return ucl.to_format(get_general_metadata(task), 'json-compact')
  end
}

local selectors = {
  default = function(task)
    return true
  end,
  is_spam = function(task)
    local action = task:get_metric_action('default')
    return (action == 'reject' or action == 'add header')
  end,
  is_spam_authed = function(task)
    if not task:get_user() then
      return false
    end
    local action = task:get_metric_action('default')
    return (action == 'reject' or action == 'add header')
  end,
  is_reject = function(task)
    local action = task:get_metric_action('default')
    return (action == 'reject')
  end,
  is_reject_authed = function(task)
    if not task:get_user() then
      return false
    end
    local action = task:get_metric_action('default')
    return (action == 'reject')
  end,
}

local function maybe_defer(task, rule)
  if rule.defer then
    rspamd_logger.warnx(task, 'deferring message')
    task:set_metric_action('default', 'soft reject')
  end
end

local pushers = {
  redis_pubsub = function(task, formatted, rule)
    local _,ret,upstream
    local function redis_pub_cb(err)
      if err then
        rspamd_logger.errx(task, 'got error %s when publishing on server %s',
            err, upstream:get_addr())
        return maybe_defer(task, rule)
      end
      return true
    end
    ret,_,upstream = rspamd_redis_make_request(task,
      redis_params, -- connect params
      nil, -- hash key
      true, -- is write
      redis_pub_cb, --callback
      'PUBLISH', -- command
      {rule.channel, formatted} -- arguments
    )
    if not ret then
      rspamd_logger.errx(task, 'error connecting to redis')
      maybe_defer(task, rule)
    end
  end,
  http = function(task, formatted, rule)
    local function http_callback(err, code)
      if err then
        rspamd_logger.errx(task, 'got error %s in http callback', err)
        return maybe_defer(task, rule)
      end
      if code ~= 200 then
        rspamd_logger.errx(task, 'got unexpected http status: %s', code)
        return maybe_defer(task, rule)
      end
      return true
    end
    local hdrs = {}
    if rule.meta_headers then
      local gm = get_general_metadata(task, false, true)
      local pfx = rule.meta_header_prefix or 'X-Rspamd-'
      for k, v in pairs(gm) do
        if type(v) == 'table' then
          hdrs[pfx .. k] = ucl.to_format(v, 'json-compact')
        else
          hdrs[pfx .. k] = v
        end
      end
    end
    rspamd_http.request({
      task=task,
      url=rule.url,
      body=formatted,
      callback=http_callback,
      mime_type=rule.mime_type or settings.mime_type,
      headers=hdrs,
    })
  end,
  send_mail = function(task, formatted, rule)
    local function mail_cb(err, data, conn)
      local function no_error(merr, mdata, wantcode)
        wantcode = wantcode or '2'
        if merr then
          rspamd_logger.errx(task, 'got error in tcp callback: %s', merr)
          if conn then
            conn:close()
          end
          maybe_defer(task, rule)
          return false
        end
        if mdata then
          if type(mdata) ~= 'string' then
            mdata = tostring(mdata)
            end
          if string.sub(mdata, 1, 1) ~= wantcode then
            rspamd_logger.errx(task, 'got bad smtp response: %s', mdata)
            if conn then
              conn:close()
            end
            maybe_defer(task, rule)
            return false
            end
        else
            rspamd_logger.errx(task, 'no data')
          if conn then
            conn:close()
          end
          maybe_defer(task, rule)
          return false
        end
        return true
      end
      local function all_done_cb(merr, mdata)
        if conn then
          conn:close()
        end
        return true
      end
      local function quit_done_cb(merr, mdata)
        conn:add_read(all_done_cb, '\r\n')
      end
      local function quit_cb(merr, mdata)
        if no_error(merr, mdata) then
          conn:add_write(quit_done_cb, 'QUIT\r\n')
        end
      end
      local function pre_quit_cb(merr, mdata)
        if no_error(merr, '2') then
          conn:add_read(quit_cb, '\r\n')
        end
      end
      local function data_done_cb(merr, mdata)
        if no_error(merr, mdata, '3') then
          conn:add_write(pre_quit_cb, {formatted, '\r\n.\r\n'})
        end
      end
      local function data_cb(merr, mdata)
        if no_error(merr, '2') then
          conn:add_read(data_done_cb, '\r\n')
        end
      end
      local function rcpt_done_cb(merr, mdata)
        if no_error(merr, mdata) then
          conn:add_write(data_cb, 'DATA\r\n')
        end
      end
      local function rcpt_cb(merr, mdata)
        if no_error(merr, '2') then
          conn:add_read(rcpt_done_cb, '\r\n')
        end
      end
      local function from_done_cb(merr, mdata)
        if no_error(merr, mdata) then
          conn:add_write(rcpt_cb, {'RCPT TO: <', rule.mail_to, '>\r\n'})
        end
      end
      local function from_cb(merr, mdata)
        if no_error(merr, '2') then
          conn:add_read(from_done_cb, '\r\n')
        end
      end
        local function hello_done_cb(merr, mdata)
        if no_error(merr, mdata) then
          conn:add_write(from_cb, {'MAIL FROM: <', rule.mail_from or settings.mail_from, '>\r\n'})
        end
      end
      local function hello_cb(merr)
        if no_error(merr, '2') then
          conn:add_read(hello_done_cb, '\r\n')
        end
      end
      if no_error(err, data) then
        conn:add_write(hello_cb, {'HELO ', rule.helo or settings.helo, '\r\n'})
      end
    end
    rspamd_tcp.request({
      task = task,
      callback = mail_cb,
      stop_pattern = '\r\n',
      host = rule.smtp,
      port = rule.smtp_port or settings.smtp_port or 25,
    })
  end,
}

local opts = rspamd_config:get_all_opt(N)
if not opts then return end
local process_settings = {
  select = function(val)
    selectors.custom = assert(load(val))()
  end,
  format = function(val)
    formatters.custom = assert(load(val))()
  end,
  push = function(val)
    pushers.custom = assert(load(val))()
  end,
  custom_push = function(val)
    if type(val) == 'table' then
      for k, v in pairs(val) do
        pushers[k] = assert(load(v))()
      end
    end
  end,
  custom_select = function(val)
    if type(val) == 'table' then
      for k, v in pairs(val) do
        selectors[k] = assert(load(v))()
      end
    end
  end,
  custom_format = function(val)
    if type(val) == 'table' then
      for k, v in pairs(val) do
        formatters[k] = assert(load(v))()
      end
    end
  end,
  pusher_enabled = function(val)
    if type(val) == 'string' then
      if pushers[val] then
        settings.pusher_enabled[val] = true
      else
        rspamd_logger.errx(rspamd_config, 'Pusher type: %s is invalid', val)
      end
    elseif type(val) == 'table' then
      for _, v in ipairs(val) do
        if pushers[v] then
          settings.pusher_enabled[v] = true
        else
          rspamd_logger.errx(rspamd_config, 'Pusher type: %s is invalid', val)
        end
      end
    end
  end,
}
for k, v in pairs(opts) do
  local f = process_settings[k]
  if f then
    f(opts[k])
  else
    settings[k] = v
  end
end
if type(settings.rules) ~= 'table' then
  -- Legacy config
  settings.rules = {}
  if not next(settings.pusher_enabled) then
    if pushers.custom then
      rspamd_logger.infox(rspamd_config, 'Custom pusher implicitly enabled')
      settings.pusher_enabled.custom = true
    else
      -- Check legacy options
      if settings.url then
        rspamd_logger.warnx(rspamd_config, 'HTTP pusher implicitly enabled')
        settings.pusher_enabled.http = true
      end
      if settings.channel then
        rspamd_logger.warnx(rspamd_config, 'Redis Pubsub pusher implicitly enabled')
        settings.pusher_enabled.redis_pubsub = true
      end
      if settings.smtp and settings.mail_to then
        rspamd_logger.warnx(rspamd_config, 'SMTP pusher implicitly enabled')
        settings.pusher_enabled.send_mail = true
      end
    end
  end
  if not next(settings.pusher_enabled) then
    rspamd_logger.errx(rspamd_config, 'No push backend enabled')
    return
  end
  if settings.formatter then
    settings.format = formatters[settings.formatter]
    if not settings.format then
      rspamd_logger.errx(rspamd_config, 'No such formatter: %s', settings.formatter)
      return
    end
  end
  if settings.selector then
    settings.select = selectors[settings.selector]
    if not settings.select then
      rspamd_logger.errx(rspamd_config, 'No such selector: %s', settings.selector)
      return
    end
  end
  for k in pairs(settings.pusher_enabled) do
    local formatter = settings.pusher_format[k]
    local selector = settings.pusher_select[k]
    if not formatter then
      settings.pusher_format[k] = settings.formatter or 'default'
      rspamd_logger.infox(rspamd_config, 'Using default formatter for %s pusher', k)
    else
      if not formatters[formatter] then
        rspamd_logger.errx(rspamd_config, 'No such formatter: %s - disabling %s', formatter, k)
        settings.pusher_enabled.k = nil
      end
    end
    if not selector then
      settings.pusher_select[k] = settings.selector or 'default'
      rspamd_logger.infox(rspamd_config, 'Using default selector for %s pusher', k)
    else
      if not selectors[selector] then
        rspamd_logger.errx(rspamd_config, 'No such selector: %s - disabling %s', selector, k)
        settings.pusher_enabled.k = nil
      end
    end
  end
  if settings.pusher_enabled.redis_pubsub then
    redis_params = rspamd_parse_redis_server(N)
    if not redis_params then
      rspamd_logger.errx(rspamd_config, 'No redis servers are specified')
      settings.pusher_enabled.redis_pubsub = nil
    else
      local r = {}
      r.backend = 'redis_pubsub'
      r.channel = settings.channel
      r.defer = settings.defer
      r.selector = settings.pusher_select.redis_pubsub
      r.formatter = settings.pusher_format.redis_pubsub
      settings.rules[r.backend:upper()] = r
    end
  end
  if settings.pusher_enabled.http then
    if not settings.url then
      rspamd_logger.errx(rspamd_config, 'No URL is specified')
      settings.pusher_enabled.http = nil
    else
      local r = {}
      r.backend = 'http'
      r.url = settings.url
      r.mime_type = settings.mime_type
      r.defer = settings.defer
      r.selector = settings.pusher_select.http
      r.formatter = settings.pusher_format.http
      settings.rules[r.backend:upper()] = r
    end
  end
  if settings.pusher_enabled.send_mail then
    if not (settings.mail_to and settings.smtp) then
      rspamd_logger.errx(rspamd_config, 'No mail_to and/or smtp setting is specified')
      settings.pusher_enabled.send_mail = nil
    else
      local r = {}
      r.backend = 'send_mail'
      r.mail_to = settings.mail_to
      r.mail_from = settings.mail_from
      r.helo = settings.hello
      r.smtp = settings.smtp
      r.smtp_port = settings.smtp_port
      r.email_template = settings.email_template
      r.defer = settings.defer
      r.selector = settings.pusher_select.send_mail
      r.formatter = settings.pusher_format.send_mail
      settings.rules[r.backend:upper()] = r
    end
  end
  if not next(settings.pusher_enabled) then
    rspamd_logger.errx(rspamd_config, 'No push backend enabled')
    return
  end
elseif not next(settings.rules) then
  rspamd_logger.debugm(N, rspamd_config, 'No rules enabled')
  return
end
if not settings.rules or not next(settings.rules) then
  rspamd_logger.errx(rspamd_config, 'No rules enabled')
  return
end
local backend_required_elements = {
  http = {
    'url',
  },
  smtp = {
    'mail_to',
    'smtp',
  },
  redis_pubsub = {
    'channel',
  },
}
local check_element = {
  selector = function(k, v)
    if not selectors[v] then
      rspamd_logger.errx(rspamd_config, 'Rule %s has invalid selector %s', k, v)
      return false
    else
      return true
    end
  end,
  formatter = function(k, v)
    if not formatters[v] then
      rspamd_logger.errx(rspamd_config, 'Rule %s has invalid formatter %s', k, v)
      return false
    else
      return true
    end
  end,
}
local backend_check = {
  default = function(k, rule)
    local reqset = backend_required_elements[rule.backend]
    if reqset then
      for _, e in ipairs(reqset) do
        if not rule[e] then
          rspamd_logger.errx(rspamd_config, 'Rule %s misses required setting %s', k, e)
          settings.rules[k] = nil
        end
      end
    end
    for sett, v in pairs(rule) do
      local f = check_element[sett]
      if f then
        if not f(sett, v) then
          settings.rules[k] = nil
        end
      end
    end
  end,
}
backend_check.redis_pubsub = function(k, rule)
  if not redis_params then
    redis_params = rspamd_parse_redis_server(N)
  end
  if not redis_params then
    rspamd_logger.errx(rspamd_config, 'No redis servers are specified')
    settings.rules[k] = nil
  else
    backend_check.default(k, rule)
  end
end
setmetatable(backend_check, {
  __index = function()
    return backend_check.default
  end,
})
for k, v in pairs(settings.rules) do
  if type(v) == 'table' then
    local backend = v.backend
    if not backend then
      rspamd_logger.errx(rspamd_config, 'Rule %s has no backend', k)
      settings.rules[k] = nil
    elseif not pushers[backend] then
      rspamd_logger.errx(rspamd_config, 'Rule %s has invalid backend %s', k, backend)
      settings.rules[k] = nil
    else
      local f = backend_check[backend]
      f(k, v)
    end
  else
    rspamd_logger.errx(rspamd_config, 'Rule %s has bad type: %s', k, type(v))
    settings.rules[k] = nil
  end
end

local function gen_exporter(rule)
  return function (task)
    local selector = rule.selector or 'default'
    local selected = selectors[selector](task)
    if selected then
      rspamd_logger.debugm(N, task, 'Message selected for processing')
      local formatter = rule.formatter or 'default'
      local formatted = formatters[formatter](task, rule)
      if formatted then
        pushers[rule.backend](task, formatted, rule)
      else
        rspamd_logger.debugm(N, task, 'Formatter [%s] returned non-truthy value [%s]', formatter, formatted)
      end
    else
      rspamd_logger.debugm(N, task, 'Selector [%s] returned non-truthy value [%s]', selector, selected)
    end
  end
end

if not next(settings.rules) then
  rspamd_logger.errx(rspamd_config, 'No rules enabled')
end
for k, r in pairs(settings.rules) do
  rspamd_config:register_symbol({
    name = 'EXPORT_METADATA_' .. k,
    type = 'postfilter',
    callback = gen_exporter(r),
    priority = 10
  })
end
