// ==============================================================================
// StormDNS
// Author: nullroute1970
// Github: https://github.com/nullroute1970/StormDNS
// Year: 2026
// ==============================================================================

package udpserver

import (
	"context"
	"net"
	"time"

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
	s.sessions.mu.RLock()
	records := make([]*sessionRecord, 0, 16)
	for _, r := range s.sessions.byID {
		if r != nil && !r.isClosed() && r.ClientUDPAddr != nil {
			records = append(records, r)
		}
	}
	s.sessions.mu.RUnlock()

	now := time.Now()
	for _, record := range records {
		addr := record.ClientUDPAddr
		if addr == nil {
			continue
		}
		for {
			pkt, ok := s.dequeueSessionResponse(record.ID, now)
			if !ok {
				break
			}
			s.sendRawVPNPacketUDP(record, pkt, addr)
		}
	}
}

func (s *Server) sendRawVPNPacketUDP(record *sessionRecord, pkt *VpnProto.Packet, addr *net.UDPAddr) {
	if s.udpDownConn == nil || pkt == nil || addr == nil {
		return
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
		return
	}
	encrypted, err := s.codec.Encrypt(raw)
	if err != nil {
		return
	}
	_, _ = s.udpDownConn.WriteToUDP(encrypted, addr)
}
