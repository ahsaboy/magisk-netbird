package main

import (
	"net/netip"
	"strings"
	"sync/atomic"
)

// Module marks use bits 21-31; Android keeps netId and policy bits in 0-20.
const (
	moduleMarkMask    = 0xffe00000
	helperMark        = 0x4ea00000
	androidMarkMask   = 0x1fffff
	protectedFromVPN  = 0x20000
	unhealthyAttempts = 2
)

// origin describes where an intercepted query came from and where it was
// sent before the kernel redirected it to the helper.
type origin struct {
	tcp    bool
	client netip.AddrPort
	local  netip.AddrPort
}

type lookupFunc func(origin) (netip.AddrPort, uint32, error)
type exchangeFunc func(target string, request []byte, tcp bool, mark uint32) ([]byte, error)

// resolver sends every query to NetBird first. NetBird answers REFUSED only
// when no handler (peer zone, custom zone, match domain or primary
// nameserver) owns the name; those queries go to the destination the client
// originally chose, with its original Android routing mark. NetBird's own
// NXDOMAIN and SERVFAIL are returned unchanged.
//
// When NetBird cannot be reached, queries fail open to the original
// destination, except names under zones NetBird is known to own (peer domain
// and match domains), which get SERVFAIL. Records of NetBird custom zones are
// not visible in the client status and may then reach the original resolver.
type resolver struct {
	zones    []string
	target   netip.AddrPort
	healthy  atomic.Bool
	lookup   lookupFunc
	exchange exchangeFunc
}

func newResolver(target netip.AddrPort, lookup lookupFunc, exchanger exchangeFunc) *resolver {
	value := &resolver{target: target, lookup: lookup, exchange: exchanger}
	value.healthy.Store(true)
	return value
}

func (r *resolver) answer(request []byte, source origin) []byte {
	if len(request) < 12 {
		return nil
	}
	if isProbe(request) {
		return reply(request, rcodeRefused)
	}
	var primary []byte
	if r.healthy.Load() {
		response, err := r.exchange(r.target.String(), request, source.tcp, helperMark)
		if err == nil && rcode(response) != rcodeRefused {
			return response
		}
		if err == nil {
			primary = response
		}
	}
	// NetBird does not own the name, or NetBird is unreachable: fail open to
	// the resolver the client asked for, but never for a known NetBird zone.
	if primary == nil && r.ownedZone(request) {
		return failure(request)
	}
	if response := r.fallback(request, source); response != nil {
		return response
	}
	if primary != nil {
		return primary
	}
	return failure(request)
}

func (r *resolver) fallback(request []byte, source origin) []byte {
	if r.lookup == nil {
		return nil
	}
	destination, mark, err := r.lookup(source)
	if err != nil || !destination.IsValid() {
		return nil
	}
	address := destination.Addr().Unmap()
	if address.IsLoopback() || address.IsUnspecified() || destination.Port() == listenPort {
		return nil
	}
	if address.IsLinkLocalUnicast() && address.Zone() == "" {
		zone := source.client.Addr().Zone()
		local := source.local.Addr()
		if local.Zone() != "" && local.WithZone("") == address {
			zone = local.Zone()
		}
		address = address.WithZone(zone)
	}
	destination = netip.AddrPortFrom(address, destination.Port())
	if destination == r.target || netip.AddrPortFrom(address.WithZone(""), destination.Port()) == r.target {
		return nil
	}
	response, err := r.exchange(destination.String(), request, source.tcp, fallbackMark(mark))
	if err != nil {
		return nil
	}
	return response
}

// ownedZone reports whether the question name is a known NetBird zone or
// lies below one.
func (r *resolver) ownedZone(request []byte) bool {
	name, ok := questionName(request)
	if !ok {
		return false
	}
	for _, zone := range r.zones {
		if name == zone || strings.HasSuffix(name, "."+zone) {
			return true
		}
	}
	return false
}

// questionName returns the lower-case first question name (no compression is
// valid in a question).
func questionName(request []byte) (string, bool) {
	var labels []string
	for offset := 12; offset < len(request); {
		length := int(request[offset])
		if length == 0 {
			return strings.ToLower(strings.Join(labels, ".")), len(labels) > 0
		}
		if length > 63 || offset+1+length > len(request) {
			return "", false
		}
		labels = append(labels, string(request[offset+1:offset+1+length]))
		offset += 1 + length
	}
	return "", false
}

// fallbackMark keeps the client's netId and permission bits, marks the
// socket as the helper's own and protects it from VPN routing: the original
// query left through a non-VPN interface, otherwise it was not intercepted.
func fallbackMark(original uint32) uint32 {
	return original&androidMarkMask | protectedFromVPN | helperMark
}
