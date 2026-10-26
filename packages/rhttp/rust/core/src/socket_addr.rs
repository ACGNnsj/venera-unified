// According to reqwest documentation, the port "0" will use the
// "conventional port for the given scheme", e.g. 80 for HTTP and 443 for HTTPS.
const FALLBACK_PORT: &str = "0";

pub(crate) trait SocketAddrDigester {
    /// Adds `FALLBACK_PORT` when the string has no port.
    fn digest_ip(self) -> String;
}

impl SocketAddrDigester for String {
    fn digest_ip(self) -> String {
        let has_dot = self.contains(".");

        if has_dot && !self.contains(":") {
            // IPv4 without port.
            return format!("{self}:{FALLBACK_PORT}");
        }

        if !has_dot && !self.contains("[") {
            // IPv6 without port.
            return format!("[{self}]:{FALLBACK_PORT}");
        }

        self
    }
}
