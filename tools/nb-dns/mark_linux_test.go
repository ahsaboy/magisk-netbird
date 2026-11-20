package main

import (
	"context"
	"errors"
	"net"
	"syscall"
	"testing"
)

// SO_MARK needs CAP_NET_ADMIN, so these run only as root.
func TestHelperMarkIsSet(test *testing.T) {
	configuration := net.ListenConfig{Control: markControl(helperMark)}
	connection, err := configuration.ListenPacket(context.Background(), "udp4", "127.0.0.1:0")
	if errors.Is(err, syscall.EPERM) {
		test.Skip("SO_MARK needs CAP_NET_ADMIN")
	}
	if err != nil {
		test.Fatal(err)
	}
	defer connection.Close()
	raw, err := connection.(*net.UDPConn).SyscallConn()
	if err != nil {
		test.Fatal(err)
	}
	var mark int
	raw.Control(func(descriptor uintptr) {
		mark, err = syscall.GetsockoptInt(int(descriptor), syscall.SOL_SOCKET, syscall.SO_MARK)
	})
	if err != nil || mark != helperMark {
		test.Fatalf("mark = %#x, %v", mark, err)
	}
	target, _ := testResolver(test, answer)
	if err := check(target, "custom.example", false); err != nil {
		test.Fatal(err)
	}
}
