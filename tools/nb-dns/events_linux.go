package main

import (
	"os/exec"
	"syscall"
	"time"
)

// RTNLGRP_LINK, RTNLGRP_IPV4_RULE and RTNLGRP_IPV6_RULE as bind() group bits.
const networkGroups = 1<<(1-1) | 1<<(8-1) | 1<<(19-1)

const minimumSyncInterval = 10 * time.Second

// watchNetwork runs `dns.sh sync` shortly after Android changes networks or
// VPNs, instead of waiting for the next watcher heartbeat.
func watchNetwork(syncPath string) {
	descriptor, err := syscall.Socket(syscall.AF_NETLINK, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC, syscall.NETLINK_ROUTE)
	if err != nil {
		return
	}
	defer syscall.Close(descriptor)
	if err = syscall.Bind(descriptor, &syscall.SockaddrNetlink{Family: syscall.AF_NETLINK, Groups: networkGroups}); err != nil {
		return
	}
	events := make(chan struct{}, 1)
	go func() {
		buffer := make([]byte, 1<<16)
		for {
			length, _, err := syscall.Recvfrom(descriptor, buffer, 0)
			if err != nil {
				if err == syscall.EINTR || err == syscall.ENOBUFS {
					continue
				}
				close(events)
				return
			}
			messages, err := syscall.ParseNetlinkMessage(buffer[:length])
			if err != nil {
				continue
			}
			for _, message := range messages {
				if networkEventRelevant(message.Header.Type, message.Data) {
					select {
					case events <- struct{}{}:
					default:
					}
					break
				}
			}
		}
	}()
	var last time.Time
	for range events {
		// Let Android finish switching before reconciling once, and never
		// reconcile more than once per minimumSyncInterval.
		delay := 2 * time.Second
		if wait := time.Until(last.Add(minimumSyncInterval)); wait > delay {
			delay = wait
		}
		settle := time.NewTimer(delay)
	drain:
		for {
			select {
			case _, open := <-events:
				if !open {
					settle.Stop()
					return
				}
				if !last.IsZero() && time.Until(last.Add(minimumSyncInterval)) > 2*time.Second {
					continue
				}
				settle.Reset(2 * time.Second)
			case <-settle.C:
				break drain
			}
		}
		exec.Command(syncPath, "sync").Run()
		last = time.Now()
	}
}
