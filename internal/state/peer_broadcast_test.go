package state

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestPeerBroadcastWriteReadRoundTrip(t *testing.T) {
	runRoot := t.TempDir()
	records := []PeerRecord{
		{PeerID: "peer_2", Verdict: "PASS", Summary: "second"},
		{PeerID: "peer_1", Verdict: "NEEDS_WORK", Summary: "first"},
	}

	if err := WritePeerBroadcast(runRoot, 1, 2, records); err != nil {
		t.Fatalf("WritePeerBroadcast() error = %v", err)
	}
	got, err := ReadPeerBroadcast(runRoot, 1, 2)
	if err != nil {
		t.Fatalf("ReadPeerBroadcast() error = %v", err)
	}
	want := []PeerRecord{
		{PeerID: "peer_1", Verdict: "NEEDS_WORK", Summary: "first"},
		{PeerID: "peer_2", Verdict: "PASS", Summary: "second"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("ReadPeerBroadcast() = %#v, want %#v", got, want)
	}
}

func TestPeerBroadcastSortsByPeerIDDeterministically(t *testing.T) {
	records := []PeerRecord{
		{PeerID: "peer_b", Verdict: "PASS", Summary: "b"},
		{PeerID: "peer_a", Verdict: "FAIL", Summary: "a"},
	}
	runRootA := t.TempDir()
	runRootB := t.TempDir()

	if err := WritePeerBroadcast(runRootA, 1, 2, records); err != nil {
		t.Fatalf("WritePeerBroadcast(A) error = %v", err)
	}
	if err := WritePeerBroadcast(runRootB, 1, 2, []PeerRecord{records[1], records[0]}); err != nil {
		t.Fatalf("WritePeerBroadcast(B) error = %v", err)
	}
	dataA, err := ReadPeerBroadcastBytes(runRootA, 1, 2)
	if err != nil {
		t.Fatalf("ReadPeerBroadcastBytes(A) error = %v", err)
	}
	dataB, err := ReadPeerBroadcastBytes(runRootB, 1, 2)
	if err != nil {
		t.Fatalf("ReadPeerBroadcastBytes(B) error = %v", err)
	}
	if !bytes.Equal(dataA, dataB) {
		t.Fatalf("broadcast bytes differ:\nA=%s\nB=%s", dataA, dataB)
	}
}

func TestPeerBroadcastPathAndRoundOneRefusal(t *testing.T) {
	runRoot := t.TempDir()
	if err := WritePeerBroadcast(runRoot, 1, 1, []PeerRecord{{PeerID: "peer_1"}}); err == nil {
		t.Fatal("WritePeerBroadcast(round 1) error = nil, want refusal")
	}
	path := filepath.Join(runRoot, "iterations", "1", "round-2", "peer-broadcast.json")
	if got := PeerBroadcastPath(runRoot, 1, 2); got != path {
		t.Fatalf("PeerBroadcastPath() = %q, want %q", got, path)
	}
	if _, err := os.Stat(filepath.Join(runRoot, "iterations", "1", "round-1", "peer-broadcast.json")); !os.IsNotExist(err) {
		t.Fatalf("round-1 peer-broadcast.json exists or stat error = %v, want not exist", err)
	}
}
