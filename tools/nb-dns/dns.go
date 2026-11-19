package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"strings"
	"time"
)

const (
	rcodeServerFailure = 2
	rcodeRefused       = 5
	probeName          = "nb-dns-probe.invalid"
)

func query(name string, identifier uint16) ([]byte, error) {
	message := make([]byte, 12)
	binary.BigEndian.PutUint16(message, identifier)
	message[2], message[5] = 1, 1
	name = strings.TrimSuffix(name, ".")
	if len(name) == 0 || len(name) > 253 {
		return nil, errors.New("invalid DNS name")
	}
	for _, label := range strings.Split(name, ".") {
		if len(label) == 0 || len(label) > 63 {
			return nil, errors.New("invalid DNS label")
		}
		for _, character := range label {
			if !(character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character >= '0' && character <= '9' || character == '-' || character == '_') {
				return nil, errors.New("DNS name must use ASCII labels")
			}
		}
		message = append(message, byte(len(label)))
		message = append(message, label...)
	}
	return append(message, 0, 0, 1, 0, 1), nil
}

func validReply(request, reply []byte) bool {
	return len(request) >= 12 && len(reply) >= 12 && reply[2]&0x80 != 0 && binary.BigEndian.Uint16(request) == binary.BigEndian.Uint16(reply)
}

func rcode(reply []byte) byte {
	return reply[3] & 15
}

// exchange sends one DNS message. mark is applied as SO_MARK on Linux so the
// module's firewall rules recognise the helper's own traffic.
func exchange(target string, request []byte, tcp bool, mark uint32) ([]byte, error) {
	protocol := "udp"
	if tcp {
		protocol = "tcp"
	}
	dialer := net.Dialer{Timeout: 3 * time.Second, Control: markControl(mark)}
	connection, err := dialer.Dial(protocol, target)
	if err != nil {
		return nil, err
	}
	defer connection.Close()
	if err = connection.SetDeadline(time.Now().Add(4 * time.Second)); err != nil {
		return nil, err
	}
	if tcp {
		if len(request) > 65535 {
			return nil, errors.New("oversized request")
		}
		frame := make([]byte, 2, len(request)+2)
		binary.BigEndian.PutUint16(frame, uint16(len(request)))
		if err = writeAll(connection, append(frame, request...)); err != nil {
			return nil, err
		}
		if _, err = io.ReadFull(connection, frame[:2]); err != nil {
			return nil, err
		}
		reply := make([]byte, binary.BigEndian.Uint16(frame))
		if _, err = io.ReadFull(connection, reply); err != nil {
			return nil, err
		}
		if !validReply(request, reply) {
			return nil, errors.New("invalid TCP DNS reply")
		}
		return reply, nil
	}
	if _, err = connection.Write(request); err != nil {
		return nil, err
	}
	reply := make([]byte, 65535)
	length, err := connection.Read(reply)
	if err != nil {
		return nil, err
	}
	reply = reply[:length]
	if !validReply(request, reply) {
		return nil, errors.New("invalid UDP DNS reply")
	}
	if reply[2]&2 != 0 {
		return exchange(target, request, true, mark)
	}
	return reply, nil
}

func writeAll(writer io.Writer, data []byte) error {
	for len(data) > 0 {
		written, err := writer.Write(data)
		if err != nil {
			return err
		}
		if written == 0 {
			return io.ErrShortWrite
		}
		data = data[written:]
	}
	return nil
}

// check requires a successful answer for name over UDP and, unless udpOnly,
// over TCP as well.
func check(target, name string, udpOnly bool) error {
	request, err := query(name, 0x4e42)
	if err != nil {
		return err
	}
	transports := []bool{false, true}
	if udpOnly {
		transports = transports[:1]
	}
	for _, tcp := range transports {
		reply, err := exchange(target, request, tcp, helperMark)
		if err != nil {
			return err
		}
		if rcode(reply) != 0 || binary.BigEndian.Uint16(reply[6:8]) == 0 {
			return errors.New("DNS name has no successful answer")
		}
	}
	return nil
}

// probe confirms that a helper listener answers over UDP and TCP. The helper
// replies to probeName itself, without contacting any resolver.
func probe(target string) error {
	request, err := query(probeName, 0x4e50)
	if err != nil {
		return err
	}
	for _, tcp := range []bool{false, true} {
		if _, err := exchange(target, request, tcp, helperMark); err != nil {
			return err
		}
	}
	return nil
}

var probeQuestion, _ = query(probeName, 0)

func isProbe(request []byte) bool {
	return len(request) >= len(probeQuestion) && bytes.EqualFold(request[12:len(probeQuestion)-4], probeQuestion[12:len(probeQuestion)-4])
}

func questionEnd(request []byte) int {
	if len(request) < 12 || binary.BigEndian.Uint16(request[4:6]) == 0 {
		return 0
	}
	for offset := 12; offset < len(request) && offset < 12+255; {
		length := int(request[offset])
		if length == 0 {
			if offset+5 <= len(request) {
				return offset + 5
			}
			return 0
		}
		if length > 63 {
			return 0
		}
		offset += 1 + length
	}
	return 0
}

func reply(request []byte, code byte) []byte {
	if len(request) < 12 {
		return nil
	}
	end := questionEnd(request)
	length := max(12, end)
	response := append([]byte(nil), request[:length]...)
	response[2] = 0x80 | request[2]&0x79
	response[3] = 0x80 | code
	clear(response[4:12])
	if end != 0 {
		response[5] = 1
	}
	return response
}

func failure(request []byte) []byte {
	return reply(request, rcodeServerFailure)
}
