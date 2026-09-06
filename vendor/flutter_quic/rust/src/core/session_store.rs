//! Encrypted, transactional TLS ticket storage. A ticket is removed and synced
//! before rustls receives it, including across concurrent processes and crashes.

use fs2::FileExt;
use ring::{
    aead,
    rand::{SecureRandom, SystemRandom},
};
use rustls::{
    client::{ClientSessionKey, ClientSessionStore, Tls12Session, Tls13Session},
    crypto::{kx::NamedGroup, CryptoProvider},
};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};
use zeroize::Zeroizing;

// Both our envelope and rustls's prerelease encoding are version-specific.
const FORMAT: &[u8] = b"wimsy-quic/rustls-0.24.0-dev.1/v1";
const MAX_FILE: u64 = 4 * 1024 * 1024;
type Cache = BTreeMap<String, Vec<Vec<u8>>>;

pub struct PersistentSessions {
    path: PathBuf,
    key: Zeroizing<[u8; 32]>,
    provider: Arc<CryptoProvider>,
    gate: Mutex<()>,
}

impl std::fmt::Debug for PersistentSessions {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PersistentSessions").finish_non_exhaustive()
    }
}

impl PersistentSessions {
    pub fn new(path: PathBuf, key: &[u8], provider: Arc<CryptoProvider>) -> io::Result<Self> {
        if !path.is_absolute() || key.len() != 32 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Invalid ticket-store configuration",
            ));
        }
        let store = Self {
            path,
            key: Zeroizing::new(key.try_into().unwrap()),
            provider,
            gate: Mutex::new(()),
        };
        // Verify that locking and durable writes work before enabling persistence.
        store.transaction(|_| ())?;
        Ok(store)
    }

    fn cache_key(key: &ClientSessionKey<'_>) -> String {
        format!("{:02x?}:{}", key.config_hash, key.server_name.to_str())
    }

    fn cipher(&self) -> aead::LessSafeKey {
        aead::LessSafeKey::new(
            aead::UnboundKey::new(&aead::AES_256_GCM, self.key.as_ref()).unwrap(),
        )
    }

    fn read(&self) -> io::Result<Cache> {
        let mut file = match File::open(&self.path) {
            Ok(file) => file,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Cache::new()),
            Err(e) => return Err(e),
        };
        if file.metadata()?.len() > MAX_FILE {
            return Err(invalid_data());
        }
        let mut bytes = Zeroizing::new(Vec::new());
        file.read_to_end(&mut bytes)?;
        if bytes.len() < FORMAT.len() + 12 + aead::AES_256_GCM.tag_len()
            || !bytes.starts_with(FORMAT)
        {
            return Err(invalid_data());
        }
        let nonce = aead::Nonce::try_assume_unique_for_key(&bytes[FORMAT.len()..FORMAT.len() + 12])
            .map_err(|_| invalid_data())?;
        let plain = self
            .cipher()
            .open_in_place(
                nonce,
                aead::Aad::from(FORMAT),
                &mut bytes[FORMAT.len() + 12..],
            )
            .map_err(|_| invalid_data())?;
        let cache: Cache = serde_json::from_slice(plain).map_err(|_| invalid_data())?;
        if cache.len() > 64 || cache.values().any(|tickets| tickets.len() > 8) {
            return Err(invalid_data());
        }
        Ok(cache)
    }

    fn write(&self, cache: &Cache) -> io::Result<()> {
        let mut bytes = Zeroizing::new(serde_json::to_vec(cache).map_err(io::Error::other)?);
        let mut nonce = [0u8; 12];
        SystemRandom::new()
            .fill(&mut nonce)
            .map_err(|_| io::Error::other("Random source unavailable"))?;
        self.cipher()
            .seal_in_place_append_tag(
                aead::Nonce::assume_unique_for_key(nonce),
                aead::Aad::from(FORMAT),
                &mut *bytes,
            )
            .map_err(|_| io::Error::other("Ticket encryption failed"))?;
        if bytes.len() as u64 + FORMAT.len() as u64 + 12 > MAX_FILE {
            return Err(invalid_data());
        }
        let temporary = self.path.with_extension("tmp");
        let mut file = private_file(&temporary, true)?;
        file.write_all(FORMAT)?;
        file.write_all(&nonce)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        fs::rename(&temporary, &self.path)?;
        #[cfg(unix)]
        File::open(self.path.parent().unwrap())?.sync_all()?;
        Ok(())
    }

    fn transaction<T>(&self, update: impl FnOnce(&mut Cache) -> T) -> io::Result<T> {
        let _gate = self
            .gate
            .lock()
            .map_err(|_| io::Error::other("Ticket-store lock poisoned"))?;
        let lock = private_file(&self.path.with_extension("lock"), false)?;
        lock.lock_exclusive()?;
        // Corruption, a changed key, or a new encoding invalidates tickets.
        // Ordinary I/O failures must not be mistaken for an empty cache.
        let mut cache = match self.read() {
            Ok(cache) => cache,
            Err(e) if e.kind() == io::ErrorKind::InvalidData => Cache::new(),
            Err(e) => return Err(e),
        };
        let result = update(&mut cache);
        self.write(&cache)?;
        // The file lock is released by RAII on every return/error path.
        Ok(result)
    }
}

fn invalid_data() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "Invalid ticket cache")
}

fn private_file(path: &Path, truncate: bool) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options
        .read(true)
        .write(true)
        .create(true)
        .truncate(truncate);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

impl ClientSessionStore for PersistentSessions {
    // Hints are optional; TLS 1.2 cannot be used with QUIC.
    fn set_kx_hint(&self, _: ClientSessionKey<'static>, _: NamedGroup) {}
    fn kx_hint(&self, _: &ClientSessionKey<'_>) -> Option<NamedGroup> {
        None
    }
    fn set_tls12_session(&self, _: ClientSessionKey<'static>, _: Tls12Session) {}
    fn tls12_session(&self, _: &ClientSessionKey<'_>) -> Option<Tls12Session> {
        None
    }
    fn remove_tls12_session(&self, _: &ClientSessionKey<'static>) {}

    fn insert_tls13_ticket(&self, key: ClientSessionKey<'static>, value: Tls13Session) {
        let mut bytes = Vec::new();
        value.encode(&mut bytes);
        let _ = self.transaction(|cache| {
            let tickets = cache.entry(Self::cache_key(&key)).or_default();
            if tickets.len() == 8 {
                tickets.remove(0);
            }
            tickets.push(bytes);
            while cache.len() > 64 {
                cache.pop_first();
            }
        });
    }

    fn take_tls13_ticket(&self, key: &ClientSessionKey<'static>) -> Option<Tls13Session> {
        let bytes = Zeroizing::new(
            self.transaction(|cache| cache.get_mut(&Self::cache_key(key)).and_then(Vec::pop))
                .ok()??,
        );
        Tls13Session::from_slice(&bytes, &self.provider).ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store(path: &Path) -> PersistentSessions {
        PersistentSessions::new(
            path.to_owned(),
            &[7; 32],
            Arc::new(rustls_ring::DEFAULT_PROVIDER),
        )
        .unwrap()
    }

    #[test]
    fn encrypted_transactions_survive_reopen_and_consume_once() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("tickets.bin");
        store(&path)
            .transaction(|cache| {
                cache.insert("server".into(), vec![b"sensitive-ticket-secret".to_vec()]);
            })
            .unwrap();
        let bytes = fs::read(&path).unwrap();
        assert!(!bytes
            .windows(23)
            .any(|part| part == b"sensitive-ticket-secret"));
        let first = store(&path);
        let second = store(&path);
        let take = |s: &PersistentSessions| {
            s.transaction(|cache| cache.get_mut("server").unwrap().pop())
                .unwrap()
        };
        assert_eq!(take(&first).unwrap(), b"sensitive-ticket-secret");
        assert!(take(&second).is_none());
    }

    #[test]
    fn corruption_and_wrong_keys_discard_tickets() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("tickets.bin");
        store(&path)
            .transaction(|cache| {
                cache.insert("server".into(), vec![vec![1, 2, 3]]);
            })
            .unwrap();
        let wrong = PersistentSessions::new(
            path.clone(),
            &[8; 32],
            Arc::new(rustls_ring::DEFAULT_PROVIDER),
        )
        .unwrap();
        assert!(wrong.transaction(|cache| cache.is_empty()).unwrap());
        fs::write(&path, b"truncated or obsolete cache format").unwrap();
        assert!(store(&path).transaction(|cache| cache.is_empty()).unwrap());
    }

    #[test]
    fn failed_commit_does_not_release_a_ticket() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("tickets.bin");
        let store = store(&path);
        store
            .transaction(|cache| {
                cache.insert("server".into(), vec![vec![1]]);
            })
            .unwrap();
        // A directory at the temporary-file path makes the durable write fail.
        fs::create_dir(path.with_extension("tmp")).unwrap();
        assert!(store
            .transaction(|cache| cache.get_mut("server").unwrap().pop())
            .is_err());
        fs::remove_dir(path.with_extension("tmp")).unwrap();
        assert_eq!(
            store
                .transaction(|cache| cache.get_mut("server").unwrap().pop())
                .unwrap(),
            Some(vec![1])
        );
    }

    #[test]
    fn independent_stores_cannot_consume_the_same_entry() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("tickets.bin");
        store(&path)
            .transaction(|cache| {
                cache.insert("server".into(), (0..8).map(|n| vec![n]).collect());
            })
            .unwrap();
        let workers: Vec<_> = (0..8)
            .map(|_| {
                let path = path.clone();
                std::thread::spawn(move || {
                    store(&path)
                        .transaction(|cache| cache.get_mut("server").unwrap().pop())
                        .unwrap()
                        .unwrap()
                })
            })
            .collect();
        let mut consumed: Vec<_> = workers
            .into_iter()
            .map(|worker| worker.join().unwrap())
            .collect();
        consumed.sort();
        assert_eq!(consumed, (0..8).map(|n| vec![n]).collect::<Vec<_>>());
    }

    // A dedicated test-process entry point: using a fresh OS process proves
    // resumption cannot accidentally rely on shared TLS config or RAM tickets.
    #[test]
    #[ignore = "invoked by resumes_in_a_fresh_process with a live loopback server"]
    fn child_client() {
        let dir = PathBuf::from(std::env::var("XIMPY_TEST_TICKETS").unwrap());
        let addr: std::net::SocketAddr =
            std::env::var("XIMPY_TEST_SERVER").unwrap().parse().unwrap();
        let early_expected = std::env::var("XIMPY_TEST_EARLY").unwrap() == "true";
        tokio::runtime::Runtime::new().unwrap().block_on(async {
            let provider = Arc::new(rustls_ring::DEFAULT_PROVIDER);
            let mut roots = rustls::RootCertStore::empty();
            roots
                .add(rustls_pki_types::CertificateDer::from(
                    fs::read(dir.join("cert.der")).unwrap(),
                ))
                .unwrap();
            if std::env::var("XIMPY_TEST_EXTRA_ROOT").as_deref() == Ok("true") {
                roots
                    .add(rustls_pki_types::CertificateDer::from(
                        fs::read(dir.join("extra.der")).unwrap(),
                    ))
                    .unwrap();
            }
            let mut tls = rustls::ClientConfig::builder(provider)
                .with_root_certificates(roots)
                .with_no_client_auth()
                .unwrap();
            tls.enable_early_data = true;
            tls.resumption =
                rustls::client::Resumption::store(Arc::new(store(&dir.join("tickets.bin"))));
            let mut endpoint = quinn::Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
            endpoint.set_default_client_config(quinn::ClientConfig::new(Arc::new(
                quinn::crypto::rustls::QuicClientConfig::try_from(tls).unwrap(),
            )));
            let name = std::env::var("XIMPY_TEST_NAME").unwrap_or_else(|_| "localhost".into());
            let connecting = endpoint.connect(addr, &name).unwrap();
            let (connection, acceptance) = match connecting.into_0rtt() {
                Ok((connection, acceptance)) => {
                    assert!(early_expected, "unexpected persisted ticket");
                    (connection, Some(acceptance))
                }
                Err(connecting) => {
                    assert!(!early_expected, "ticket did not survive process restart");
                    (connecting.await.unwrap(), None)
                }
            };
            let (mut send, mut recv) = connection.open_bi().await.unwrap();
            send.write_all(b"authentication").await.unwrap();
            send.finish().unwrap();
            if let Some(acceptance) = acceptance {
                assert!(acceptance.await);
            }
            assert_eq!(recv.read_to_end(1024).await.unwrap(), b"success");
            connection.close(0u32.into(), b"done");
            endpoint.wait_idle().await;
        });
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn resumes_in_a_fresh_process() {
        tokio::time::timeout(std::time::Duration::from_secs(30), async {
            let dir = tempfile::tempdir().unwrap();
            let cert = rcgen::generate_simple_self_signed(vec![
                "localhost".into(),
                "other.localhost".into(),
            ])
            .unwrap();
            let extra = rcgen::generate_simple_self_signed(vec!["extra.localhost".into()]).unwrap();
            fs::write(dir.path().join("extra.der"), extra.cert.der()).unwrap();
            fs::write(dir.path().join("cert.der"), cert.cert.der()).unwrap();
            let mut tls = rustls::ServerConfig::builder(Arc::new(rustls_ring::DEFAULT_PROVIDER))
                .with_no_client_auth()
                .with_single_cert(
                    Arc::new(
                        rustls::crypto::Identity::from_cert_chain(vec![cert.cert.der().clone()])
                            .unwrap(),
                    ),
                    rustls_pki_types::PrivatePkcs8KeyDer::from(cert.signing_key.serialize_der())
                        .into(),
                )
                .unwrap();
            tls.max_early_data_size = u32::MAX;
            let server = quinn::Endpoint::server(
                quinn::ServerConfig::with_crypto(Arc::new(
                    quinn::crypto::rustls::QuicServerConfig::try_from(tls).unwrap(),
                )),
                "127.0.0.1:0".parse().unwrap(),
            )
            .unwrap();
            let addr = server.local_addr().unwrap();
            let server_task = tokio::spawn(async move {
                while let Some(incoming) = server.accept().await {
                    tokio::spawn(async move {
                        let conn = incoming.await.unwrap();
                        let (mut send, mut recv) = conn.accept_bi().await.unwrap();
                        assert_eq!(recv.read_to_end(1024).await.unwrap(), b"authentication");
                        send.write_all(b"success").await.unwrap();
                        send.finish().unwrap();
                        conn.closed().await;
                    });
                }
            });
            for (round, early) in [false, true, false, false, false, false]
                .into_iter()
                .enumerate()
            {
                if round == 2 {
                    // Expired tickets must force a full handshake in a fresh process.
                    store(&dir.path().join("tickets.bin"))
                        .transaction(|cache| {
                            for tickets in cache.values_mut() {
                                for bytes in tickets {
                                    let mut ticket = Tls13Session::from_slice(
                                        bytes,
                                        &rustls_ring::DEFAULT_PROVIDER,
                                    )
                                    .unwrap();
                                    ticket.rewind_epoch(8 * 24 * 60 * 60);
                                    bytes.clear();
                                    ticket.encode(bytes);
                                }
                            }
                        })
                        .unwrap();
                } else if round == 3 {
                    // Corruption is also recovered by a normal verified handshake.
                    fs::write(dir.path().join("tickets.bin"), b"corrupt").unwrap();
                }
                let path = dir.path().to_owned();
                let output = tokio::task::spawn_blocking(move || {
                    std::process::Command::new(std::env::current_exe().unwrap())
                        .args([
                            "--exact",
                            "core::session_store::tests::child_client",
                            "--ignored",
                            "--nocapture",
                        ])
                        .env("XIMPY_TEST_TICKETS", path)
                        .env("XIMPY_TEST_SERVER", addr.to_string())
                        .env("XIMPY_TEST_EARLY", early.to_string())
                        .env("XIMPY_TEST_EXTRA_ROOT", (round == 4).to_string())
                        .env(
                            "XIMPY_TEST_NAME",
                            if round == 5 {
                                "other.localhost"
                            } else {
                                "localhost"
                            },
                        )
                        .output()
                        .unwrap()
                })
                .await
                .unwrap();
                assert!(
                    output.status.success(),
                    "child failed: {} {}",
                    String::from_utf8_lossy(&output.stdout),
                    String::from_utf8_lossy(&output.stderr)
                );
            }
            server_task.abort();
        })
        .await
        .unwrap();
    }
}
