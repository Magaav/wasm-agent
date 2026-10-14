-- Ordered, replaceable prompt sections. Lua adaptation of Pi's MIT-licensed
-- buildSystemPromptSections/diffSystemPromptSections (earendil-works/pi,
-- packages/coding-agent/src/core/system-prompt.ts, b9ab2a6238d2).
-- Pi copyright (c) 2025 Mario Zechner; MIT notice also in licenses/pi-MIT.txt.
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.
-- No tool authority or automatic context/memory loading lives in this renderer.
local M={}
function M.escape(value)
 return tostring(value or ''):gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;'):gsub('"','&quot;'):gsub("'",'&apos;')
end
function M.section(name,content,attributes)
 assert(type(name)=='string' and name:match('^[a-z][a-zA-Z0-9_%-]*$'),'invalid_system_prompt_section')
 if content==nil or content=='' then return nil end
 local keys={};for key in pairs(attributes or {})do assert(key:match('^[a-z][a-z0-9_%-]*$'),'invalid_system_prompt_attribute');keys[#keys+1]=key end;table.sort(keys)
 local attrs='';for _,key in ipairs(keys)do attrs=attrs..' '..key..'="'..M.escape(attributes[key])..'"' end
 return '<'..name..attrs..'>\n'..content..'\n</'..name..'>'
end
function M.render(sections,order)
 local out={};for _,name in ipairs(order)do if sections[name] and sections[name]~='' then out[#out+1]=sections[name] end end
 return table.concat(out,'\n\n')
end
-- Like Pi's section patch: absence is a deletion; unchanged sections emit nothing.
function M.diff(previous,current)
 local patch,changed={},false
 for name,text in pairs(current)do if previous[name]~=text then patch[name]=text;changed=true end end
 for name in pairs(previous)do if current[name]==nil then patch[name]=false;changed=true end end
 return changed and patch or nil
end
return M
