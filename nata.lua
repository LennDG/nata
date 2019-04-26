local nata = {
	_VERSION = 'Nata',
	_DESCRIPTION = 'Entity management for Lua.',
	_URL = 'https://github.com/tesselode/nata',
	_LICENSE = [[
		MIT License

		Copyright (c) 2019 Andrew Minnich

		Permission is hereby granted, free of charge, to any person obtaining a copy
		of this software and associated documentation files (the "Software"), to deal
		in the Software without restriction, including without limitation the rights
		to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
		copies of the Software, and to permit persons to whom the Software is
		furnished to do so, subject to the following conditions:

		The above copyright notice and this permission notice shall be included in all
		copies or substantial portions of the Software.

		THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
		IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
		FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
		AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
		LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
		OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
		SOFTWARE.
	]]
}

local function removeByValue(t, v)
	for i = #t, 1, -1 do
		if t[i] == v then table.remove(t, i) end
	end
end

local function entityHasKeys(entity, keys)
	for _, key in ipairs(keys) do
		if not entity[key] then return false end
	end
	return true
end

local function filterEntity(entity, filter)
	if type(filter) == 'table' then
		return entityHasKeys(entity, filter)
	elseif type(filter) == 'function' then
		return filter(entity)
	end
	return true
end

local Pool = {}
Pool.__index = Pool

function Pool:_init(options, ...)
	-- Pool fields
	self._queue = {}
	self.entities = {}
	self.hasEntity = {}
	self.groups = {}
	self.systems = {}
	self._events = {}

	-- Pool group options handling
	options = options or {}
	local groups = options.groups or {}
	for groupName, groupOptions in pairs(groups) do
		self.groups[groupName] = {
			filter = groupOptions.filter,
			sort = groupOptions.sort,
			entities = {},
			hasEntity = {},
		}
	end

	-- Pool system options handling
	local systems = options.systems or {nata.oop()}
	for _, systemDefinition in ipairs(systems) do
		table.insert(self.systems, self:newSystem(systemDefinition, ...))
	end

	-- Emit init event to all systems
	self:emit('init', ...)
end

function Pool:_addToGroup(groupName, entity)
	local group = self.groups[groupName]
	table.insert(group.entities, entity)
	if group.sort then
		table.sort(group.entities, group.sort)
	end
	group.hasEntity[entity] = true
	self:emit('addToGroup', groupName, entity)
end

function Pool:_removeFromGroup(groupName, entity)
	local group = self.groups[groupName]
	removeByValue(group.entities, entity)
	group.hasEntity[entity] = nil
	self:emit('removeFromGroup', groupName, entity)
end

function Pool:queue(entity)
	table.insert(self._queue, entity)
	return entity
end

function Pool:flush()
	for i = 1, #self._queue do
		local entity = self._queue[i]

		-- check if the entity belongs in each group and
		-- add it to/remove it from the group as needed
		for groupName, group in pairs(self.groups) do
			local belongsInGroup = filterEntity(entity, group.filter)
			if belongsInGroup and not group.hasEntity[entity] then
				self:_addToGroup(groupName, entity)
			elseif not belongsInGroup and group.hasEntity[entity] then
				self:_removeFromGroup(groupName, entity)
			end
		end

		-- add the entity to the pool if it hasn't been added already
		if not self.hasEntity[entity] then
			table.insert(self.entities, entity)
			self.hasEntity[entity] = true
			self:emit('add', entity)
		end

		-- add/remove the entity to any system as needed
		for _, system in ipairs(self.systems) do
			local belongsInSystem = filterEntity(entity, system.filter)
			if belongsInSystem and not system.hasEntity[entity] then
				system:_addEntity(entity)
			elseif not belongsInSystem and system.hasEntity[entity] then
				system:_removeEntity(entity)
			end
		end

		self._queue[i] = nil
	end
end

-- Remove an entity from groups, systems and pool
function Pool:remove(f)
	for i = #self.entities, 1, -1 do
		local entity = self.entities[i]
		if f(entity) then
			self:emit('remove', entity)
			
			-- Remove from groups
			for groupName, group in pairs(self.groups) do
				if group.hasEntity[entity] then
					self:_removeFromGroup(groupName, entity)
				end
			end

			-- Remove from systems
			for _, system in ipairs(self.systems) do
				if system.hasEntity[entity] then
					system:_removeEntity(entity)
				end
			end

			-- Remove from pool
			table.remove(self.entities, i)
			self.hasEntity[entity] = nil
		end
	end
end

function Pool:on(event, f)
	self._events[event] = self._events[event] or {}
	table.insert(self._events[event], f)
	return f
end

function Pool:off(event, f)
	if self._events[event] then
		removeByValue(self._events[event], f)
	end
end

function Pool:emit(event, ...)
	for _, system in ipairs(self.systems) do
		if type(system[event]) == 'function' then
			system[event](system, ...)
		end
	end
	if self._events[event] then
		for _, f in ipairs(self._events[event]) do
			f(...)
		end
	end
end

function Pool:getSystem(systemDefinition)
	for _, system in ipairs(self.systems) do
		if getmetatable(system).__index == systemDefinition then
			return system
		end
	end
end

function nata.oop(groupName)
	return setmetatable({_cache = {}}, {
		__index = function(t, event)
			t._cache[event] = t._cache[event] or function(self, ...)
				local entities = groupName and self.pool.groups[groupName].entities or self.pool.entities
				for _, entity in ipairs(entities) do
					if type(entity[event]) == 'function' then
						entity[event](entity, ...)
					end
				end
			end
			return t._cache[event]
		end
	})
end

function nata.new(...)
	local pool = setmetatable({}, Pool)
	pool:_init(...)
	return pool
end

--[[
	System definitions:

	Passed to nata.new to define the systems you can use. They're a table with the following keys:
	- filter - function|table|nil - defines what entities the system acts on
		- if it's a function and function(entity) returns true, the system will act on that entity
		- if it's a table and each item of the table is a key in the entity, the system will act on that entity
		- if it's nil, the system will act on every entity
	- sort (optional) - if defined, systems will sort their entities when new ones are added.
		- sort functions work the same way as with table.sort
	- continuousSort - if true, systems will also sort entities on pool calls
	- init (optional) - a self function that will run when the pool is created
	- added (optional) - a self function that will run when an entity is added
	- removed (optional) - a self function that will run when an entity is removed
	- ... - other functions will be called when pool:emit(...) is called
]]

-- A system instance that does processing on entities within a pool.
local System = {}
function System:__index(k)
	return System[k] or self._definition[k]
end

-- internal functions --

-- adds an entity to the system's pool and sorts the entities if needed
function System:_addEntity(entity, ...)
	table.insert(self.entities, entity)
	self.hasEntity[entity] = true

	-- If the system has an add function, call it with the entity
	if type(self._definition.added) == 'function' then
		self._definition.added(self, entity, ...)
	end

	if self._definition.sort then
		table.sort(self.entities, self._definition.sort)
	end
end

-- removes an entity from the system's pool
function System:_removeEntity(entity, ...)
	if not self.hasEntity[entity] then return false end

	-- I the system has a remove function, call it with the entity
	if type(self._definition.removed) == 'function' then
		self._definition.removed(self, entity, ...)
	end

	for i = #self.entities, 1, -1 do
		if self.entities[i] == entity then
			table.remove(self.entities, i)
			break
		end
	end

	self.hasEntity[entity] = false
end

-- public functions - accessible within the system definition's functions --
function System:queue(...) self.pool:queue(...) end

function Pool:newSystem(definition, ...)
	print(definition)
	local system = setmetatable({
		entities = {}, -- also accessible from within system definition's functions
		hasEntity = {}, -- also accessible from within system definition's functions
		pool = self,
		_definition = definition,
	}, System)
	return system
end

return nata
