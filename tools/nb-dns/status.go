package main

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"sort"
	"strings"
)

type serverGroup struct {
	Servers []string `json:"servers"`
	Domains []string `json:"domains"`
	Enabled bool     `json:"enabled"`
}

type clientStatus struct {
	State   string        `json:"daemonStatus"`
	IP      string        `json:"netbirdIp"`
	FQDN    string        `json:"fqdn"`
	Kernel  bool          `json:"usesKernelInterface"`
	Profile string        `json:"profileName"`
	Servers []serverGroup `json:"dnsServers"`
}

// netbirdZones lists the suffixes NetBird is known to own: the peer domain
// and every match domain. Custom zones are not part of the status output.
func netbirdZones(status clientStatus) []string {
	seen := map[string]bool{}
	var zones []string
	add := func(name string) {
		name = strings.ToLower(strings.Trim(name, "."))
		if name == "" || seen[name] {
			return
		}
		if _, err := query(name, 0); err == nil {
			seen[name] = true
			zones = append(zones, name)
		}
	}
	if _, parent, found := strings.Cut(strings.Trim(status.FQDN, "."), "."); found {
		add(parent)
	}
	for _, group := range status.Servers {
		for _, domain := range group.Domains {
			if domain != "." {
				add(domain)
			}
		}
	}
	sort.Strings(zones)
	return zones
}

func inspect(reader io.Reader) ([]string, error) {
	var status clientStatus
	if err := json.NewDecoder(io.LimitReader(reader, 16<<20)).Decode(&status); err != nil {
		return nil, err
	}
	if status.State != "Connected" {
		return nil, errors.New("disconnected")
	}
	prefix, err := netip.ParsePrefix(status.IP)
	if err != nil || !prefix.Addr().Is4() || prefix.Bits() > 30 {
		return nil, errors.New("unsupported overlay")
	}
	address := prefix.Masked().Addr().As4()
	last := binary.BigEndian.Uint32(address[:]) | (uint32(0xffffffff) >> prefix.Bits())
	binary.BigEndian.PutUint32(address[:], last-1)
	target := net.JoinHostPort(netip.AddrFrom4(address).String(), "53")
	if status.Kernel {
		target = net.JoinHostPort(prefix.Addr().String(), "53")
	}
	if _, err = query(status.FQDN, 0); err != nil {
		return nil, err
	}
	lines := []string{"target\t" + target, "name\t" + status.FQDN, fmt.Sprintf("profile\t%x", sha256.Sum256([]byte(status.Profile)))}
	// Without an enabled catch-all group NetBird answers REFUSED for public
	// names and the helper falls back to the client's original resolver.
	catchAll := "0"
	seen := map[string]bool{}
	var upstreams []string
	for _, group := range status.Servers {
		if group.Enabled && (len(group.Domains) == 0 || len(group.Domains) == 1 && group.Domains[0] == ".") {
			catchAll = "1"
		}
		for _, server := range group.Servers {
			endpoint, err := netip.ParseAddrPort(server)
			if err != nil || endpoint.Port() == 0 || endpoint.Addr().IsUnspecified() || endpoint.Addr().IsMulticast() {
				return nil, errors.New("invalid nameserver")
			}
			if !seen[server] {
				upstreams = append(upstreams, server)
				seen[server] = true
			}
		}
	}
	lines = append(lines, "catchall\t"+catchAll)
	for _, zone := range netbirdZones(status) {
		lines = append(lines, "zone\t"+zone)
	}
	sort.Strings(upstreams)
	for _, upstream := range upstreams {
		lines = append(lines, "upstream\t"+upstream)
	}
	return lines, nil
}
