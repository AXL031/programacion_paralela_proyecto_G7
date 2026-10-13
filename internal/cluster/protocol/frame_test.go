package protocol

import (
	"bytes"
	"encoding/binary"
	"io"
	"testing"
)

type fragmented struct{ io.Reader }

func (f fragmented) Read(b []byte) (int, error) { return f.Reader.Read(b[:min(1, len(b))]) }
func TestFragmentedAndConcatenatedFrames(t *testing.T) {
	var b bytes.Buffer
	for _, kind := range []string{"register", "heartbeat", "gradient"} {
		if err := Write(&b, Message{Protocol: Version, Type: kind}); err != nil {
			t.Fatal(err)
		}
	}
	r := fragmented{&b}
	for _, kind := range []string{"register", "heartbeat", "gradient"} {
		m, err := Read(r)
		if err != nil || m.Type != kind {
			t.Fatalf("frame desynchronized: %v %+v", err, m)
		}
	}
}
func TestOversizedTruncatedAndWrongVersion(t *testing.T) {
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], MaxFrame+1)
	if _, err := Read(bytes.NewReader(header[:])); err == nil {
		t.Fatal("oversized frame accepted")
	}
	binary.BigEndian.PutUint32(header[:], 12)
	if _, err := Read(bytes.NewReader(header[:])); err == nil {
		t.Fatal("truncated frame accepted")
	}
	var b bytes.Buffer
	Write(&b, Message{Protocol: 99, Type: "register"})
	if _, err := Read(&b); err == nil {
		t.Fatal("wrong protocol accepted")
	}
}
