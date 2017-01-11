import Foundation
import WebRTC
import SocketRocket
import Unbox

public class PeerConnection {
    
    public enum State: String {
        case connecting
        case connected
        case disconnecting
        case disconnected
    }
    
    public weak var connection: Connection?
    public weak var mediaConnection: MediaConnection?
    public var role: MediaStreamRole
    public var accessToken: String?
    var mediaStreamId: String?
    public var mediaOption: MediaOption
    public var clientId: String?
    public var state: State
    
    public var isAvailable: Bool {
        get { return state == .connected }
    }
    
    var mediaCapturer: MediaCapturer? {
        get { return context?.mediaCapturer }
    }
    
    public var nativePeerConnection: RTCPeerConnection? {
        get { return context?.nativePeerConnection }
    }
    
    public var nativePeerConnectionFactory: RTCPeerConnectionFactory? {
        get { return context?.nativePeerConnectionFactory }
    }
    
    var context: PeerConnectionContext?
    
    var eventLog: EventLog? {
        get { return connection?.eventLog }
    }
    
    init(connection: Connection,
         mediaConnection: MediaConnection,
         role: MediaStreamRole,
         accessToken: String? = nil,
         mediaStreamId: String? = nil,
         mediaOption: MediaOption = MediaOption()) {
        self.connection = connection
        self.mediaConnection = mediaConnection
        self.role = role
        self.accessToken = accessToken
        self.mediaStreamId = mediaStreamId
        self.mediaOption = mediaOption
        self.state = .disconnected
    }
    
    // MARK: ピア接続
    
    // 接続に成功すると nativePeerConnection プロパティがセットされる
    func connect(timeout: Int, handler: @escaping ((ConnectionError?) -> Void)) {
        eventLog?.markFormat(type: .PeerConnection, format: "connect")
        switch state {
        case .connected, .connecting, .disconnecting:
            handler(ConnectionError.connectionBusy)
        case .disconnected:
            state = .connecting
            context = PeerConnectionContext(peerConnection: self, role: role)
            context!.connect(timeout: timeout, handler: handler)
        }
    }
    
    func disconnect(handler: @escaping (ConnectionError?) -> Void) {
        eventLog?.markFormat(type: .PeerConnection, format: "disconnect")
        switch state {
        case .disconnecting:
            handler(ConnectionError.connectionBusy)
        case .disconnected:
            handler(ConnectionError.connectionDisconnected)
        case .connecting, .connected:
            assert(nativePeerConnection == nil, "nativePeerConnection must not be nil")
            state = .disconnecting
            context?.disconnect(handler: handler)
        }
    }
    
    func terminate() {
        eventLog?.markFormat(type: .PeerConnection, format: "terminate")
        state = .disconnected
        context = nil
    }
    
    // MARK: WebSocket
    
    func send(message: Messageable) -> ConnectionError? {
        let message = message.message()
        switch state {
        case .connected:
            return context!.send(message)
        case .disconnected:
            return ConnectionError.connectionDisconnected
        default:
            return ConnectionError.connectionBusy
        }
    }
    
}

class PeerConnectionContext: NSObject, SRWebSocketDelegate, RTCPeerConnectionDelegate {
    
    enum State: String {
        case signalingConnecting
        case signalingConnected
        case peerConnectionReady
        case peerConnectionOffered
        case peerConnectionAnswering
        case peerConnectionAnswered
        case peerConnectionConnecting
        case connected
        case disconnecting
        case disconnected
        case terminated
    }
    
    weak var peerConnection: PeerConnection?
    var role: MediaStreamRole
    
    var webSocket: SRWebSocket?
    
    private var _state: State = .disconnected
    
    var state: State {
        get {
            if peerConnection == nil {
                return .terminated
            } else {
                return _state
            }
        }
        set {
            _state = newValue
            switch newValue {
            case .connected:
                peerConnection?.state = .connected
            case .disconnecting:
                peerConnection?.state = .disconnecting
            case .disconnected:
                peerConnection?.state = .disconnected
            default:
                peerConnection?.state = .connecting
            }
        }
    }
    
    var nativePeerConnectionFactory: RTCPeerConnectionFactory!
    var nativePeerConnection: RTCPeerConnection!
    var upstream: RTCMediaStream?
    var mediaCapturer: MediaCapturer?
    
    var connection: Connection! {
        get { return peerConnection?.connection }
    }
    
    var eventLog: EventLog? {
        get { return connection?.eventLog }
    }
    
    var mediaConnection: MediaConnection! {
        get { return peerConnection?.mediaConnection }
    }
    
    private var timeoutTimer: Timer?
    
    private var connectCompletionHandler: ((ConnectionError?) -> Void)?
    private var disconnectCompletionHandler: ((ConnectionError?) -> Void)?
    
    init(peerConnection: PeerConnection, role: MediaStreamRole) {
        self.peerConnection = peerConnection
        self.role = role
        nativePeerConnectionFactory = RTCPeerConnectionFactory()
    }
    
    // MARK: ピア接続
    
    func connect(timeout: Int, handler: @escaping ((ConnectionError?) -> Void)) {
        if state != .disconnected {
            handler(ConnectionError.connectionBusy)
            return
        }
        
        eventLog?.markFormat(type: .WebSocket,
                             format: String(format: "open %@",
                                            connection!.URL.description))
        state = .signalingConnecting
        connectCompletionHandler = handler
        
        startTimeoutTimer(timeout: timeout) {
            timer in
            switch self.state {
            case .disconnecting, .disconnected:
                break
            case .connected:
                self.timeoutTimer?.invalidate()
                self.timeoutTimer = nil
            default:
                self.eventLog?.markFormat(type: .PeerConnection,
                                          format: "timeout connecting")
                let error = ConnectionError.connectionWaitTimeout
                self.terminate(error: error)
                self.connectCompletionHandler?(error)
                self.connectCompletionHandler = nil
            }
        }
        
        webSocket = SRWebSocket(url: connection!.URL)
        webSocket!.delegate = self
        webSocket!.open()
    }
    
    func disconnect(handler: @escaping ((ConnectionError?) -> Void)) {
        switch state {
        case .disconnected:
            handler(ConnectionError.connectionDisconnected)
        case .signalingConnected, .connected:
            disconnectCompletionHandler = handler
            terminate()
        default:
            handler(ConnectionError.connectionBusy)
        }
    }
    
    func startTimeoutTimer(timeout: Int, handler: @escaping ((Timer) -> ())) {
        timeoutTimer?.invalidate()
        timeoutTimer = Timer(timeInterval: Double(timeout), repeats: false) {
            timer in
            handler(timer)
        }
        RunLoop.main.add(timeoutTimer!, forMode: .commonModes)
    }
    
    func terminate(error: ConnectionError? = nil) {
        switch state {
        case .disconnected:
            break
            
        case .disconnecting:
            proceedDisconnecting(error :error)
            
        default:
            eventLog!.markFormat(type: .Signaling, format: "terminate all connections")
            state = .disconnecting
            if let error = error {
                webSocketEventHandlers?.onFailureHandler?(webSocket!, error)
            }
            timeoutTimer?.invalidate()
            timeoutTimer = nil
            nativePeerConnection?.close()
            webSocket?.close()
        }
    }
    
    func terminateByPeerConnection(error: Error) {
        peerConnectionEventHandlers?.onFailureHandler?(nativePeerConnection, error)
        terminate(error: ConnectionError.peerConnectionError(error))
    }
    
    private var disconnectingErrors: [ConnectionError] = []
    
    func proceedDisconnecting(error: ConnectionError? = nil) {
        print("begin proceedDisconnecting")
        if let error = error {
            disconnectingErrors.append(error)
        }
        
        if webSocket?.readyState == SRReadyState.CLOSED &&
            nativePeerConnection.signalingState == .closed &&
            nativePeerConnection.iceConnectionState == .closed {
            eventLog?.markFormat(type: .WebSocket,
                                 format: "finish disconnecting")
            
            var aggregateError: ConnectionError? = nil
            if !disconnectingErrors.isEmpty {
                aggregateError =
                    ConnectionError.aggregateError(disconnectingErrors)
            }
            peerConnectionEventHandlers?.onDisconnectHandler?(nativePeerConnection)
            
            // この順にクリアしないと落ちる
            mediaCapturer = nil
            nativePeerConnection.delegate = nil
            nativePeerConnection = nil
            nativePeerConnectionFactory = nil
            webSocket?.delegate = nil
            webSocket = nil
            
            state = .disconnected
            if let error = aggregateError {
                signalingEventHandlers?.onFailureHandler?(error)
                mediaConnection?.onFailureHandler?(error)
            }
            signalingEventHandlers?.onDisconnectHandler?()
            connectCompletionHandler?(aggregateError)
            connectCompletionHandler = nil
            disconnectCompletionHandler?(aggregateError)
            disconnectCompletionHandler = nil
            mediaConnection?.onDisconnectHandler?(aggregateError)
            peerConnection?.terminate()
            peerConnection = nil
        }
        print("end proceedDisconnecting")
        
    }
    
    func send(_ message: Messageable) -> ConnectionError? {
        switch state {
        case .disconnected, .terminated:
            eventLog!.markFormat(type: .WebSocket,
                                 format: "failed sending message (connection disconnected)")
            return ConnectionError.connectionDisconnected
            
        case .signalingConnecting, .disconnecting:
            eventLog!.markFormat(type: .WebSocket,
                                 format: "failed sending message (connection busy)")
            return ConnectionError.connectionBusy
            
        default:
            let message = message.message()
            eventLog!.markFormat(type: .WebSocket,
                                 format: "send message (state %@): %@",
                                 arguments: state.rawValue, message.description)
            let s = message.JSONRepresentation()
            eventLog!.markFormat(type: .WebSocket,
                                 format: "send message as JSON: %@",
                                 arguments: s)
            webSocket!.send(message.JSONRepresentation())
            return nil
        }
    }
    
    // MARK: SRWebSocketDelegate
    
    var webSocketEventHandlers: WebSocketEventHandlers? {
        get { return mediaConnection?.webSocketEventHandlers }
    }
    
    var signalingEventHandlers: SignalingEventHandlers? {
        get { return mediaConnection?.signalingEventHandlers }
    }
    
    var peerConnectionEventHandlers: PeerConnectionEventHandlers? {
        get { return mediaConnection?.peerConnectionEventHandlers }
    }
    
    func webSocketDidOpen(_ webSocket: SRWebSocket!) {
        eventLog?.markFormat(type: .WebSocket, format: "opened")
        eventLog?.markFormat(type: .Signaling, format: "connected")
        
        switch state {
        case .disconnected, .terminated:
            break
            
        case .disconnecting:
            proceedDisconnecting()
            
        case .signalingConnecting:
            webSocketEventHandlers?.onOpenHandler?(webSocket)
            state = .signalingConnected
            signalingEventHandlers?.onConnectHandler?()
            
            // ピア接続オブジェクトを生成する
            eventLog?.markFormat(type: .PeerConnection,
                                 format: "create peer connection")
            nativePeerConnection = nativePeerConnectionFactory.peerConnection(
                with: peerConnection!.mediaOption.configuration,
                constraints: peerConnection!.mediaOption.peerConnectionMediaConstraints,
                delegate: self)
            if role == MediaStreamRole.upstream {
                if let error = createMediaCapturer() {
                    terminate(error: error)
                    return
                }
            }
            
            // シグナリング connect を送信する
            let connect = SignalingConnect(role: SignalingRole.from(role),
                                           channel_id: connection.mediaChannelId,
                                           mediaOption: peerConnection!.mediaOption)
            eventLog?.markFormat(type: .Signaling,
                                 format: "send connect message: %@",
                                 arguments: connect.message().JSON().description)
            if let error = send(connect) {
                eventLog?.markFormat(type: .Signaling,
                                     format: "send connect message failed: %@",
                                     arguments: error.localizedDescription)
                signalingEventHandlers?.onFailureHandler?(error)
                terminate(error: ConnectionError.connectionTerminated)
                return
            }
            state = .peerConnectionReady
            
        default:
            eventLog?.markFormat(type: .Signaling,
                                 format: "WebSocket opened in invalid state")
            terminate(error: ConnectionError.connectionTerminated)
        }
    }
    
    func createMediaCapturer() -> ConnectionError? {
        eventLog?.markFormat(type: .PeerConnection, format: "create media capturer")
        mediaCapturer = MediaCapturer(factory: nativePeerConnectionFactory,
                                      mediaOption: peerConnection!.mediaOption)
        if mediaCapturer == nil {
            eventLog?.markFormat(type: .PeerConnection,
                                 format: "create media capturer failed")
            return ConnectionError.mediaCapturerFailed
        }
        
        let upstream = nativePeerConnectionFactory.mediaStream(withStreamId:
            peerConnection!.mediaStreamId ?? MediaStream.defaultStreamId)
        if peerConnection!.mediaOption.videoEnabled {
            upstream.addVideoTrack(mediaCapturer!.videoCaptureTrack)
        }
        if peerConnection!.mediaOption.audioEnabled {
            upstream.addAudioTrack(mediaCapturer!.audioCaptureTrack)
        }
        nativePeerConnection.add(upstream)
        return nil
    }
    
    public func webSocket(_ webSocket: SRWebSocket!,
                          didCloseWithCode code: Int,
                          reason: String?,
                          wasClean: Bool) {
        if let reason = reason {
            eventLog?.markFormat(type: .WebSocket,
                                 format: "close: code \(code), reason %@, clean \(wasClean)",
                arguments: reason)
        } else {
            eventLog?.markFormat(type: .WebSocket,
                                 format: "close: code \(code), clean \(wasClean)")
        }
        
        var error: ConnectionError? = nil
        if code != SRStatusCodeNormal.rawValue {
            error = ConnectionError.webSocketClose(code, reason)
        }
        
        switch state {
        case .disconnected, .terminated:
            break
            
        case .disconnecting:
            // ピア接続を解除すると、サーバーからステータスコード 1001 で接続解除される
            if code == SRStatusCodeGoingAway.rawValue {
                error = nil
            }
            proceedDisconnecting(error: error)
            
        default:
            webSocketEventHandlers?.onCloseHandler?(webSocket, code, reason, wasClean)
            terminate(error: error)
        }
    }
    
    func webSocket(_ webSocket: SRWebSocket!, didFailWithError error: Error!) {
        eventLog?.markFormat(type: .WebSocket,
                             format: "fail: %@",
                             arguments: error.localizedDescription)
        let error = ConnectionError.webSocketError(error)
        
        switch state {
        case .disconnected, .terminated:
            break
            
        case .disconnecting:
            proceedDisconnecting(error: error)
            
        default:
            webSocketEventHandlers?.onFailureHandler?(webSocket, error)
            terminate(error: error)
        }
    }
    
    func webSocket(_ webSocket: SRWebSocket!, didReceivePong pongPayload: Data!) {
        eventLog?.markFormat(type: .WebSocket,
                             format: "received pong: %@",
                             arguments: pongPayload.description)
        switch state {
        case .disconnected, .terminated:
            break
            
        case .disconnecting:
            proceedDisconnecting()
            
        default:
            webSocketEventHandlers?.onPongHandler?(webSocket, pongPayload)
        }
    }
    
    func webSocket(_ webSocket: SRWebSocket!, didReceiveMessage message: Any!) {
        eventLog?.markFormat(type: .WebSocket,
                             format: "received message: %@",
                             arguments: (message as AnyObject).description)
        
        switch state {
        case .disconnected, .terminated:
            break
            
        case .disconnecting:
            proceedDisconnecting()
            
        default:
            webSocketEventHandlers?.onMessageHandler?(webSocket, message as AnyObject)
            if let message = Message.fromJSONData(message) {
                signalingEventHandlers?.onReceiveHandler?(message)
                eventLog?.markFormat(type: .Signaling,
                                     format: "signaling message type: %@",
                                     arguments: message.type?.rawValue ??  "<unknown>")
                
                let json = message.JSON()
                switch message.type {
                case .ping?:
                    receiveSignalingPing()
                    
                case .stats?:
                    receiveSignalingStats(json: json)
                    
                    /*
                     case .notify?:
                     receiveSignalingNotify(json: json)
                     */
                    
                case .offer?:
                    receiveSignalingOffer(json: json)
                    
                default:
                    return
                }
            }
        }
    }
    
    func receiveSignalingPing() {
        eventLog?.markFormat(type: .Signaling, format: "received ping")
        
        switch state {
        case .connected:
            signalingEventHandlers?.onPingHandler?()
            if let error = self.send(SignalingPong()) {
                mediaConnection?.onFailureHandler?(error)
            }
            
        default:
            break
        }
    }
    
    func receiveSignalingStats(json: [String: Any]) {
        switch state {
        case .connected:
            var stats: SignalingStats!
            do {
                stats = Optional.some(try unbox(dictionary: json))
            } catch {
                eventLog?.markFormat(type: .Signaling,
                                     format: "failed parsing stats: %@",
                                     arguments: json.description)
                return
            }
            
            eventLog?.markFormat(type: .Signaling, format: "stats: %@",
                                 arguments: stats.description)
            
            let mediaStats = MediaConnection.Statistics(signalingStats: stats)
            signalingEventHandlers?.onUpdateHandler?(stats)
            mediaConnection?.onUpdateHandler?(mediaStats)
            
        default:
            break
        }
    }
    
    /*
     func receiveSignalingNotify(json: [String: Any]) {
     switch state {
     case .connected:
     var notify: SignalingNotify!
     do {
     notify = Optional.some(try unbox(dictionary: json))
     } catch {
     eventLog?.markFormat(type: .Signaling,
     format: "failed parsing notify: %@",
     arguments: json.description)
     }
     
     eventLog?.markFormat(type: .Signaling, format: "received notify: %@",
     arguments: notify.notifyMessage)
     signalingEventHandlers?.onNotifyHandler?(notify)
     if let notify = MediaConnection
     .Notification(rawValue: notify.notifyMessage) {
     mediaConnection?.onNotifyHandler?(notify)
     }
     
     default:
     break
     }
     }
     */
    
    func receiveSignalingOffer(json: [String: Any]) {
        switch state {
        case .peerConnectionReady:
            eventLog?.markFormat(type: .Signaling, format: "received offer")
            let offer: SignalingOffer!
            do {
                offer = Optional.some(try unbox(dictionary: json))
            } catch {
                eventLog?.markFormat(type: .Signaling,
                                     format: "parsing offer failed")
                return
            }
            
            if let config = offer.config {
                eventLog?.markFormat(type: .Signaling,
                                     format: "configure ICE transport policy")
                let peerConfig = RTCConfiguration()
                switch config.iceTransportPolicy {
                case "relay":
                    peerConfig.iceTransportPolicy = .relay
                default:
                    eventLog?.markFormat(type: .Signaling,
                                         format: "unsupported iceTransportPolicy %@",
                                         arguments: config.iceTransportPolicy)
                    return
                }
                
                eventLog?.markFormat(type: .Signaling, format: "configure ICE servers")
                for serverConfig in config.iceServers {
                    let server = RTCIceServer(urlStrings: serverConfig.urls,
                                              username: serverConfig.username,
                                              credential: serverConfig.credential)
                    peerConfig.iceServers = [server]
                }
                
                if !nativePeerConnection.setConfiguration(peerConfig) {
                    eventLog?.markFormat(type: .Signaling,
                                         format: "cannot configure peer connection")
                    terminate(error: ConnectionError
                        .failureSetConfiguration(peerConfig))
                    return
                }
            }
            
            state = .peerConnectionOffered
            let sdp = offer.sessionDescription()
            eventLog?.markFormat(type: .Signaling,
                                 format: "set remote description")
            nativePeerConnection.setRemoteDescription(sdp) {
                error in
                if let error = error {
                    self.eventLog?.markFormat(type: .Signaling,
                                              format: "set remote description failed")
                    self.terminateByPeerConnection(error: error)
                    return
                }
                
                self.eventLog?.markFormat(type: .Signaling,
                                          format: "create answer")
                self.nativePeerConnection.answer(for: self
                    .peerConnection!.mediaOption.signalingAnswerMediaConstraints)
                {
                    (sdp, error) in
                    if let error = error {
                        self.eventLog?.markFormat(type: .Signaling,
                                                  format: "creating answer failed")
                        self.peerConnectionEventHandlers?
                            .onFailureHandler?(self.nativePeerConnection, error)
                        self.terminate(error:
                            ConnectionError.peerConnectionError(error))
                        return
                    }
                    self.eventLog?.markFormat(type: .Signaling,
                                              format: "generated answer: %@",
                                              arguments: sdp!)
                    self.nativePeerConnection.setLocalDescription(sdp!) {
                        error in
                        if let error = error {
                            self.eventLog?.markFormat(type: .Signaling,
                                                      format: "set local description failed")
                            self.peerConnectionEventHandlers?
                                .onFailureHandler?(self.nativePeerConnection, error)
                            self.terminate(error:
                                ConnectionError.peerConnectionError(error))
                            return
                        }
                        
                        self.eventLog?.markFormat(type: .Signaling,
                                                  format: "send answer")
                        let answer = SignalingAnswer(sdp: sdp!.sdp)
                        if let error = self.send(answer) {
                            self.terminate(error: ConnectionError.peerConnectionError(error))
                            return
                        }
                        self.state = .peerConnectionAnswered
                    }
                }
            }
            
        default:
            eventLog?.markFormat(type: .Signaling,
                                 format: "offer: invalid state %@",
                                 arguments: state.rawValue)
            terminate(error: ConnectionError.connectionTerminated)
        }
    }
    
    // MARK: RTCPeerConnectionDelegate
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didChange stateChanged: RTCSignalingState) {
        eventLog?.markFormat(type: .PeerConnection,
                             format: "signaling state changed: %@",
                             arguments: stateChanged.description)
        switch state {
        case .disconnected, .terminated:
            break
            
        case .disconnecting:
            proceedDisconnecting()
            
        default:
            peerConnectionEventHandlers?.onChangeSignalingStateHandler?(
                nativePeerConnection, stateChanged)
            switch stateChanged {
            case .closed:
                terminate(error: ConnectionError.connectionTerminated)
            default:
                break
            }
        }
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didAdd stream: RTCMediaStream) {
        eventLog?.markFormat(type: .PeerConnection, format: "added stream")
        switch state {
        case .disconnected, .terminated:
            break
            
        case .disconnecting:
            proceedDisconnecting()
            
        default:
            guard peerConnection != nil else {
                return
            }
            
            peerConnectionEventHandlers?.onAddStreamHandler?(nativePeerConnection, stream)
            nativePeerConnection.add(stream)
            let wrap = MediaStream(peerConnection: peerConnection!,
                                   nativeMediaStream: stream)
            peerConnection?.addMediaStream(stream: wrap)
            
        }
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didRemove stream: RTCMediaStream) {
        eventLog?.markFormat(type: .PeerConnection, format: "removed stream")
        switch state {
        case .disconnected, .terminated:
            break
            
        case .disconnecting:
            proceedDisconnecting()
            
        default:
            peerConnectionEventHandlers?
                .onRemoveStreamHandler?(nativePeerConnection, stream)
            nativePeerConnection.remove(stream)
            peerConnection?.removeMediaStream(mediaStreamId: stream.streamId)
        }
    }
    
    func peerConnectionShouldNegotiate(_ nativePeerConnection: RTCPeerConnection) {
        eventLog?.markFormat(type: .PeerConnection, format: "should negatiate")
        switch state {
        case .disconnected, .terminated:
            break
            
        case .disconnecting:
            proceedDisconnecting()
            
        default:
            peerConnectionEventHandlers?.onNegotiateHandler?(nativePeerConnection)
        }
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didChange newState: RTCIceConnectionState) {
        eventLog?.markFormat(type: .PeerConnection,
                             format: "ICE connection state changed: %@",
                             arguments: newState.description)
        
        switch state {
        case .disconnected, .terminated:
            break
            
        case .disconnecting:
            proceedDisconnecting()
            
        default:
            peerConnectionEventHandlers?
                .onChangeIceConnectionState?(nativePeerConnection, newState)
            switch newState {
            case .connected:
                switch state {
                case .peerConnectionAnswered:
                    eventLog?.markFormat(type: .PeerConnection,
                                         format: "remote peer connected",
                                         arguments: newState.description)
                    state = .connected
                    peerConnectionEventHandlers?.onConnectHandler?(nativePeerConnection)
                    connectCompletionHandler?(nil)
                    connectCompletionHandler = nil
                default:
                    eventLog?.markFormat(type: .PeerConnection,
                                         format: "ICE connection completed but invalid state %@",
                                         arguments: newState.description)
                    terminate(error: ConnectionError.iceConnectionFailed)
                }
                
            case .closed, .disconnected:
                terminate(error: ConnectionError.iceConnectionDisconnected)
                
            case .failed:
                let error = ConnectionError.iceConnectionFailed
                mediaConnection?.onFailureHandler?(error)
                terminate(error: error)
                
            default:
                break
            }
        }
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didChange newState: RTCIceGatheringState) {
        eventLog?.markFormat(type: .PeerConnection,
                             format: "ICE gathering state changed: %@",
                             arguments: newState.description)
        switch state {
        case .disconnected, .terminated:
            break
            
        case .disconnecting:
            proceedDisconnecting()
            
        default:
            peerConnectionEventHandlers?
                .onChangeIceGatheringStateHandler?(nativePeerConnection, newState)
        }
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didGenerate candidate: RTCIceCandidate) {
        eventLog?.markFormat(type: .PeerConnection, format: "candidate generated: %@",
                             arguments: candidate.sdp)
        switch state {
        case .disconnected, .terminated:
            break
            
        case .disconnecting:
            proceedDisconnecting()
            
        default:
            peerConnectionEventHandlers?
                .onGenerateIceCandidateHandler?(nativePeerConnection, candidate)
            if let error = send(SignalingICECandidate(candidate: candidate.sdp)) {
                eventLog!.markFormat(type: .PeerConnection,
                                     format: "send candidate to server failed")
                terminate(error: error)
            }
        }
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didRemove candidates: [RTCIceCandidate]) {
        eventLog?.markFormat(type: .PeerConnection,
                             format: "candidates %d removed",
                             arguments: candidates.count)
        switch state {
        case .disconnected, .terminated:
            break
            
        case .disconnecting:
            proceedDisconnecting()
            
        default:
            peerConnectionEventHandlers?
                .onRemoveCandidatesHandler?(nativePeerConnection, candidates)
        }
    }
    
    // NOTE: Sora はデータチャネルに非対応
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didOpen dataChannel: RTCDataChannel) {
        eventLog?.markFormat(type: .PeerConnection,
                             format:
            "data channel opened (Sora does not support data channels")
    }
    
}