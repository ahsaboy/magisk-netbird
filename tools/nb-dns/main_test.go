package main

import (
	"bytes"
	"encoding/binary"
	"io"
	"net"
	"net/netip"
	"strings"
	"sync/atomic"
	"testing"
)

func answer(request []byte) []byte {
	reply := append([]byte(nil), request...)
	reply[2], reply[3], reply[7] = 0x81, 0x80, 1
	return append(reply, 0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 10, 1, 2, 3)
}

func testResolver(test *testing.T, udpReply func([]byte) []byte) (string, *atomic.Int32) {
	test.Helper()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		test.Fatal(err)
	}
	udp, err := net.ListenPacket("udp4", listener.Addr().String())
	if err != nil {
		listener.Close()
		test.Fatal(err)
	}
	test.Cleanup(func() { listener.Close(); udp.Close() })
	tcpQueries := &atomic.Int32{}
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer connection.Close()
				header := make([]byte, 2)
				if _, err := io.ReadFull(connection, header); err != nil {
					return
				}
				request := make([]byte, binary.BigEndian.Uint16(header))
				if _, err := io.ReadFull(connection, request); err != nil {
					return
				}
				tcpQueries.Add(1)
				reply := answer(request)
				binary.BigEndian.PutUint16(header, uint16(len(reply)))
				writeAll(connection, append(header, reply...))
			}()
		}
	}()
	go func() {
		for {
			buffer := make([]byte, 65535)
			length, remote, err := udp.ReadFrom(buffer)
			if err != nil {
				return
			}
			udp.WriteTo(udpReply(buffer[:length]), remote)
		}
	}()
	return listener.Addr().String(), tcpQueries
}

func TestExchangePreservesRequestAndSupportsTCP(test *testing.T) {
	target, _ := testResolver(test, answer)
	request, err := query("custom.example", 42)
	if err != nil {
		test.Fatal(err)
	}
	for _, tcp := range []bool{false, true} {
		reply, err := exchange(target, request, tcp, 0)
		if err != nil {
			test.Fatal(err)
		}
		if string(reply[12:len(request)]) != string(request[12:]) {
			test.Fatal("question changed")
		}
		if binary.BigEndian.Uint16(reply[6:8]) != 1 {
			test.Fatal("answer missing")
		}
		if binary.BigEndian.Uint16(request) != 42 || request[2] != 1 {
			test.Fatal("request mutated")
		}
	}
	if err := check(target, "custom.example", false); err != nil {
		test.Fatal(err)
	}
}

func TestUDPTruncationRetriesOverTCP(test *testing.T) {
	target, count := testResolver(test, func(request []byte) []byte {
		reply := append([]byte(nil), request...)
		reply[2] = 0x83
		return reply
	})
	request, _ := query("large.example", 77)
	reply, err := exchange(target, request, false, 0)
	if err != nil {
		test.Fatal(err)
	}
	if count.Load() != 1 || reply[2]&2 != 0 || binary.BigEndian.Uint16(reply[6:8]) != 1 {
		test.Fatal("TCP retry failed")
	}
}

func TestRejectsMismatchedReply(test *testing.T) {
	target, _ := testResolver(test, func(request []byte) []byte { reply := answer(request); reply[0] ^= 1; return reply })
	request, _ := query("example.com", 8)
	if _, err := exchange(target, request, false, 0); err == nil {
		test.Fatal("accepted another transaction")
	}
}

func TestReplyCopiesFirstQuestion(test *testing.T) {
	request, _ := query("MixedCase.example", 42)
	question := append([]byte(nil), request[12:]...)
	request[2] = 0x10 | 1
	request[5], request[7], request[9], request[11] = 2, 1, 1, 1
	request = append(request, 0, 0, 28, 0, 1)
	for _, response := range [][]byte{reply(request, rcodeRefused), failure(request)} {
		if !bytes.Equal(response[12:], question) {
			test.Fatalf("question = %x, want %x", response[12:], question)
		}
		if !bytes.Equal(response[:3], []byte{0, 42, 0x91}) || !bytes.Equal(response[4:12], []byte{0, 1, 0, 0, 0, 0, 0, 0}) {
			test.Fatalf("unexpected reply header %x", response[:12])
		}
	}
	if response := failure(request[:12+len(question)-1]); len(response) != 12 ||
		!bytes.Equal(response[4:], make([]byte, 8)) || rcode(response) != rcodeServerFailure {
		test.Fatalf("expected header-only SERVFAIL for truncated question, got %x", response)
	}
}

func TestInspectUsesLocalPeerAndActualPrefix(test *testing.T) {
	input := `{"peers":{"details":[{"netbirdIp":"100.64.1.2/16"}]},"daemonStatus":"Connected","netbirdIp":"10.99.1.2/16","fqdn":"phone.custom","usesKernelInterface":false,"dnsServers":[{"servers":["223.5.5.5:53","[2001:4860:4860::8888]:53"]}]}`
	lines, err := inspect(strings.NewReader(input))
	if err != nil {
		test.Fatal(err)
	}
	if lines[0] != "target\t10.99.255.254:53" {
		test.Fatalf("wrong local endpoint: %v", lines)
	}
	if len(lines) != 7 || lines[3] != "catchall\t0" || lines[4] != "zone\tcustom" {
		test.Fatal(lines)
	}
	for _, invalid := range []string{
		`{"daemonStatus":"Disconnected"}`,
		`{"daemonStatus":"Connected","netbirdIp":"10.0.0.1/32"}`,
		`{"daemonStatus":"Connected","netbirdIp":"10.0.0.1/16","fqdn":"local.example","dnsServers":[{"servers":["; touch unsafe"]}]}`,
	} {
		if _, err := inspect(strings.NewReader(invalid)); err == nil {
			test.Fatalf("accepted %s", invalid)
		}
	}
}

func TestQueryNameValidation(test *testing.T) {
	for _, name := range []string{"", ".", "a..b", strings.Repeat("x", 64) + ".example"} {
		if _, err := query(name, 1); err == nil {
			test.Fatalf("accepted %q", name)
		}
	}
}

func attribute(kind uint16, payload []byte) []byte {
	data := make([]byte, (len(payload)+7)&^3)
	binary.NativeEndian.PutUint16(data, uint16(len(payload)+4))
	binary.NativeEndian.PutUint16(data[2:], kind)
	copy(data[4:], payload)
	return data
}

func conntrackFixture(host string, port uint16) []byte {
	originalProtocol := append(attribute(1, []byte{17}), attribute(3, []byte{0, 53})...)
	original := attribute(2, originalProtocol)
	address := netip.MustParseAddr(host)
	addressKind := uint16(1)
	if address.Is6() {
		addressKind = 3
	}
	ipFields := attribute(addressKind, address.AsSlice())
	sourcePort := make([]byte, 2)
	binary.BigEndian.PutUint16(sourcePort, port)
	reply := append(attribute(1, ipFields), attribute(2, attribute(2, sourcePort))...)
	return append(attribute(1, original), attribute(2, reply)...)
}

func TestConntrackCleanupOnlySelectsModuleNAT(test *testing.T) {
	for _, host := range []string{"127.0.0.1", "::1"} {
		if ownedTuple(conntrackFixture(host, listenPort)) == nil {
			test.Fatal("module tuple missed", host)
		}
	}
	for _, fixture := range []struct {
		host string
		port uint16
	}{{"127.0.0.1", 53}, {"127.0.0.2", listenPort}, {"10.99.255.254", 53}, {"2001:db8::1", listenPort}} {
		if ownedTuple(conntrackFixture(fixture.host, fixture.port)) != nil {
			test.Fatal("selected another resolver", fixture)
		}
	}
	for _, malformed := range [][]byte{nil, {0, 0, 1, 0}, {255, 255, 1, 0}, {5, 0, 1, 0, 1}} {
		if ownedTuple(malformed) != nil {
			test.Fatal("selected malformed tuple")
		}
	}
}

func TestInspectDetectsCatchAllGroup(test *testing.T) {
	for input, want := range map[string]string{
		`{"daemonStatus":"Connected","netbirdIp":"10.0.0.1/16","fqdn":"local.example","dnsServers":[]}`:                                                                       "catchall\t0",
		`{"daemonStatus":"Connected","netbirdIp":"10.0.0.1/16","fqdn":"local.example","dnsServers":[{"servers":["1.1.1.1:53"],"domains":[],"enabled":true}]}`:                 "catchall\t1",
		`{"daemonStatus":"Connected","netbirdIp":"10.0.0.1/16","fqdn":"local.example","dnsServers":[{"servers":["1.1.1.1:53"],"domains":[],"enabled":false}]}`:                "catchall\t0",
		`{"daemonStatus":"Connected","netbirdIp":"10.0.0.1/16","fqdn":"local.example","dnsServers":[{"servers":["10.0.0.53:53"],"domains":["corp.example"],"enabled":true}]}`: "catchall\t0",
	} {
		lines, err := inspect(strings.NewReader(input))
		if err != nil {
			test.Fatal(err)
		}
		if lines[3] != want {
			test.Fatalf("%s: %v", input, lines)
		}
	}
}

type fakeExchange struct {
	codes   map[string]byte
	fail    map[string]bool
	targets []string
	marks   []uint32
}

func (f *fakeExchange) exchange(target string, request []byte, tcp bool, mark uint32) ([]byte, error) {
	f.targets = append(f.targets, target)
	f.marks = append(f.marks, mark)
	if f.fail[target] {
		return nil, io.ErrUnexpectedEOF
	}
	return reply(request, f.codes[target]), nil
}

func resolverFixture(codes map[string]byte, fail map[string]bool, original string, mark uint32) (*resolver, *fakeExchange) {
	fake := &fakeExchange{codes: codes, fail: fail}
	lookup := func(origin) (netip.AddrPort, uint32, error) {
		if original == "" {
			return netip.AddrPort{}, 0, io.EOF
		}
		return netip.MustParseAddrPort(original), mark, nil
	}
	return newResolver(netip.MustParseAddrPort("10.99.255.254:53"), lookup, fake.exchange), fake
}

func TestResolverFallsBackOnlyWhenNetBirdRefuses(test *testing.T) {
	request, _ := query("router.lan", 9)
	source := origin{client: netip.MustParseAddrPort("192.0.2.10:4000"), local: netip.MustParseAddrPort("127.0.0.1:5354")}
	for _, item := range []struct {
		netbird byte
		want    byte
		calls   int
	}{{0, 0, 1}, {3, 3, 1}, {rcodeServerFailure, rcodeServerFailure, 1}, {rcodeRefused, 0, 2}} {
		dns, fake := resolverFixture(map[string]byte{"10.99.255.254:53": item.netbird, "192.0.2.1:53": 0}, nil, "192.0.2.1:53", 0x10064)
		response := dns.answer(request, source)
		if rcode(response) != item.want || len(fake.targets) != item.calls {
			test.Fatalf("netbird rcode %d: got %d after %v", item.netbird, rcode(response), fake.targets)
		}
		if fake.marks[0] != helperMark {
			test.Fatal("NetBird query lacks the helper mark")
		}
		if item.calls == 2 && fake.marks[1] != 0x10064|protectedFromVPN|helperMark {
			test.Fatalf("fallback mark %#x", fake.marks[1])
		}
	}
}

func TestResolverFailsOpenWhenNetBirdIsUnreachable(test *testing.T) {
	request, _ := query("example.com", 10)
	source := origin{client: netip.MustParseAddrPort("192.0.2.10:4000"), local: netip.MustParseAddrPort("127.0.0.1:5354")}
	dns, fake := resolverFixture(map[string]byte{"192.0.2.1:53": 0}, map[string]bool{"10.99.255.254:53": true}, "192.0.2.1:53", 0)
	if rcode(dns.answer(request, source)) != 0 || len(fake.targets) != 2 {
		test.Fatal("unreachable NetBird did not fall back", fake.targets)
	}
	dns.healthy.Store(false)
	fake.targets = nil
	if rcode(dns.answer(request, source)) != 0 || len(fake.targets) != 1 || fake.targets[0] != "192.0.2.1:53" {
		test.Fatal("degraded helper still waited for NetBird", fake.targets)
	}
}

func TestResolverNeverFallsBackToItselfOrLoopback(test *testing.T) {
	request, _ := query("example.com", 11)
	source := origin{client: netip.MustParseAddrPort("127.0.0.1:4000"), local: netip.MustParseAddrPort("127.0.0.1:5354")}
	for _, original := range []string{"", "127.0.0.1:5354", "[::1]:53", "10.99.255.254:53"} {
		dns, fake := resolverFixture(map[string]byte{"10.99.255.254:53": rcodeRefused}, nil, original, 0)
		if rcode(dns.answer(request, source)) != rcodeRefused || len(fake.targets) != 1 {
			test.Fatalf("%q: unexpected fallback %v", original, fake.targets)
		}
	}
	dns, fake := resolverFixture(nil, map[string]bool{"10.99.255.254:53": true}, "", 0)
	if rcode(dns.answer(request, source)) != rcodeServerFailure || len(fake.targets) != 1 {
		test.Fatal("expected SERVFAIL without a fallback destination", fake.targets)
	}
}

func TestResolverFallbackLinkLocalZone(test *testing.T) {
	request, _ := query("example.com", 12)
	for _, item := range []struct {
		original string
		local    string
		want     string
	}{
		{"[fe80::53%original]:53", "[fe80::53%local]:53", "[fe80::53%original]:53"},
		{"[fe80::53]:53", "[fe80::53%local]:53", "[fe80::53%local]:53"},
		{"[fe80::53]:53", "[fe80::53]:53", "[fe80::53%client]:53"},
		{"[fe80::53]:53", "[fe80::99%local]:53", "[fe80::53%client]:53"},
		{"[2001:db8::53]:53", "[::1]:5354", "[2001:db8::53]:53"},
	} {
		source := origin{client: netip.MustParseAddrPort("[fe80::2%client]:4000"), local: netip.MustParseAddrPort(item.local)}
		dns, fake := resolverFixture(nil, nil, item.original, 0)
		if dns.fallback(request, source) == nil || len(fake.targets) != 1 || fake.targets[0] != item.want {
			test.Fatalf("original %s, local %s: got %v, want %s", item.original, item.local, fake.targets, item.want)
		}
	}
}

func TestProbeIsAnsweredLocally(test *testing.T) {
	request, _ := query(probeName, 12)
	dns, fake := resolverFixture(nil, nil, "", 0)
	response := dns.answer(request, origin{})
	if !validReply(request, response) || len(fake.targets) != 0 {
		test.Fatal("probe left the helper")
	}
	other, _ := query("nb-dns-probe.example", 13)
	if isProbe(other) {
		test.Fatal("matched another name")
	}
}

func TestConntrackLookupKeyAndEntry(test *testing.T) {
	nat := origin{client: netip.MustParseAddrPort("192.0.2.10:4000"), local: netip.MustParseAddrPort("127.0.0.1:5354")}
	direction, from, to, protocol := lookupKey(nat)
	if direction != tupleReply || from != nat.local || to != nat.client || protocol != 17 {
		test.Fatal("NAT key", direction, from, to, protocol)
	}
	tproxy := origin{tcp: true, client: netip.MustParseAddrPort("[2001:db8::2]:4000"), local: netip.MustParseAddrPort("[2001:db8::53]:53")}
	direction, from, to, protocol = lookupKey(tproxy)
	if direction != tupleOriginal || from != tproxy.client || to != tproxy.local || protocol != 6 {
		test.Fatal("TPROXY key", direction, from, to, protocol)
	}
	for _, destination := range []string{"192.0.2.1:53", "[2001:db8:1::1]:53"} {
		original := netip.MustParseAddrPort(destination)
		client := netip.MustParseAddrPort("192.0.2.10:4000")
		if original.Addr().Is6() {
			client = netip.MustParseAddrPort("[2001:db8:1::2]:4000")
		}
		entry := append(encodeTuple(tupleOriginal, 17, client, original), encodeAttribute(conntrackMark, binary.BigEndian.AppendUint32(nil, 0x10064))...)
		parsed, mark, err := parseEntry(entry)
		if err != nil || parsed != original || mark != 0x10064 {
			test.Fatal(parsed, mark, err)
		}
	}
	if _, _, err := parseEntry(nil); err == nil {
		test.Fatal("accepted empty entry")
	}
}

func TestNetworkEventsIgnoreModuleRules(test *testing.T) {
	rule := func(priority uint32) []byte {
		return append(make([]byte, ruleHeaderSize), encodeAttribute(rulePriority, binary.NativeEndian.AppendUint32(nil, priority))...)
	}
	if !networkEventRelevant(routeNewRule, rule(22000)) || !networkEventRelevant(routeNewLink, nil) {
		test.Fatal("missed Android network change")
	}
	wireless := append(make([]byte, linkHeaderSize), encodeAttribute(linkWireless, []byte{1, 2, 3, 4})...)
	if networkEventRelevant(routeNewLink, wireless) {
		test.Fatal("reacted to a wireless driver event")
	}
	if !networkEventRelevant(routeNewLink, append(make([]byte, linkHeaderSize), encodeAttribute(3, []byte("wlan0\x00"))...)) {
		test.Fatal("missed a link change")
	}
	if networkEventRelevant(routeNewRule, rule(84)) || networkEventRelevant(routeDelRule, rule(85)) || networkEventRelevant(24, nil) {
		test.Fatal("reacted to module or route noise")
	}
}

func TestInspectListsNetBirdZones(test *testing.T) {
	input := `{"daemonStatus":"Connected","netbirdIp":"10.0.0.1/16","fqdn":"phone.Peers.Example.","dnsServers":[{"servers":["1.1.1.1:53"],"domains":[],"enabled":true},{"servers":["10.0.0.53:53"],"domains":["corp.example","peers.example","."],"enabled":true}]}`
	lines, err := inspect(strings.NewReader(input))
	if err != nil {
		test.Fatal(err)
	}
	zones := []string{}
	for _, line := range lines {
		if value, found := strings.CutPrefix(line, "zone\t"); found {
			zones = append(zones, value)
		}
	}
	if strings.Join(zones, ",") != "corp.example,peers.example" {
		test.Fatal(zones)
	}
}

func TestUnreachableNetBirdKeepsKnownZonesPrivate(test *testing.T) {
	source := origin{client: netip.MustParseAddrPort("192.0.2.10:4000"), local: netip.MustParseAddrPort("127.0.0.1:5354")}
	dns, fake := resolverFixture(map[string]byte{"192.0.2.1:53": 0}, map[string]bool{"10.99.255.254:53": true}, "192.0.2.1:53", 0)
	dns.zones = []string{"peers.example", "corp.example"}
	for _, name := range []string{"phone.peers.example", "PEERS.example", "db.corp.example"} {
		fake.targets = nil
		request, _ := query(name, 14)
		if rcode(dns.answer(request, source)) != rcodeServerFailure || len(fake.targets) != 1 {
			test.Fatalf("%s left NetBird while it was unreachable: %v", name, fake.targets)
		}
	}
	for _, name := range []string{"example.com", "notpeers.example"} {
		fake.targets = nil
		request, _ := query(name, 15)
		if rcode(dns.answer(request, source)) != 0 || len(fake.targets) != 2 {
			test.Fatalf("%s did not fail open: %v", name, fake.targets)
		}
	}
	// Reachable NetBird refusing a name keeps the normal fallback.
	dns, fake = resolverFixture(map[string]byte{"10.99.255.254:53": rcodeRefused, "192.0.2.1:53": 0}, nil, "192.0.2.1:53", 0)
	dns.zones = []string{"peers.example"}
	request, _ := query("other.peers.example", 16)
	if rcode(dns.answer(request, source)) != 0 || len(fake.targets) != 2 {
		test.Fatal("REFUSED from a reachable NetBird must fall back", fake.targets)
	}
}
