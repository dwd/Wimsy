//! Core Endpoint API - Direct Quinn endpoint wrapper

use flutter_rust_bridge::frb;
use crate::core::connection::QuicConnection;
use crate::errors::QuicError;
use std::net::{SocketAddr, Ipv4Addr, Ipv6Addr};
use std::sync::{Arc, OnceLock};

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

    /// Create a client endpoint using the Mozilla trust roots
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
        
        // Reuse the same verifier, credentials and session cache across endpoints.
        // rustls requires their identity to remain stable for session resumption.
        static CRYPTO: OnceLock<Arc<quinn::crypto::rustls::QuicClientConfig>> = OnceLock::new();
        let crypto = CRYPTO.get_or_init(|| {
            let roots = rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
            let mut crypto = rustls::ClientConfig::builder()
                .with_root_certificates(roots)
                .with_no_client_auth();
            crypto.alpn_protocols = vec![b"xmpp-client".to_vec()];
            crypto.enable_early_data = true;
            Arc::new(quinn::crypto::rustls::QuicClientConfig::try_from(crypto)
                .expect("TLS 1.3 provider supports QUIC"))
        }).clone();
        let mut config = quinn::ClientConfig::new(crypto);

        // Configure transport parameters for better performance
        let mut transport = quinn::TransportConfig::default();
        // Advertise a large max_idle_timeout (2 hours) so the server knows we are
        // willing to keep the connection alive for a long time.  Per RFC 9000 §10.1
        // the negotiated idle timeout is min(ours, theirs), so if the server
        // advertises a shorter value (e.g. 30 s) that shorter value wins — but at
        // least we are expressing our preference for a long-lived connection rather
        // than silently accepting whatever the server proposes.  Application-level
        // PING frames (sent by the Dart layer based on the negotiated QUIC and/or
        // XMPP idle timeout) keep the connection alive within that window.
        // Similarly, we do not set keep_alive_interval here; the Dart layer drives
        // periodic QUIC PING frames via connection_send_ping() instead.
        let two_hours_ms = 2 * 60 * 60 * 1000; // 7_200_000 ms
        transport.max_idle_timeout(Some(
            quinn::IdleTimeout::try_from(std::time::Duration::from_millis(two_hours_ms))
                .expect("2-hour idle timeout is within Quinn's VarInt range"),
        ));
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
    
    /// Return a provisional connection only when a cached TLS ticket allows 0-RTT.
    /// No application data is sent here: the caller must first select a winner.
    pub async fn connect_early(&self, addr: String, server_name: String)
        -> Result<(QuicConnection, bool), QuicError> {
        let addr: SocketAddr = addr.parse()
            .map_err(|e| QuicError::Config(format!("Invalid address: {e}")))?;
        let connecting = self.inner.connect(addr, &server_name)
            .map_err(|e| QuicError::Connection(e.to_string()))?;
        match connecting.into_0rtt() {
            Ok((connection, accepted)) => Ok((QuicConnection::early(connection, accepted), true)),
            Err(connecting) => Ok((QuicConnection::new(connecting.await
                .map_err(|e| QuicError::Connection(e.to_string()))?), false)),
        }
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


#[cfg(test)]
mod early_data_tests {
    use super::*;

    async fn resumed_connection(reject: bool) {
        let cert = rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
        let mut server_tls = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(vec![cert.cert.der().clone()],
                rustls_pki_types::PrivatePkcs8KeyDer::from(cert.signing_key.serialize_der()).into()).unwrap();
        server_tls.max_early_data_size = u32::MAX;
        let mut roots = rustls::RootCertStore::empty();
        roots.add(cert.cert.der().clone()).unwrap();
        let mut client_tls = rustls::ClientConfig::builder()
            .with_root_certificates(roots).with_no_client_auth();
        client_tls.enable_early_data = true;
        let client_config = quinn::ClientConfig::new(Arc::new(
            quinn::crypto::rustls::QuicClientConfig::try_from(client_tls).unwrap()));
        let server_config = |tls| quinn::ServerConfig::with_crypto(Arc::new(
            quinn::crypto::rustls::QuicServerConfig::try_from(tls).unwrap()));
        let server = quinn::Endpoint::server(server_config(server_tls.clone()),
            "127.0.0.1:0".parse().unwrap()).unwrap();
        let addr = server.local_addr().unwrap().to_string();
        let mut client = quinn::Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
        client.set_default_client_config(client_config);
        let client = QuicEndpoint { inner: client };

        // Keep both server connections alive until all client assertions finish.
        let (ready_tx, mut ready_rx) = tokio::sync::mpsc::channel(2);
        let task = tokio::spawn(async move {
            let mut connections = Vec::new();
            for round in 0..2 {
                let conn = server.accept().await.unwrap().await.unwrap();
                let (mut send, mut recv) = conn.accept_bi().await.unwrap();
                let data = recv.read_to_end(1024).await.unwrap();
                assert_eq!(data, b"authentication");
                send.write_all(b"success").await.unwrap();
                send.finish().unwrap();
                connections.push(conn);
                if round == 0 && reject {
                    server_tls.max_early_data_size = 0;
                    server.set_server_config(Some(server_config(server_tls.clone())));
                }
                ready_tx.send(()).await.unwrap();
            }
            std::future::pending::<()>().await;
        });
        let first = client.connect(addr.clone(), "localhost".into()).await.unwrap();
        let exchange = async |conn: &quinn::Connection| {
            let (mut send, mut recv) = conn.open_bi().await.unwrap();
            send.write_all(b"authentication").await.unwrap();
            send.finish().unwrap();
            assert_eq!(recv.read_to_end(1024).await.unwrap(), b"success");
        };
        exchange(first.inner()).await;
        ready_rx.recv().await.unwrap();
        let (resumed, early) = client.connect_early(addr, "localhost".into()).await.unwrap();
        assert!(early, "first exchange should have cached an early-data ticket");
        let (mut send, mut recv) = resumed.inner().open_bi().await.unwrap();
        // A fast local server may already have rejected the early stream.
        let _ = send.write_all(b"authentication").await;
        let _ = send.finish();
        assert_eq!(resumed.wait_handshake().await.unwrap(), !reject);
        if reject {
            assert!(recv.read_to_end(1024).await.is_err());
            exchange(resumed.inner()).await;
        } else {
            assert_eq!(recv.read_to_end(1024).await.unwrap(), b"success");
        }
        ready_rx.recv().await.unwrap();
        task.abort();
    }

    #[tokio::test]
    async fn accepts_resumed_early_data() {
        tokio::time::timeout(std::time::Duration::from_secs(10), resumed_connection(false)).await.unwrap();
    }

    #[tokio::test]
    async fn rejects_early_streams_but_allows_replay_after_handshake() {
        tokio::time::timeout(std::time::Duration::from_secs(10), resumed_connection(true)).await.unwrap();
    }
}
