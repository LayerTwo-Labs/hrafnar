package munin

// Sharded LRU block cache. 16 shards, each an independent LRU under its own
// mutex, keyed by (run_id, block_offset). Stores verified, decompressed
// block payloads. Entries pinned by outstanding handles are never evicted;
// they are freed when the last handle releases.

import "base:runtime"
import "core:sync"

CACHE_SHARD_COUNT :: 16

Cache_Key :: struct {
	run_id: u64,
	offset: u64,
}

Cache_Entry :: struct {
	key:     Cache_Key,
	payload: []byte,
	refs:    int, // outstanding handles
	evicted: bool, // dropped from the map while pinned; free on last release
	prev:    ^Cache_Entry, // LRU list, most-recent at head
	next:    ^Cache_Entry,
}

Cache_Shard :: struct {
	mu:         sync.Mutex,
	entries:    map[Cache_Key]^Cache_Entry,
	head:       ^Cache_Entry,
	tail:       ^Cache_Entry,
	bytes_used: int,
	capacity:   int,
}

Cache :: struct {
	shards:    [CACHE_SHARD_COUNT]Cache_Shard,
	allocator: runtime.Allocator,
}

// Cache_Handle pins one block payload. A zero handle releases as a no-op;
// a handle with no entry owns its payload directly (the uncached path).
Cache_Handle :: struct {
	payload:   []byte,
	allocator: runtime.Allocator,
	cache:     ^Cache,
	entry:     ^Cache_Entry,
}

cache_init :: proc(c: ^Cache, capacity_bytes: int, allocator := context.allocator) {
	c.allocator = allocator
	per_shard := max(capacity_bytes / CACHE_SHARD_COUNT, 1)
	for &s in c.shards {
		s.entries = make(map[Cache_Key]^Cache_Entry, allocator)
		s.head = nil
		s.tail = nil
		s.bytes_used = 0
		s.capacity = per_shard
	}
}

// cache_destroy frees everything. No handles may be outstanding.
cache_destroy :: proc(c: ^Cache) {
	for &s in c.shards {
		for _, e in s.entries {
			delete(e.payload, c.allocator)
			free(e, c.allocator)
		}
		delete(s.entries)
	}
}

@(private = "file")
shard_for :: proc(c: ^Cache, key: Cache_Key) -> ^Cache_Shard {
	h := (key.run_id ~ key.offset * 0x9E3779B97F4A7C15) * 0xBF58476D1CE4E5B9
	return &c.shards[h >> 60 & (CACHE_SHARD_COUNT - 1)]
}

@(private = "file")
lru_unlink :: proc(s: ^Cache_Shard, e: ^Cache_Entry) {
	if e.prev != nil {e.prev.next = e.next} else {s.head = e.next}
	if e.next != nil {e.next.prev = e.prev} else {s.tail = e.prev}
	e.prev = nil
	e.next = nil
}

@(private = "file")
lru_push_front :: proc(s: ^Cache_Shard, e: ^Cache_Entry) {
	e.prev = nil
	e.next = s.head
	if s.head != nil {s.head.prev = e}
	s.head = e
	if s.tail == nil {s.tail = e}
}

@(private = "file")
evict_over_capacity :: proc(c: ^Cache, s: ^Cache_Shard) {
	e := s.tail
	for s.bytes_used > s.capacity && e != nil {
		prev := e.prev
		if e.refs == 0 {
			lru_unlink(s, e)
			delete_key(&s.entries, e.key)
			s.bytes_used -= len(e.payload)
			delete(e.payload, c.allocator)
			free(e, c.allocator)
		}
		e = prev
	}
}

// cache_get returns the block payload for (r.run_id, offset), reading and
// verifying it on a miss. The handle must be released when done.
cache_get :: proc(
	c: ^Cache,
	r: ^Run,
	offset, length: u64,
) -> (
	payload: []byte,
	handle: Cache_Handle,
	err: Error,
) {
	key := Cache_Key{run_id = r.run_id, offset = offset}
	s := shard_for(c, key)

	sync.mutex_lock(&s.mu)
	if e, hit := s.entries[key]; hit {
		e.refs += 1
		lru_unlink(s, e)
		lru_push_front(s, e)
		sync.mutex_unlock(&s.mu)
		return e.payload, Cache_Handle{payload = e.payload, cache = c, entry = e}, nil
	}
	sync.mutex_unlock(&s.mu)

	// Miss: read outside the lock so a slow disk doesn't stall the shard.
	data := read_block_direct(r.f, offset, length, c.allocator) or_return

	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if e, hit := s.entries[key]; hit {
		// Raced with another reader; theirs won.
		delete(data, c.allocator)
		e.refs += 1
		lru_unlink(s, e)
		lru_push_front(s, e)
		return e.payload, Cache_Handle{payload = e.payload, cache = c, entry = e}, nil
	}

	e := new(Cache_Entry, c.allocator)
	e.key = key
	e.payload = data
	e.refs = 1
	s.entries[key] = e
	lru_push_front(s, e)
	s.bytes_used += len(data)
	evict_over_capacity(c, s)
	return e.payload, Cache_Handle{payload = e.payload, cache = c, entry = e}, nil
}

cache_handle_release :: proc(h: ^Cache_Handle) {
	if h.entry != nil {
		c := h.cache
		s := shard_for(c, h.entry.key)
		sync.mutex_lock(&s.mu)
		h.entry.refs -= 1
		if h.entry.refs == 0 && h.entry.evicted {
			delete(h.entry.payload, c.allocator)
			free(h.entry, c.allocator)
		}
		sync.mutex_unlock(&s.mu)
	} else if h.payload != nil {
		delete(h.payload, h.allocator)
	}
	h^ = {}
}

// cache_drop_run removes every cached block belonging to a run, called when
// the run file is deleted. Pinned entries are marked and freed on release.
cache_drop_run :: proc(c: ^Cache, run_id: u64) {
	for &s in c.shards {
		sync.mutex_lock(&s.mu)
		to_remove := make([dynamic]Cache_Key, context.temp_allocator)
		for key, e in s.entries {
			if key.run_id != run_id {continue}
			append(&to_remove, key)
			lru_unlink(&s, e)
			s.bytes_used -= len(e.payload)
			if e.refs == 0 {
				delete(e.payload, c.allocator)
				free(e, c.allocator)
			} else {
				e.evicted = true
			}
		}
		for key in to_remove {
			delete_key(&s.entries, key)
		}
		sync.mutex_unlock(&s.mu)
	}
}
