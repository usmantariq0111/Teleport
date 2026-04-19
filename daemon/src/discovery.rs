//! Local-network discovery via Bonjour / mDNS-SD.
//!
//! When the host starts, it advertises a service of type
//! `_teleport._tcp.local.` on the configured port. Joiners on the same
//! Wi-Fi / LAN see it appear without anyone typing an IP address.
//!
//! We only advertise — the joiner-side browser lives in the Swift UI
//! (uses Apple's NWBrowser, which integrates with the macOS network
//! permissions dialog). That keeps the Rust binary slim and avoids two
//! mDNS resolvers fighting on the same host.
//!
//! TXT record keys we set:
//!   * `v` — protocol version (matches `proto::PROTOCOL_VERSION`)
//!   * `host` — the OS-reported hostname, for the UI's peer list
//!
//! The handle returned from `start_advertising` keeps the registration
//! alive; dropping it shuts the service down so it doesn't linger if
//! the host stops.

use crate::proto::PROTOCOL_VERSION;
use mdns_sd::{ServiceDaemon, ServiceInfo};

const SERVICE_TYPE: &str = "_teleport._tcp.local.";

/// Holds the running mDNS daemon + the registered service name. Drop to
/// unregister and stop responding to queries.
pub struct BonjourAdvertisement {
    daemon: ServiceDaemon,
    full_name: String,
}

impl BonjourAdvertisement {
    pub fn shutdown(self) {
        // Best-effort: unregister, then shutdown. Errors only matter for
        // logs; the OS will drop the registration when the process dies
        // anyway.
        let _ = self.daemon.unregister(&self.full_name);
        let _ = self.daemon.shutdown();
    }
}

impl Drop for BonjourAdvertisement {
    fn drop(&mut self) {
        let _ = self.daemon.unregister(&self.full_name);
        let _ = self.daemon.shutdown();
    }
}

/// Start advertising. Returns `None` (and logs to stderr) if mDNS
/// initialisation fails — the host still works fine, joiners just need
/// to type the IP manually.
pub fn start_advertising(port: u16) -> Option<BonjourAdvertisement> {
    let daemon = match ServiceDaemon::new() {
        Ok(d) => d,
        Err(e) => {
            eprintln!("⚠️  Bonjour: failed to start mDNS daemon: {e}");
            return None;
        }
    };

    let raw_hostname = gethostname::gethostname()
        .to_string_lossy()
        .into_owned();
    let hostname = sanitize_for_mdns(&raw_hostname);
    let instance_name = format!("Teleport @ {hostname}");

    // mDNS expects the host name to end with `.local.`.
    let mdns_hostname = format!("{hostname}.local.");

    let mut txt = std::collections::HashMap::new();
    txt.insert("v".to_string(), PROTOCOL_VERSION.to_string());
    txt.insert("host".to_string(), raw_hostname);

    let service = match ServiceInfo::new(
        SERVICE_TYPE,
        &instance_name,
        &mdns_hostname,
        "",        // empty addresses → mdns-sd will autodetect non-loopback IPv4s
        port,
        Some(txt),
    ) {
        Ok(svc) => svc.enable_addr_auto(),
        Err(e) => {
            eprintln!("⚠️  Bonjour: failed to build ServiceInfo: {e}");
            let _ = daemon.shutdown();
            return None;
        }
    };

    let full_name = service.get_fullname().to_string();
    if let Err(e) = daemon.register(service) {
        eprintln!("⚠️  Bonjour: failed to register service: {e}");
        let _ = daemon.shutdown();
        return None;
    }

    println!("📣 Bonjour: advertising '{instance_name}' on port {port}");
    Some(BonjourAdvertisement { daemon, full_name })
}

/// mDNS service instance names allow most printable Unicode but pragmatic
/// readability says strip anything weird that some browsers choke on.
fn sanitize_for_mdns(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' {
                c
            } else {
                '-'
            }
        })
        .collect();
    let trimmed = cleaned.trim_matches('-');
    if trimmed.is_empty() {
        "teleport-host".to_string()
    } else {
        trimmed.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::sanitize_for_mdns;

    #[test]
    fn sanitises_spaces_and_unicode() {
        assert_eq!(sanitize_for_mdns("Dev's MacBook Pro"), "Dev-s-MacBook-Pro");
        assert_eq!(sanitize_for_mdns("---"), "teleport-host");
        assert_eq!(sanitize_for_mdns("résumé"), "r-sum");
        assert_eq!(sanitize_for_mdns(""), "teleport-host");
    }
}
