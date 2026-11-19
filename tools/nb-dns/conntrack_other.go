//go:build !linux

package main

import (
	"errors"
	"net/netip"
)

func cleanConnections(remove bool) error {
	return errors.New("conntrack requires Linux")
}

func lookupOrigin(origin) (netip.AddrPort, uint32, error) {
	return netip.AddrPort{}, 0, errors.New("conntrack requires Linux")
}
