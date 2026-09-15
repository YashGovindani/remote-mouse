import Foundation
import WebRTC

/// One WebRTC peer connection per phone. The phone opens an unordered, unreliable data channel (UDP-like: no
/// retransmits, no head-of-line blocking) for the high-rate move/scroll events. Offer/answer/ICE signalling
/// travels over the phone's WebSocket. Delegate callbacks arrive on WebRTC's own threads.
final class RTCBridge: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()
    private let pc: RTCPeerConnection
    private var channel: RTCDataChannel?
    private let onMessage: (Data) -> Void
    private let signal: ([String: Any]) -> Void
    private let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

    init?(onMessage: @escaping (Data) -> Void, signal: @escaping ([String: Any]) -> Void) {
        self.onMessage = onMessage
        self.signal = signal
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = []                       // same LAN: host candidates only
        guard let pc = RTCBridge.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else { return nil }
        self.pc = pc
        super.init()
        pc.delegate = self
    }

    var isOpen: Bool { channel?.readyState == .open }

    /// Handles a signalling message from the phone: {"sdp": {type, sdp}} or {"ice": {candidate, sdpMid, sdpMLineIndex}}.
    func handleSignal(_ m: [String: Any]) {
        if let sdp = m["sdp"] as? [String: Any], let type = sdp["type"] as? String, let text = sdp["sdp"] as? String, type == "offer" {
            pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: text)) { [weak self] err in
                guard let self else { return }
                if let err { NSLog("rtc: remote offer rejected: %@", err.localizedDescription); return }
                self.pc.answer(for: self.constraints) { [weak self] desc, err in
                    guard let self, let desc else { NSLog("rtc: answer failed: %@", err?.localizedDescription ?? "?"); return }
                    self.pc.setLocalDescription(desc) { [weak self] err in
                        guard let self else { return }
                        if let err { NSLog("rtc: local answer failed: %@", err.localizedDescription); return }
                        self.signal(["t": "rtc", "sdp": ["type": "answer", "sdp": desc.sdp]])
                    }
                }
            }
        } else if let ice = m["ice"] as? [String: Any], let text = ice["candidate"] as? String, !text.isEmpty {
            let cand = RTCIceCandidate(sdp: text, sdpMLineIndex: Int32(ice["sdpMLineIndex"] as? Int ?? 0), sdpMid: ice["sdpMid"] as? String)
            pc.add(cand) { err in if let err { NSLog("rtc: candidate rejected: %@", err.localizedDescription) } }
        }
    }

    func close() {
        channel?.close()
        channel = nil
        pc.close()
    }

    // MARK: RTCPeerConnectionDelegate
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        NSLog("rtc: ice connection state %d", newState.rawValue)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        signal(["t": "rtc", "ice": ["candidate": candidate.sdp, "sdpMid": candidate.sdpMid ?? "0",
                                    "sdpMLineIndex": Int(candidate.sdpMLineIndex)]])
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        channel = dataChannel
        dataChannel.delegate = self
        NSLog("rtc: data channel '%@' open (unordered, no retransmits)", dataChannel.label)
    }

    // MARK: RTCDataChannelDelegate
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        NSLog("rtc: data channel state %d", dataChannel.readyState.rawValue)
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        onMessage(buffer.data)
    }
}
