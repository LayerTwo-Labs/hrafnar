package hugin

import "base:intrinsics"

// Fixed-width row encodings for the three Munin keyspaces and the two join
// scatter keyspaces. Index key fields are big-endian so lexicographic byte
// order matches numeric order; Bitcoin-native fields (txids, amounts) keep
// their internal encoding.

DIRECTION_FUNDING :: u8(0)
DIRECTION_SPEND :: u8(1)

// history: key 45 = scripthash 32 | height u32 BE | txnum u32 BE
//          | direction u8 | io_index u32 BE; value 8 = amount u64 LE.
HISTORY_KEY_LEN :: 45
HISTORY_ROW_SIZE :: 53

history_row_encode :: proc "contextless" (
	buf: []byte,
	scripthash_: [32]u8,
	height: u32,
	txnum: u32,
	direction: u8,
	io_index: u32,
	amount: u64,
) {
	scripthash_ := scripthash_
	copy(buf[0:32], scripthash_[:])
	put_u32be(buf[32:], height)
	put_u32be(buf[36:], txnum)
	buf[40] = direction
	put_u32be(buf[41:], io_index)
	put_u64le(buf[45:], amount)
}

History_Row :: struct {
	scripthash: [32]u8,
	height:     u32,
	txnum:      u32,
	direction:  u8,
	io_index:   u32,
	amount:     u64,
}

history_row_decode :: proc "contextless" (row: []byte) -> (r: History_Row) {
	copy(r.scripthash[:], row[0:32])
	r.height = get_u32be(row[32:])
	r.txnum = get_u32be(row[36:])
	r.direction = row[40]
	r.io_index = get_u32be(row[41:])
	r.amount = get_u64le(row[45:])
	return
}

// history_value_decode decodes the 8-byte amount value (for reads through
// Munin, where key and value arrive separately).
history_value_decode :: proc "contextless" (value: []byte) -> u64 {
	return get_u64le(value)
}

history_key_decode :: proc "contextless" (key: []byte) -> (r: History_Row) {
	copy(r.scripthash[:], key[0:32])
	r.height = get_u32be(key[32:])
	r.txnum = get_u32be(key[36:])
	r.direction = key[40]
	r.io_index = get_u32be(key[41:])
	return
}

// txloc: key 32 = txid; value 14 = file_no u16 | offset u32 | length u32
//        | height u32 (all LE).
TXLOC_KEY_LEN :: 32
TXLOC_ROW_SIZE :: 46

txloc_row_encode :: proc "contextless" (
	buf: []byte,
	txid: [32]u8,
	file_no: u16,
	offset: u32,
	length: u32,
	height: u32,
) {
	txid := txid
	copy(buf[0:32], txid[:])
	buf[32] = byte(file_no)
	buf[33] = byte(file_no >> 8)
	put_u32le(buf[34:], offset)
	put_u32le(buf[38:], length)
	put_u32le(buf[42:], height)
}

Txloc_Value :: struct {
	file_no: u16,
	offset:  u32,
	length:  u32,
	height:  u32,
}

txloc_value_decode :: proc "contextless" (value: []byte) -> (v: Txloc_Value) {
	v.file_no = u16(value[0]) | u16(value[1]) << 8
	v.offset = get_u32le(value[2:])
	v.length = get_u32le(value[6:])
	v.height = get_u32le(value[10:])
	return
}

// spends: key 36 = funding txid 32 | vout u32 BE;
//         value 12 = height u32 BE | txnum u32 BE | vin u32 BE.
//
// The spender's txid is deliberately NOT stored: (height, txnum) locates
// the spending transaction exactly, and a query resolves the txid with one
// block read. Trading 32 bytes per spend row for that read keeps the
// keyspace at ~40% of the size while staying exact (the key is the full
// outpoint).
SPENDS_KEY_LEN :: 36
SPENDS_ROW_SIZE :: 48

spends_row_encode :: proc "contextless" (
	buf: []byte,
	funding_txid: [32]u8,
	vout: u32,
	height: u32,
	txnum: u32,
	vin: u32,
) {
	funding_txid := funding_txid
	copy(buf[0:32], funding_txid[:])
	put_u32be(buf[32:], vout)
	put_u32be(buf[36:], height)
	put_u32be(buf[40:], txnum)
	put_u32be(buf[44:], vin)
}

Spend_Value :: struct {
	height: u32,
	txnum:  u32,
	vin:    u32,
}

spends_value_decode :: proc "contextless" (value: []byte) -> (v: Spend_Value) {
	v.height = get_u32be(value[0:])
	v.txnum = get_u32be(value[4:])
	v.vin = get_u32be(value[8:])
	return
}

// join funding side: outpoint 36 (txid | vout BE) | scripthash 32
//                    | amount u64 LE | height u32 BE | txnum u32 BE.
//
// height/txnum ride along so the join can emit the history FUNDING row for
// every output — funding rows are not scattered separately in phase 1,
// which removes an entire keyspace of spill.
JOINF_ROW_SIZE :: 84
JOIN_KEY_LEN :: 36

joinf_row_encode :: proc "contextless" (
	buf: []byte,
	txid: [32]u8,
	vout: u32,
	scripthash_: [32]u8,
	amount: u64,
	height: u32,
	txnum: u32,
) {
	txid := txid
	scripthash_ := scripthash_
	copy(buf[0:32], txid[:])
	put_u32be(buf[32:], vout)
	copy(buf[36:68], scripthash_[:])
	put_u64le(buf[68:], amount)
	put_u32be(buf[76:], height)
	put_u32be(buf[80:], txnum)
}

// join spend side: outpoint 36 | height u32 BE | txnum u32 BE | vin u32 BE.
JOINS_ROW_SIZE :: 48

joins_row_encode :: proc "contextless" (
	buf: []byte,
	prev_txid: [32]u8,
	prev_vout: u32,
	height: u32,
	txnum: u32,
	vin: u32,
) {
	prev_txid := prev_txid
	copy(buf[0:32], prev_txid[:])
	put_u32be(buf[32:], prev_vout)
	put_u32be(buf[36:], height)
	put_u32be(buf[40:], txnum)
	put_u32be(buf[44:], vin)
}

// ---------------------------------------------------------------------------

@(private)
put_u32be :: proc "contextless" (buf: []byte, x: u32) {
	buf[0] = byte(x >> 24)
	buf[1] = byte(x >> 16)
	buf[2] = byte(x >> 8)
	buf[3] = byte(x)
}

@(private)
// Rows are packed at arbitrary offsets, so these are UNALIGNED loads of
// Odin's endian-specific types: one load plus a byte swap, rather than a
// hand-rolled shift-and-or chain. Keys compare as big-endian integers,
// which orders identically to a byte-wise comparison.
get_u64be :: proc "contextless" (buf: []byte) -> u64 {
	#no_bounds_check return u64(intrinsics.unaligned_load((^u64be)(&buf[0])))
}

get_u32be :: proc "contextless" (buf: []byte) -> u32 {
	#no_bounds_check return u32(intrinsics.unaligned_load((^u32be)(&buf[0])))
}

// key_bucket returns the scatter/munin bucket for a key: its top
// bucket_bits bits, big-endian from byte 0.
key_bucket :: proc "contextless" (key: []byte, bucket_bits: u32) -> int {
	acc: u32
	n := int((bucket_bits + 7) / 8)
	for i in 0 ..< n {
		acc = acc << 8 | u32(key[i])
	}
	return int(acc >> (u32(n * 8) - bucket_bits))
}

// ---------------------------------------------------------------------------
// Compact row forms (cfg.compact): 8-byte hash prefixes with the identity
// fields moved into the key so every real entry still has a unique key.
// False prefix matches are filtered at query time by verifying against
// the actual chain data — the index shrinks ~3x, queries pay reads.

C_HISTORY_KEY_LEN :: 21 // sh8 | height4 | txnum4 | dir1 | io4
C_HISTORY_ROW_SIZE :: 21 // no value: amount recovered from the chain
C_TXLOC_KEY_LEN :: 14 // txid8 | file2 | offset4 (the location IS the identity)
C_TXLOC_ROW_SIZE :: 22 // value: len4 | height4
C_SPENDS_KEY_LEN :: 24 // txid8 | vout4 | height4 | txnum4 | vin4
C_SPENDS_ROW_SIZE :: 24 // no value

// history_row_compact converts a full history row into its compact form.
history_row_compact :: proc "contextless" (full: []byte, out: []byte) {
	copy(out[0:8], full[0:8]) // sh prefix
	copy(out[8:21], full[32:45]) // height | txnum | dir | io, layouts align
}

c_history_key_decode :: proc "contextless" (key: []byte) -> (height: u32, txnum: u32, direction: u8, io_index: u32) {
	height = get_u32be(key[8:])
	txnum = get_u32be(key[12:])
	direction = key[16]
	io_index = get_u32be(key[17:])
	return
}

// txloc_row_compact converts a full txloc row (txid32 + file2|off4|len4|height4
// LE value) into txid8|file|offset key + len|height value. The disk
// location is unique per transaction, so the key needs no txnum — and
// BIP-30 duplicate txids simply become two distinct rows (queries pick
// the later height, mirroring consensus).
txloc_row_compact :: proc "contextless" (full: []byte, out: []byte) {
	copy(out[0:8], full[0:8]) // txid prefix
	copy(out[8:14], full[32:38]) // file | offset, as stored (LE)
	copy(out[14:22], full[38:46]) // len | height, as stored (LE)
}

c_txloc_decode :: proc "contextless" (key: []byte, value: []byte) -> (v: Txloc_Value) {
	v.file_no = u16(key[8]) | u16(key[9]) << 8
	v.offset = get_u32le(key[10:])
	v.length = get_u32le(value[0:])
	v.height = get_u32le(value[4:])
	return
}

// spends_row_compact converts a full spends row
// (txid32|vout4 key + height4|txnum4|vin4 value) into the compact key.
spends_row_compact :: proc "contextless" (full: []byte, out: []byte) {
	copy(out[0:8], full[0:8]) // txid prefix
	copy(out[8:12], full[32:36]) // vout (big-endian in the full key)
	copy(out[12:24], full[36:48]) // height | txnum | vin from the value
}

c_spends_key_decode :: proc "contextless" (key: []byte) -> (vout: u32, height: u32, txnum: u32, vin: u32) {
	vout = get_u32be(key[8:])
	height = get_u32be(key[12:])
	txnum = get_u32be(key[16:])
	vin = get_u32be(key[20:])
	return
}
