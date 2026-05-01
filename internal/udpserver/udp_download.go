// ==============================================================================
// StormDNS
// Author: nullroute1970
// Github: https://github.com/retro1878/DNS2UDP
// Year: 2026
// ==============================================================================

package udpserver

import (
	"context"
	"errors"
	"net"
	"syscall"
	"time"

	Enums "stormdns-go/internal/enums"
	VpnProto "stormdns-go/internal/vpnproto"
)

func (s *Server) signalUDPSend() {
	if s == nil || s.udpSendSignal == nil {
		return
	}
	select {
	case s.udpSendSignal <- struct{}{}:
	default:
	}
}

// setUDPActiveRecord registers a session record in the fast active-session index
// (improvement 4). Call this immediately after ClientUDPAddr is set.
func (s *Server) setUDPActiveRecord(id uint8, r *sessionRecord) {
	if s == nil || id == 0 {
		return
	}
	s.udpActiveMu.Lock()
	s.udpActiveRecords[id] = r
	s.udpActiveMu.Unlock()
}

// clearUDPActiveRecord removes a session from the fast active-session index.
// Call this from cleanupClosedSession.
func (s *Server) clearUDPActiveRecord(id uint8) {
	if s == nil || id == 0 {
		return
	}
	s.udpActiveMu.Lock()
	s.udpActiveRecords[id] = nil
	s.udpActiveMu.Unlock()
}

func (s *Server) runUDPSender(ctx context.Context) {
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.drainAllUDPSessions()
		case <-s.udpSendSignal:
			s.drainAllUDPSessions()
		}
	}
}

func (s *Server) drainAllUDPSessions() {
	// Improvement 3: reuse drainBuf — no allocation per call.
	// Improvement 4: read only the active-session index instead of the full session map.
	s.drainBuf = s.drainBuf[:0]
	s.udpActiveMu.RLock()
	for _, r := range s.udpActiveRecords {
		if r != nil && !r.isClosed() {
			s.drainBuf = append(s.drainBuf, r)
		}
	}
	s.udpActiveMu.RUnlock()

	now := time.Now()
	for _, record := range s.drainBuf {
		addr := record.ClientUDPAddr
		if addr == nil {
			continue
		}
		for {
			pkt, ok := s.dequeueSessionResponse(record.ID, now)
			if !ok {
				break
			}
			// Improvement 2: stop draining this session if the OS send buffer is full.
			if !s.sendRawVPNPacketUDP(record, pkt, addr) {
				break
			}
		}
	}
}

// sendRawVPNPacketUDP encrypts and sends one VPN packet over the UDP download
// channel. Returns false when the OS network buffer is full (ENOBUFS/EAGAIN),
// signalling the caller to stop draining the session for this tick.
func (s *Server) sendRawVPNPacketUDP(record *sessionRecord, pkt *VpnProto.Packet, addr *net.UDPAddr) bool {
	if s.udpDownConn == nil || pkt == nil || addr == nil {
		return true // not a congestion signal
	}
	raw, err := VpnProto.BuildRaw(VpnProto.BuildOptions{
		SessionID:       record.ID,
		SessionCookie:   record.Cookie,
		PacketType:      pkt.PacketType,
		StreamID:        pkt.StreamID,
		SequenceNum:     pkt.SequenceNum,
		FragmentID:      pkt.FragmentID,
		TotalFragments:  pkt.TotalFragments,
		CompressionType: pkt.CompressionType,
		Payload:         pkt.Payload,
	})
	if err != nil {
		return true
	}
	encrypted, err := s.codec.Encrypt(raw)
	if err != nil {
		return true
	}
	_, err = s.udpDownConn.WriteToUDP(encrypted, addr)
	if err != nil && isNetBufferFull(err) {
		return false
	}
	return true
}

// runUDPReceiver reads client-originated UDP packets (ACKs, NACKs) from the
// same socket the server uses to send download data, and dispatches them
// through the normal post-session handling path.
func (s *Server) runUDPReceiver(ctx context.Context) {
	conn := s.udpDownConn
	if conn == nil {
		return
	}
	buf := make([]byte, 65535)
	for {
		if ctx.Err() != nil {
			return
		}
		_ = conn.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
		n, _, err := conn.ReadFromUDP(buf)
		if err != nil {
			continue
		}
		if n < 4 {
			continue
		}
		pktData := make([]byte, n)
		copy(pktData, buf[:n])
		s.handleClientUDPUplink(pktData)
	}
}

func (s *Server) handleClientUDPUplink(data []byte) {
	raw, err := s.codec.Decrypt(data)
	if err != nil {
		return
	}
	pkt, err := VpnProto.Parse(raw)
	if err != nil {
		return
	}
	// Only allow ACK/NACK packets over the UDP uplink; anything else
	// that needs the full DNS validation/response cycle must come via DNS.
	if pkt.PacketType != Enums.PACKET_STREAM_DATA_ACK &&
		pkt.PacketType != Enums.PACKET_STREAM_DATA_NACK {
		return
	}
	now := time.Now()
	validation := s.validatePostSessionPacketRaw(pkt, now)
	if !validation.ok {
		return
	}
	s.handlePostSessionPacket(pkt, validation.record)
}

// validatePostSessionPacketRaw validates a VPN packet that arrived over the UDP
// uplink (no DNS question packet available). It checks that the session exists
// and the cookie matches, then updates the session's last-activity timestamp.
func (s *Server) validatePostSessionPacketRaw(pkt VpnProto.Packet, now time.Time) postSessionValidation {
	validation := s.sessions.ValidateAndTouch(pkt.SessionID, pkt.SessionCookie, now)
	if validation.Valid {
		return postSessionValidation{
			record: validation.Active,
			ok:     true,
		}
	}
	return postSessionValidation{}
}

// isNetBufferFull reports whether err signals that the OS UDP send buffer is
// exhausted. On Linux this is ENOBUFS; on BSD/macOS it may also be EAGAIN.
func isNetBufferFull(err error) bool {
	var errno syscall.Errno
	if errors.As(err, &errno) {
		return errno == syscall.ENOBUFS || errno == syscall.EAGAIN || errno == syscall.EWOULDBLOCK
	}
	return false
}
