// The viewers: the listener that advertises the share (`startAdvertising`), the connections that must prove the code
// before one takes the seat (`attach`, `linkStateChanged`), the wrong codes that rotate it (`rotateCode`), what the
// viewer sends back (`handleIncoming`), and ending them all when the share stops sending (`endViewers`).

import Foundation
import NitidoCore
import NitidoLink
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "share")

extension ShareModel {
    /// What the share tells viewers about itself: this Mac's name and the picture's size and scale, sent by the
    /// listener, and again on every resize and takeover.
    var hello: Hello {
        Hello(protocolVersion: protocolVersion, role: .share, name: name,
              pixelWidth: UInt16(min(pixelSize.width, 65535)), pixelHeight: UInt16(min(pixelSize.height, 65535)), scale: Float(scale))
    }

    func startAdvertising() {
        guard advertiser == nil else { return }
        do {
            let adv = try Advertiser(name: name, code: code, hello: hello)
            advertiser = adv
            // Weak on every connection, as in every ShareModel loop: a whole-loop `guard let self` keeps the model
            // alive for as long as the listener lives (Task 8 fix round 1).
            tasks.append(Task { [weak self] in
                // Retired before it ran: the listener is stopped already, and starting it now would wait forever.
                guard !Task.isCancelled else { return }
                do {
                    let port = try await adv.start()
                    // Ready just before a rotation or a failure retired it, this listener's port is no longer the one
                    // viewers can reach.
                    if let self, adv === advertiser {
                        log.info("listening for viewers on port \(port, privacy: .public)")
                        listeningPort = port
                    }
                } catch {
                    // A failure is also on `adv.states`, which fails the share (`advertiserStateChanged`). A listener
                    // stopped before it was ready throws too, and that is a retired session, not a failure.
                    return
                }
                for await incoming in adv.incoming {
                    guard let self else { return }
                    // A connection the listener took before a rotation or a failure retired it (`rotateCode`,
                    // `endViewers`) can still be in its stream: it was made for a code or a share that is gone, so it
                    // goes, rather than pair with the old code or count against the new one.
                    guard adv === advertiser else { incoming.close(); continue }
                    attach(incoming)
                }
            })
            // A listener that fails after it started ends `incoming` without a word: its states say why.
            tasks.append(Task { [weak self] in
                for await s in adv.states {
                    guard let self else { return }
                    advertiserStateChanged(s, of: adv)
                }
            })
        } catch {
            log.error("could not create the network listener: \(String(describing: error), privacy: .public)")
            state = .failed("Nítido could not listen for viewers on the local network (error \((error as NSError).code)). Press Retry to try again.")
            endViewers()
        }
    }

    /// A wait says why viewers cannot reach this Mac yet (Local Network off, for one). A failure, before or after the
    /// listener was ready, fails the share with Retry: nobody could join it any more. A retired listener says nothing.
    private func advertiserStateChanged(_ s: Advertiser.State, of adv: Advertiser) {
        guard adv === advertiser else { return }
        switch s {
        case .ready: networkNotice = nil
        case .advertised(let registered): advertisedName = registered
        case .waiting(let reason): networkNotice = "Viewers cannot reach this Mac. \(reason)"
        case .failed(let reason):
            networkNotice = nil
            state = .failed("Nítido stopped listening for viewers on the local network. \(reason) Press Retry to listen again.")
            endViewers()
        case .stopped: break
        }
    }

    /// The share stopped sending: a capture, codec or listener failure, or Stop Sharing in the menu bar (the stream ends
    /// with an error). The viewer is told with `bye(sharingStopped)` and says the sharer stopped sharing, instead of
    /// staying connected over a frozen picture, and the listener stops, so nobody new pairs with a share that sends
    /// nothing. Retry listens again (`start`, then `.started`, then `startAdvertising`).
    func endViewers() {
        if link != nil { log.info("the share stopped sending; ending the viewer's link and the listener"); ink.endRemoteStrokes() }
        link?.close(reason: ByeReason.sharingStopped); link = nil
        linkTasks.forEach { $0.cancel() }; linkTasks = []
        unpaired.values.forEach { $0.link.close(); $0.states.cancel() }; unpaired = [:]
        isSending = false; viewerName = nil; viewerReconnecting = false; reconnectGraceToken &+= 1; viewerNeedsKeyframe = false
        heldFromSeq = nil
        forgetForcedKeyframes()
        advertiser?.stop(); advertiser = nil; listeningPort = nil; networkNotice = nil; advertisedName = nil; viewerNotice = nil
    }

    /// One viewer at a time, and only one that proved the code. The listener hands a connection over before its
    /// TLS-PSK handshake has run, so it could be anybody on the network: a port scan, or a viewer with a mistyped
    /// code. It waits here, apart from the viewer, and takes over only once it is ready (`linkStateChanged`).
    private func attach(_ incoming: NitidoLink.Link) {
        // Each connection is a handshake run against the current code: capped, so a host cannot test many guesses at
        // once before the ninth failure is counted, nor hold the listener with connections that never speak.
        let host = incoming.remoteHost
        guard Self.admitsUnpaired(from: host, among: unpaired.values.map(\.link.remoteHost)) else {
            log.info("letting go of a connection from \(host ?? "an unknown address", privacy: .public) at once: \(self.unpaired.count, privacy: .public) connections are already proving the code")
            incoming.close()
            return
        }
        // Weak on every state, as every ShareModel loop is (Task 8 fix round 1). Plain tasks rather than a task group:
        // Swift 6 rejects a weak capture of the model in a group's `@MainActor` child task.
        let states = Task { [weak self] in
            for await s in incoming.states {
                guard let self else { return }
                linkStateChanged(s, for: incoming)
            }
        }
        unpaired[ObjectIdentifier(incoming)] = (incoming, states)
    }

    /// At most this many connections prove the code at once, and at most `maxUnpairedPerAddress` from one address.
    nonisolated static let maxUnpaired = 8
    nonisolated static let maxUnpairedPerAddress = 3

    /// Whether a connection from `host` may start proving the code while connections from `hosts` still do.
    nonisolated static func admitsUnpaired(from host: String?, among hosts: [String?]) -> Bool {
        hosts.count < maxUnpaired && hosts.filter { $0 == host }.count < maxUnpairedPerAddress
    }

    private func linkStateChanged(_ s: NitidoLink.Link.State, for l: NitidoLink.Link) {
        switch s {
        case .ready:
            // The handshake proved the code and the hellos match: this viewer takes over from the current one, which is
            // told another Mac took its seat. Its messages are heard from now on (they wait in the link's stream until then).
            guard let pairing = unpaired.removeValue(forKey: ObjectIdentifier(l)) else { return }
            if link != nil { ink.endRemoteStrokes() }   // the viewer it replaces sends no more points
            link?.close(reason: ByeReason.replaced)
            linkTasks.forEach { $0.cancel() }
            link = l; viewerName = l.peerHello?.name; isSending = true; connectionCount += 1
            viewerReconnecting = false; reconnectGraceToken &+= 1; viewerNotice = nil
            // The hello the link sent was the listener's when the connection came in: a resize since (its handshake can
            // straddle one) would leave this viewer with the old size and scale. The current ones are said again.
            l.send(.hello(hello))
            linkTasks = [
                pairing.states,
                Task { [weak self] in
                    for await m in l.messages {
                        guard let self, link === l else { return }
                        handleIncoming(m)
                    }
                },
            ]
            // Each viewer starts from the initial rate for the picture's size (spec 8), not from the rate a congested
            // viewer before it left. With the codec loop on, the slider keeps the rate; without an encoder, the next
            // frame makes one at the initial rate (`makeEncoder`).
            if !loopback, let encoder {
                currentBitrate = BitrateController.initialBitrate(width: encoder.width, height: encoder.height)
                controller = BitrateController(initial: currentBitrate)
                encoder.setBitrate(currentBitrate)
            }
            // A skip, a hold-off or a time over the threshold was the last viewer's link's.
            backlogPolicy = BacklogPolicy()
            viewerNeedsKeyframe = true; heldFromSeq = encoder?.nextSeq
            // A new viewer's first keyframe goes at once; one that comes back shares the limit of its link before.
            let host = l.remoteHost
            if host == nil || host != forcedKeyframesViewer { forgetForcedKeyframes(); forcedKeyframesViewer = host }
            forceKeyframe()
        case .failed(let m):
            if unpaired.removeValue(forKey: ObjectIdentifier(l)) != nil {
                // It proved the code and speaks another protocol version: said over the picture (spec 12), and the
                // viewer, if any, goes on as it was. Not a wrong code.
                if l.incompatible { noteIncompatible(l); return }
                // A wrong code, or not a viewer at all: the viewer, if any, goes on as it was. A link that was the
                // viewer's had proved the code, so only these can count as wrong codes, and only those that failed on
                // the keys, once per attempt (`HandshakeFailures`).
                let host = l.remoteHost
                let counted = handshakeFailures.record(host: host, keyMismatch: l.keyMismatch, at: handshakeClock())
                let verdict = !l.keyMismatch ? "not a wrong code"
                    : counted ? "wrong code \(handshakeFailures.count) of \(HandshakeFailures.rotateAfter)"
                    : "the same attempt as the last failure from there"
                log.info("a connection from \(host ?? "an unknown address", privacy: .public) ended before it proved the code (\(verdict, privacy: .public)): \(m, privacy: .public)")
                if handshakeFailures.shouldRotate { rotateCode() }
                return
            }
            guard l === link else { return }
            // Gone without `bye`: a viewer reconnects by itself (`LinkSession`), so it is shown as reconnecting. A stroke
            // it was drawing gets no `.end` now: it fades like an ended one.
            isSending = false; link = nil; log.info("viewer link failed: \(m, privacy: .public)")
            ink.endRemoteStrokes()
            viewerReconnecting = true
            reconnectGraceToken &+= 1
            let token = reconnectGraceToken, grace = reconnectGrace
            Task { [weak self] in
                do { try await Task.sleep(for: grace) } catch { return }
                guard let self, token == reconnectGraceToken, viewerReconnecting else { return }
                log.info("the viewer did not come back; waiting for a viewer")
                viewerReconnecting = false; viewerName = nil
            }
        case .cancelled:
            if unpaired.removeValue(forKey: ObjectIdentifier(l)) != nil {
                if l.incompatible { noteIncompatible(l) }
                return
            }
            guard l === link else { return }
            isSending = false; viewerName = nil; link = nil; viewerReconnecting = false; reconnectGraceToken &+= 1
            ink.endRemoteStrokes()
        case .connecting: break
        }
    }

    /// A Mac that proved the code but speaks another protocol version (`Link.incompatible`): the share says so over the
    /// picture, naming both versions, and the Mac never took the seat (a link is ready only once the hellos match).
    private func noteIncompatible(_ l: NitidoLink.Link) {
        let who = l.peerHello?.name ?? "A Mac"
        let theirs = l.peerHello.map { " (protocol \($0.protocolVersion); this Mac speaks \(protocolVersion))" } ?? ""
        log.info("\(who, privacy: .public) proved the code but speaks another protocol version\(theirs, privacy: .public)")
        viewerNotice = "\(who) runs a different version of Nítido\(theirs). Update both Macs."
    }

    /// Three wrong codes over the share (a viewer pairing in between does not reset the count, spec 13) mean someone may
    /// be guessing: new code, new key, so a paired viewer can see the code change and need the new one after its next
    /// drop. Port probes and handshakes cut short do not count (`HandshakeFailures`). Internal so a test can change the
    /// code between a connection reaching the old listener's stream and the share taking it from there.
    func rotateCode() {
        handshakeFailures.rotated()
        // A new code, never the one being guessed (`makeCode` repeats one in 10,000 draws).
        let old = code
        repeat { code = Pairing.makeCode() } while code == old
        log.info("three wrong codes; showing a new one")
        // The connections still in their handshake on the old listener were made for the old code, which no longer
        // pairs: they go with it, so none can pair with the old code, nor fail later and count against the new one.
        if !unpaired.isEmpty {
            let n = unpaired.count
            log.info("letting go of \(n, privacy: .public) connection\(n == 1 ? "" : "s", privacy: .public) still proving the old code")
        }
        unpaired.values.forEach { $0.link.close(); $0.states.cancel() }; unpaired = [:]
        advertiser?.stop(); advertiser = nil
        listeningPort = nil   // the stopped listener's port; the new listener sets its own once ready
        startAdvertising()
    }

    private func handleIncoming(_ m: Message) {
        switch m {
        case .hello(let h): viewerName = h.name
        case .stroke(let s): ink.applyRemote(s)
        case .undo(let id): ink.undoRemote(id: id)
        case .clear: ink.clearRemote()
        case .cursor(let c): ink.remoteCursor(c, name: viewerName ?? "Viewer")
        case .keyframeRequest: forceKeyframe()
        default: break
        }
    }
}
