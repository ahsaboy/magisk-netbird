package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"net/netip"
	"syscall"
)

const (
	conntrackNew           = 0x100
	conntrackGet           = 0x101
	conntrackDelete        = 0x102
	conntrackOriginalTuple = 0x8001
	netlinkDumpInterrupted = 0x10
)

func netlinkRequest(descriptor int, kind uint16, flags uint16, sequence uint32, family byte, payload []byte) error {
	data := make([]byte, 20, 20+len(payload))
	binary.NativeEndian.PutUint32(data, uint32(20+len(payload)))
	binary.NativeEndian.PutUint16(data[4:], kind)
	binary.NativeEndian.PutUint16(data[6:], flags)
	binary.NativeEndian.PutUint32(data[8:], sequence)
	data[16] = family
	return syscall.Sendto(descriptor, append(data, payload...), 0, &syscall.SockaddrNetlink{Family: syscall.AF_NETLINK})
}

func cleanConnections(remove bool) error {
	descriptor, err := syscall.Socket(syscall.AF_NETLINK, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC, syscall.NETLINK_NETFILTER)
	if err != nil {
		return err
	}
	defer syscall.Close(descriptor)
	if err = syscall.Bind(descriptor, &syscall.SockaddrNetlink{Family: syscall.AF_NETLINK}); err != nil {
		return err
	}
	if err = syscall.SetsockoptTimeval(descriptor, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &syscall.Timeval{Sec: 3}); err != nil {
		return err
	}
	if err = netlinkRequest(descriptor, conntrackGet, syscall.NLM_F_REQUEST|syscall.NLM_F_DUMP, 1, 0, nil); err != nil {
		return err
	}
	type pendingTuple struct {
		family byte
		data   []byte
	}
	var pending []pendingTuple
	buffer := make([]byte, 1<<20)
	done := false
	for !done {
		length, _, err := syscall.Recvfrom(descriptor, buffer, 0)
		if err != nil {
			return err
		}
		messages, err := syscall.ParseNetlinkMessage(buffer[:length])
		if err != nil {
			return err
		}
		for _, message := range messages {
			if message.Header.Seq != 1 {
				continue
			}
			if message.Header.Flags&netlinkDumpInterrupted != 0 {
				return errors.New("conntrack dump interrupted")
			}
			if message.Header.Type == syscall.NLMSG_DONE {
				done = true
				continue
			}
			if message.Header.Type == syscall.NLMSG_ERROR {
				return netlinkError(message.Data)
			}
			if len(message.Data) < 4 {
				continue
			}
			if tuple := ownedTuple(message.Data[4:]); remove && tuple != nil {
				pending = append(pending, pendingTuple{message.Data[0], append([]byte(nil), tuple...)})
			}
		}
	}
	for index, tuple := range pending {
		attribute := make([]byte, (len(tuple.data)+7)&^3)
		binary.NativeEndian.PutUint16(attribute, uint16(4+len(tuple.data)))
		binary.NativeEndian.PutUint16(attribute[2:], conntrackOriginalTuple)
		copy(attribute[4:], tuple.data)
		sequence := uint32(index + 2)
		if err = netlinkRequest(descriptor, conntrackDelete, syscall.NLM_F_REQUEST|syscall.NLM_F_ACK, sequence, tuple.family, attribute); err != nil {
			return err
		}
		length, _, err := syscall.Recvfrom(descriptor, buffer, 0)
		if err != nil {
			return err
		}
		messages, err := syscall.ParseNetlinkMessage(buffer[:length])
		if err != nil {
			return err
		}
		acknowledged := false
		for _, message := range messages {
			if message.Header.Seq == sequence && message.Header.Type == syscall.NLMSG_ERROR {
				if err := netlinkError(message.Data); err != nil && !errors.Is(err, syscall.ENOENT) {
					return err
				}
				acknowledged = true
			}
		}
		if !acknowledged {
			return errors.New("conntrack delete not acknowledged")
		}
	}
	return nil
}

func conntrackSocket() (int, error) {
	descriptor, err := syscall.Socket(syscall.AF_NETLINK, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC, syscall.NETLINK_NETFILTER)
	if err != nil {
		return -1, err
	}
	if err = syscall.Bind(descriptor, &syscall.SockaddrNetlink{Family: syscall.AF_NETLINK}); err == nil {
		err = syscall.SetsockoptTimeval(descriptor, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &syscall.Timeval{Sec: 1})
	}
	if err != nil {
		syscall.Close(descriptor)
		return -1, err
	}
	return descriptor, nil
}

// lookupOrigin asks conntrack where an intercepted query was originally
// sent and which Android mark its socket carried (saved by CONNMARK).
func lookupOrigin(source origin) (netip.AddrPort, uint32, error) {
	direction, from, to, protocol := lookupKey(source)
	if !from.IsValid() || !to.IsValid() || from.Addr().Is4() != to.Addr().Is4() {
		return netip.AddrPort{}, 0, errors.New("invalid connection tuple")
	}
	family := byte(syscall.AF_INET)
	if from.Addr().Is6() {
		family = syscall.AF_INET6
	}
	descriptor, err := conntrackSocket()
	if err != nil {
		return netip.AddrPort{}, 0, err
	}
	defer syscall.Close(descriptor)
	if err = netlinkRequest(descriptor, conntrackGet, syscall.NLM_F_REQUEST, 1, family, encodeTuple(direction, protocol, from, to)); err != nil {
		return netip.AddrPort{}, 0, err
	}
	buffer := make([]byte, 1<<16)
	length, _, err := syscall.Recvfrom(descriptor, buffer, 0)
	if err != nil {
		return netip.AddrPort{}, 0, err
	}
	messages, err := syscall.ParseNetlinkMessage(buffer[:length])
	if err != nil {
		return netip.AddrPort{}, 0, err
	}
	for _, message := range messages {
		if message.Header.Seq != 1 {
			continue
		}
		if message.Header.Type == syscall.NLMSG_ERROR {
			if err := netlinkError(message.Data); err != nil {
				return netip.AddrPort{}, 0, err
			}
			continue
		}
		if message.Header.Type == conntrackNew && len(message.Data) > 4 {
			return parseEntry(message.Data[4:])
		}
	}
	return netip.AddrPort{}, 0, errors.New("conntrack entry not found")
}

func netlinkError(data []byte) error {
	if len(data) < 4 {
		return errors.New("short netlink error")
	}
	code := int32(binary.NativeEndian.Uint32(data))
	if code == 0 {
		return nil
	}
	return fmt.Errorf("conntrack: %w", syscall.Errno(-code))
}
