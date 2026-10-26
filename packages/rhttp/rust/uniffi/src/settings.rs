//! uniffi-facing mirror of [`rhttp_core::ClientSettings`].
//!
//! The core crate keeps the authoritative settings types free of any foreign
//! binding. This module only carries the values across the FFI boundary and
//! converts them field by field, so a Kotlin/Swift caller can express every
//! configuration that the Flutter Rust Bridge adapter can.
//!
//! Two core details cannot be exported as plain data and get an adapter here:
//!
//! * `DnsSettings::DynamicDns` holds an `Arc<dyn DnsResolver>`; it is exported
//!   through the [`DnsResolverCallback`] foreign trait and bridged with
//!   `tokio::task::spawn_blocking` (see `CallbackDnsResolver`).
//! * `chrono::Duration` is converted from `std::time::Duration`, the only
//!   duration type uniffi supports natively.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use rhttp_core::{
    ClientCertificate as CoreClientCertificate, ClientSettings as CoreClientSettings,
    CookieSettings as CoreCookieSettings, CustomProxy as CoreCustomProxy,
    DnsSettings as CoreDnsSettings, DynamicDnsSettings as CoreDynamicDnsSettings,
    HttpVersionPref as CoreHttpVersionPref, ProxyCondition as CoreProxyCondition,
    ProxySettings as CoreProxySettings, RedirectSettings as CoreRedirectSettings,
    StaticDnsSettings as CoreStaticDnsSettings, TimeoutSettings as CoreTimeoutSettings,
    TlsSettings as CoreTlsSettings, TlsVersion as CoreTlsVersion,
};

use crate::RhttpError;

/// Every setting accepted by `RhttpClient.new()`.
///
/// Start from `defaultClientOptions()` and override what you need; every
/// field is optional except the HTTP version preference and the status-code
/// policy, which the core type always carries.
#[derive(Clone, Debug, uniffi::Record)]
pub struct ClientOptions {
    pub user_agent: Option<String>,
    pub http_version_pref: HttpVersionPref,
    /// When true (the default) a non-success status is returned as
    /// `RhttpError.Status` instead of an error-free response.
    pub throw_on_status_code: bool,
    pub cookie_settings: Option<CookieSettings>,
    pub timeout_settings: Option<TimeoutSettings>,
    pub proxy_settings: Option<ProxySettings>,
    pub redirect_settings: Option<RedirectSettings>,
    pub tls_settings: Option<TlsSettings>,
    pub dns_settings: Option<DnsSettings>,
}

/// The settings [`rhttp_core::ClientSettings::default`] would use.
#[uniffi::export]
pub fn default_client_options() -> ClientOptions {
    ClientOptions {
        user_agent: None,
        http_version_pref: HttpVersionPref::All,
        throw_on_status_code: true,
        cookie_settings: None,
        timeout_settings: None,
        proxy_settings: None,
        redirect_settings: None,
        tls_settings: None,
        dns_settings: None,
    }
}

impl ClientOptions {
    pub(crate) fn into_core(self) -> Result<CoreClientSettings, RhttpError> {
        let mut settings = CoreClientSettings::default();
        settings.user_agent = self.user_agent;
        settings.http_version_pref = self.http_version_pref.into();
        settings.throw_on_status_code = self.throw_on_status_code;

        if let Some(cookie_settings) = self.cookie_settings {
            settings.cookie_settings = Some(cookie_settings.into());
        }
        if let Some(timeout_settings) = self.timeout_settings {
            settings.timeout_settings = Some(timeout_settings.into_core()?);
        }
        if let Some(proxy_settings) = self.proxy_settings {
            settings.proxy_settings = Some(proxy_settings.into());
        }
        if let Some(redirect_settings) = self.redirect_settings {
            settings.redirect_settings = Some(redirect_settings.into_core()?);
        }
        if let Some(tls_settings) = self.tls_settings {
            settings.tls_settings = Some(tls_settings.into());
        }
        if let Some(dns_settings) = self.dns_settings {
            settings.dns_settings = Some(dns_settings.into_core());
        }

        Ok(settings)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum HttpVersionPref {
    Http10,
    Http11,
    Http2,
    Http3,
    All,
}

impl From<HttpVersionPref> for CoreHttpVersionPref {
    fn from(value: HttpVersionPref) -> Self {
        match value {
            HttpVersionPref::Http10 => CoreHttpVersionPref::Http10,
            HttpVersionPref::Http11 => CoreHttpVersionPref::Http11,
            HttpVersionPref::Http2 => CoreHttpVersionPref::Http2,
            HttpVersionPref::Http3 => CoreHttpVersionPref::Http3,
            HttpVersionPref::All => CoreHttpVersionPref::All,
        }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CookieSettings {
    pub store_cookies: bool,
}

impl From<CookieSettings> for CoreCookieSettings {
    fn from(value: CookieSettings) -> Self {
        CoreCookieSettings {
            store_cookies: value.store_cookies,
        }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct TimeoutSettings {
    pub timeout: Option<Duration>,
    pub connect_timeout: Option<Duration>,
    pub keep_alive_timeout: Option<Duration>,
    pub keep_alive_ping: Option<Duration>,
}

impl TimeoutSettings {
    fn into_core(self) -> Result<CoreTimeoutSettings, RhttpError> {
        Ok(CoreTimeoutSettings {
            timeout: optional_duration_to_core(self.timeout)?,
            connect_timeout: optional_duration_to_core(self.connect_timeout)?,
            keep_alive_timeout: optional_duration_to_core(self.keep_alive_timeout)?,
            keep_alive_ping: optional_duration_to_core(self.keep_alive_ping)?,
        })
    }
}

#[derive(Clone, Debug, uniffi::Enum)]
pub enum ProxySettings {
    /// Ignore every proxy, including `HTTP_PROXY` style environment settings.
    NoProxy,
    CustomProxyList {
        proxies: Vec<CustomProxy>,
    },
}

impl From<ProxySettings> for CoreProxySettings {
    fn from(value: ProxySettings) -> Self {
        match value {
            ProxySettings::NoProxy => CoreProxySettings::NoProxy,
            ProxySettings::CustomProxyList { proxies } => CoreProxySettings::CustomProxyList(
                proxies.into_iter().map(CustomProxy::into_core).collect(),
            ),
        }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CustomProxy {
    pub url: String,
    pub condition: ProxyCondition,
}

impl CustomProxy {
    fn into_core(self) -> CoreCustomProxy {
        CoreCustomProxy {
            url: self.url,
            condition: self.condition.into(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum ProxyCondition {
    Http,
    Https,
    All,
}

impl From<ProxyCondition> for CoreProxyCondition {
    fn from(value: ProxyCondition) -> Self {
        match value {
            ProxyCondition::Http => CoreProxyCondition::Http,
            ProxyCondition::Https => CoreProxyCondition::Https,
            ProxyCondition::All => CoreProxyCondition::All,
        }
    }
}

#[derive(Clone, Debug, uniffi::Enum)]
pub enum RedirectSettings {
    NoRedirect,
    LimitedRedirects { max_redirects: u32 },
}

impl RedirectSettings {
    fn into_core(self) -> Result<CoreRedirectSettings, RhttpError> {
        match self {
            RedirectSettings::NoRedirect => Ok(CoreRedirectSettings::NoRedirect),
            RedirectSettings::LimitedRedirects { max_redirects } => {
                let max_redirects =
                    i32::try_from(max_redirects).map_err(|_| RhttpError::InvalidSettings {
                        message: format!("max_redirects {max_redirects} does not fit in i32"),
                    })?;
                Ok(CoreRedirectSettings::LimitedRedirects(max_redirects))
            }
        }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct TlsSettings {
    pub trust_root_certificates: bool,
    /// PEM-encoded additional root certificates.
    pub trusted_root_certificates: Vec<Vec<u8>>,
    pub verify_certificates: bool,
    pub client_certificate: Option<ClientCertificate>,
    pub min_tls_version: Option<TlsVersion>,
    pub max_tls_version: Option<TlsVersion>,
    pub sni: bool,
}

impl From<TlsSettings> for CoreTlsSettings {
    fn from(value: TlsSettings) -> Self {
        CoreTlsSettings {
            trust_root_certificates: value.trust_root_certificates,
            trusted_root_certificates: value.trusted_root_certificates,
            verify_certificates: value.verify_certificates,
            client_certificate: value.client_certificate.map(ClientCertificate::into_core),
            min_tls_version: value.min_tls_version.map(TlsVersion::into_core),
            max_tls_version: value.max_tls_version.map(TlsVersion::into_core),
            sni: value.sni,
        }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct ClientCertificate {
    pub certificate: Vec<u8>,
    pub private_key: Vec<u8>,
}

impl ClientCertificate {
    fn into_core(self) -> CoreClientCertificate {
        CoreClientCertificate {
            certificate: self.certificate,
            private_key: self.private_key,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum TlsVersion {
    Tls1_2,
    Tls1_3,
}

impl TlsVersion {
    fn into_core(self) -> CoreTlsVersion {
        match self {
            TlsVersion::Tls1_2 => CoreTlsVersion::Tls1_2,
            TlsVersion::Tls1_3 => CoreTlsVersion::Tls1_3,
        }
    }
}

#[derive(Clone, uniffi::Enum)]
pub enum DnsSettings {
    /// Resolve the listed hosts to fixed addresses; `fallback` is used for
    /// every other host.
    StaticDns {
        overrides: HashMap<String, Vec<String>>,
        fallback: Option<String>,
    },
    /// Ask the host application for addresses on every lookup.
    DynamicDns {
        resolver: Arc<dyn DnsResolverCallback>,
    },
}

impl std::fmt::Debug for DnsSettings {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DnsSettings::StaticDns {
                overrides,
                fallback,
            } => formatter
                .debug_struct("StaticDns")
                .field("overrides", overrides)
                .field("fallback", fallback)
                .finish(),
            // The host callback has no printable contents of its own.
            DnsSettings::DynamicDns { .. } => formatter.debug_struct("DynamicDns").finish(),
        }
    }
}

impl DnsSettings {
    fn into_core(self) -> CoreDnsSettings {
        match self {
            DnsSettings::StaticDns {
                overrides,
                fallback,
            } => CoreDnsSettings::StaticDns(CoreStaticDnsSettings {
                overrides,
                fallback,
            }),
            DnsSettings::DynamicDns { resolver } => {
                CoreDnsSettings::DynamicDns(CoreDynamicDnsSettings {
                    resolver: Arc::new(CallbackDnsResolver { callback: resolver }),
                })
            }
        }
    }
}

/// Host-implemented DNS resolution, the uniffi counterpart of the Dart
/// `DnsResolver` callback used by the Flutter Rust Bridge adapter.
///
/// The core contract is asynchronous; foreign trait methods are synchronous, so
/// the adapter runs this on a blocking worker of the tokio runtime. Keep the
/// implementation cheap and do not call it recursively from the same thread.
#[uniffi::export(foreign)]
pub trait DnsResolverCallback: Send + Sync {
    /// Return the addresses (IPv4 with optional port, or `host:port`) the host
    /// wants to use for `host`. An empty list signals "no answer".
    fn resolve(&self, host: String) -> Vec<String>;
}

struct CallbackDnsResolver {
    callback: Arc<dyn DnsResolverCallback>,
}

impl rhttp_core::DnsResolver for CallbackDnsResolver {
    fn resolve(&self, host: String) -> rhttp_core::DnsFuture {
        let callback = Arc::clone(&self.callback);
        Box::pin(async move {
            match tokio::task::spawn_blocking(move || callback.resolve(host)).await {
                Ok(addresses) => addresses,
                // The host callback panicked or the runtime is shutting down.
                // Answer with "no records": reqwest then reports its own DNS
                // error, which beats aborting the process under `panic = "abort"`.
                Err(_join_error) => Vec::new(),
            }
        })
    }
}

fn duration_to_core(value: Duration) -> Result<chrono::Duration, RhttpError> {
    chrono::Duration::from_std(value).map_err(|error| RhttpError::InvalidSettings {
        message: format!("duration is out of range: {error}"),
    })
}

fn optional_duration_to_core(
    value: Option<Duration>,
) -> Result<Option<chrono::Duration>, RhttpError> {
    match value {
        Some(value) => duration_to_core(value).map(Some),
        None => Ok(None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn options_with_every_field() -> ClientOptions {
        ClientOptions {
            user_agent: Some("rhttp-uniffi-test/1.0".to_string()),
            http_version_pref: HttpVersionPref::Http2,
            throw_on_status_code: false,
            cookie_settings: Some(CookieSettings {
                store_cookies: true,
            }),
            timeout_settings: Some(TimeoutSettings {
                timeout: Some(Duration::from_secs(9)),
                connect_timeout: Some(Duration::from_secs(3)),
                keep_alive_timeout: Some(Duration::from_millis(1500)),
                keep_alive_ping: Some(Duration::from_millis(500)),
            }),
            proxy_settings: Some(ProxySettings::CustomProxyList {
                proxies: vec![CustomProxy {
                    url: "http://127.0.0.1:7897".to_string(),
                    condition: ProxyCondition::Http,
                }],
            }),
            redirect_settings: Some(RedirectSettings::LimitedRedirects { max_redirects: 4 }),
            tls_settings: Some(TlsSettings {
                trust_root_certificates: false,
                trusted_root_certificates: vec![b"pem".to_vec()],
                verify_certificates: false,
                client_certificate: Some(ClientCertificate {
                    certificate: b"cert".to_vec(),
                    private_key: b"key".to_vec(),
                }),
                min_tls_version: Some(TlsVersion::Tls1_2),
                max_tls_version: Some(TlsVersion::Tls1_3),
                sni: false,
            }),
            dns_settings: Some(DnsSettings::StaticDns {
                overrides: HashMap::from([(
                    "example.com".to_string(),
                    vec!["1.1.1.1".to_string()],
                )]),
                fallback: Some("9.9.9.9".to_string()),
            }),
        }
    }

    #[test]
    fn every_setting_reaches_the_core_type() {
        let core = options_with_every_field()
            .into_core()
            .expect("settings convert");

        assert_eq!(core.user_agent.as_deref(), Some("rhttp-uniffi-test/1.0"));
        assert_eq!(core.http_version_pref, CoreHttpVersionPref::Http2);
        assert!(!core.throw_on_status_code);

        let cookies = core.cookie_settings.as_ref().expect("cookie settings");
        assert!(cookies.store_cookies);

        let timeouts = core.timeout_settings.as_ref().expect("timeout settings");
        assert_eq!(
            timeouts.timeout,
            Some(chrono::Duration::seconds(9)),
            "timeout must survive the std -> chrono conversion"
        );
        assert_eq!(timeouts.connect_timeout, Some(chrono::Duration::seconds(3)));
        assert_eq!(
            timeouts.keep_alive_timeout,
            Some(chrono::Duration::milliseconds(1500))
        );
        assert_eq!(
            timeouts.keep_alive_ping,
            Some(chrono::Duration::milliseconds(500))
        );

        match core.proxy_settings.as_ref().expect("proxy settings") {
            CoreProxySettings::CustomProxyList(proxies) => {
                assert_eq!(proxies.len(), 1);
                assert_eq!(proxies[0].url, "http://127.0.0.1:7897");
                assert_eq!(proxies[0].condition, CoreProxyCondition::Http);
            }
            CoreProxySettings::NoProxy => panic!("expected a custom proxy list"),
        }

        match core.redirect_settings.as_ref().expect("redirect settings") {
            CoreRedirectSettings::LimitedRedirects(count) => assert_eq!(*count, 4),
            CoreRedirectSettings::NoRedirect => panic!("expected limited redirects"),
        }

        let tls = core.tls_settings.as_ref().expect("tls settings");
        assert!(!tls.trust_root_certificates);
        assert_eq!(tls.trusted_root_certificates, vec![b"pem".to_vec()]);
        assert!(!tls.verify_certificates);
        assert_eq!(tls.min_tls_version, Some(CoreTlsVersion::Tls1_2));
        assert_eq!(tls.max_tls_version, Some(CoreTlsVersion::Tls1_3));
        assert!(!tls.sni);
        let certificate = tls.client_certificate.as_ref().expect("client certificate");
        assert_eq!(certificate.certificate, b"cert".to_vec());
        assert_eq!(certificate.private_key, b"key".to_vec());

        match core.dns_settings.as_ref().expect("dns settings") {
            CoreDnsSettings::StaticDns(static_dns) => {
                assert_eq!(
                    static_dns.overrides.get("example.com"),
                    Some(&vec!["1.1.1.1".to_string()])
                );
                assert_eq!(static_dns.fallback.as_deref(), Some("9.9.9.9"));
            }
            CoreDnsSettings::DynamicDns(_) => panic!("expected static dns"),
        }
    }

    struct FixedResolver {
        answer: Vec<String>,
    }

    impl DnsResolverCallback for FixedResolver {
        fn resolve(&self, _host: String) -> Vec<String> {
            self.answer.clone()
        }
    }

    #[tokio::test]
    async fn dynamic_dns_callback_bridges_into_the_core_resolver() {
        let resolver: Arc<dyn DnsResolverCallback> = Arc::new(FixedResolver {
            answer: vec!["1.2.3.4".to_string()],
        });

        let settings = DnsSettings::DynamicDns { resolver };
        let core = match settings.into_core() {
            CoreDnsSettings::DynamicDns(settings) => settings,
            CoreDnsSettings::StaticDns(_) => panic!("expected dynamic dns"),
        };

        // The foreign callback is synchronous while the core contract is async;
        // the bridge must still deliver the answer from a blocking worker.
        let addresses =
            rhttp_core::DnsResolver::resolve(core.resolver.as_ref(), "example.com".to_string())
                .await;
        assert_eq!(addresses, vec!["1.2.3.4".to_string()]);
    }

    #[test]
    fn default_options_match_the_core_defaults() {
        let core = default_client_options()
            .into_core()
            .expect("settings convert");
        let expected = CoreClientSettings::default();

        assert_eq!(core.user_agent, expected.user_agent);
        assert_eq!(core.http_version_pref, expected.http_version_pref);
        assert_eq!(core.throw_on_status_code, expected.throw_on_status_code);
        assert!(core.cookie_settings.is_none());
        assert!(core.timeout_settings.is_none());
        assert!(core.proxy_settings.is_none());
        assert!(core.redirect_settings.is_none());
        assert!(core.tls_settings.is_none());
        assert!(core.dns_settings.is_none());
    }
}
