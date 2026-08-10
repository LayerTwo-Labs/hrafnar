package hugin

// scriptPubKey classification and scripthash derivation.
//
// The scripthash is SHA256 of the raw scriptPubKey bytes — defined for
// every script, standard or not. Classification exists for address
// rendering and address-to-script conversion; indexing never needs it.

Script_Class :: enum {
	Nonstandard,
	P2PKH, // OP_DUP OP_HASH160 <20> OP_EQUALVERIFY OP_CHECKSIG
	P2SH, // OP_HASH160 <20> OP_EQUAL
	P2WPKH, // OP_0 <20>
	P2WSH, // OP_0 <32>
	P2TR, // OP_1 <32>
	P2PK, // <33|65 pubkey> OP_CHECKSIG
	Op_Return, // OP_RETURN ...
}

OP_0 :: 0x00
OP_RETURN :: 0x6A
OP_DUP :: 0x76
OP_EQUAL :: 0x87
OP_EQUALVERIFY :: 0x88
OP_HASH160 :: 0xA9
OP_CHECKSIG :: 0xAC
OP_1 :: 0x51

// script_classify identifies the standard template, if any.
script_classify :: proc "contextless" (script: []byte) -> Script_Class {
	n := len(script)
	switch {
	case n == 25 &&
	     script[0] == OP_DUP &&
	     script[1] == OP_HASH160 &&
	     script[2] == 20 &&
	     script[23] == OP_EQUALVERIFY &&
	     script[24] == OP_CHECKSIG:
		return .P2PKH
	case n == 23 && script[0] == OP_HASH160 && script[1] == 20 && script[22] == OP_EQUAL:
		return .P2SH
	case n == 22 && script[0] == OP_0 && script[1] == 20:
		return .P2WPKH
	case n == 34 && script[0] == OP_0 && script[1] == 32:
		return .P2WSH
	case n == 34 && script[0] == OP_1 && script[1] == 32:
		return .P2TR
	case n == 35 && script[0] == 33 && script[34] == OP_CHECKSIG:
		return .P2PK
	case n == 67 && script[0] == 65 && script[66] == OP_CHECKSIG:
		return .P2PK
	case n >= 1 && script[0] == OP_RETURN:
		return .Op_Return
	}
	return .Nonstandard
}

// scripthash is SHA256 over the raw script. Non-standard scripts index
// fine; they simply have no address rendering.
scripthash :: proc(script: []byte) -> [32]u8 {
	return sha256(script)
}

// script_payload returns the hash/key payload for a classified script:
// the 20-byte hash for P2PKH/P2SH/P2WPKH, the 32-byte program for
// P2WSH/P2TR. Empty for other classes.
script_payload :: proc "contextless" (script: []byte, class: Script_Class) -> []byte {
	switch class {
	case .P2PKH:
		return script[3:23]
	case .P2SH:
		return script[2:22]
	case .P2WPKH, .P2WSH:
		return script[2:]
	case .P2TR:
		return script[2:]
	case .P2PK, .Op_Return, .Nonstandard:
		return nil
	}
	return nil
}
