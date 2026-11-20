package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
)

func run(arguments []string) error {
	if len(arguments) == 1 && arguments[0] == "inspect" {
		lines, err := inspect(os.Stdin)
		if err != nil {
			return err
		}
		for _, line := range lines {
			fmt.Println(line)
		}
		return nil
	}
	if len(arguments) >= 5 && arguments[0] == "config" {
		if _, err := netip.ParseAddrPort(arguments[1]); err != nil {
			return err
		}
		if _, err := query(arguments[2], 0); err != nil {
			return err
		}
		if !filepath.IsAbs(arguments[3]) || !filepath.IsAbs(arguments[4]) {
			return errors.New("state and sync paths must be absolute")
		}
		for _, zone := range arguments[5:] {
			if _, err := query(zone, 0); err != nil {
				return err
			}
		}
		return json.NewEncoder(os.Stdout).Encode(config{Target: arguments[1], Name: arguments[2], State: arguments[3], Sync: arguments[4], Zones: arguments[5:]})
	}
	if len(arguments) == 3 && arguments[0] == "check" {
		return check(arguments[1], arguments[2], false)
	}
	if len(arguments) == 2 && arguments[0] == "probe" {
		return probe(arguments[1])
	}
	if len(arguments) == 2 && arguments[0] == "serve" {
		return serve(arguments[1])
	}
	if len(arguments) == 1 && arguments[0] == "conntrack-check" {
		return cleanConnections(false)
	}
	if len(arguments) == 1 && arguments[0] == "cleanup" {
		return cleanConnections(true)
	}
	if len(arguments) == 2 && arguments[0] == "endpoint" {
		endpoint, err := netip.ParseAddrPort(arguments[1])
		if err != nil {
			return err
		}
		family := "4"
		if endpoint.Addr().Is6() {
			family = "6"
		}
		fmt.Printf("%s\t%s\t%d\n", family, endpoint.Addr(), endpoint.Port())
		return nil
	}
	return errors.New("usage: nb-dns {inspect|config IP:PORT NAME STATE-DIR SYNC [ZONE...]|check IP:PORT NAME|probe IP:PORT|serve CONFIG|conntrack-check|cleanup|endpoint IP:PORT}")
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
