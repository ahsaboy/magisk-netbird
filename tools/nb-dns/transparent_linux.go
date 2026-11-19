package main

import (
	"context"
	"encoding/binary"
	"errors"
	"net"
	"strconv"
	"syscall"
)

const (
	ipv6Transparent         = 75
	ipv6OriginalDestination = 74
)

func transparentControl(network, address string, connection syscall.RawConn) error {
	var socketError error
	err := connection.Control(func(descriptor uintptr) {
		socketError = syscall.SetsockoptInt(int(descriptor), syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1)
		if socketError == nil {
			socketError = syscall.SetsockoptInt(int(descriptor), syscall.IPPROTO_IPV6, ipv6Transparent, 1)
		}
		if socketError == nil {
			socketError = syscall.SetsockoptInt(int(descriptor), syscall.IPPROTO_IPV6, ipv6OriginalDestination, 1)
		}
	})
	if err != nil {
		return err
	}
	return socketError
}

func transparentListeners(endpoint string) (net.PacketConn, net.Listener, error) {
	configuration := net.ListenConfig{Control: transparentControl}
	udp, err := configuration.ListenPacket(context.Background(), "udp6", endpoint)
	if err != nil {
		return nil, nil, err
	}
	tcp, err := configuration.Listen(context.Background(), "tcp6", endpoint)
	if err != nil {
		udp.Close()
		return nil, nil, err
	}
	return udp, tcp, nil
}

func originalDestination(control []byte) (*net.UDPAddr, error) {
	messages, err := syscall.ParseSocketControlMessage(control)
	if err != nil {
		return nil, err
	}
	for _, message := range messages {
		if message.Header.Level == syscall.IPPROTO_IPV6 && message.Header.Type == ipv6OriginalDestination && len(message.Data) >= 28 {
			address := &net.UDPAddr{IP: append(net.IP(nil), message.Data[8:24]...), Port: int(binary.BigEndian.Uint16(message.Data[2:4]))}
			if scope := binary.NativeEndian.Uint32(message.Data[24:28]); scope != 0 {
				if iface, err := net.InterfaceByIndex(int(scope)); err == nil {
					address.Zone = iface.Name
				} else {
					address.Zone = strconv.FormatUint(uint64(scope), 10)
				}
			}
			return address, nil
		}
	}
	return nil, errors.New("original IPv6 DNS destination unavailable")
}

func readPacket(connection net.PacketConn, buffer []byte) (int, net.Addr, *net.UDPAddr, error) {
	udp, ok := connection.(*net.UDPConn)
	if !ok {
		return 0, nil, nil, errors.New("UDP connection required")
	}
	control := make([]byte, 256)
	length, controlLength, _, remote, err := udp.ReadMsgUDP(buffer, control)
	if err != nil {
		return 0, nil, nil, err
	}
	if controlLength == 0 {
		return length, remote, nil, nil
	}
	original, err := originalDestination(control[:controlLength])
	return length, remote, original, err
}

func writePacket(connection net.PacketConn, reply []byte, remote net.Addr, original *net.UDPAddr) error {
	if original == nil || original.Port == listenPort {
		_, err := connection.WriteTo(reply, remote)
		return err
	}
	configuration := net.ListenConfig{Control: transparentControl}
	sender, err := configuration.ListenPacket(context.Background(), "udp6", original.String())
	if err != nil {
		return err
	}
	defer sender.Close()
	_, err = sender.WriteTo(reply, remote)
	return err
}
