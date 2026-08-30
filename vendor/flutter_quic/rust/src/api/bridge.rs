#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // flutter_rust_bridge installs an Android logger at TRACE by default.
    // Quinn's packet and frame tracing is far too noisy for normal runs and
    // can evict the actual close reason from logcat. Keep warnings, errors,
    // and useful lifecycle information while suppressing per-packet output.
    flutter_rust_bridge::setup_default_user_utils();
    log::set_max_level(log::LevelFilter::Info);
}

// Core API exposure functions to ensure flutter_rust_bridge discovers our types
use crate::core::{QuicEndpoint, QuicConnection, QuicSendStream, QuicRecvStream, QuicSendStreamStats};
use crate::core::{QuicConnectionStats, QuicPathStats, QuicFrameStats, QuicUdpStats};
use crate::core::connection::QuicPeerTransportParams;
use crate::core::{QuicServerConfig, QuicTransportConfig, QuicEndpointConfig};
use crate::convenience::{QuicClient, QuicClientConfig};
use crate::errors::{QuicError, QuicWriteException, QuicReadException, QuicReadToEndException, QuicDatagramException};
use std::net::SocketAddr;



/// Create a new QUIC client endpoint
pub fn create_client_endpoint() -> Result<QuicEndpoint, QuicError> {
    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| QuicError::Endpoint(format!("Failed to create runtime: {:?}", e)))?;
    
    rt.block_on(async {
        QuicEndpoint::client()
    })
}

/// Create a new QUIC server endpoint
pub fn create_server_endpoint(config: QuicServerConfig, addr: String) -> Result<QuicEndpoint, QuicError> {
    QuicEndpoint::server(config, addr)
}

/// Write data to a QUIC send stream
/// This exposes the QuicSendStream.write() method to flutter_rust_bridge
pub async fn send_stream_write(
    mut stream: QuicSendStream,
    data: Vec<u8>,
) -> Result<(QuicSendStream, usize), QuicWriteException> {
    let bytes_written = stream.write(data).await?;
    Ok((stream, bytes_written))
}

/// Write all data to a QUIC send stream
/// This exposes the QuicSendStream.write_all() method to flutter_rust_bridge
pub async fn send_stream_write_all(
    mut stream: QuicSendStream,
    data: Vec<u8>,
) -> Result<QuicSendStream, QuicWriteException> {
    stream.write_all(data).await?;
    Ok(stream)
}

/// Snapshot byte-range acknowledgement state without changing the stream.
pub fn send_stream_stats(
    stream: QuicSendStream,
) -> Result<(QuicSendStream, QuicSendStreamStats), QuicWriteException> {
    let stats = stream.stats()?;
    Ok((stream, stats))
}

/// Finish a QUIC send stream
/// This exposes the QuicSendStream.finish() method to flutter_rust_bridge
pub fn send_stream_finish(
    mut stream: QuicSendStream,
) -> Result<QuicSendStream, QuicWriteException> {
    stream.finish()?;
    Ok(stream)
}

/// Read data from a QUIC recv stream
/// This exposes the QuicRecvStream.read() method to flutter_rust_bridge
pub async fn recv_stream_read(
    mut stream: QuicRecvStream,
    max_length: usize,
) -> Result<(QuicRecvStream, Option<Vec<u8>>), QuicReadException> {
    let data = stream.read(max_length).await?;
    Ok((stream, data))
}

/// Read all remaining data from a QUIC recv stream
/// This exposes the QuicRecvStream.read_to_end() method to flutter_rust_bridge
pub async fn recv_stream_read_to_end(
    mut stream: QuicRecvStream,
    max_length: usize,
) -> Result<(QuicRecvStream, Vec<u8>), QuicReadToEndException> {
    let data = stream.read_to_end(max_length).await?;
    Ok((stream, data))
}

/// Open a bidirectional stream on a QUIC connection.
///
/// Takes a shared reference so multiple concurrent `open_bi` calls can be in
/// flight simultaneously without racing on the Auto_Owned arc. Quinn's
/// `Connection::open_bi` only needs `&self` internally.
///
/// This exposes the QuicConnection.open_bi() method to flutter_rust_bridge.
pub async fn connection_open_bi(
    connection: &QuicConnection,
) -> Result<(QuicSendStream, QuicRecvStream), QuicError> {
    let (send_stream, recv_stream) = connection.open_bi().await?;
    Ok((send_stream, recv_stream))
}

/// Accept the next server-initiated bidirectional stream on a QUIC connection.
///
/// Blocks until the remote peer opens a new bidirectional stream or the
/// connection is closed. Returns `None` (as a missing tuple) when the
/// connection has been terminated.
///
/// Unlike `connection_open_bi`, this function takes a shared reference so it
/// does NOT consume the `QuicConnection` arc. This allows `accept_bi` to block
/// waiting for a server-initiated stream concurrently with `open_bi` calls
/// without holding the Auto_Owned ownership lock.
///
/// This exposes the QuicConnection.accept_bi() method to flutter_rust_bridge.
pub async fn connection_accept_bi(
    connection: &QuicConnection,
) -> Result<(Option<QuicSendStream>, Option<QuicRecvStream>), QuicError> {
    match connection.accept_bi().await {
        Some((send_stream, recv_stream)) => Ok((Some(send_stream), Some(recv_stream))),
        None => Ok((None, None)),
    }
}

/// Open a unidirectional stream on a QUIC connection.
///
/// Takes a shared reference — see `connection_open_bi` for rationale.
///
/// This exposes the QuicConnection.open_uni() method to flutter_rust_bridge.
pub async fn connection_open_uni(
    connection: &QuicConnection,
) -> Result<QuicSendStream, QuicError> {
    let send_stream = connection.open_uni().await?;
    Ok(send_stream)
}

/// Connect to a server using a QUIC endpoint.
///
/// If `qlog_path` is `Some`, Quinn will write a full QUIC event trace (in
/// qlog JSON-SEQ format) to that file for the lifetime of the connection.
/// The resulting file can be analysed offline with tools such as
/// [qvis](https://qvis.quictools.info/) or Wireshark's qlog importer.
///
/// This exposes the QuicEndpoint.connect() method to flutter_rust_bridge.
pub async fn endpoint_connect(
    _endpoint: QuicEndpoint,
    addr: String,
    server_name: String,
    qlog_path: Option<String>,
) -> Result<(QuicEndpoint, QuicConnection), QuicError> {
    // Build the endpoint inside the async executor context.
    let remote_addr: SocketAddr = addr.parse()
        .map_err(|e| QuicError::Connection(format!("Invalid address: {:?}", e)))?;
    let endpoint = QuicEndpoint::client_for_remote_with_qlog(remote_addr, qlog_path)?;
    let connection = endpoint.connect(addr, server_name).await?;
    Ok((endpoint, connection))
}

/// Rebind the endpoint's UDP socket to a fresh unspecified address on the
/// same address family, triggering a QUIC PATH_CHALLENGE on the new path.
/// This enables connection migration (RFC 9000 §9) after a network-interface
/// change without tearing down the XMPP session.
///
/// Takes a shared reference so the endpoint can remain in use while the
/// rebind is in progress.
///
/// This exposes the QuicEndpoint.rebind_to_current_address() method to flutter_rust_bridge.
///
/// This must be `async` so that flutter_rust_bridge dispatches it on the Tokio
/// executor thread pool.  Quinn's `Endpoint::rebind` internally touches the
/// Tokio I/O driver, which panics with "there is no reactor running" when
/// called from a plain OS thread outside a Tokio runtime context.
pub async fn endpoint_rebind_to_current_address(
    endpoint: &QuicEndpoint,
) -> Result<(), QuicError> {
    endpoint.rebind_to_current_address()
}

/// Send a datagram on a QUIC connection.
///
/// Takes a shared reference — see `connection_open_bi` for rationale.
///
/// This exposes the QuicConnection.send_datagram() method to flutter_rust_bridge.
pub fn connection_send_datagram(
    connection: &QuicConnection,
    data: Vec<u8>,
) -> Result<(), QuicDatagramException> {
    connection.send_datagram(data)?;
    Ok(())
}

/// Send a datagram with backpressure on a QUIC connection.
///
/// Takes a shared reference — see `connection_open_bi` for rationale.
///
/// This exposes the QuicConnection.send_datagram_wait() method to flutter_rust_bridge.
pub async fn connection_send_datagram_wait(
    connection: &QuicConnection,
    data: Vec<u8>,
) -> Result<(), QuicDatagramException> {
    connection.send_datagram_wait(data).await?;
    Ok(())
}

/// Read a datagram from a QUIC connection.
///
/// Takes a shared reference — see `connection_open_bi` for rationale.
///
/// This exposes the QuicConnection.read_datagram() method to flutter_rust_bridge.
pub async fn connection_read_datagram(
    connection: &QuicConnection,
) -> Option<Vec<u8>> {
    connection.read_datagram().await
}

/// Get datagram send buffer space.
///
/// Takes a shared reference — see `connection_open_bi` for rationale.
///
/// This exposes the QuicConnection.datagram_send_buffer_space() method to flutter_rust_bridge.
pub fn connection_datagram_send_buffer_space(
    connection: &QuicConnection,
) -> usize {
    connection.datagram_send_buffer_space()
}

/// Get maximum datagram size.
///
/// Takes a shared reference — see `connection_open_bi` for rationale.
///
/// This exposes the QuicConnection.max_datagram_size() method to flutter_rust_bridge.
pub fn connection_max_datagram_size(
    connection: &QuicConnection,
) -> Option<usize> {
    connection.max_datagram_size()
}

// Connection Info bridge functions

/// Get the remote address of a QUIC connection.
///
/// Takes a shared reference — see `connection_open_bi` for rationale.
///
/// This exposes the QuicConnection.remote_address() method to flutter_rust_bridge.
pub fn connection_remote_address(
    connection: &QuicConnection,
) -> crate::models::types::SocketAddress {
    let addr = connection.remote_address();
    crate::models::types::SocketAddress {
        ip: addr.ip().to_string(),
        port: addr.port(),
    }
}

/// Get the local IP address of a QUIC connection.
///
/// Takes a shared reference — see `connection_open_bi` for rationale.
///
/// This exposes the QuicConnection.local_ip() method to flutter_rust_bridge.
pub fn connection_local_ip(
    connection: &QuicConnection,
) -> Option<String> {
    connection.local_ip().map(|ip| ip.to_string())
}

/// Get the RTT of a QUIC connection in milliseconds.
///
/// Takes a shared reference — see `connection_open_bi` for rationale.
///
/// This exposes the QuicConnection.rtt() method to flutter_rust_bridge.
pub fn connection_rtt_millis(
    connection: &QuicConnection,
) -> u64 {
    connection.rtt().as_millis() as u64
}

/// Get the stable ID of a QUIC connection.
///
/// Takes a shared reference — see `connection_open_bi` for rationale.
///
/// This exposes the QuicConnection.stable_id() method to flutter_rust_bridge.
pub fn connection_stable_id(
    connection: &QuicConnection,
) -> usize {
    connection.stable_id()
}

/// Get the close reason of a QUIC connection.
///
/// Takes a shared reference — see `connection_open_bi` for rationale.
///
/// This exposes the QuicConnection.close_reason() method to flutter_rust_bridge.
pub fn connection_close_reason(
    connection: &QuicConnection,
) -> Option<String> {
    connection.close_reason()
}

/// Get the statistics of a QUIC connection.
///
/// Takes a shared reference — see `connection_open_bi` for rationale.
///
/// This exposes the QuicConnection.stats() method to flutter_rust_bridge.
pub fn connection_stats(
    connection: &QuicConnection,
) -> QuicConnectionStats {
    connection.stats()
}

/// Get the peer's advertised QUIC transport parameters relevant to stream credits.
///
/// Exposes [`QuicConnection::peer_transport_params`] across the FFI. Useful for
/// diagnosing `connection_open_bi` hangs caused by the peer advertising a small
/// `initial_max_streams_bidi` and never raising it with `MAX_STREAMS`.
///
/// Takes a shared reference — see `connection_open_bi` for rationale.
pub fn connection_peer_transport_params(
    connection: &QuicConnection,
) -> QuicPeerTransportParams {
    connection.peer_transport_params()
}

/// Send a QUIC PING frame to the peer, eliciting an ACK and resetting the idle timer.
///
/// This is a best-effort keepalive: it causes Quinn to emit a PING frame on the next
/// poll, which the peer must acknowledge. This resets both sides' idle timers, preventing
/// the connection from being closed due to inactivity.
///
/// Takes a shared reference — see `connection_open_bi` for rationale.
pub fn connection_send_ping(connection: &QuicConnection) {
    connection.send_ping();
}

// Configuration builder functions

/// Create a new server config with single certificate
pub fn server_config_with_single_cert(
    cert_chain: Vec<Vec<u8>>,
    key: Vec<u8>,
) -> Result<QuicServerConfig, String> {
    QuicServerConfig::with_single_cert(cert_chain, key)
}

/// Create a new transport config
pub fn transport_config_new() -> QuicTransportConfig {
    QuicTransportConfig::new()
}

/// Create a new endpoint config
pub fn endpoint_config_new() -> QuicEndpointConfig {
    QuicEndpointConfig::new()
}

// Type exposure functions to ensure flutter_rust_bridge discovers our types
pub fn _expose_types_for_frb_generation() {
    let _endpoint: Option<QuicEndpoint> = None;
    let _connection: Option<QuicConnection> = None;
    let _send_stream: Option<QuicSendStream> = None;
    let _recv_stream: Option<QuicRecvStream> = None;
    let _error: Option<QuicError> = None;
    let _write_exception: Option<QuicWriteException> = None;
    let _read_exception: Option<QuicReadException> = None;
    let _read_to_end_exception: Option<QuicReadToEndException> = None;
    let _datagram_exception: Option<QuicDatagramException> = None;
    let _connection_stats: Option<QuicConnectionStats> = None;
    let _path_stats: Option<QuicPathStats> = None;
    let _frame_stats: Option<QuicFrameStats> = None;
    let _udp_stats: Option<QuicUdpStats> = None;
    let _peer_params: Option<QuicPeerTransportParams> = None;
    let _server_config: Option<QuicServerConfig> = None;
    let _transport_config: Option<QuicTransportConfig> = None;
    let _endpoint_config: Option<QuicEndpointConfig> = None;
}

// Legacy expose functions for backwards compatibility with generated code
pub fn _expose_connection_type(connection: QuicConnection) -> QuicConnection {
    connection
}

pub fn _expose_send_stream_type(stream: QuicSendStream) -> QuicSendStream {
    stream
}

pub fn _expose_recv_stream_type(stream: QuicRecvStream) -> QuicRecvStream {
    stream
}

// Convenience API exposure functions

/// Create a new QuicClient with default configuration
pub fn quic_client_create() -> Result<QuicClient, QuicError> {
    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| QuicError::Endpoint(format!("Failed to create runtime: {:?}", e)))?;
    
    rt.block_on(async {
        QuicClient::create()
    })
}

/// Create a new QuicClient with custom configuration
pub fn quic_client_create_with_config(config: QuicClientConfig) -> Result<QuicClient, QuicError> {
    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| QuicError::Endpoint(format!("Failed to create runtime: {:?}", e)))?;
    
    rt.block_on(async {
        QuicClient::create_with_config(config)
    })
}

/// Send data using QuicClient and return response
pub async fn quic_client_send(
    client: QuicClient,
    url: String,
    data: String,
) -> Result<(QuicClient, String), QuicError> {
    let response = client.send(url, data).await?;
    Ok((client, response))
}

/// Send data with timeout using QuicClient
pub async fn quic_client_send_with_timeout(
    client: QuicClient,
    url: String,
    data: String,
) -> Result<(QuicClient, String), QuicError> {
    let response = client.send_with_timeout(url, data).await?;
    Ok((client, response))
}

/// Send a GET request using QuicClient
pub async fn quic_client_get(
    client: QuicClient,
    url: String,
) -> Result<(QuicClient, String), QuicError> {
    let response = client.get(url).await?;
    Ok((client, response))
}

/// Send a POST request using QuicClient
pub async fn quic_client_post(
    client: QuicClient,
    url: String,
    data: String,
) -> Result<(QuicClient, String), QuicError> {
    let response = client.post(url, data).await?;
    Ok((client, response))
}

/// Send a GET request with timeout using QuicClient
pub async fn quic_client_get_with_timeout(
    client: QuicClient,
    url: String,
) -> Result<(QuicClient, String), QuicError> {
    let response = client.get_with_timeout(url).await?;
    Ok((client, response))
}

/// Send a POST request with timeout using QuicClient
pub async fn quic_client_post_with_timeout(
    client: QuicClient,
    url: String,
    data: String,
) -> Result<(QuicClient, String), QuicError> {
    let response = client.post_with_timeout(url, data).await?;
    Ok((client, response))
}

/// Get QuicClient configuration
pub fn quic_client_config(client: QuicClient) -> (QuicClient, QuicClientConfig) {
    let config = client.config();
    (client, config)
}

/// Clear QuicClient connection pool
pub fn quic_client_clear_pool(client: QuicClient) -> QuicClient {
    client.clear_pool();
    client
}

/// Create a new QuicClientConfig with default values
pub fn quic_client_config_new() -> QuicClientConfig {
    QuicClientConfig::default()
}

/// Expose QuicClient and QuicClientConfig types for flutter_rust_bridge
pub fn _expose_quic_client_type(client: QuicClient) -> QuicClient {
    client
}

pub fn _expose_quic_client_config_type(config: QuicClientConfig) -> QuicClientConfig {
    config
}
