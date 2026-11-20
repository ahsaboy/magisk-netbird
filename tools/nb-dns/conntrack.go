package main

import (
	"encoding/binary"
	"errors"
	"net/netip"
)

// ctnetlink attribute numbers (linux/netfilter/nfnetlink_conntrack.h).
const (
	attributeNested = 0x8000
	tupleOriginal   = 1
	tupleReply      = 2
	tupleIP         = 1
	tupleProtocol   = 2
	conntrackMark   = 8
	protocolNumber  = 1
	protocolSource  = 2
	protocolTarget  = 3
)

func attributes(data []byte) map[uint16][]byte {
	result := map[uint16][]byte{}
	for len(data) >= 4 {
		length := int(binary.NativeEndian.Uint16(data))
		if length < 4 || length > len(data) {
			break
		}
		result[binary.NativeEndian.Uint16(data[2:])&0x3fff] = data[4:length]
		aligned := (length + 3) &^ 3
		if aligned > len(data) {
			break
		}
		data = data[aligned:]
	}
	return result
}

func encodeAttribute(kind uint16, payload []byte) []byte {
	data := make([]byte, (len(payload)+7)&^3)
	binary.NativeEndian.PutUint16(data, uint16(len(payload)+4))
	binary.NativeEndian.PutUint16(data[2:], kind)
	copy(data[4:], payload)
	return data
}

func port(value uint16) []byte {
	return binary.BigEndian.AppendUint16(nil, value)
}

// encodeTuple builds a CTA_TUPLE_ORIG or CTA_TUPLE_REPLY lookup key.
func encodeTuple(direction uint16, protocol byte, source, destination netip.AddrPort) []byte {
	sourceKind, destinationKind := uint16(1), uint16(2)
	if source.Addr().Is6() {
		sourceKind, destinationKind = 3, 4
	}
	addresses := append(encodeAttribute(sourceKind, source.Addr().AsSlice()), encodeAttribute(destinationKind, destination.Addr().AsSlice())...)
	protocols := append(encodeAttribute(protocolNumber, []byte{protocol}), encodeAttribute(protocolSource, port(source.Port()))...)
	protocols = append(protocols, encodeAttribute(protocolTarget, port(destination.Port()))...)
	tuple := append(encodeAttribute(tupleIP|attributeNested, addresses), encodeAttribute(tupleProtocol|attributeNested, protocols)...)
	return encodeAttribute(direction|attributeNested, tuple)
}

// parseEntry returns the original destination and connection mark of a
// conntrack entry.
func parseEntry(data []byte) (netip.AddrPort, uint32, error) {
	fields := attributes(data)
	original := attributes(fields[tupleOriginal])
	addresses := attributes(original[tupleIP])
	protocols := attributes(original[tupleProtocol])
	raw := addresses[2]
	if raw == nil {
		raw = addresses[4]
	}
	address, ok := netip.AddrFromSlice(raw)
	if !ok || len(protocols[protocolTarget]) != 2 {
		return netip.AddrPort{}, 0, errors.New("incomplete conntrack entry")
	}
	var mark uint32
	if len(fields[conntrackMark]) == 4 {
		mark = binary.BigEndian.Uint32(fields[conntrackMark])
	}
	return netip.AddrPortFrom(address, binary.BigEndian.Uint16(protocols[protocolTarget])), mark, nil
}

// lookupKey selects the conntrack key for an intercepted query. A NAT
// redirect arrives on the helper's own port and is found by its reply tuple;
// a TPROXY query keeps its original destination as the local address.
func lookupKey(source origin) (uint16, netip.AddrPort, netip.AddrPort, byte) {
	protocol := byte(17)
	if source.tcp {
		protocol = 6
	}
	client := netip.AddrPortFrom(source.client.Addr().Unmap(), source.client.Port())
	local := netip.AddrPortFrom(source.local.Addr().Unmap(), source.local.Port())
	if local.Port() == listenPort && local.Addr().IsLoopback() {
		return tupleReply, local, client, protocol
	}
	return tupleOriginal, client, local, protocol
}

func ownedTuple(data []byte) []byte {
	fields := attributes(data)
	original, reply := attributes(fields[1]), attributes(fields[2])
	protocol := attributes(original[2])
	if len(protocol[1]) != 1 || (protocol[1][0] != 6 && protocol[1][0] != 17) {
		return nil
	}
	if len(protocol[3]) != 2 || binary.BigEndian.Uint16(protocol[3]) != 53 {
		return nil
	}
	replyProtocol := attributes(reply[2])
	if len(replyProtocol[2]) != 2 || binary.BigEndian.Uint16(replyProtocol[2]) != listenPort {
		return nil
	}
	ipFields := attributes(reply[1])
	for _, key := range []uint16{1, 3} {
		address, ok := netip.AddrFromSlice(ipFields[key])
		if ok && (address == netip.MustParseAddr("127.0.0.1") || address == netip.IPv6Loopback()) {
			return fields[1]
		}
	}
	return nil
}
