package main

import (
	"encoding/binary"
	"net"
	"syscall"
	"testing"
	"unsafe"
)

func TestOriginalIPv6Destination(test *testing.T) {
	control := make([]byte, syscall.CmsgSpace(28))
	header := (*syscall.Cmsghdr)(unsafe.Pointer(&control[0]))
	header.Level = syscall.IPPROTO_IPV6
	header.Type = ipv6OriginalDestination
	header.SetLen(syscall.CmsgLen(28))
	address := control[syscall.CmsgLen(0):]
	binary.BigEndian.PutUint16(address[2:], 53)
	copy(address[8:24], net.ParseIP("2001:db8::53").To16())
	destination, err := originalDestination(control)
	if err != nil {
		test.Fatal(err)
	}
	if destination.String() != "[2001:db8::53]:53" {
		test.Fatal(destination)
	}
	if _, err := originalDestination(nil); err == nil {
		test.Fatal("missing destination accepted")
	}
}
