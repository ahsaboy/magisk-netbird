//go:build !linux

package main

import (
	"net"
)

func transparentListeners(endpoint string) (net.PacketConn, net.Listener, error) {
	udp, err := net.ListenPacket("udp6", endpoint)
	if err != nil {
		return nil, nil, err
	}
	tcp, err := net.Listen("tcp6", endpoint)
	if err != nil {
		udp.Close()
		return nil, nil, err
	}
	return udp, tcp, nil
}

func readPacket(connection net.PacketConn, buffer []byte) (int, net.Addr, *net.UDPAddr, error) {
	length, remote, err := connection.ReadFrom(buffer)
	return length, remote, nil, err
}

func writePacket(connection net.PacketConn, reply []byte, remote net.Addr, original *net.UDPAddr) error {
	_, err := connection.WriteTo(reply, remote)
	return err
}
