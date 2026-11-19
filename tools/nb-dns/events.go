package main

import "encoding/binary"

// rtnetlink message types and attributes (linux/rtnetlink.h, fib_rules.h).
const (
	routeNewLink   = 16
	routeDelLink   = 17
	routeNewRule   = 32
	routeDelRule   = 33
	ruleHeaderSize = 12
	rulePriority   = 6
	linkHeaderSize = 16
	linkWireless   = 11
)

// networkEventRelevant reports link and policy-rule changes that may move
// Android's default network or a VPN. The module's own rules are ignored so
// that applying them does not trigger another reconcile.
func networkEventRelevant(kind uint16, data []byte) bool {
	switch kind {
	case routeNewLink, routeDelLink:
		// Wireless drivers report scan and association events as RTM_NEWLINK
		// with IFLA_WIRELESS; those do not change routing.
		if len(data) >= linkHeaderSize {
			if _, wireless := attributes(data[linkHeaderSize:])[linkWireless]; wireless {
				return false
			}
		}
		return true
	case routeNewRule, routeDelRule:
		if len(data) < ruleHeaderSize {
			return false
		}
		priority := attributes(data[ruleHeaderSize:])[rulePriority]
		if len(priority) == 4 {
			switch binary.NativeEndian.Uint32(priority) {
			case 84, 85:
				return false
			}
		}
		return true
	}
	return false
}
