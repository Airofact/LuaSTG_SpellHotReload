---@class SpellHotReload.Snapshot
---@field file_name string
---@field content string
---@field hash string
---@field read_update integer
---@field source string?

---@class SpellHotReload.Candidate
---@field file_name string
---@field generation integer
---@field changed_update integer
---@field source string?
---@field first_content string?
---@field first_hash string?
---@field first_read_update integer?
---@field stable boolean?

---@class SpellHotReload.SnapshotStore
local SnapshotStore = {}
SnapshotStore.__index = SnapshotStore

local HASH_MODULUS_1 = 2147483647
local HASH_MODULUS_2 = 2147483629

---@param value table?
---@return table?
local function copy_record(value)
	if value == nil then
		return nil
	end
	local result = {}
	for key, item in pairs(value) do
		result[key] = item
	end
	return result
end

---Deterministic, non-cryptographic content hash used only as a fast dedup key.
---@param content string
---@return string
function SnapshotStore.ContentHash(content)
	assert(type(content) == "string", "content must be a string")
	local hash_1 = 0
	local hash_2 = 0
	for index = 1, #content do
		local byte = string.byte(content, index)
		hash_1 = (hash_1 * 131 + byte) % HASH_MODULUS_1
		hash_2 = (hash_2 * 65599 + byte) % HASH_MODULUS_2
	end
	return string.format("%d:%d:%d", #content, hash_1, hash_2)
end

---@param options table?
---@return SpellHotReload.SnapshotStore
function SnapshotStore.New(options)
	options = options or {}
	local instance = setmetatable({}, SnapshotStore)
	instance._hash = options.hash or SnapshotStore.ContentHash
	instance._accepted = {}
	instance._candidates = {}
	instance._dismissed = {}
	instance._partial = {} -- sticky: accepted bytes no longer prove live definitions
	instance._next_generation = 0
	return instance
end

---@param file_name string
---@param changed_update integer
---@param source string?
---@return SpellHotReload.Candidate
function SnapshotStore:BeginCandidate(file_name, changed_update, source)
	assert(type(file_name) == "string", "file_name must be a string")
	assert(type(changed_update) == "number", "changed_update must be a number")
	self._next_generation = self._next_generation + 1
	local candidate = {
		file_name = file_name,
		generation = self._next_generation,
		changed_update = changed_update,
		source = source,
	}
	self._candidates[file_name] = candidate
	return copy_record(candidate)
end

---@param file_name string
function SnapshotStore:CancelCandidate(file_name)
	self._candidates[file_name] = nil
end

---Drop the current candidate AND remember the bytes the user rejected, so a
---drift rescan or an identical re-export does not resurrect the same candidate.
---Only a stable candidate carries bytes worth remembering; a candidate that was
---still stabilizing is simply cancelled.
---@param file_name string
---@return SpellHotReload.Snapshot?
function SnapshotStore:DismissCandidate(file_name)
	local current = self._candidates[file_name]
	self._candidates[file_name] = nil
	if current == nil or current.first_content == nil then
		return nil
	end
	local record = {
		file_name = file_name,
		content = current.first_content,
		hash = current.first_hash or self._hash(current.first_content),
	}
	self._dismissed[file_name] = record
	return copy_record(record)
end

---True when the given bytes are exactly the ones the user previously rejected
---for this file. Used to short-circuit drift/rescan before starting a candidate.
---@param file_name string
---@param content string
---@return boolean
function SnapshotStore:IsDismissed(file_name, content)
	assert(type(content) == "string", "content must be a string")
	local record = self._dismissed[file_name]
	if record == nil then
		return false
	end
	return record.hash == self._hash(content) and record.content == content
end

---@param file_name string
---@return SpellHotReload.Snapshot?
function SnapshotStore:GetAccepted(file_name)
	return copy_record(self._accepted[file_name])
end

---Record an actual partial publication, not a whole-file acknowledgement. The
---caller supplies the successful transaction revision; this bookkeeping API is
---not commit authority and never advances accepted bytes or discards pending.
---Only the current stable generation/exact bytes can be recorded. Once partial,
---baseline equality cannot prove "unchanged" for the rest of this session.
function SnapshotStore:RecordPartialPublication(file_name, generation, content, revision)
	local current = self._candidates[file_name]
	if current == nil or current.generation ~= generation then
		return nil, "superseded"
	end
	if current.stable ~= true or type(content) ~= "string" or content ~= current.first_content then
		return nil, "stable candidate bytes required"
	end
	if type(revision) ~= "number" or revision < 1 or revision % 1 ~= 0 then
		return nil, "positive integer revision required"
	end
	local previous = self._partial[file_name]
	if previous ~= nil and revision <= previous.revision then
		return nil, "publication revision did not advance"
	end
	local record = { generation = generation, revision = revision }
	self._partial[file_name] = record
	return copy_record(record)
end

---Metadata only; per-unit versions remain the authority for published content.
function SnapshotStore:GetPartialPublication(file_name)
	return copy_record(self._partial[file_name])
end

function SnapshotStore:HasPartialPublication(file_name)
	return self._partial[file_name] ~= nil
end

---Set an accepted snapshot directly (baseline or legacy full-file publication).
---After a partial publication, only Clear/new session may establish a baseline.
---@param file_name string
---@param content string
---@param source string?
---@return SpellHotReload.Snapshot?, string?
function SnapshotStore:SetAccepted(file_name, content, source)
	assert(type(content) == "string", "content must be a string")
	if self:HasPartialPublication(file_name) then
		return nil, "partial publication cannot acknowledge the whole file"
	end
	local accepted = {
		file_name = file_name,
		content = content,
		hash = self._hash(content),
		read_update = 0,
		source = source,
	}
	self._accepted[file_name] = accepted
	-- a published baseline supersedes any earlier rejection of these bytes
	self._dismissed[file_name] = nil
	return copy_record(accepted)
end

---@return string[]
function SnapshotStore:GetAcceptedFileNames()
	local result = {}
	for file_name in pairs(self._accepted) do
		result[#result + 1] = file_name
	end
	table.sort(result)
	return result
end

---@param file_name string
---@return SpellHotReload.Candidate?
function SnapshotStore:GetCandidate(file_name)
	return copy_record(self._candidates[file_name])
end

---@return string[]
function SnapshotStore:GetCandidateFileNames()
	local result = {}
	for file_name in pairs(self._candidates) do
		result[#result + 1] = file_name
	end
	table.sort(result)
	return result
end

---@param file_name string
---@param generation integer
---@param content string
---@param read_update integer
---@return SpellHotReload.Candidate?, string?
function SnapshotStore:RecordFirstRead(file_name, generation, content, read_update)
	assert(type(content) == "string", "content must be a string")
	local current = self._candidates[file_name]
	if current == nil or current.generation ~= generation then
		return nil, "superseded"
	end
	local candidate = {
		file_name = current.file_name,
		generation = current.generation,
		changed_update = current.changed_update,
		source = current.source,
		first_content = content,
		first_hash = self._hash(content),
		first_read_update = read_update,
	}
	self._candidates[file_name] = candidate
	return copy_record(candidate)
end

---Verify a second read against the candidate's first read. When the bytes are
---identical the candidate is marked stable and KEPT in the candidate set — the
---user-facing Apply action later promotes it to accepted. A differing second read
---supersedes the candidate and starts a fresh generation. A stable read that
---equals the accepted baseline is dropped only before any partial publication:
---after that, even original bytes may need to undo already-published definitions.
---@param file_name string
---@param generation integer
---@param content string
---@param read_update integer
---@param minimum_update_gap integer
---@return SpellHotReload.Candidate?, string
function SnapshotStore:VerifyStable(file_name, generation, content, read_update, minimum_update_gap)
	assert(type(content) == "string", "content must be a string")
	local current = self._candidates[file_name]
	if current == nil or current.generation ~= generation then
		return nil, "superseded"
	end
	if current.first_content == nil or current.first_read_update == nil then
		return nil, "first-read-required"
	end
	if read_update - current.first_read_update < minimum_update_gap then
		return nil, "too-soon"
	end

	local content_hash = self._hash(content)
	if content_hash ~= current.first_hash or content ~= current.first_content then
		self:BeginCandidate(file_name, read_update, "verification-mismatch")
		return nil, "changed"
	end

	-- Byte equality proves nothing about per-unit publication after partial Apply.
	local previous = self._accepted[file_name]
	if not self:HasPartialPublication(file_name) and previous ~= nil
		and previous.hash == content_hash and previous.content == content then
		self._candidates[file_name] = nil
		return nil, "unchanged"
	end

	-- stable but the user already rejected exactly these bytes: drop it and keep
	-- the rejection so repeated drift scans stay quiet. Different bytes clear the
	-- rejection (a genuine new edit is allowed to surface).
	local dismissed = self._dismissed[file_name]
	if dismissed ~= nil then
		if dismissed.hash == content_hash and dismissed.content == content then
			self._candidates[file_name] = nil
			return nil, "dismissed"
		end
		self._dismissed[file_name] = nil
	end

	current.stable = true
	return copy_record(current), "stable"
end

---Drop accepted, candidate, dismissed bytes and partial metadata at session end.
---Keep generation
---monotonic so a stale first-read ticket cannot match a future candidate.
function SnapshotStore:Clear()
	self._accepted = {}
	self._candidates = {}
	self._dismissed = {}
	self._partial = {}
	return true
end

return SnapshotStore
