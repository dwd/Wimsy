//! Core Endpoint API - Direct Quinn endpoint wrapper

use flutter_rust_bridge::frb;
use crate::core::connection::QuicConnection;
use crate::errors::QuicError;
use std::net::{SocketAddr, Ipv4Addr, Ipv6Addr};
use std::sync::Arc;

#[frb(opaque)]
pub struct QuicEndpoint {
    inner: quinn::Endpoint,
}

impl QuicEndpoint {
    /// Create a new server endpoint with the given configuration
    pub fn server(config: crate::core::config::QuicServerConfig, addr: String) -> Result<Self, QuicError> {
        let rt = tokio::runtime::Runtime::new()
            .map_err(|e| QuicError::Endpoint(format!("Failed to create runtime: {:?}", e)))?;
        
        rt.block_on(async {
            let addr: SocketAddr = addr.parse()
                .map_err(|e| QuicError::Config(format!("Invalid address: {:?}", e)))?;
            
            let endpoint = quinn::Endpoint::server(config.into_inner(), addr)
                .map_err(|e| QuicError::Endpoint(format!("Failed to create server endpoint: {:?}", e)))?;
            
            Ok(Self { inner: endpoint })
        })
    }

    /// Create a new client endpoint with insecure configuration (for testing)
    pub fn client() -> Result<Self, QuicError> {
        let bind_addr = SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), 0);
        Self::client_with_bind_addr(bind_addr, None)
    }

    /// Create a client endpoint suitable for the target remote address family.
    pub fn client_for_remote(remote_addr: SocketAddr) -> Result<Self, QuicError> {
        Self::client_for_remote_with_qlog(remote_addr, None)
    }

    /// Create a client endpoint suitable for the target remote address family,
    /// optionally writing a qlog trace to `qlog_path`.
    pub fn client_for_remote_with_qlog(
        remote_addr: SocketAddr,
        qlog_path: Option<String>,
    ) -> Result<Self, QuicError> {
        let bind_addr = if remote_addr.is_ipv6() {
            SocketAddr::new(Ipv6Addr::UNSPECIFIED.into(), 0)
        } else {
            SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), 0)
        };
        Self::client_with_bind_addr(bind_addr, qlog_path)
    }

    fn client_with_bind_addr(bind_addr: SocketAddr, qlog_path: Option<String>) -> Result<Self, QuicError> {
        // Ensure crypto provider is installed
        if rustls::crypto::CryptoProvider::get_default().is_none() {
            rustls::crypto::ring::default_provider()
                .install_default()
                .map_err(|_| QuicError::Config("Failed to install default crypto provider".to_string()))?;
        }
        
        // Create insecure client config
        let crypto = rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(SkipServerVerification::new())
            .with_no_client_auth();
        let mut crypto = crypto;
        crypto.alpn_protocols = vec![b"xmpp-client".to_vec()];
            
        let mut config = quinn::ClientConfig::new(Arc::new(
            quinn::crypto::rustls::QuicClientConfig::try_from(crypto)
                .map_err(|e| QuicError::Config(format!("Failed to create QUIC client config: {:?}", e)))?
        ));
        
        // Configure transport parameters for better performance
        let mut transport = quinn::TransportConfig::default();
        // Do not advertise a max_idle_timeout — we leave it as None (infinite) so the
        // server's preference wins during negotiation.  If the server also advertises no
        // timeout the connection can remain idle indefinitely; if it does advertise one,
        // that value becomes the negotiated timeout.  Application-level PING frames
        // (sent by the Dart layer based on the negotiated QUIC and/or XMPP idle timeout)
        // keep the connection alive without imposing an arbitrary local limit.
        // Similarly, we do not set keep_alive_interval here; the Dart layer drives
        // periodic QUIC PING frames via connection_send_ping() instead.
        transport.max_concurrent_bidi_streams(25u32.into());
        transport.max_concurrent_uni_streams(25u32.into());
        // Reduce buffer sizes to prevent bufferbloat on low-bandwidth / high-latency
        // paths.  Quinn's defaults (send_window=16 MiB, stream/connection receive
        // windows=8 MiB) can queue many seconds of data on a slow link, inflating
        // application-perceived latency far above the wire RTT.  256 KiB send window
        // and receive windows keep the in-flight queue shallow (≈2 RTTs at 1 Mbps)
        // while still allowing full throughput on fast paths.  The receive windows
        // also tell the server to slow its burst sending, which is the client-side
        // lever for inbound bufferbloat without requiring server changes.
        transport.send_window(256 * 1024);
        transport.stream_receive_window(quinn::VarInt::from_u32(256 * 1024));
        transport.receive_window(quinn::VarInt::from_u32(512 * 1024));

        // If a qlog path was provided, open the file and attach a qlog stream
        // so Quinn writes a full QUIC trace (transport events, stream opens,
        // flow-control frames, etc.) to that file for offline analysis with
        // tools like qvis (https://qvis.quictools.info/).
        if let Some(ref path) = qlog_path {
            match std::fs::File::create(path) {
                Ok(file) => {
                    let mut qlog_config = quinn_proto::QlogConfig::default();
                    qlog_config.writer(Box::new(file));
                    qlog_config.title(Some("Wimsy QUIC trace".to_string()));
                    qlog_config.description(Some(format!("QUIC connection to {}", path)));
                    if let Some(stream) = qlog_config.into_stream() {
                        transport.qlog_stream(Some(stream));
                    }
                }
                Err(e) => {
                    tracing::warn!("qlog: failed to create file {:?}: {}", path, e);
                }
            }
        }

        config.transport_config(Arc::new(transport));
        
        // Create endpoint with default socket
        let mut endpoint = quinn::Endpoint::client(bind_addr)
            .map_err(|e| QuicError::Endpoint(format!("Failed to create client endpoint: {:?}", e)))?;
            
        endpoint.set_default_client_config(config);
        
        Ok(Self { inner: endpoint })
    }
    
    /// Connect to a server
    pub async fn connect(&self, addr: String, server_name: String) -> Result<QuicConnection, QuicError> {
        let addr: SocketAddr = addr.parse()
            .map_err(|e| QuicError::Connection(format!("Invalid address: {:?}", e)))?;
        
        let connecting = self.inner.connect(addr, &server_name)
            .map_err(|e| QuicError::Connection(format!("Failed to initiate connection: {:?}", e)))?;
        
        let connection = connecting.await
            .map_err(|e| QuicError::Connection(format!("Failed to establish connection: {:?}", e)))?;
        
        Ok(QuicConnection::new(connection))
    }
    
    /// Rebind the endpoint's UDP socket to a fresh unspecified address on the
    /// same address family as the current local socket.  Quinn will then
    /// automatically send a PATH_CHALLENGE on the new path, enabling QUIC
    /// connection migration (RFC 9000 §9) without tearing down the XMPP
    /// session.
    pub fn rebind_to_current_address(&self) -> Result<(), QuicError> {
        // Determine the address family from the current local address so we
        // bind the new socket on the same family (IPv4 vs IPv6).
        let local_addr = self.inner.local_addr()
            .map_err(|e| QuicError::Endpoint(format!("Failed to get local address: {:?}", e)))?;
        let bind_addr = if local_addr.is_ipv6() {
            std::net::SocketAddr::new(Ipv6Addr::UNSPECIFIED.into(), 0)
        } else {
            std::net::SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), 0)
        };
        let socket = std::net::UdpSocket::bind(bind_addr)
            .map_err(|e| QuicError::Endpoint(format!("Failed to bind new UDP socket: {:?}", e)))?;
        self.inner.rebind(socket)
            .map_err(|e| QuicError::Endpoint(format!("Failed to rebind endpoint: {:?}", e)))?;
        Ok(())
    }

    /// Get a reference to the inner Quinn endpoint
    pub(crate) fn inner(&self) -> &quinn::Endpoint {
        &self.inner
    }
}

/// Skip server certificate verification for testing purposes
#[derive(Debug)]
struct SkipServerVerification;

impl SkipServerVerification {
    fn new() -> Arc<Self> {
        Arc::new(Self)
    }
}

impl rustls::client::danger::ServerCertVerifier for SkipServerVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &rustls::pki_types::CertificateDer<'_>,
        _intermediates: &[rustls::pki_types::CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        vec![
            rustls::SignatureScheme::RSA_PKCS1_SHA1,
            rustls::SignatureScheme::ECDSA_SHA1_Legacy,
            rustls::SignatureScheme::RSA_PKCS1_SHA256,
            rustls::SignatureScheme::ECDSA_NISTP256_SHA256,
            rustls::SignatureScheme::RSA_PKCS1_SHA384,
            rustls::SignatureScheme::ECDSA_NISTP384_SHA384,
            rustls::SignatureScheme::RSA_PKCS1_SHA512,
            rustls::SignatureScheme::ECDSA_NISTP521_SHA512,
            rustls::SignatureScheme::RSA_PSS_SHA256,
            rustls::SignatureScheme::RSA_PSS_SHA384,
            rustls::SignatureScheme::RSA_PSS_SHA512,
            rustls::SignatureScheme::ED25519,
            rustls::SignatureScheme::ED448,
        ]
    }
} 
