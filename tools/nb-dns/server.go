package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"
)

const listenPort = 5354

type config struct {
	Target string   `json:"target"`
	Name   string   `json:"name"`
	State  string   `json:"state"`
	Sync   string   `json:"sync"`
	Zones  []string `json:"zones"`
}

func loadConfig(path string) (config, netip.AddrPort, error) {
	var configuration config
	data, err := os.ReadFile(path)
	if err != nil {
		return configuration, netip.AddrPort{}, err
	}
	if err = json.Unmarshal(data, &configuration); err != nil {
		return configuration, netip.AddrPort{}, err
	}
	target, err := netip.ParseAddrPort(configuration.Target)
	if err != nil {
		return configuration, netip.AddrPort{}, err
	}
	if _, err = query(configuration.Name, 0); err != nil {
		return configuration, netip.AddrPort{}, err
	}
	if !filepath.IsAbs(configuration.State) || (configuration.Sync != "" && !filepath.IsAbs(configuration.Sync)) {
		return configuration, netip.AddrPort{}, errors.New("state and sync paths must be absolute")
	}
	return configuration, target, nil
}

func writeState(directory, name, value string) {
	temporary := filepath.Join(directory, "."+name+".tmp")
	if err := os.WriteFile(temporary, []byte(value+"\n"), 0o600); err == nil {
		os.Rename(temporary, filepath.Join(directory, name))
	}
}

func addrPort(address net.Addr) netip.AddrPort {
	switch value := address.(type) {
	case *net.UDPAddr:
		return value.AddrPort()
	case *net.TCPAddr:
		return value.AddrPort()
	}
	return netip.AddrPort{}
}

// listen opens the IPv4 listeners (required) and the best available IPv6
// listener: transparent for TPROXY, plain for NAT, or none.
func listen() ([][2]io.Closer, string, error) {
	var pairs [][2]io.Closer
	udp, err := net.ListenPacket("udp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(listenPort)))
	if err != nil {
		return nil, "", err
	}
	tcp, err := net.Listen("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(listenPort)))
	if err != nil {
		udp.Close()
		return nil, "", err
	}
	pairs = append(pairs, [2]io.Closer{udp, tcp})
	endpoint := net.JoinHostPort("::1", strconv.Itoa(listenPort))
	mode := "transparent"
	udp6, tcp6, err := transparentListeners(endpoint)
	if err != nil {
		mode = "plain"
		udp6, err = net.ListenPacket("udp6", endpoint)
		if err == nil {
			if tcp6, err = net.Listen("tcp6", endpoint); err != nil {
				udp6.Close()
			}
		}
	}
	if err != nil {
		return pairs, "none", nil
	}
	return append(pairs, [2]io.Closer{udp6, tcp6}), mode, nil
}

func serve(path string) error {
	configuration, target, err := loadConfig(path)
	if err != nil {
		return err
	}
	pairs, mode, err := listen()
	if err != nil {
		return err
	}
	defer func() {
		for _, pair := range pairs {
			pair[0].Close()
			pair[1].Close()
		}
	}()
	dns := newResolver(target, lookupOrigin, exchange)
	dns.zones = configuration.Zones
	limit := make(chan struct{}, 128)
	for _, pair := range pairs {
		go serveUDP(pair[0].(net.PacketConn), dns, limit)
		go serveTCP(pair[1].(net.Listener), dns, limit)
	}
	writeState(configuration.State, "listeners", mode)
	if configuration.Sync != "" {
		go watchNetwork(configuration.Sync)
	}
	stopped := make(chan os.Signal, 1)
	signal.Notify(stopped, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(stopped)
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	failures := 0
	state := ""
	for {
		// A failing NetBird resolver switches the helper to pass-through
		// instead of exiting: the redirect rules keep a working listener.
		if check(configuration.Target, configuration.Name, true) == nil {
			failures = 0
			dns.healthy.Store(true)
		} else if failures++; failures >= unhealthyAttempts {
			dns.healthy.Store(false)
		}
		next := "ok"
		if !dns.healthy.Load() {
			next = "degraded"
		}
		if next != state {
			writeState(configuration.State, "health", next)
			state = next
		}
		select {
		case <-stopped:
			return nil
		case <-ticker.C:
		}
	}
}

func transient(err error) bool {
	if errors.Is(err, net.ErrClosed) {
		return false
	}
	time.Sleep(10 * time.Millisecond)
	return true
}

func serveUDP(connection net.PacketConn, dns *resolver, limit chan struct{}) {
	local := addrPort(connection.LocalAddr())
	for {
		buffer := make([]byte, 65535)
		length, remote, original, err := readPacket(connection, buffer)
		if err != nil {
			if length > 0 || transient(err) {
				continue
			}
			return
		}
		request := buffer[:length]
		source := origin{client: addrPort(remote), local: local}
		if original != nil {
			source.local = original.AddrPort()
		}
		select {
		case limit <- struct{}{}:
		default:
			writePacket(connection, failure(request), remote, original)
			continue
		}
		go func() {
			defer func() { <-limit }()
			if response := dns.answer(request, source); response != nil {
				writePacket(connection, fitUDP(request, response), remote, original)
			}
		}()
	}
}

func serveTCP(listener net.Listener, dns *resolver, limit chan struct{}) {
	for {
		connection, err := listener.Accept()
		if err != nil {
			if transient(err) {
				continue
			}
			return
		}
		select {
		case limit <- struct{}{}:
		default:
			connection.Close()
			continue
		}
		go func() {
			defer func() { <-limit }()
			defer connection.Close()
			source := origin{tcp: true, client: addrPort(connection.RemoteAddr()), local: addrPort(connection.LocalAddr())}
			for {
				connection.SetDeadline(time.Now().Add(10 * time.Second))
				header := make([]byte, 2)
				if _, err := io.ReadFull(connection, header); err != nil {
					return
				}
				request := make([]byte, binary.BigEndian.Uint16(header))
				if _, err := io.ReadFull(connection, request); err != nil {
					return
				}
				response := dns.answer(request, source)
				if response == nil {
					return
				}
				binary.BigEndian.PutUint16(header, uint16(len(response)))
				if err := writeAll(connection, append(header, response...)); err != nil {
					return
				}
			}
		}()
	}
}
