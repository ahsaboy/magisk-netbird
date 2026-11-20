package main

import "syscall"

// markControl sets SO_MARK on outgoing sockets; it needs CAP_NET_ADMIN.
func markControl(mark uint32) func(string, string, syscall.RawConn) error {
	if mark == 0 {
		return nil
	}
	return func(_, _ string, connection syscall.RawConn) error {
		var socketError error
		if err := connection.Control(func(descriptor uintptr) {
			socketError = syscall.SetsockoptInt(int(descriptor), syscall.SOL_SOCKET, syscall.SO_MARK, int(mark))
		}); err != nil {
			return err
		}
		return socketError
	}
}
