import NIOCore

/// Splits an inbound byte stream on `\n`, emitting each line without its
/// delimiter.
///
/// This is deliberately hand-rolled rather than `NIOExtras.LineBasedFrameDecoder`.
/// The only thing this package needs from `swift-nio-extras` is that one type,
/// and depending on it pulls in `swift-nio-http2`, `swift-nio-ssl`,
/// `swift-certificates`, `swift-crypto`, `swift-asn1` and friends — TLS and
/// crypto supply-chain surface, plus build time, for a package that terminates
/// no TLS and needs a newline scan.
///
/// One deliberate behavioural difference from the NIOExtras decoder: a partial
/// trailing line at EOF is **discarded** rather than surfaced as
/// `leftoverDataWhenDone`. Consumers here treat a closed connection as a clean
/// end of stream (the previous hand-rolled `VsockLineReader` returned `nil`),
/// and turning a guest that died mid-line into a thrown error rather than a
/// clean EOF would be a silent behaviour change for every read loop.
struct LineFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    /// Guards against a peer that never sends a newline: without a ceiling the
    /// accumulating buffer would grow until the host ran out of memory.
    let maximumLineLength: Int

    init(maximumLineLength: Int = 1024 * 1024) {
        self.maximumLineLength = maximumLineLength
    }

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let newlineIndex = buffer.readableBytesView.firstIndex(of: 0x0A) else {
            if buffer.readableBytes > maximumLineLength {
                throw FirecrackerError.deserializationError(
                    "Line exceeded \(maximumLineLength) bytes without a newline")
            }
            return .needMoreData
        }

        let length = newlineIndex - buffer.readableBytesView.startIndex
        // `readSlice` cannot fail here: `length` came from the readable view.
        let line = buffer.readSlice(length: length)!
        buffer.moveReaderIndex(forwardBy: 1)  // consume the delimiter
        context.fireChannelRead(wrapInboundOut(line))
        return .continue
    }

    func decodeLast(
        context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool
    ) throws -> DecodingState {
        // Drain any whole lines that arrived with the final read, then let the
        // remainder go. See the note above on why this does not throw.
        while case .continue = try decode(context: context, buffer: &buffer) {}
        buffer.moveReaderIndex(to: buffer.writerIndex)
        return .needMoreData
    }
}
