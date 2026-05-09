package prompts

import (
	"bytes"
	"testing"
)

func TestInjectPeerBroadcastSubstitutesMarker(t *testing.T) {
	got, err := InjectPeerBroadcast([]byte("before\n"+PeerBroadcastMarker+"\nafter"), []byte(`[{"peer_id":"peer_1"}]`))
	if err != nil {
		t.Fatalf("InjectPeerBroadcast() error = %v", err)
	}
	if !bytes.Equal(got, []byte(`before
[{"peer_id":"peer_1"}]
after`)) {
		t.Fatalf("InjectPeerBroadcast() = %q", got)
	}
}

func TestInjectPeerBroadcastRequiresMarker(t *testing.T) {
	_, err := InjectPeerBroadcast([]byte("no marker"), []byte("[]"))
	if err == nil {
		t.Fatal("InjectPeerBroadcast() error = nil, want marker error")
	}
}
