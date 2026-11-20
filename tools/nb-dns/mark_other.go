//go:build !linux

package main

import "syscall"

func markControl(uint32) func(string, string, syscall.RawConn) error {
	return nil
}
