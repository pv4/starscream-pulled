//
//  WSEngine.swift
//  Starscream
//
//  Created by Dalton Cherry on 6/15/19.
//  Copyright © 2019 Vluxe. All rights reserved.
//

import Foundation

public class WSEngine: Engine, TransportEventClient, FramerEventClient,
FrameCollectorDelegate, HTTPHandlerDelegate {
    private var doLog: (String)->Void
    private let transport: Transport
    private let framer: Framer
    private let httpHandler: HTTPHandler
    private let compressionHandler: CompressionHandler?
    private let certPinner: CertificatePinning?
    private let headerChecker: HeaderValidator
    private var request: URLRequest!
    
    private let frameHandler = FrameCollector()
    private var didUpgrade = false
    private var secKeyValue = ""
    private let writeQueue = DispatchQueue(label: "com.vluxe.starscream.writequeue")
    private let mutex = DispatchSemaphore(value: 1)
    private var canSend = false
    
    weak var delegate: EngineDelegate?
    public var respondToPingWithPong: Bool = true
    
    public init(doLog: ((String)->Void),
                transport: Transport,
                certPinner: CertificatePinning? = nil,
                headerValidator: HeaderValidator = FoundationSecurity(),
                httpHandler: HTTPHandler = FoundationHTTPHandler(),
                framer: Framer = WSFramer(),
                compressionHandler: CompressionHandler? = nil) {
        self.doLog = doLog
        self.transport = transport
        self.framer = framer
        self.httpHandler = httpHandler
        self.certPinner = certPinner
        self.headerChecker = headerValidator
        self.compressionHandler = compressionHandler
        framer.updateCompression(supports: compressionHandler != nil)
        frameHandler.delegate = self
    }
    
    public func register(delegate: EngineDelegate) {
        doLog("WSEngine.register entry")
        self.delegate = delegate
        doLog("WSEngine.register exit")
    }
    
    public func start(request: URLRequest) {
        doLog("WSEngine.start entry")
        mutex.wait()
        let isConnected = canSend
        mutex.signal()
        if isConnected {
            doLog("WSEngine.start exit connected")
            return
        }
        doLog("WSEngine.start continue notConnected")
        
        self.request = request
        transport.register(delegate: self)
        framer.register(delegate: self)
        httpHandler.register(delegate: self)
        frameHandler.delegate = self
        guard let url = request.url else {
            doLog("WSEngine.start exit notUrl")
            return
        }
        doLog("WSEngine.start connecting")
        transport.connect(url: url, timeout: request.timeoutInterval, certificatePinning: certPinner)
        doLog("WSEngine.start exit")
    }
    
    public func stop(closeCode: UInt16 = CloseCode.normal.rawValue) {
        doLog("WSEngine.stop entry")
        let capacity = MemoryLayout<UInt16>.size
        var pointer = [UInt8](repeating: 0, count: capacity)
        writeUint16(&pointer, offset: 0, value: closeCode)
        let payload = Data(bytes: pointer, count: MemoryLayout<UInt16>.size)
        doLog("WSEngine.stop beforeWrite")
        write(data: payload, opcode: .connectionClose, completion: { [weak self] in
            doLog("WSEngine.stop writeCompletion entry")
            self?.reset()
            doLog("WSEngine.stop writeCompletion afterReset")
            self?.forceStop()
            doLog("WSEngine.stop writeCompletion exit")
        })
        doLog("WSEngine.stop exit")
    }
    
    public func forceStop() {
        doLog("WSEngine.forceStop entry")
        transport.disconnect()
        doLog("WSEngine.forceStop exit")
    }
    
    public func write(string: String, completion: (() -> ())?) {
        let data = string.data(using: .utf8)!
        write(data: data, opcode: .textFrame, completion: completion)
    }
    
    public func write(data: Data, opcode: FrameOpCode, completion: (() -> ())?) {
        doLog("WSEngine.write entry")
        writeQueue.async { [weak self] in
            doLog("WSEngine.write cb entry")
            guard let s = self else {
                doLog("WSEngine.write cb exit noSelf")
                return
            }
            doLog("WSEngine.write cb self")
            s.mutex.wait()
            let canWrite = s.canSend
            s.mutex.signal()
            if !canWrite {
                doLog("WSEngine.write cb exit cannotWrite")
                return
            }
            doLog("WSEngine.write cb canWrite")
            
            var isCompressed = false
            var sendData = data
            if let compressedData = s.compressionHandler?.compress(data: data) {
                sendData = compressedData
                isCompressed = true
            }
            
            doLog("WSEngine.write cb creatingFrame")
            let frameData = s.framer.createWriteFrame(opcode: opcode, payload: sendData, isCompressed: isCompressed)
            doLog("WSEngine.write cb writing")
            s.transport.write(data: frameData, completion: {_ in
                doLog("WSEngine.write cb written entry")
                completion?()
                doLog("WSEngine.write cb written exit")
            })
            doLog("WSEngine.write cb exit")
        }
        doLog("WSEngine.write exit")
    }
    
    // MARK: - TransportEventClient
    
    public func connectionChanged(state: ConnectionState) {
        doLog("WSEngine.connectionChanged entry")
        switch state {
        case .connected:
            doLog("WSEngine.connectionChanged.connected entry")
            secKeyValue = HTTPWSHeader.generateWebSocketKey()
            let wsReq = HTTPWSHeader.createUpgrade(request: request, supportsCompression: framer.supportsCompression(), secKeyValue: secKeyValue)
            let data = httpHandler.convert(request: wsReq)
            doLog("WSEngine.connectionChanged.connected written")
            transport.write(data: data, completion: {_ in })
            doLog("WSEngine.connectionChanged.connected exit")
        case .waiting:
            doLog("WSEngine.connectionChanged.waiting")
            break
        case .failed(let error):
            doLog("WSEngine.connectionChanged.failed entry")
            handleError(error)
            doLog("WSEngine.connectionChanged.failed exit")
        case .viability(let isViable):
            doLog("WSEngine.connectionChanged.viability entry")
            broadcast(event: .viabilityChanged(isViable))
            doLog("WSEngine.connectionChanged.viability exit")
        case .shouldReconnect(let status):
            doLog("WSEngine.connectionChanged.shouldReconnect entry")
            broadcast(event: .reconnectSuggested(status))
            doLog("WSEngine.connectionChanged.shouldReconnect exit")
        case .receive(let data):
            doLog("WSEngine.connectionChanged.receive entry")
            if didUpgrade {
                framer.add(data: data)
            } else {
                let offset = httpHandler.parse(data: data)
                if offset > 0 {
                    let extraData = data.subdata(in: offset..<data.endIndex)
                    framer.add(data: extraData)
                }
            }
            doLog("WSEngine.connectionChanged.receive exit")
        case .cancelled:
            doLog("WSEngine.connectionChanged.cancelled entry")
            broadcast(event: .cancelled)
            doLog("WSEngine.connectionChanged.cancelled exit")
        }
        doLog("WSEngine.connectionChanged exit")
    }
    
    // MARK: - HTTPHandlerDelegate
    
    public func didReceiveHTTP(event: HTTPEvent) {
        doLog("WSEngine.didReceiveHttp entry")
        switch event {
        case .success(let headers):
            doLog("WSEngine.didReceiveHttp.success entry")
            if let error = headerChecker.validate(headers: headers, key: secKeyValue) {
                doLog("WSEngine.didReceiveHttp.success beforeHandleError")
                handleError(error)
                doLog("WSEngine.didReceiveHttp exit handleError")
                return
            }
            mutex.wait()
            didUpgrade = true
            canSend = true
            mutex.signal()
            doLog("WSEngine.didReceiveHttp.success compressionHandlerLoad")
            compressionHandler?.load(headers: headers)
            if let url = request.url {
                HTTPCookie.cookies(withResponseHeaderFields: headers, for: url).forEach {
                    HTTPCookieStorage.shared.setCookie($0)
                }
            }

            doLog("WSEngine.didReceiveHttp.success broadcaseConnected")
            broadcast(event: .connected(headers))
            doLog("WSEngine.didReceiveHttp.success exit")
        case .failure(let error):
            doLog("WSEngine.didReceiveHttp.failure entry")
            handleError(error)
            doLog("WSEngine.didReceiveHttp.failure exit")
        }
        doLog("WSEngine.didReceiveHttp exit")
    }
    
    // MARK: - FramerEventClient
    
    public func frameProcessed(event: FrameEvent) {
        doLog("WSEngine.frameProcessed entry")
        switch event {
        case .frame(let frame):
            doLog("WSEngine.frameProcessed frame entry")
            frameHandler.add(frame: frame)
            doLog("WSEngine.frameProcessed frame exit")
        case .error(let error):
            doLog("WSEngine.frameProcessed error entry")
            handleError(error)
            doLog("WSEngine.frameProcessed error exit")
        }
        doLog("WSEngine.frameProcessed exit")
    }
    
    // MARK: - FrameCollectorDelegate
    
    public func decompress(data: Data, isFinal: Bool) -> Data? {
        return compressionHandler?.decompress(data: data, isFinal: isFinal)
    }
    
    public func didForm(event: FrameCollector.Event) {
        doLog("WSEngine.didForm entry")
        switch event {
        case .text(let string):
            doLog("WSEngine.didForm.text entry")
            broadcast(event: .text(string))
            doLog("WSEngine.didForm.text exit")
        case .binary(let data):
            doLog("WSEngine.didForm.binary entry")
            broadcast(event: .binary(data))
            doLog("WSEngine.didForm.binary exit")
        case .pong(let data):
            doLog("WSEngine.didForm.pong entry")
            broadcast(event: .pong(data))
            doLog("WSEngine.didForm.pong exit")
        case .ping(let data):
            doLog("WSEngine.didForm.ping entry")
            broadcast(event: .ping(data))
            if respondToPingWithPong {
                doLog("WSEngine.didForm.ping writing")
                write(data: data ?? Data(), opcode: .pong, completion: nil)
                doLog("WSEngine.didForm.ping written")
            }
            doLog("WSEngine.didForm.ping exit")
        case .closed(let reason, let code):
            doLog("WSEngine.didForm.closed entry")
            broadcast(event: .disconnected(reason, code))
            doLog("WSEngine.didForm.closed stopping")
            stop(closeCode: code)
            doLog("WSEngine.didForm.closed exit")
        case .error(let error):
            doLog("WSEngine.didForm.error entry")
            handleError(error)
            doLog("WSEngine.didForm.error exit")
        }
        doLog("WSEngine.didForm exit")
    }
    
    private func broadcast(event: WebSocketEvent) {
        doLog("WSEngine.broadcast entry")
        delegate?.didReceive(event: event)
        doLog("WSEngine.broadcast exit")
    }
    
    //This call can be coming from a lot of different queues/threads.
    //be aware of that when modifying shared variables
    private func handleError(_ error: Error?) {
        doLog("WSEngine.handleError entry")
        if let wsError = error as? WSError {
            stop(closeCode: wsError.code)
        } else {
            stop()
        }
        
        doLog("WSEngine.handleError didReceiving")
        delegate?.didReceive(event: .error(error))
        doLog("WSEngine.handleError exit")
    }
    
    private func reset() {
        mutex.wait()
        canSend = false
        didUpgrade = false
        mutex.signal()
    }
    
    
}
