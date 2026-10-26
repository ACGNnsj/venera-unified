use chrono::Duration;
use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

/// A DNS answer future returned by a host-provided resolver.
pub type DnsFuture = Pin<Box<dyn Future<Output = Vec<String>> + Send + 'static>>;

/// UI-neutral dynamic DNS resolver contract.
///
/// The FRB adapter implements this by awaiting `DartFnFuture<Vec<String>>`;
/// a future uniffi adapter can implement it with a callback interface.
pub trait DnsResolver: Send + Sync {
    fn resolve(&self, host: String) -> DnsFuture;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HttpVersionPref {
    Http10,
    Http11,
    Http2,
    Http3,
    All,
}

pub struct ClientSettings {
    pub cookie_settings: Option<CookieSettings>,
    pub http_version_pref: HttpVersionPref,
    pub timeout_settings: Option<TimeoutSettings>,
    pub throw_on_status_code: bool,
    pub proxy_settings: Option<ProxySettings>,
    pub redirect_settings: Option<RedirectSettings>,
    pub tls_settings: Option<TlsSettings>,
    pub dns_settings: Option<DnsSettings>,
    pub user_agent: Option<String>,
}

pub struct CookieSettings {
    pub store_cookies: bool,
}

pub enum ProxySettings {
    NoProxy,
    CustomProxyList(Vec<CustomProxy>),
}

pub struct CustomProxy {
    pub url: String,
    pub condition: ProxyCondition,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProxyCondition {
    Http,
    Https,
    All,
}

pub enum RedirectSettings {
    NoRedirect,
    LimitedRedirects(i32),
}

pub struct TimeoutSettings {
    pub timeout: Option<Duration>,
    pub connect_timeout: Option<Duration>,
    pub keep_alive_timeout: Option<Duration>,
    pub keep_alive_ping: Option<Duration>,
}

pub struct TlsSettings {
    pub trust_root_certificates: bool,
    pub trusted_root_certificates: Vec<Vec<u8>>,
    pub verify_certificates: bool,
    pub client_certificate: Option<ClientCertificate>,
    pub min_tls_version: Option<TlsVersion>,
    pub max_tls_version: Option<TlsVersion>,
    pub sni: bool,
}

pub enum DnsSettings {
    StaticDns(StaticDnsSettings),
    DynamicDns(DynamicDnsSettings),
}

pub struct StaticDnsSettings {
    pub overrides: HashMap<String, Vec<String>>,
    pub fallback: Option<String>,
}

pub struct DynamicDnsSettings {
    pub resolver: Arc<dyn DnsResolver>,
}

pub struct ClientCertificate {
    pub certificate: Vec<u8>,
    pub private_key: Vec<u8>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TlsVersion {
    Tls1_2,
    Tls1_3,
}

impl Default for ClientSettings {
    fn default() -> Self {
        ClientSettings {
            cookie_settings: None,
            http_version_pref: HttpVersionPref::All,
            timeout_settings: None,
            throw_on_status_code: true,
            proxy_settings: None,
            redirect_settings: None,
            tls_settings: None,
            dns_settings: None,
            user_agent: None,
        }
    }
}
