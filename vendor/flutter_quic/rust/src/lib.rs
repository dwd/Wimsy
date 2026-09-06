

pub mod api;
pub mod core;
pub mod convenience;
pub mod models;
pub mod errors;
mod frb_generated;

// Re-export convenience API for easy access
pub use convenience::{QuicClient, QuicClientConfig};

#[cfg(test)]
mod tests {
    use super::core::QuicEndpoint;

    #[tokio::test]
    async fn client_endpoint_creation() {
        let endpoint = QuicEndpoint::client().expect("create client endpoint");
        assert!(endpoint.inner().local_addr().is_ok());
    }

    #[tokio::test]
    async fn silent_peer_acquisition_has_a_caller_deadline() {
        // Hold a UDP port open without answering, rather than relying on an
        // external server or waiting for the production two-hour idle timeout.
        let silent = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        let endpoint = QuicEndpoint::client().unwrap();
        let result = tokio::time::timeout(std::time::Duration::from_millis(100),
            endpoint.connect(silent.local_addr().unwrap().to_string(), "localhost".into())).await;
        assert!(result.is_err());
    }
}
