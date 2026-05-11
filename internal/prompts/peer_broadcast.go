package prompts

import (
	"bytes"
	"fmt"
)

const PeerBroadcastMarker = "{{{{PEER_BROADCAST}}}}"

// InjectPeerBroadcast replaces the peer-broadcast marker with serialized
// broadcast JSON for debate rounds after round one.
func InjectPeerBroadcast(template []byte, broadcast []byte) ([]byte, error) {
	if !bytes.Contains(template, []byte(PeerBroadcastMarker)) {
		return nil, fmt.Errorf("peer broadcast marker %q not found", PeerBroadcastMarker)
	}
	return bytes.Replace(template, []byte(PeerBroadcastMarker), broadcast, 1), nil
}
